/**
 * @file ml-mmioreplay.c
 * @brief Replay a captured list of MMIO register writes through /dev/mem, fast.
 *
 * Reads a file of "0xADDR 0xVAL" lines (a write trace from the mmiotrace tool) and
 * applies every write in order to the mapped media register block. A single mmap
 * covers the whole VIF/CSI/ISP window, so all writes land in one process in
 * milliseconds - unlike one ml-regdump fork per write, which spreads a 48k-write
 * sequence over minutes and breaks any timing-sensitive strobe. This exists to test
 * whether replaying the vendor's exact register sequence drives the hardware, before
 * that sequence is encoded in a driver. Bring-up only; never against a running vendor.
 *
 * Build: see build.sh (static, aarch64).
 * Use:   ml-mmioreplay <pairs-file>
 *          each line: "0x<physaddr> 0x<value>" (extra columns ignored)
 *        Env MMIO_BASE / MMIO_SPAN override the mapped window (defaults cover the
 *        media blocks 0x08800000 + 0x00500000).
 */
#include <fcntl.h>
#include <inttypes.h>
#include <stdint.h>
#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include <sys/mman.h>
#include <unistd.h>

#define PAGE_SIZE 4096

int main(int argc, char **argv)
{
    if (argc < 2) {
        fprintf(stderr, "usage: ml-mmioreplay <pairs-file>\n");
        return 2;
    }

    uint64_t base = 0x08800000;
    size_t span = 0x00500000;
    const char *e;

    if ((e = getenv("MMIO_BASE")) != NULL) {
        base = strtoull(e, NULL, 0);
    }
    if ((e = getenv("MMIO_SPAN")) != NULL) {
        span = (size_t)strtoull(e, NULL, 0);
    }
    /* Page align the base down and round the span up. */
    uint64_t page_base = base & ~((uint64_t)PAGE_SIZE - 1);
    span = (span + (base - page_base) + PAGE_SIZE - 1) & ~((size_t)PAGE_SIZE - 1);

    FILE *fp = fopen(argv[1], "r");
    if (fp == NULL) {
        perror("ml-mmioreplay: open pairs");
        return 1;
    }

    int mem_fd = open("/dev/mem", O_RDWR | O_SYNC);
    if (mem_fd < 0) {
        perror("ml-mmioreplay: /dev/mem");
        fclose(fp);
        return 1;
    }

    volatile uint8_t *map = mmap(NULL, span, PROT_READ | PROT_WRITE, MAP_SHARED, mem_fd,
                                 (off_t)page_base);
    if (map == MAP_FAILED) {
        perror("ml-mmioreplay: mmap");
        close(mem_fd);
        fclose(fp);
        return 1;
    }

    char line[256];
    unsigned long applied = 0;
    unsigned long skipped = 0;

    while (fgets(line, sizeof(line), fp) != NULL) {
        uint64_t addr;
        uint32_t val;

        /* Accept "0xADDR 0xVAL ...". strtoull handles the 0x prefix. */
        char *p = line;
        while (*p == ' ' || *p == '\t') {
            p++;
        }
        if (*p == '\0' || *p == '\n' || *p == '#') {
            continue;
        }

        char *end;
        addr = strtoull(p, &end, 0);
        if (end == p) {
            continue;
        }
        val = (uint32_t)strtoul(end, &end, 0);

        if (addr < page_base || addr + 4 > page_base + span) {
            skipped++;
            continue;
        }

        *(volatile uint32_t *)(map + (addr - page_base)) = val;
        applied++;
    }

    munmap((void *)map, span);
    close(mem_fd);
    fclose(fp);

    printf("ml-mmioreplay: applied %lu writes, skipped %lu (out of window 0x%" PRIx64
           "+0x%zx)\n",
           applied, skipped, page_base, span);
    return 0;
}
