/**
 * @file ml-isploop.c
 * @brief Drive the vendor's exact per-frame VIF+ISP cycle, phase-locked to frame starts.
 *
 * The vendor's steady state is a 20-write cycle per frame, extracted verbatim from the
 * combined write trace: six VIF acknowledge writes, three indirect-port transactions on
 * ISP 0x0cc/0x0d4, and seven statistics buffer addresses. The open driver applies a static
 * setup table and then never writes either block again.
 *
 * A previous test ran this cycle by hand thirty times and nothing moved, but that is not the
 * same experiment: the vendor runs it once per frame, immediately after observing the frame
 * start. This tool polls VIF 0x17c for bit24 and runs the cycle on each one, so the writes
 * land in the same phase relative to the hardware that the vendor's do.
 *
 * It also reports the frame-start RATE rather than a single sample. VIF 0x17c is
 * write-1-to-clear, so one read only says whether a bit is currently pending; the meaningful
 * measurement is starts observed per second across a window.
 *
 * The three output planes are the ISP writer's targets (page 0x02e00), NOT the statistics
 * pool the per-frame loop re-arms. Markers are written a word at a time because dd on
 * /dev/mem silently writes nothing on this device.
 *
 * Usage: ml-isploop [seconds] [--no-cycle] [--plane ADDR]...
 *   --no-cycle  poll and measure only, drive nothing (control run)
 *   --plane     mark and check this address instead of the ISP defaults; repeat
 *               up to three times. Use it to watch the CVISP output ring, whose
 *               planes are elsewhere entirely.
 */
#include <fcntl.h>
#include <stdint.h>
#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include <sys/mman.h>
#include <time.h>
#include <unistd.h>

#define VIF_BASE   0x08870000u
#define ISP_BASE   0x08c00000u
#define CVISP_BASE 0x08e00000u
#define BLOCK_LEN  0x10000u

/* CVISP output queue: the three plane bases, and the tick group the vendor issues once per
 * ring wrap. Rotating these on each frame start is the vendor's exact cadence.
 */
#define CVISP_PLANE_Y  0x8098
#define CVISP_PLANE_U  0x8174
#define CVISP_PLANE_V  0x8194

static const uint32_t cvisp_ring[5][3] = {
	{ 0x28014000, 0x28232000, 0x282bb000 },
	{ 0x2834c000, 0x2856a000, 0x285f3000 },
	{ 0x28684000, 0x288a2000, 0x2892b000 },
	{ 0x289bc000, 0x28bda000, 0x28c63000 },
	{ 0x28cf4000, 0x28f12000, 0x28f9b000 },
};

static const uint32_t cvisp_tick[8] = {
	0x4600, 0x4604, 0x4608, 0x460c, 0x4700, 0x4704, 0x4708, 0x470c,
};

/* Output planes from the setup table (page 0x02e00), with the luma/chroma spacing. */
#define PLANE0     0x2b439200u
#define PLANE1     0x2b614200u
#define PLANE2     0x2b703200u
#define PLANE_LEN  0x1DA000u	/* 1945600, the observed luma stride */
#define MARK_STEP  0x1000u
#define MARK_WORD  0xa5a5a5a5u

#define VIF_BP_STATUS  0x17c	/* W1C; bit24 = path0 frame start */
#define FRAME_START    0x01000000u

struct wr {
	uint32_t base;
	uint32_t off;
	uint32_t val;
};

/* The vendor's per-frame cycle, in order, from out/au-mmiotrace/mmio-combined.log. */
static const struct wr cycle[] = {
	{ VIF_BASE, 0x17c, 0x01000000 },
	{ VIF_BASE, 0x184, 0x00000000 },
	{ VIF_BASE, 0x194, 0x00000000 },
	{ VIF_BASE, 0x194, 0x00000000 },
	{ VIF_BASE, 0x294, 0x00000000 },
	{ VIF_BASE, 0x294, 0x00000000 },
	{ ISP_BASE, 0x0cc, 0x04001550 },
	{ ISP_BASE, 0x0d4, 0x003a2000 },
	{ ISP_BASE, 0x0cc, 0x00000000 },
	{ ISP_BASE, 0x0d4, 0x10000200 },
	{ ISP_BASE, 0x0cc, 0x00000000 },
	{ ISP_BASE, 0x0d4, 0x00000100 },
	{ ISP_BASE, 0x75a0, 0x2a660400 },
	{ ISP_BASE, 0x75bc, 0x2a660400 },
	{ ISP_BASE, 0x6440, 0x2a662200 },
	{ ISP_BASE, 0x6474, 0x2a662200 },
	{ ISP_BASE, 0x600c, 0x2a6a0200 },
	{ ISP_BASE, 0x280c, 0x2a6a3200 },
	{ ISP_BASE, 0x6508, 0x2a7a4200 },
	{ ISP_BASE, 0x2808, 0x2b2f8c00 },
};

/* mmap needs a page-aligned offset; the plane addresses are not (they end in 0x200), so
 * align down and hand back a pointer adjusted by the remainder.
 */
static volatile uint8_t *map_block(int fd, uint32_t phys, uint32_t len)
{
	uint32_t slack = phys & 0xfffu;
	uint32_t base = phys - slack;
	void *p = mmap(NULL, len + slack, PROT_READ | PROT_WRITE, MAP_SHARED, fd, base);

	if (p == MAP_FAILED) {
		fprintf(stderr, "mmap 0x%08x (page base 0x%08x) failed\n", phys, base);
		exit(1);
	}
	return (volatile uint8_t *)p + slack;
}

static void unmap_block(volatile uint8_t *p, uint32_t phys, uint32_t len)
{
	uint32_t slack = phys & 0xfffu;

	munmap((void *)(p - slack), len + slack);
}

static double now_s(void)
{
	struct timespec ts;

	clock_gettime(CLOCK_MONOTONIC, &ts);
	return ts.tv_sec + ts.tv_nsec / 1e9;
}

/* Mark one plane and report how many words were still ours afterwards. */
static unsigned mark_plane(int fd, uint32_t phys, unsigned count)
{
	volatile uint8_t *m = map_block(fd, phys, count * MARK_STEP);
	unsigned i;

	for (i = 0; i < count; i++) {
		*(volatile uint32_t *)(m + i * MARK_STEP) = MARK_WORD;
	}
	unmap_block(m, phys, count * MARK_STEP);
	return count;
}

static unsigned check_plane(int fd, uint32_t phys, unsigned count, uint32_t *first)
{
	volatile uint8_t *m = map_block(fd, phys, count * MARK_STEP);
	unsigned i, hit = 0;

	for (i = 0; i < count; i++) {
		uint32_t v = *(volatile uint32_t *)(m + i * MARK_STEP);

		if (v != MARK_WORD) {
			if (!hit) {
				*first = v;
			}
			hit++;
		}
	}
	unmap_block(m, phys, count * MARK_STEP);
	return hit;
}

int main(int argc, char **argv)
{
	double seconds = (argc > 1 && argv[1][0] != '-') ? atof(argv[1]) : 10.0;
	int drive = 1;
	int fd, i;
	volatile uint8_t *vif, *isp;
	unsigned long starts = 0, cycles = 0, polls = 0;
	double t0, t;
	uint32_t planes[3] = { PLANE0, PLANE1, PLANE2 };
	unsigned nplanes = 3, given = 0;
	const unsigned marks = 24;
	uint32_t s_vif1f0 = 0, s_vif17c = 0, s_isp7050 = 0, s_isp706c = 0, s_isp2e90 = 0;
	int sampled = 0;
	int cvisp = 0;
	const char *dump = NULL;
	volatile uint8_t *cvb = NULL;
	unsigned slot = 1, wraps = 0;

	for (i = 1; i < argc; i++) {
		if (!strcmp(argv[i], "--no-cycle")) {
			drive = 0;
		} else if (!strcmp(argv[i], "--cvisp")) {
			cvisp = 1;
			drive = 0;
		} else if (!strcmp(argv[i], "--dump") && i + 1 < argc) {
			dump = argv[++i];
		} else if (!strcmp(argv[i], "--plane") && i + 1 < argc) {
			if (given == 3) {
				fprintf(stderr, "at most three --plane addresses\n");
				return 1;
			}
			planes[given++] = strtoul(argv[++i], NULL, 0);
		}
	}
	if (given) {
		nplanes = given;
	}

	fd = open("/dev/mem", O_RDWR | O_SYNC);
	if (fd < 0) {
		perror("open /dev/mem");
		return 1;
	}

	for (i = 0; i < (int)nplanes; i++) {
		mark_plane(fd, planes[i], marks);
	}
	printf("marked %u words on each of %u output planes\n", marks, nplanes);

	vif = map_block(fd, VIF_BASE, BLOCK_LEN);
	isp = map_block(fd, ISP_BASE, BLOCK_LEN);
	if (cvisp) {
		cvb = map_block(fd, CVISP_BASE, BLOCK_LEN);
	}

	printf("%s for %.1f s\n", drive ? "driving the vendor cycle on each frame start"
				       : "measuring only (control, no writes)", seconds);

	t0 = now_s();
	while ((t = now_s()) - t0 < seconds) {
		uint32_t st = *(volatile uint32_t *)(vif + VIF_BP_STATUS);

		polls++;
		if (!(st & FRAME_START)) {
			continue;
		}
		starts++;

		/* Sample the status registers while a frame start is in hand, so the
		 * pixel domain is provably live at the moment of the read.
		 */
		if (!sampled) {
			s_vif1f0 = *(volatile uint32_t *)(vif + 0x1f0);
			s_vif17c = st;
			s_isp7050 = *(volatile uint32_t *)(isp + 0x7050);
			s_isp706c = *(volatile uint32_t *)(isp + 0x706c);
			s_isp2e90 = *(volatile uint32_t *)(isp + 0x2e90);
			sampled = 1;
		}

		if (cvisp) {
			/*
			 * Arm the next ring slot, one per frame start, which is the
			 * vendor's cadence. Driving the queue faster than frame rate
			 * supersedes each address before the hardware can use it, so a
			 * burst of rotations lands every frame in the same buffer.
			 */
			*(volatile uint32_t *)(cvb + CVISP_PLANE_Y) = cvisp_ring[slot][0];
			*(volatile uint32_t *)(cvb + CVISP_PLANE_U) = cvisp_ring[slot][1];
			*(volatile uint32_t *)(cvb + CVISP_PLANE_V) = cvisp_ring[slot][2];
			slot = (slot + 1) % 5;
			if (!slot) {
				for (i = 0; i < 8; i++) {
					*(volatile uint32_t *)(cvb + cvisp_tick[i]) = 0x100;
				}
				wraps++;
			}
			cycles++;
		}
		if (!drive) {
			/* Still acknowledge, or the bit stays latched and every later poll
			 * counts the same event again.
			 */
			*(volatile uint32_t *)(vif + VIF_BP_STATUS) = FRAME_START;
			continue;
		}
		for (i = 0; i < (int)(sizeof cycle / sizeof cycle[0]); i++) {
			volatile uint8_t *b = (cycle[i].base == VIF_BASE) ? vif : isp;

			*(volatile uint32_t *)(b + cycle[i].off) = cycle[i].val;
		}
		cycles++;
	}
	t = now_s() - t0;

	printf("\n%.1f s: %lu polls, %lu frame starts (%.1f/s), %lu cycles driven\n",
	       t, polls, starts, starts / t, cycles);

	/* Cached from inside the window, NOT re-read here. Reading VIF registers
	 * once the pixel domain has stopped hard-hangs this SoC into a watchdog
	 * reset to slot A, and the stream can end before this tool does: the
	 * grabber has its own timeout. Issuing fresh reads at this point cost a
	 * session once. The values below are the last ones sampled while frames
	 * were demonstrably still arriving.
	 */
	if (sampled) {
		printf("vif 0x1f0=%08x 0x17c=%08x  isp 0x7050=%08x 0x706c=%08x 0x2e90=%08x"
		       " (sampled in-window)\n",
		       s_vif1f0, s_vif17c, s_isp7050, s_isp706c, s_isp2e90);
	} else {
		printf("no frame start seen, so no in-window sample was taken;"
		       " registers deliberately not read\n");
	}

	if (cvisp) {
		printf("cvisp: %lu slots armed, %u wraps\n", cycles, wraps);
	}

	/*
	 * Dump the first plane. mmap rather than read(): dd on /dev/mem fails with EFAULT on
	 * this device in both directions, which is the same reason markers are written a word
	 * at a time.
	 */
	if (dump) {
		/*
		 * Stride is 2048 for a 1920-wide plane, measured: the gap between bright runs
		 * in a dumped plane is exactly 2048 and every sub-gap pair sums to it. Dumping
		 * width * height instead of stride * height truncates at 1012 of 1080 rows and
		 * makes every row appear shifted, which renders as diagonal scanlines and looks
		 * like a picture. It is not one.
		 *
		 * Every plane given with --plane is dumped, to <name>.0, <name>.1 and so on, so
		 * one run captures Y, U and V together. Comparing them is what separates "the
		 * colour is there and only luma collapsed" from "the data never arrived", and a
		 * second run cannot answer it because the frame will have changed.
		 */
		const uint32_t len = 2048 * 1080;
		unsigned p;

		for (p = 0; p < nplanes; p++) {
			volatile uint8_t *m = map_block(fd, planes[p], len);
			char path[256];
			FILE *f;

			snprintf(path, sizeof path, "%s.%u", dump, p);
			f = fopen(path, "wb");
			if (!f) {
				perror(path);
			} else {
				uint32_t off;

				for (off = 0; off < len; off += 4096) {
					fwrite((const void *)(m + off), 1,
					       (len - off < 4096) ? len - off : 4096, f);
				}
				fclose(f);
				printf("dumped %u bytes of 0x%08x to %s\n", len,
				       planes[p], path);
			}
			unmap_block(m, planes[p], len);
		}
	}

	for (i = 0; i < (int)nplanes; i++) {
		uint32_t first = 0;
		unsigned hit = check_plane(fd, planes[i], marks, &first);

		printf("plane %d 0x%08x: %u/%u markers overwritten%s", i, planes[i], hit, marks,
		       hit ? "" : "\n");
		if (hit) {
			printf(", first differing word 0x%08x\n", first);
		}
	}
	close(fd);
	return 0;
}
