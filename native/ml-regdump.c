/**
 * @file ml-regdump.c
 * @brief Dump a window of 32-bit MMIO registers through /dev/mem.
 *
 * Reads a contiguous run of 32-bit registers from a physical base address and prints them as
 * offset/value pairs. Intended for observing a live hardware block: one invocation dumps a whole
 * register window, where busybox devmem needs one process per word.
 *
 * Reading is the default and the only mode that touches nothing. The optional write mode exists
 * for bring-up work and must not be used against a running vendor stack.
 *
 * Build: see build.sh (static, aarch64).
 * Use:   ml-regdump <base> [word_count]      dump word_count words from base (default 16)
 *        ml-regdump -w <address> <value>     write one 32-bit word (bring-up only)
 */
#include <fcntl.h>
#include <stdint.h>
#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include <sys/mman.h>
#include <unistd.h>

/** Page size used to align the mmap window; the SoC uses 4 KiB pages. */
#define PAGE_SIZE 4096

/** Largest number of words a single dump may request, to bound the mapping. */
#define MAX_WORD_COUNT 8192

/**
 * @brief Map the page-aligned region covering @p physical_address for @p byte_length bytes.
 *
 * @param mem_fd          open file descriptor for /dev/mem.
 * @param physical_address physical address of the first byte of interest.
 * @param byte_length     number of bytes that must be covered.
 * @param writable        map with write permission as well as read.
 * @param mapping_out     receives the mapping base (page aligned).
 * @param mapping_length_out receives the mapped length.
 *
 * @return pointer to @p physical_address inside the mapping, or NULL on failure.
 */
static volatile uint32_t *map_register_window(int mem_fd, uint64_t physical_address,
                                              size_t byte_length, int writable,
                                              void **mapping_out, size_t *mapping_length_out)
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
        perror("ml-regdump: mmap");
        return NULL;
    }

    *mapping_out = mapping;
    *mapping_length_out = mapping_length;

    return (volatile uint32_t *)((char *)mapping + page_offset);
}

/**
 * @brief Print @p word_count registers starting at @p physical_address, 4 per line.
 *
 * @param mem_fd           open file descriptor for /dev/mem.
 * @param physical_address physical address of the first register.
 * @param word_count       number of 32-bit words to read.
 *
 * @return 0 on success, 1 on failure.
 */
static int dump_registers(int mem_fd, uint64_t physical_address, size_t word_count)
{
    void *mapping = NULL;
    size_t mapping_length = 0;
    volatile uint32_t *registers;

    registers = map_register_window(mem_fd, physical_address, word_count * sizeof(uint32_t), 0,
                                    &mapping, &mapping_length);
    if (registers == NULL) {
        return 1;
    }

    for (size_t i = 0; i < word_count; i++) {
        /* Start a new line every 4 words, labelled with the offset from the base. */
        if ((i % 4) == 0) {
            printf("%s+0x%04zx:", (i == 0) ? "" : "\n", i * sizeof(uint32_t));
        }

        printf(" %08x", registers[i]);
    }

    printf("\n");
    munmap(mapping, mapping_length);

    return 0;
}

/**
 * @brief Write one 32-bit register.
 *
 * @param mem_fd           open file descriptor for /dev/mem.
 * @param physical_address physical address of the register.
 * @param value            value to write.
 *
 * @return 0 on success, 1 on failure.
 */
static int write_register(int mem_fd, uint64_t physical_address, uint32_t value)
{
    void *mapping = NULL;
    size_t mapping_length = 0;
    volatile uint32_t *registers;

    registers = map_register_window(mem_fd, physical_address, sizeof(uint32_t), 1, &mapping,
                                    &mapping_length);
    if (registers == NULL) {
        return 1;
    }

    registers[0] = value;
    printf("wrote 0x%08x -> 0x%08llx (reads back 0x%08x)\n", value,
           (unsigned long long)physical_address, registers[0]);

    munmap(mapping, mapping_length);

    return 0;
}

/**
 * @brief Entry point: parse arguments and dispatch to the dump or write path.
 */
int main(int argc, char **argv)
{
    int mem_fd;
    int result;

    if (argc < 2) {
        fprintf(stderr,
                "usage: ml-regdump <base> [word_count]   dump registers (default 16 words)\n"
                "       ml-regdump -w <address> <value>  write one word (bring-up only)\n");
        return 2;
    }

    mem_fd = open("/dev/mem", O_RDWR | O_SYNC);
    if (mem_fd < 0) {
        perror("ml-regdump: open /dev/mem");
        return 1;
    }

    if (strcmp(argv[1], "-w") == 0) {
        if (argc < 4) {
            fprintf(stderr, "ml-regdump: -w needs an address and a value\n");
            close(mem_fd);
            return 2;
        }

        result = write_register(mem_fd, strtoull(argv[2], NULL, 0),
                                (uint32_t)strtoul(argv[3], NULL, 0));
    } else {
        size_t word_count = (argc >= 3) ? (size_t)strtoul(argv[2], NULL, 0) : 16;

        if (word_count == 0 || word_count > MAX_WORD_COUNT) {
            fprintf(stderr, "ml-regdump: word_count must be 1..%d\n", MAX_WORD_COUNT);
            close(mem_fd);
            return 2;
        }

        result = dump_registers(mem_fd, strtoull(argv[1], NULL, 0), word_count);
    }

    close(mem_fd);

    return result;
}
