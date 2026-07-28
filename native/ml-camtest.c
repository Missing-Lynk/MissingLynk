/**
 * @file ml-camtest.c
 * @brief Air-unit camera capture-path bring-up and observation tool.
 *
 * The capture path is sensor -> MIPI CSI-2 -> VIF -> DDR, with the ISP reading frames back
 * out of DDR rather than sitting inline. The VIF therefore writes whole frames to memory,
 * and the addresses it writes to are held in its own register window.
 *
 * This tool exists to answer, on hardware and without a kernel driver, where those frames
 * land and what the working register configuration looks like. Run against the vendor stack
 * while it is streaming, the read-only subcommands capture a known-good configuration and
 * can pull a frame straight out of DDR; run against the open stack, the same subcommands
 * show what our own boot leaves behind.
 *
 * Everything is read-only unless the subcommand is explicitly a write. The write paths exist
 * for open-slot bring-up and must not be pointed at a running vendor stack.
 *
 * Register offsets and their meanings come from the vendor media library; the map is
 * documented alongside the reverse-engineering notes for the capture path.
 *
 * Build: see build.sh (static, aarch64).
 */
#include <errno.h>
#include <fcntl.h>
#include <stdint.h>
#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include <sys/ioctl.h>
#include <sys/mman.h>
#include <unistd.h>

#include <linux/i2c.h>
#include <linux/i2c-dev.h>

/** Page size used to align mmap windows; the SoC uses 4 KiB pages. */
#define PAGE_SIZE 4096

/** Video interface block, the DMA front end that writes frames to DDR. */
#define VIF_BASE 0x8870000

/** MIPI CSI-2 receiver block. Instances are paired: 0x1000 per pair, +0x400 within a pair. */
#define CSI_BASE 0x8880000

/** Clock generation unit leaf bank: the camera gates live here. */
#define CGU_LEAF_BASE 0x0a104000

/** Number of capture "views" the VIF exposes. */
#define VIF_VIEW_COUNT 8

/* VIF register offsets. The bypass family writes views straight to DDR; the ISP family
 * hands frames to the ISP. The vendor FPV pipeline drives the ISP family.
 */
#define VIF_VIEW_CONTROL      0x000   /**< + view*4, bit12 latches the buffer addresses. */
#define VIF_VIEW_ADDR_Y       0x020   /**< + view*4, Y plane physical address. */
#define VIF_VIEW_ADDR_U       0x040   /**< + view*4, U plane physical address. */
#define VIF_VIEW_ADDR_V       0x060   /**< + view*4, V plane physical address. */
#define VIF_ISP_PATH_FIRST    0x0c0   /**< First ISP-path configuration register. */
#define VIF_ISP_PATH_LAST     0x0ec   /**< Last ISP-path configuration register. */
#define VIF_MIPI_DATATYPE     0x0cc   /**< CSI-2 data type the VIF expects (0x2c = RAW12). */
#define VIF_GEOMETRY          0x0d8   /**< Frame geometry, width in the high half. */
#define VIF_VIEW_STRIDE       0x200   /**< + view*8, stride and count word 0. */
#define VIF_VIEW_DDR_SIZE_Y   0x340   /**< + view*4, Y plane DDR size. */
#define VIF_LINE_THRESHOLD    0x410   /**< + channel*4, low-delay line interrupt threshold. */

/** Sensor i2c address (7-bit) and its register-address width. */
#define SENSOR_I2C_ADDRESS 0x1a

/** Bytes read per line of a hexdump. */
#define HEXDUMP_LINE_BYTES 16

/** Largest single physical read this tool will perform, to bound the mapping. */
#define MAX_READ_BYTES (64u * 1024u * 1024u)

/**
 * @brief Map the page-aligned region covering @p physical_address for @p byte_length bytes.
 *
 * @param mem_fd              open file descriptor for /dev/mem.
 * @param physical_address    physical address of the first byte of interest.
 * @param byte_length         number of bytes that must be covered.
 * @param writable            map with write permission as well as read.
 * @param mapping_out         receives the mapping base (page aligned).
 * @param mapping_length_out  receives the mapped length.
 *
 * @return pointer to @p physical_address inside the mapping, or NULL on failure.
 */
static void *map_physical(int mem_fd, uint64_t physical_address, size_t byte_length,
                          int writable, void **mapping_out, size_t *mapping_length_out)
{
    uint64_t page_base = physical_address & ~((uint64_t)PAGE_SIZE - 1);
    size_t page_offset = (size_t)(physical_address - page_base);
    size_t mapping_length = page_offset + byte_length;
    int protection = PROT_READ;
    void *mapping;

    /* Round the mapping up to a whole number of pages. */
    mapping_length = (mapping_length + PAGE_SIZE - 1) & ~((size_t)PAGE_SIZE - 1);

    if (writable) {
        protection |= PROT_WRITE;
    }

    mapping = mmap(NULL, mapping_length, protection, MAP_SHARED, mem_fd, (off_t)page_base);
    if (mapping == MAP_FAILED) {
        perror("ml-camtest: mmap");
        return NULL;
    }

    *mapping_out = mapping;
    *mapping_length_out = mapping_length;

    return (char *)mapping + page_offset;
}

/**
 * @brief Read one 32-bit register from a block.
 *
 * @param mem_fd    open file descriptor for /dev/mem.
 * @param base      physical base address of the block.
 * @param offset    byte offset within the block.
 * @param value_out receives the register value.
 *
 * @return 0 on success, 1 on failure.
 */
static int read_register(int mem_fd, uint64_t base, uint32_t offset, uint32_t *value_out)
{
    void *mapping = NULL;
    size_t mapping_length = 0;
    volatile uint32_t *reg;

    reg = map_physical(mem_fd, base + offset, sizeof(uint32_t), 0, &mapping, &mapping_length);
    if (reg == NULL) {
        return 1;
    }

    *value_out = *reg;
    munmap(mapping, mapping_length);

    return 0;
}

/**
 * @brief Print a labelled window of 32-bit registers, four per line.
 *
 * @param mem_fd      open file descriptor for /dev/mem.
 * @param label       human-readable name printed above the dump.
 * @param base        physical base address of the block.
 * @param offset      byte offset of the first register.
 * @param word_count  number of 32-bit words to print.
 *
 * @return 0 on success, 1 on failure.
 */
static int dump_window(int mem_fd, const char *label, uint64_t base, uint32_t offset,
                       size_t word_count)
{
    void *mapping = NULL;
    size_t mapping_length = 0;
    volatile uint32_t *registers;
    size_t index;

    registers = map_physical(mem_fd, base + offset, word_count * sizeof(uint32_t), 0,
                             &mapping, &mapping_length);
    if (registers == NULL) {
        return 1;
    }

    printf("--- %s (0x%08llx + 0x%03x, %zu words) ---\n", label,
           (unsigned long long)base, offset, word_count);

    for (index = 0; index < word_count; index++) {
        if ((index % 4) == 0) {
            printf("%s+0x%03zx:", (index == 0) ? "" : "\n",
                   offset + index * sizeof(uint32_t));
        }

        printf(" %08x", registers[index]);
    }

    printf("\n");
    munmap(mapping, mapping_length);

    return 0;
}

/**
 * @brief Open the sensor's i2c bus and select the sensor address.
 *
 * The sensor uses 16-bit register addresses, which the SMBus helpers cannot express, so
 * every transfer is issued as a raw two-message I2C_RDWR with a repeated start.
 *
 * @param bus_number i2c adapter number the sensor sits on.
 *
 * @return open file descriptor, or -1 on failure.
 */
static int open_sensor_bus(int bus_number)
{
    char path[32];
    int fd;

    snprintf(path, sizeof(path), "/dev/i2c-%d", bus_number);

    fd = open(path, O_RDWR);
    if (fd < 0) {
        fprintf(stderr, "ml-camtest: open %s: %s\n", path, strerror(errno));
        return -1;
    }

    return fd;
}

/**
 * @brief Read one 8-bit sensor register.
 *
 * @param bus_fd     open i2c adapter file descriptor.
 * @param reg        16-bit register address.
 * @param value_out  receives the register value.
 *
 * @return 0 on success, 1 on failure.
 */
static int sensor_read(int bus_fd, uint16_t reg, uint8_t *value_out)
{
    uint8_t address_buffer[2] = { (uint8_t)(reg >> 8), (uint8_t)(reg & 0xff) };
    struct i2c_msg messages[2];
    struct i2c_rdwr_ioctl_data transfer;

    messages[0].addr = SENSOR_I2C_ADDRESS;
    messages[0].flags = 0;
    messages[0].len = sizeof(address_buffer);
    messages[0].buf = address_buffer;

    messages[1].addr = SENSOR_I2C_ADDRESS;
    messages[1].flags = I2C_M_RD;
    messages[1].len = 1;
    messages[1].buf = value_out;

    transfer.msgs = messages;
    transfer.nmsgs = 2;

    if (ioctl(bus_fd, I2C_RDWR, &transfer) < 0) {
        fprintf(stderr, "ml-camtest: read sensor 0x%04x: %s\n", reg, strerror(errno));
        return 1;
    }

    return 0;
}

/**
 * @brief Print the sensor state that identifies the running mode.
 *
 * @param bus_number i2c adapter the sensor sits on.
 *
 * @return 0 on success, 1 on failure.
 */
static int report_sensor(int bus_number)
{
    static const struct {
        uint16_t reg;
        const char *meaning;
    } interesting[] = {
        { 0x0000, "model id high (expect 0x92)" },
        { 0x0001, "model id low (expect 0x35)" },
        { 0x0100, "mode select (1 = streaming)" },
        { 0x0114, "lane mode (0x01 = 2 lanes, 0x03 = 4 lanes)" },
        { 0x030f, "pll (0x4b with 2 lanes, 0x26 with 4)" },
        { 0x0340, "frame length high" },
        { 0x0341, "frame length low" },
        { 0x034c, "output width high" },
        { 0x034d, "output width low" },
        { 0x034e, "output height high" },
        { 0x034f, "output height low" },
    };
    size_t index;
    int bus_fd;
    int failures = 0;

    bus_fd = open_sensor_bus(bus_number);
    if (bus_fd < 0) {
        return 1;
    }

    printf("--- sensor (i2c-%d, 7-bit 0x%02x) ---\n", bus_number, SENSOR_I2C_ADDRESS);

    for (index = 0; index < sizeof(interesting) / sizeof(interesting[0]); index++) {
        uint8_t value;

        if (sensor_read(bus_fd, interesting[index].reg, &value) != 0) {
            failures++;
            continue;
        }

        printf("0x%04x = 0x%02x   %s\n", interesting[index].reg, value,
               interesting[index].meaning);
    }

    close(bus_fd);

    return failures ? 1 : 0;
}

/**
 * @brief Dump every register window the capture path uses.
 *
 * Read-only. Safe to run against a live vendor stack, and the whole point of running it
 * there: it captures a known-good configuration of blocks we have no driver for.
 *
 * @param mem_fd     open file descriptor for /dev/mem.
 * @param bus_number i2c adapter the sensor sits on, or -1 to skip the sensor.
 *
 * @return 0 on success, 1 if any window failed to map.
 */
static int command_snapshot(int mem_fd, int bus_number)
{
    int failures = 0;

    /* VIF: the per-view control and buffer banks, the ISP-path configuration, the stride
     * bank, the DDR sizes, and the low-delay line thresholds.
     */
    failures += dump_window(mem_fd, "vif view control + buffers", VIF_BASE, 0x000, 48);
    failures += dump_window(mem_fd, "vif isp path + geometry", VIF_BASE, 0x0c0, 16);
    failures += dump_window(mem_fd, "vif stride bank", VIF_BASE, 0x200, 32);
    failures += dump_window(mem_fd, "vif ddr sizes", VIF_BASE, 0x340, 32);
    failures += dump_window(mem_fd, "vif line thresholds", VIF_BASE, 0x400, 16);

    /* CSI-2: the shared head plus the first two per-instance windows. */
    failures += dump_window(mem_fd, "csi head", CSI_BASE, 0x000, 32);
    failures += dump_window(mem_fd, "csi instance 0", CSI_BASE, 0x400, 48);
    failures += dump_window(mem_fd, "csi instance 1", CSI_BASE, 0x800, 48);

    /* CGU: which camera clocks are gated on. */
    failures += dump_window(mem_fd, "cgu leaf bank", CGU_LEAF_BASE, 0x000, 24);

    if (bus_number >= 0) {
        failures += report_sensor(bus_number);
    }

    return failures ? 1 : 0;
}

/**
 * @brief Judge whether a block of memory plausibly holds image data.
 *
 * A frame buffer is neither all one value nor uniformly random: it has many distinct byte
 * values but a strong local correlation. Two cheap statistics separate a live frame from
 * both an untouched buffer and unrelated memory well enough to decide where to look next.
 *
 * @param data   buffer to examine.
 * @param length number of bytes to examine.
 */
static void report_content(const uint8_t *data, size_t length)
{
    size_t histogram[256];
    size_t distinct = 0;
    size_t nonzero = 0;
    uint64_t neighbour_delta = 0;
    size_t index;

    memset(histogram, 0, sizeof(histogram));

    for (index = 0; index < length; index++) {
        histogram[data[index]]++;

        if (data[index] != 0) {
            nonzero++;
        }

        if (index > 0) {
            int delta = (int)data[index] - (int)data[index - 1];

            neighbour_delta += (uint64_t)(delta < 0 ? -delta : delta);
        }
    }

    for (index = 0; index < 256; index++) {
        if (histogram[index] != 0) {
            distinct++;
        }
    }

    printf("  %zu bytes: %zu distinct values, %.1f%% non-zero, mean neighbour delta %.1f\n",
           length, distinct, 100.0 * (double)nonzero / (double)length,
           length > 1 ? (double)neighbour_delta / (double)(length - 1) : 0.0);

    if (distinct < 4) {
        printf("  verdict: flat, this is not a frame\n");
    } else if (distinct > 64 && nonzero * 4 > length) {
        printf("  verdict: plausibly a frame\n");
    } else {
        printf("  verdict: has structure but is sparse, inspect before trusting\n");
    }
}

/**
 * @brief Print the first bytes of a buffer as a hexdump.
 *
 * @param data   buffer to print.
 * @param length number of bytes to print.
 */
static void hexdump(const uint8_t *data, size_t length)
{
    size_t index;

    for (index = 0; index < length; index++) {
        if ((index % HEXDUMP_LINE_BYTES) == 0) {
            printf("%s  %04zx:", (index == 0) ? "" : "\n", index);
        }

        printf(" %02x", data[index]);
    }

    printf("\n");
}

/**
 * @brief Report where the VIF is currently writing frames, and what is at those addresses.
 *
 * Reads the per-view buffer address registers and the ISP-path configuration, then examines
 * the memory each plausible address points at. Read-only.
 *
 * @param mem_fd open file descriptor for /dev/mem.
 *
 * @return 0 on success, 1 on failure.
 */
static int command_findbuf(int mem_fd)
{
    uint32_t geometry;
    uint32_t datatype;
    unsigned int view;

    if (read_register(mem_fd, VIF_BASE, VIF_GEOMETRY, &geometry) != 0 ||
        read_register(mem_fd, VIF_BASE, VIF_MIPI_DATATYPE, &datatype) != 0) {
        return 1;
    }

    printf("vif geometry 0x%08x = %u x %u, csi data type 0x%02x%s\n", geometry,
           geometry >> 16, geometry & 0xffff, datatype & 0xff,
           (datatype & 0xff) == 0x2c ? " (RAW12)" : "");

    for (view = 0; view < VIF_VIEW_COUNT; view++) {
        uint32_t control;
        uint32_t address;
        uint32_t ddr_size;
        void *mapping = NULL;
        size_t mapping_length = 0;
        size_t probe_length;
        uint8_t *frame;

        if (read_register(mem_fd, VIF_BASE, VIF_VIEW_CONTROL + view * 4, &control) != 0 ||
            read_register(mem_fd, VIF_BASE, VIF_VIEW_ADDR_Y + view * 4, &address) != 0 ||
            read_register(mem_fd, VIF_BASE, VIF_VIEW_DDR_SIZE_Y + view * 4, &ddr_size) != 0) {
            return 1;
        }

        printf("view %u: control 0x%08x  y address 0x%08x  ddr size 0x%08x\n",
               view, control, address, ddr_size);

        /* 0 and 0x80000000 are the values an unprogrammed view carries; anything else is
         * a real DDR target worth looking at.
         */
        if (address == 0 || address == 0x80000000u) {
            continue;
        }

        probe_length = 4096;
        frame = map_physical(mem_fd, address, probe_length, 0, &mapping, &mapping_length);
        if (frame == NULL) {
            continue;
        }

        report_content(frame, probe_length);
        hexdump(frame, 64);
        munmap(mapping, mapping_length);
    }

    return 0;
}

/**
 * @brief Copy a span of physical memory into a file.
 *
 * The intended use is pulling a frame the VIF has written out of DDR so it can be debayered
 * on a host. Read-only with respect to the device.
 *
 * @param mem_fd            open file descriptor for /dev/mem.
 * @param physical_address  first byte to copy.
 * @param byte_length       number of bytes to copy.
 * @param path              destination file.
 *
 * @return 0 on success, 1 on failure.
 */
static int command_grab(int mem_fd, uint64_t physical_address, size_t byte_length,
                        const char *path)
{
    void *mapping = NULL;
    size_t mapping_length = 0;
    uint8_t *source;
    FILE *output;
    size_t written;

    if (byte_length == 0 || byte_length > MAX_READ_BYTES) {
        fprintf(stderr, "ml-camtest: length must be 1..%u bytes\n", MAX_READ_BYTES);
        return 1;
    }

    source = map_physical(mem_fd, physical_address, byte_length, 0, &mapping, &mapping_length);
    if (source == NULL) {
        return 1;
    }

    output = fopen(path, "wb");
    if (output == NULL) {
        fprintf(stderr, "ml-camtest: open %s: %s\n", path, strerror(errno));
        munmap(mapping, mapping_length);
        return 1;
    }

    written = fwrite(source, 1, byte_length, output);
    fclose(output);

    report_content(source, byte_length < 65536 ? byte_length : 65536);
    munmap(mapping, mapping_length);

    if (written != byte_length) {
        fprintf(stderr, "ml-camtest: short write to %s (%zu of %zu)\n", path, written,
                byte_length);
        return 1;
    }

    printf("wrote %zu bytes from 0x%08llx to %s\n", byte_length,
           (unsigned long long)physical_address, path);

    return 0;
}

/**
 * @brief Watch a VIF buffer address register and report how often it changes.
 *
 * The VIF rotates buffer addresses from its frame-done interrupt handler, so a changing
 * address register is direct evidence that frames are completing, without needing to
 * interpret the frames themselves.
 *
 * @param mem_fd  open file descriptor for /dev/mem.
 * @param view    view index to watch.
 * @param seconds how long to watch for.
 *
 * @return 0 on success, 1 on failure.
 */
static int command_watch(int mem_fd, unsigned int view, unsigned int seconds)
{
    uint32_t previous = 0;
    unsigned int changes = 0;
    unsigned int elapsed;

    if (view >= VIF_VIEW_COUNT) {
        fprintf(stderr, "ml-camtest: view must be 0..%d\n", VIF_VIEW_COUNT - 1);
        return 1;
    }

    if (read_register(mem_fd, VIF_BASE, VIF_VIEW_ADDR_Y + view * 4, &previous) != 0) {
        return 1;
    }

    printf("watching view %u buffer address for %u seconds (start 0x%08x)\n", view, seconds,
           previous);

    for (elapsed = 0; elapsed < seconds * 100; elapsed++) {
        uint32_t current;

        usleep(10000);

        if (read_register(mem_fd, VIF_BASE, VIF_VIEW_ADDR_Y + view * 4, &current) != 0) {
            return 1;
        }

        if (current != previous) {
            changes++;
            previous = current;
        }
    }

    printf("%u address changes in %u seconds (%.1f per second)\n", changes, seconds,
           (double)changes / (double)seconds);

    if (changes == 0) {
        printf("verdict: this view is not rotating buffers, it is not capturing\n");
    }

    return 0;
}

/**
 * @brief Print usage.
 */
static void print_usage(void)
{
    fprintf(stderr,
            "usage: ml-camtest <command> [arguments]\n"
            "\n"
            "  snapshot [i2c_bus]        dump every capture-path register window (read-only)\n"
            "  findbuf                   report where the VIF writes frames and what is there\n"
            "  grab <addr> <len> <file>  copy physical memory to a file (pull a frame)\n"
            "  watch <view> <seconds>    report how often a view rotates its buffer address\n"
            "\n"
            "Every command is read-only. Run against the vendor stack while it streams to\n"
            "capture a working configuration.\n");
}

/**
 * @brief Entry point: parse arguments and dispatch to a subcommand.
 */
int main(int argc, char **argv)
{
    int mem_fd;
    int result;

    if (argc < 2) {
        print_usage();
        return 2;
    }

    mem_fd = open("/dev/mem", O_RDWR | O_SYNC);
    if (mem_fd < 0) {
        perror("ml-camtest: open /dev/mem");
        return 1;
    }

    if (strcmp(argv[1], "snapshot") == 0) {
        int bus_number = (argc >= 3) ? atoi(argv[2]) : 0;

        result = command_snapshot(mem_fd, bus_number);
    } else if (strcmp(argv[1], "findbuf") == 0) {
        result = command_findbuf(mem_fd);
    } else if (strcmp(argv[1], "grab") == 0) {
        if (argc < 5) {
            fprintf(stderr, "ml-camtest: grab needs an address, a length and a file\n");
            close(mem_fd);
            return 2;
        }

        result = command_grab(mem_fd, strtoull(argv[2], NULL, 0),
                              (size_t)strtoull(argv[3], NULL, 0), argv[4]);
    } else if (strcmp(argv[1], "watch") == 0) {
        if (argc < 4) {
            fprintf(stderr, "ml-camtest: watch needs a view index and a duration\n");
            close(mem_fd);
            return 2;
        }

        result = command_watch(mem_fd, (unsigned int)strtoul(argv[2], NULL, 0),
                               (unsigned int)strtoul(argv[3], NULL, 0));
    } else {
        print_usage();
        result = 2;
    }

    close(mem_fd);

    return result;
}
