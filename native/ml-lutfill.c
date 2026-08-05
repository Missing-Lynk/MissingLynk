/**
 * @file ml-lutfill.c
 * @brief Fill a physical DRAM region with a pattern, for the ISP gamma LUT.
 *
 * The ISP reads its gamma/tone LUT by DMA from an address programmed into registers 0x0030,
 * 0x0040 and 0x0050. The vendor allocates a 16 KiB buffer, memcpy's the curve into it from
 * the tuning blob, flushes, and writes that buffer's device address into all three slots.
 *
 * Our register replay reproduces those writes, ending on the vendor's own physical addresses
 * inside the isp_cma reservation (gamma 0x2b2ec600, compander 0x2b2e0c00, DRC 0x2b2e9200), but
 * never puts anything at them. So the hardware fetches whatever those pages happen to contain.
 * The placeholder values 0x82000000/0x83000000/0x84000000 do appear earlier in the sequence and
 * are overwritten, so a claim that the slots point outside DRAM is wrong.
 *
 * The fetch is triggered by a pulse on ISP 0x0014 with the module's bits, issued after the
 * address is written, so a fill only takes effect if it happens before the replay reaches that
 * pulse. That is why filling after the arm changed nothing.
 *
 * No image defect is currently attributed to these tables. The tone response that originally
 * motivated this tool was measured on a DRAM buffer that nothing was writing, so it was not a
 * measurement of the ISP's output at all and the gamma theory remains untested.
 *
 * This tool writes a curve into a real address so the slots can be pointed at it. It
 * deliberately does not touch any register: use ml-regdump for that, so the two halves of the
 * experiment stay separable and a bad curve can be re-filled without re-arming anything.
 *
 * Word-at-a-time because dd on /dev/mem transfers nothing on this device, in both directions.
 *
 * Usage:
 *   ml-lutfill <phys> <count> ramp[:<max>]   ascending 0..max across count entries
 *   ml-lutfill <phys> <count> const:<hex>    every entry the same, the bluntest probe
 *   ml-lutfill <phys> <count> index          entry i = i
 *   ml-lutfill <phys> <count> read           print the first 16 entries, change nothing
 *   ml-lutfill <phys> <count> save:<path>    write the region out verbatim, change nothing
 *   ml-lutfill <phys> <count> load:<path>    fill from a file, for a real extracted curve
 *
 * Example, 4096 u32 slots at the top of the isp_cma reservation:
 *   ml-lutfill 0x2bf00000 4096 ramp:4095
 */
#include <fcntl.h>
#include <stdint.h>
#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include <sys/mman.h>
#include <unistd.h>

int main(int argc, char **argv)
{
    uint32_t phys, count, slack, base;
    const char *mode;
    volatile uint8_t *map;
    volatile uint32_t *lut;
    unsigned i;
    int fd;

    if (argc < 4) {
        fprintf(stderr,
            "usage: %s <phys> <count> ramp[:max] | const:<hex> | index | read"
            " | save:<path> | load:<path>\n",
            argv[0]);

        return 2;
    }

    phys = strtoul(argv[1], NULL, 0);
    count = strtoul(argv[2], NULL, 0);
    mode = argv[3];

    fd = open("/dev/mem", O_RDWR | O_SYNC);
    if (fd < 0) {
        perror("open /dev/mem");
        return 1;
    }

    slack = phys & 0xfffu;
    base = phys - slack;
    map = mmap(NULL, count * 4 + slack, PROT_READ | PROT_WRITE, MAP_SHARED, fd, base);
    if (map == MAP_FAILED) {
        perror("mmap");
        close(fd);
        return 1;
    }

    lut = (volatile uint32_t *)(map + slack);

    if (!strcmp(mode, "read")) {
        printf("0x%08x, first 16 of %u entries:\n", phys, count);
        for (i = 0; i < 16 && i < count; i++) {
            printf("  [%4u] 0x%08x\n", i, lut[i]);
        }
    } else if (!strncmp(mode, "save:", 5)) {
        /*
         * Copy the region out so it can be pulled to the host and
         * inspected. DDR survives a RAM-boot, so if the vendor stack
         * ran in slot A before us these addresses may still hold its
         * real tuning tables, which is worth more than any curve we
         * could synthesise. Word-at-a-time, matching the rest of this
         * tool, and read-only: nothing is written back.
         */
        FILE *f = fopen(mode + 5, "wb");

        if (!f) {
            perror("fopen");
            munmap((void *)map, count * 4 + slack);
            close(fd);
            return 1;
        }

        for (i = 0; i < count; i++) {
            uint32_t v = lut[i];

            if (fwrite(&v, sizeof(v), 1, f) != 1) {
                perror("fwrite");
                fclose(f);
                munmap((void *)map, count * 4 + slack);
                close(fd);
                return 1;
            }
        }

        fclose(f);
        printf("saved 0x%08x, %u entries, to %s\n", phys, count,
               mode + 5);
    } else if (!strncmp(mode, "load:", 5)) {
        /*
         * Fill from a file holding the table verbatim, little-endian
         * u32 per entry. This is how a curve extracted from the vendor
         * tuning blob gets in: a real curve is worth more than any
         * synthetic ramp, because a ramp only tests the mechanism
         * while the real one tests the mechanism and the source at
         * once. Short files are an error rather than a partial fill,
         * which would leave a torn table the hardware still fetches.
         */
        FILE *f = fopen(mode + 5, "rb");

        if (!f) {
            perror("fopen");
            munmap((void *)map, count * 4 + slack);
            close(fd);
            return 1;
        }

        for (i = 0; i < count; i++) {
            uint32_t val;

            if (fread(&val, sizeof(val), 1, f) != 1) {
                fprintf(stderr,
                    "%s: short file, %u of %u entries\n",
                    mode + 5, i, count);
                fclose(f);
                munmap((void *)map, count * 4 + slack);
                close(fd);

                return 1;
            }
            lut[i] = val;
        }

        fclose(f);
        printf("filled 0x%08x, %u entries, from %s\n", phys, count,
               mode + 5);
    } else if (!strncmp(mode, "const:", 6)) {
        uint32_t v = strtoul(mode + 6, NULL, 16);

        for (i = 0; i < count; i++) {
            lut[i] = v;
        }

        printf("filled 0x%08x, %u entries, constant 0x%08x\n", phys, count, v);
    } else if (!strcmp(mode, "index")) {
        for (i = 0; i < count; i++) {
            lut[i] = i;
        }

        printf("filled 0x%08x, %u entries, entry = index\n", phys, count);
    } else if (!strncmp(mode, "ramp", 4)) {
        uint32_t max = (mode[4] == ':') ? strtoul(mode + 5, NULL, 0) : 4095;

        for (i = 0; i < count; i++) {
            lut[i] = (uint32_t)(((uint64_t)i * max) / (count - 1));
        }

        printf("filled 0x%08x, %u entries, ramp 0..%u\n", phys, count, max);
    } else {
        fprintf(stderr, "unknown mode: %s\n", mode);
        munmap((void *)map, count * 4 + slack);
        close(fd);
        return 2;
    }

    munmap((void *)map, count * 4 + slack);
    close(fd);
    return 0;
}
