/*
 * ml-3a: userspace auto-exposure loop for the air-unit camera.
 *
 * Implements the vendor's recovered AE algorithm (plans/au-ae-decision-law.md,
 * hdf-075) against the open ar-isp driver's statistics export. The vendor's 3A
 * split is reproduced: the kernel owns the interrupt path, statistics
 * ping-pong and the derived register stages; this daemon consumes statistics
 * and writes the operating point back through module parameters.
 *
 * The control variable is an index into the vendor's 366-entry exposure table
 * (ml-3a-exptable.h, measured vendor output). One entry is {gain Q8,
 * line_count}: the exposure/gain split is a property of the table. The entry's
 * gain is also the ladder abscissa (exp_tbl_val / 256), so one index actuates
 * sensor exposure, sensor analogue gain and the three ISP gain ladders
 * consistently.
 *
 * Decision law (all constants measured from the running vendor stack):
 *
 *      delta = luma_target - current_luma
 *      at the top index with delta > 0: counts as settled, no step
 *      |delta| <= 5: settled
 *      else step = truncf((50/256) * 77.893997 * log10f(target / current))
 *           zero step with a nonzero log takes sign(log) and arms a one-
 *           decision skip; the index clamps to [1, 365]
 *
 * Metering follows the vendor's producer exactly (hdf-077): the 36x16 grid is
 * decimated to 9x8 by sampling each block's top-left zone, each sampled zone
 * becomes a Bayer population average of its four channel means, and the mean
 * of those 72 values is the metered luma. Validated against the vendor's own
 * per-cell buffers in the live heap dump, whose 72-value mean is 38.347222
 * against a recorded current_luma of 38.347221.
 *
 * The luma target is the vendor's five-knot curve over exp_index, linearly
 * interpolated and clamped outside the knots. Both vendor captures sit past
 * the last knot, target 41.
 */
#include <errno.h>
#include <fcntl.h>
#include <getopt.h>
#include <math.h>
#include <stdint.h>
#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include <time.h>
#include <unistd.h>

#include "ml-3a-exptable.h"

#define STATS_RAW_PATH  "/sys/kernel/debug/ar-isp/stats_raw"
#define LADDER_ARM_PATH "/sys/kernel/debug/ar-isp/ladders"
#define SENSOR_EXPOSURE "/sys/module/nt99235/parameters/exposure"
#define SENSOR_GAIN     "/sys/module/nt99235/parameters/gain"
#define ISP_RNR_GAIN    "/sys/module/ar_isp/parameters/rnr_gain"
#define ISP_LNR_GAIN    "/sys/module/ar_isp/parameters/lnr_gain"
#define ISP_DE3D_GAIN   "/sys/module/ar_isp/parameters/de3d_gain"

/* Grid geometry, mirroring ar-isp-stats.h. */
#define RRO_COLS        36
#define RRO_ROWS        16
#define RRO_ZONES       (RRO_COLS * RRO_ROWS)
#define RRO_BLOCK       0x100
#define RRO_COL_STRIDE  0x200
#define RRO_SIZE        (RRO_COLS * RRO_COL_STRIDE)
#define HIST_SIZE       0x1000
#define STATS_RAW_SIZE  (4 + RRO_SIZE + HIST_SIZE + 4)

/* Vendor rebin: 36x16 aggregated into 9 columns by 8 rows. */
#define BIN_COLS        9
#define BIN_ROWS        8

/* Decision-law constants, measured (hdf-075: state+36..52, +4512, +44). */
#define AE_TOLERANCE            5.0f
#define AE_DAMPING              (50.0f / 256.0f)
#define AE_LOG_LADDER           77.893997f
#define AE_MIN_STEP_SKIP        1
#define AE_INDEX_MIN            1
#define AE_INDEX_MAX            (ML3A_EXP_TABLE_LEN - 1)

/* The five-knot luma target curve over exp_index (hdf-075: state 0x4000+184). */
static const struct {
    int index;
    int target;
} ae_target_curve[] = {
    { 20, 54 }, { 80, 54 }, { 120, 52 }, { 150, 49 }, { 200, 41 },
};
#define AE_TARGET_KNOTS 5

struct ae_state {
    int exp_index;
    int skip_countdown;
    unsigned int settle_counter;
};

struct ae_opts {
    int start_index;
    int max_step;               /* 0 = no clamp (vendor behaviour) */
    int floor_index;
    int ceil_index;
    int dry_run;
    int decisions;              /* stop after N decisions, 0 = run forever */
    int no_ladders;
    int verbose;
};

static uint32_t get_le32(const uint8_t *p)
{
    return (uint32_t)p[0] | ((uint32_t)p[1] << 8) |
           ((uint32_t)p[2] << 16) | ((uint32_t)p[3] << 24);
}

static uint32_t rro_count(const uint8_t *rro, unsigned int col,
              unsigned int row, unsigned int channel)
{
    return get_le32(rro + col * RRO_COL_STRIDE + (row * 4 + channel) * 4);
}

static uint32_t rro_sum(const uint8_t *rro, unsigned int col, unsigned int row,
            unsigned int channel)
{
    return get_le32(rro + col * RRO_COL_STRIDE + RRO_BLOCK +
            (row * 4 + channel) * 4);
}

/*
 * Zone luma, the vendor's Bayer population average.
 *
 * Each channel mean is an integer division of the zone sum by the zone count
 * plus one, then the four means are weighted 512, 1024 on the mean of the two
 * greens, 512, and shifted right by 11: the two green sites carry half the
 * total and the two non-green sites a quarter each. The weights are the
 * vendor's own, at state 0x4000+120..132. This is a population average and
 * not a BT.601 luma, so it needs no red-versus-blue assignment: the outer two
 * channels carry equal weight and only the greens are identified.
 *
 * The greens are summed at full width rather than pre-averaged with a
 * truncating shift. Replaying the vendor's per-cell buffers, the pre-averaged
 * form reproduces 68 of 72 cells and every miss is one low, which is exactly
 * what dropping the odd bit of the green pair costs; the full-width form has
 * no such bias. The difference is one LSB on a per-cell value that is then
 * averaged over 72 cells, far below the loop's tolerance of 5 either way.
 */
static float zone_luma(const uint8_t *rro, unsigned int col, unsigned int row)
{
    uint32_t mean[4];

    for (unsigned int ch = 0; ch < 4; ch++) {
        uint32_t count = rro_count(rro, col, row, ch);
        mean[ch] = rro_sum(rro, col, row, ch) / (count + 1);
    }

    return (float)((512 * mean[0] + 512 * mean[1] +
            512 * mean[2] + 512 * mean[3]) >> 11);
}

/*
 * The vendor metering: the 36x16 grid is decimated, not averaged. The
 * producer walks source rows 0, 2, ... 14 and source columns 0, 4, ... 32,
 * so each 9x8 output cell is the top-left source zone of its 4x2 block and
 * exactly 72 cells are written. The mean over those 72 is the metered luma;
 * the per-zone weight table is uniform on this product, so the weighted mean
 * the vendor computes and this plain mean are the same number.
 */
static float metered_luma(const uint8_t *rro)
{
    float total = 0.0f;

    for (unsigned int br = 0; br < BIN_ROWS; br++) {
        for (unsigned int bc = 0; bc < BIN_COLS; bc++) {
            total += zone_luma(rro, bc * 4, br * 2);
        }
    }

    return total / (float)(BIN_COLS * BIN_ROWS);
}

/* current_luma = min(metered * scale, 255); the vendor scale reads 1.0. */
static float current_luma_from(float metered)
{
    return metered > 255.0f ? 255.0f : metered;
}

static int luma_target_for(int exp_index)
{
    if (exp_index <= ae_target_curve[0].index) {
        return ae_target_curve[0].target;
    }

    if (exp_index >= ae_target_curve[AE_TARGET_KNOTS - 1].index) {
        return ae_target_curve[AE_TARGET_KNOTS - 1].target;
    }

    for (int i = 1; i < AE_TARGET_KNOTS; i++) {
        if (exp_index < ae_target_curve[i].index) {
            int x0 = ae_target_curve[i - 1].index;
            int y0 = ae_target_curve[i - 1].target;
            int x1 = ae_target_curve[i].index;
            int y1 = ae_target_curve[i].target;

            return y0 + (y1 - y0) * (exp_index - x0) / (x1 - x0);
        }
    }

    return ae_target_curve[AE_TARGET_KNOTS - 1].target;
}

/*
 * One decision. Returns the (possibly zero) step taken and updates the state.
 * The saturation rule is asymmetric on purpose: wanting more exposure while
 * already at the top index counts as settled, so the settle counter climbs in
 * the dark instead of resetting every frame.
 */
static int ae_decide(struct ae_state *st, float current_luma)
{
    float target = (float)luma_target_for(st->exp_index);
    float delta = target - current_luma;
    float log_term;
    int step;

    if (st->exp_index >= AE_INDEX_MAX && delta > 0.0f) {
        st->settle_counter++;
        return 0;
    }

    if (fabsf(delta) <= AE_TOLERANCE) {
        st->settle_counter++;
        return 0;
    }

    if (st->skip_countdown != 0) {
        st->skip_countdown--;
        return 0;
    }

    log_term = log10f(target / current_luma);
    step = (int)truncf(AE_DAMPING * AE_LOG_LADDER * log_term);
    if (step == 0 && log_term != 0.0f) {
        step = log_term > 0.0f ? 1 : -1;
        st->skip_countdown = AE_MIN_STEP_SKIP;
    }

    st->settle_counter = 0;
    st->exp_index += step;
    if (st->exp_index < AE_INDEX_MIN) {
        st->exp_index = AE_INDEX_MIN;
    }

    if (st->exp_index > AE_INDEX_MAX) {
        st->exp_index = AE_INDEX_MAX;
    }

    return step;
}

/*
 * Sensor analogue gain: the largest code whose gain does not exceed the
 * table gain, gain(code) = 2^(code >> 4) * (16 + (code & 0xf)) / 16. The
 * residue stays in the ladder abscissa, matching the vendor's split (live
 * capture: table gain 15.383, sensor code 0x3e = 15.0). 0x5f is the hardware
 * ceiling; higher codes wedge the sensor.
 */
static unsigned int sensor_gain_code(uint32_t gain_q8)
{
    unsigned int best = 0;

    for (unsigned int code = 0; code <= 0x5f; code++) {
        uint32_t q8 = (256u << (code >> 4)) * (16 + (code & 0xf)) / 16;

        if (q8 <= gain_q8) {
            best = code;
        }
    }

    return best;
}

static int write_int(const char *path, int value)
{
    char buf[16];
    int fd, len, ret = 0;

    fd = open(path, O_WRONLY);
    if (fd < 0) {
        return -errno;
    }

    len = snprintf(buf, sizeof(buf), "%d\n", value);
    if (write(fd, buf, len) != len) {
        ret = -errno;
    }

    close(fd);
    return ret;
}

/*
 * Apply one table entry: sensor exposure and gain (each param write commits
 * inside the sensor's group hold), the three ladder abscissas in Q8, then the
 * ladder-only re-apply. The sensor driver clamps exposure at vts - 2 = 1123,
 * two lines under the table's 1125 ceiling; accepted as a 0.2% parity nit.
 */
static int ae_actuate(const struct ae_opts *opts, int exp_index)
{
    const struct ml3a_exp_entry *e = &ml3a_exp_table[exp_index];
    unsigned int code = sensor_gain_code(e->gain_q8);
    int ret;

    if (opts->dry_run) {
        return 0;
    }

    ret = write_int(SENSOR_EXPOSURE, (int)e->line_count);
    if (ret) {
        return ret;
    }

    ret = write_int(SENSOR_GAIN, (int)code);
    if (ret) {
        return ret;
    }

    if (opts->no_ladders) {
        return 0;
    }

    ret = write_int(ISP_RNR_GAIN, (int)e->gain_q8);
    if (!ret) {
        ret = write_int(ISP_LNR_GAIN, (int)e->gain_q8);
    }

    if (!ret) {
        ret = write_int(ISP_DE3D_GAIN, (int)e->gain_q8);
    }

    if (!ret) {
        ret = write_int(LADDER_ARM_PATH, 1);
    }

    return ret;
}

/*
 * One coherent stats_raw snapshot. The driver returns EAGAIN before the first
 * flip and the two sequence words differ if a flip landed mid-copy; both
 * retry. Returns the flip sequence, or negative errno.
 */
static int read_stats(uint8_t *buf)
{
    int tries;

    for (tries = 0; tries < 5; tries++) {
        int fd = open(STATS_RAW_PATH, O_RDONLY);
        ssize_t got = 0, n;

        if (fd < 0) {
            return -errno;
        }

        while (got < STATS_RAW_SIZE) {
            n = read(fd, buf + got, STATS_RAW_SIZE - got);
            if (n <= 0) {
                break;
            }

            got += n;
        }

        close(fd);
        if (got == STATS_RAW_SIZE &&
            get_le32(buf) == get_le32(buf + STATS_RAW_SIZE - 4)) {
            return (int)get_le32(buf);
        }

        usleep(2000);
    }

    return -EAGAIN;
}

static int run_loop(const struct ae_opts *opts)
{
    struct ae_state st = {
        .exp_index = opts->start_index,
    };
    uint8_t *buf = malloc(STATS_RAW_SIZE);
    uint32_t last_seq = 0;
    int have_seq = 0, decided = 0, ret;

    if (!buf) {
        return 1;
    }

    /*
     * Actuate the starting index before the first decision, so the
     * hardware and this loop's idea of the operating point agree. Without
     * it a restart inherits whatever the previous run left on the sensor
     * and reports an index that is not the one in effect: measured on the
     * first live boot, where a second run started at 317 while the sensor
     * was still at the 326 the first run had driven it to. Reading the
     * state back instead does not work, because the sensor gain code is
     * quantised and many table indices share one code.
     */
    ret = ae_actuate(opts, st.exp_index);
    if (ret) {
        fprintf(stderr, "ml-3a: initial actuate: %s\n", strerror(-ret));
        free(buf);
        return 1;
    }

    while (!opts->decisions || decided < opts->decisions) {
        int seq = read_stats(buf);
        float luma;
        int step, prev;

        if (seq < 0) {
            fprintf(stderr, "ml-3a: stats_raw: %s\n",
                strerror(-seq));
            free(buf);
            return 1;
        }

        if (have_seq && (uint32_t)seq == last_seq) {
            usleep(2000);
            continue;
        }

        last_seq = (uint32_t)seq;
        have_seq = 1;

        luma = current_luma_from(metered_luma(buf + 4));
        prev = st.exp_index;
        ae_decide(&st, luma);
        if (opts->max_step && abs(st.exp_index - prev) > opts->max_step) {
            st.exp_index = st.exp_index > prev ?
                prev + opts->max_step : prev - opts->max_step;
        }

        if (st.exp_index < opts->floor_index) {
            st.exp_index = opts->floor_index;
        }

        if (opts->ceil_index && st.exp_index > opts->ceil_index) {
            st.exp_index = opts->ceil_index;
        }

        step = st.exp_index - prev;
        decided++;
        if (step || opts->verbose) {
            printf("seq %u luma %.3f target %d index %d step %d settle %u%s\n",
                   (unsigned int)seq, (double)luma,
                   luma_target_for(st.exp_index), st.exp_index,
                   step, st.settle_counter,
                   opts->dry_run ? " (dry)" : "");
            fflush(stdout);
        }
        if (step) {
            int ret = ae_actuate(opts, st.exp_index);

            if (ret) {
                fprintf(stderr, "ml-3a: actuate: %s\n",
                    strerror(-ret));
                free(buf);
                return 1;
            }
        }
    }

    free(buf);
    return 0;
}

/*
 * Self-test: the two settled vendor operating points, the recovered step
 * arithmetic on synthetic lumas, the gain-code inversion at the validated
 * points, and the table's oracle rows. Runs anywhere, touches nothing.
 */
static int fail(const char *what)
{
    fprintf(stderr, "selftest FAIL: %s\n", what);
    return 1;
}

static int selftest(void)
{
    struct ae_state st;
    int step;

    if (ml3a_exp_table[0].gain_q8 != 256 || ml3a_exp_table[0].line_count != 1) {
        return fail("table[0]");
    }

    if (ml3a_exp_table[317].gain_q8 != 3938 ||
        ml3a_exp_table[283].gain_q8 != 1432) {
        return fail("table oracle rows 317/283");
    }

    if (ml3a_exp_table[365].gain_q8 != 16328 ||
        ml3a_exp_table[365].line_count != 1125) {
        return fail("table[365]");
    }

    /* Vendor live capture: settled at 317, luma 38.347, target 41. */
    st = (struct ae_state){ .exp_index = 317 };
    step = ae_decide(&st, 38.347f);
    if (step != 0 || st.exp_index != 317 || st.settle_counter != 1) {
        return fail("live point should be settled");
    }

    /* Vendor bright capture: settled at 283, luma 45.278. */
    st = (struct ae_state){ .exp_index = 283 };
    step = ae_decide(&st, 45.278f);
    if (step != 0 || st.exp_index != 283) {
        return fail("bright point should be settled");
    }

    /* Dark scene: luma 20 at 317 steps up by 4. */
    st = (struct ae_state){ .exp_index = 317 };
    step = ae_decide(&st, 20.0f);
    if (step != 4 || st.exp_index != 321) {
        return fail("luma 20 should step +4");
    }

    /* Slightly bright: luma 47, damped step truncates to 0, min-step -1. */
    st = (struct ae_state){ .exp_index = 317 };
    step = ae_decide(&st, 47.0f);
    if (step != -1 || st.exp_index != 316 || st.skip_countdown != 1) {
        return fail("luma 47 should min-step -1 and arm the skip");
    }

    step = ae_decide(&st, 47.0f);
    if (step != 0 || st.exp_index != 316 || st.skip_countdown != 0) {
        return fail("armed skip should absorb the next decision");
    }

    /* Top saturation in the dark counts as settled. */
    st = (struct ae_state){ .exp_index = AE_INDEX_MAX };
    step = ae_decide(&st, 10.0f);
    if (step != 0 || st.settle_counter != 1) {
        return fail("dark at the top index should settle");
    }

    /* Bottom clamp. */
    st = (struct ae_state){ .exp_index = 2 };
    step = ae_decide(&st, 255.0f);
    if (st.exp_index != AE_INDEX_MIN) {
        return fail("bottom clamp");
    }

    /* Gain-code inversion at the validated points. */
    if (sensor_gain_code(3938) != 0x3e) {
        return fail("gain 3938 should quantise to 0x3e");
    }

    if (sensor_gain_code(1432) != 0x26) {
        return fail("gain 1432 should quantise to 0x26");
    }

    if (sensor_gain_code(256) != 0x00) {
        return fail("gain 256 should quantise to 0");
    }

    if (sensor_gain_code(16328) != 0x5f) {
        return fail("gain 16328 should quantise to 0x5f");
    }

    /* Target curve: clamp regions and one interpolated point. */
    if (luma_target_for(317) != 41 || luma_target_for(10) != 54) {
        return fail("target curve clamps");
    }

    if (luma_target_for(100) != 53) {
        return fail("target at 100 should interpolate to 53");
    }

    /*
     * Synthetic grid. Count 99 with sum 4000 gives a channel mean of 40
     * under the vendor's count-plus-one divisor, so every sampled zone is
     * a population average of 40 and so is the frame. A gradient is
     * written into the rows the vendor does not sample, which must not
     * move the result: that is what proves the decimation rather than an
     * average over each block.
     */
    {
        uint8_t *rro = calloc(1, RRO_SIZE);
        unsigned int col, row, ch;
        float luma;

        if (!rro) {
            return fail("alloc");
        }

        for (col = 0; col < RRO_COLS; col++) {
            for (row = 0; row < RRO_ROWS; row++) {
                int sampled = (row % 2) == 0 && (col % 4) == 0;

                for (ch = 0; ch < 4; ch++) {
                    uint32_t off = col * RRO_COL_STRIDE +
                        (row * 4 + ch) * 4;
                    uint32_t sum = sampled ? 4000 : 24000;

                    rro[off] = 99;
                    off += RRO_BLOCK;
                    rro[off] = sum & 0xff;
                    rro[off + 1] = (sum >> 8) & 0xff;
                }
            }
        }

        luma = metered_luma(rro);
        free(rro);
        if (fabsf(luma - 40.0f) > 0.01f) {
            return fail("synthetic grid luma");
        }
    }

    printf("selftest OK\n");
    return 0;
}

static void usage(void)
{
    fprintf(stderr,
        "usage: ml-3a [options]\n"
        "  --selftest        run the replay oracle and exit\n"
        "  --start-index N   initial exp_index (default 317, the boot recipe)\n"
        "  --max-step N      clamp a decision to N indices (low authority)\n"
        "  --floor N         never go below index N\n"
        "  --ceil N          never go above index N\n"
        "  --decisions N     stop after N decisions\n"
        "  --dry-run         decide and log, never write\n"
        "  --no-ladders      actuate the sensor only\n"
        "  --verbose         log settled decisions too\n");
}

int main(int argc, char **argv)
{
    static const struct option longopts[] = {
        { "selftest", no_argument, NULL, 't' },
        { "start-index", required_argument, NULL, 's' },
        { "max-step", required_argument, NULL, 'm' },
        { "floor", required_argument, NULL, 'f' },
        { "ceil", required_argument, NULL, 'c' },
        { "decisions", required_argument, NULL, 'n' },
        { "dry-run", no_argument, NULL, 'd' },
        { "no-ladders", no_argument, NULL, 'L' },
        { "verbose", no_argument, NULL, 'v' },
        { NULL, 0, NULL, 0 },
    };
    struct ae_opts opts = {
        .start_index = 317,
        .floor_index = AE_INDEX_MIN,
    };
    int c;

    while ((c = getopt_long(argc, argv, "", longopts, NULL)) != -1) {
        switch (c) {
        case 't': {
            return selftest();
        } break;

        case 's': {
            opts.start_index = atoi(optarg);
        } break;

        case 'm': {
            opts.max_step = atoi(optarg);
        } break;

        case 'f': {
            opts.floor_index = atoi(optarg);
        } break;

        case 'c': {
            opts.ceil_index = atoi(optarg);
        } break;

        case 'n': {
            opts.decisions = atoi(optarg);
        } break;

        case 'd': {
            opts.dry_run = 1;
        } break;

        case 'L': {
            opts.no_ladders = 1;
        } break;

        case 'v': {
            opts.verbose = 1;
        } break;

        default: {
            usage();
            return 1;
        } break;
        }
    }

    if (opts.start_index < AE_INDEX_MIN || opts.start_index > AE_INDEX_MAX) {
        usage();
        return 1;
    }

    return run_loop(&opts);
}
