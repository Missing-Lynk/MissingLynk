/* Bare-metal AR9301 qspi SPI-NAND WRITER: restore the known-good slot-A gpt0 to flash, run as a
   downloaded .GMI payload via the BootROM. Flips the active A/B slot back to A.

   gpt0 = flash 0x100000 = blocks 8,9 = pages 512..639 (128 pages x 2048 = 256 KiB).
   Embedded gpt0_data[] (data.S .incbin of out/P1_GND/mtd5-gpt0.bin, the verified A-active dump).
   Sequence: pre-read sanity (EFI PART) -> erase block 8,9 -> program pages 512..639 ->
   read-back + byte-compare EVERY page -> only print success if verify is perfect.
   Any erase/program/verify failure prints the spot and stops (writes nothing further).
*/
#include <stdint.h>

#define QSPI_BASE   0x01e00000u
#define R_CTRL 0x04
#define R_LANE 0x10
#define R_CMD 0x14
#define R_ADDR 0x18
#define R_DATALEN 0x1c
#define R_DMACTRL 0x20
#define R_STATUS0 0x30
#define R_FIFOSTAT 0x34
#define R_IRQ_EN 0x40
#define R_RX_FIFO 0x100
#define R_TX_FIFO 0x200
#define STATUS0_BUSY (1u<<0)
#define FST_RX_LEVEL(s) ((s)&0x7f)
#define FST_RX_EMPTY (1u<<7)
#define FST_TX_FREE(s) (((s)>>8)&0x7f)
#define FIFO_WORDS 0x40
#define LANE_ARM 0x00000001u
#define OP_WREN 0x06
#define OP_SET_FEAT 0x1f
#define OP_GET_FEAT 0x0f
#define OP_BLOCK_ERASE 0xd8
#define OP_PROG_LOAD 0x02
#define OP_PROG_EXEC 0x10
#define OP_PAGE_READ 0x13
#define OP_READ_CACHE 0x0b
#define FEAT_PROTECT 0xa0
#define FEAT_STATUS 0xc0
#define PAGE_SIZE 2048u
#define PAGES_PER_BLOCK 64u
#define STAT_BUSY 0x01          /* NAND status: operation in progress */
#define STAT_ERASE_FAIL 0x04    /* NAND status: last block-erase failed */
#define STAT_PROG_FAIL 0x08     /* NAND status: last page-program failed */
#define UART_BASE 0x01500000u

static inline void w32(uint32_t v, uint32_t a)
{
    *(volatile uint32_t *)(uintptr_t)a = v;
}

static inline void w8(uint8_t v, uint32_t a)
{
    *(volatile uint8_t *)(uintptr_t)a = v;
}

static inline uint32_t r32(uint32_t a)
{
    return *(volatile uint32_t *)(uintptr_t)a;
}

#define REG(o) (QSPI_BASE+(o))

static void uputc(char c)
{
    while (!(r32(UART_BASE + 0x14) & (1u << 5))) {
    }
    w32((uint32_t)(uint8_t)c, UART_BASE);
}

static void uputs(const char *s)
{
    while (*s) {
        uputc(*s++);
    }
}

static void uhex8(uint8_t b)
{
    const char *h = "0123456789abcdef";
    uputc(h[b >> 4]);
    uputc(h[b & 0xf]);
}

static void uhex16(uint16_t v)
{
    uhex8(v >> 8);
    uhex8(v & 0xff);
}

static uint32_t cmd_word(uint8_t op, uint32_t ab, uint32_t db, int out)
{
    return (uint32_t)op | ((ab & 7u) << 8) | ((db & 0xfu) << 12) | (out ? (1u << 24) : 0u);
}

static void wait_idle(void)
{
    while (r32(REG(R_STATUS0)) & STATUS0_BUSY) {
    }
}

static void send_cmd(uint8_t op, uint32_t ab, uint32_t addr, uint32_t db, uint32_t dl, int out)
{
    wait_idle();
    w32(cmd_word(op, ab, db, out), REG(R_CMD));
    if (ab) {
        w32(addr, REG(R_ADDR));
    }

    w32(dl, REG(R_DATALEN));
    w32(LANE_ARM, REG(R_LANE));
}

static void tx_push(const uint8_t *buf, uint32_t len)
{
    uint32_t words = len / 4, tail = len % 4;
    while (words) {
        uint32_t s = r32(REG(R_FIFOSTAT)), n = FST_TX_FREE(s);
        if (!n) {
            continue;
        }

        if (n > words) {
            n = words;
        }

        while (n--) {
            uint32_t w;
            __builtin_memcpy(&w, buf, 4);
            w32(w, REG(R_TX_FIFO));
            buf += 4;
            words--;
        }
    }

    for (uint32_t i = 0; i < tail; i++) {
        w8(buf[i], REG(R_TX_FIFO));
    }
}

static void tx_wait_drained(void)
{
    while (FST_TX_FREE(r32(REG(R_FIFOSTAT))) != FIFO_WORDS) {
    }
}

static void rx_drain(uint8_t *buf, uint32_t len)
{
    uint32_t words = len / 4, tail = len % 4;
    while (words) {
        uint32_t s = r32(REG(R_FIFOSTAT)), n = FST_RX_LEVEL(s);
        if (!n) {
            continue;
        }

        if (n > words) {
            n = words;
        }

        while (n--) {
            uint32_t w = r32(REG(R_RX_FIFO));
            __builtin_memcpy(buf, &w, 4);
            buf += 4;
            words--;
        }
    }

    if (tail) {
        uint32_t w;
        while (r32(REG(R_FIFOSTAT)) & FST_RX_EMPTY) {
        }

        w = r32(REG(R_RX_FIFO));
        for (uint32_t i = 0; i < tail; i++) {
            buf[i] = (uint8_t)(w >> (8 * i));
        }
    }
}

static void quiesce(void)
{
    w32(0, REG(R_DMACTRL));
    w32(0, REG(R_IRQ_EN));
}

static void nand_init(void)
{
    w32(0, REG(R_IRQ_EN));
    w32(0, REG(R_CTRL));
    w32(0, REG(R_CMD));
    w32(0, REG(R_DMACTRL));
}

static void nand_wren(void)
{
    send_cmd(OP_WREN, 0, 0, 0, 0, 0);
}

static uint8_t nand_status(void)
{
    uint8_t st = 0;
    send_cmd(OP_GET_FEAT, 1, FEAT_STATUS, 0, 1, 0);
    rx_drain(&st, 1);
    quiesce();

    return st;
}

static int wait_ready(uint8_t failmask)
{
    uint8_t st;
    do {
        st = nand_status();
    } while (st & STAT_BUSY);

    return (st & failmask) ? -1 : 0;
}

static void nand_unlock(void)
{
    uint8_t z = 0;
    send_cmd(OP_SET_FEAT, 1, FEAT_PROTECT, 0, 1, 1);
    tx_push(&z, 1);
    tx_wait_drained();
    quiesce();
}

static int nand_erase(uint32_t block)
{
    uint32_t page = block * PAGES_PER_BLOCK;
    nand_wren();
    send_cmd(OP_BLOCK_ERASE, 3, page, 0, 0, 0);
    quiesce();

    return wait_ready(STAT_ERASE_FAIL);
}

static int nand_program(uint32_t page, const uint8_t *src)
{
    nand_wren();
    send_cmd(OP_PROG_LOAD, 2, 0, 0, PAGE_SIZE, 1);
    tx_push(src, PAGE_SIZE);
    tx_wait_drained();
    quiesce();
    send_cmd(OP_PROG_EXEC, 3, page, 0, 0, 0);
    quiesce();

    return wait_ready(STAT_PROG_FAIL);
}

static int nand_read(uint32_t page, uint8_t *buf)
{
    send_cmd(OP_PAGE_READ, 3, page, 0, 0, 0);
    quiesce();
    if (wait_ready(0) < 0) {     /* read has no failure bit; just wait for ready */
        return -1;
    }

    send_cmd(OP_READ_CACHE, 2, 0, 1, PAGE_SIZE, 0);
    rx_drain(buf, PAGE_SIZE);
    quiesce();

    return 0;
}

extern const uint8_t gpt0_data[];   /* 256 KiB, A-active gpt0 dump (data.S) */
static uint8_t pagebuf[PAGE_SIZE];
#define GPT0_PAGE0 512u
#define GPT0_NPAGES 128u
#define GPT_SIG_OFF 0x200       /* "EFI PART" signature offset within gpt0's first page (LBA1) */

static void halt(void)
{
    for (;;) {
        uputs("HALT ");
        for (volatile int d = 0; d < 6000000; d++) {
        }
    }
}

void payload_main(void)
{
    nand_init();
    /* pre-check: current gpt0 must read back with the GPT magic */
    if (nand_read(GPT0_PAGE0, pagebuf) < 0) {
        uputs("\r\nPRECHECK read FAIL\r\n");
        halt();
    }

    int ok = 1;
    const char *magic = "EFI PART";
    for (int i = 0; i < 8; i++) {
        if (pagebuf[GPT_SIG_OFF + i] != (uint8_t)magic[i]) {
            ok = 0;
        }
    }

    if (!ok) {
        uputs("\r\nPRECHECK no EFI PART -- aborting\r\n");
        halt();
    }

    uputs("\r\nPRECHECK ok; unlocking + erasing gpt0 blocks 8,9...\r\n");
    nand_unlock();

    if (nand_erase(8) < 0) {
        uputs("ERASE blk8 FAIL\r\n");
        halt();
    }

    if (nand_erase(9) < 0) {
        uputs("ERASE blk9 FAIL\r\n");
        halt();
    }

    uputs("programming 128 pages...\r\n");
    for (uint32_t i = 0; i < GPT0_NPAGES; i++) {
        if (nand_program(GPT0_PAGE0 + i, gpt0_data + i * PAGE_SIZE) < 0) {
            uputs("PROG FAIL page+");
            uhex16(i);
            uputs("\r\n");
            halt();
        }
    }

    uputs("verifying...\r\n");
    for (uint32_t i = 0; i < GPT0_NPAGES; i++) {
        if (nand_read(GPT0_PAGE0 + i, pagebuf) < 0) {
            uputs("VERIFY read FAIL +");
            uhex16(i);
            uputs("\r\n");
            halt();
        }
        const uint8_t *src = gpt0_data + i * PAGE_SIZE;
        for (uint32_t j = 0; j < PAGE_SIZE; j++) {
            if (pagebuf[j] != src[j]) {
                uputs("VERIFY MISMATCH page+");
                uhex16(i);
                uputs(" off+");
                uhex16(j);
                uputs("\r\n");
                halt();
            }
        }
    }

    for (;;) {
        uputs("WRITE+VERIFY OK -- gpt0 restored to slot A. POWER-CYCLE to boot stock A. ");
        for (volatile int d = 0; d < 6000000; d++) {
        }
    }
}
