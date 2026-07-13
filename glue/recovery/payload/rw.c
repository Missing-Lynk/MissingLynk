/* Bare-metal AR9301 qspi SPI-NAND access for the Artosyn goggle, run as a downloaded .GMI
   payload via the BootROM. Register sequence per glue/recovery/payload notes (RE'd from
   kernel/overlay/drivers/spi/spi-ar9301.c). UART left at BootROM 115200; we just use putc.

   payload_main(): init qspi, READ gpt0 first page (flash 0x100000 = page 512) and print the
   GPT magic + status over UART, in a loop. READ-ONLY -- proves the controller works before we
   ever erase/program. */
#include <stdint.h>

#define QSPI_BASE   0x01e00000u
#define R_CTRL      0x04
#define R_LANE      0x10
#define R_CMD       0x14
#define R_ADDR      0x18
#define R_DATALEN   0x1c
#define R_DMACTRL   0x20
#define R_STATUS0   0x30
#define R_FIFOSTAT  0x34
#define R_IRQ_EN    0x40
#define R_RX_FIFO   0x100
#define R_TX_FIFO   0x200
#define STATUS0_BUSY (1u<<0)
#define FST_RX_LEVEL(s) ((s)&0x7f)
#define FST_RX_EMPTY (1u<<7)
#define FST_TX_FREE(s)  (((s)>>8)&0x7f)
#define FIFO_WORDS  0x40
#define LANE_ARM    0x00000001u
#define OP_WREN     0x06
#define OP_SET_FEAT 0x1f
#define OP_GET_FEAT 0x0f
#define OP_BLOCK_ERASE 0xd8
#define OP_PROG_LOAD   0x02
#define OP_PROG_EXEC   0x10
#define OP_PAGE_READ   0x13
#define OP_READ_CACHE  0x0b
#define FEAT_PROTECT 0xa0
#define FEAT_STATUS  0xc0
#define PAGE_SIZE   2048u
#define PAGES_PER_BLOCK 64u

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

static void udelay(void)
{
    for (volatile int d = 0; d < 3000000; d++) {
    }
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
    w32(LANE_ARM, REG(R_LANE));            /* arm last */
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
    } while (st & 0x01);

    return (st & failmask) ? -1 : 0;
}

static int nand_read_page(uint32_t page, uint8_t *buf)
{
    send_cmd(OP_PAGE_READ, 3, page, 0, 0, 0);
    quiesce();
    if (wait_ready(0x00) < 0) {
        return -1;
    }

    send_cmd(OP_READ_CACHE, 2, 0, 1, PAGE_SIZE, 0);
    rx_drain(buf, PAGE_SIZE);
    quiesce();

    return 0;
}

static uint8_t pagebuf[2048];

void payload_main(void)
{
    nand_init();
    int r = nand_read_page(512, pagebuf);     /* gpt0 first page @ flash 0x100000 */
    while (1) {
        uputs("\r\nRD rc=");
        uhex8((uint8_t)r);
        uputs(" magic@0x200='");
        for (int i = 0x200; i < 0x208; i++) {
            char c = pagebuf[i];
            uputc((c >= 32 && c < 127) ? c : '.');
        }

        uputs("' p0[0:8]=");
        for (int i = 0; i < 8; i++) {
            uhex8(pagebuf[i]);
        }

        uputc(' ');
        udelay();
    }
}
