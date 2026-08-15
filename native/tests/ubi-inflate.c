/**
 * @file ubi-inflate.c
 * @brief Host test: the rootfs writer that inflates a gzipped .mlimg member into ubiformat.
 *
 * The rootfs component is stored gzip-compressed in the bundle and inflated as it is streamed
 * into ubiformat's stdin, so what reaches flash is produced by this code rather than copied from
 * the image. Nothing downstream re-checks it against the payload digest: preflight hashes the
 * member as stored (compressed), and ubiformat verifies per eraseblock what it was handed, not
 * what the manifest promised. A defect here therefore writes a corrupt rootfs that passes every
 * other gate, and the unit finds out at boot.
 *
 * The real ubiformat is replaced by a stub reader that keeps every byte it is given, so the test
 * drives the shipped ubi_write - its fork, its pipe, its inflate loop - and compares the bytes
 * that arrive at the far end against the payload that went in. Members are compressed here with
 * zlib rather than shipped as fixtures, so the test carries no binary and covers whatever the
 * local zlib emits.
 */
#include "../mlflash/src/ubi.h"

#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include <unistd.h>
#include <zlib.h>

static int g_failed;

static void check(int ok, const char *what)
{
    printf("%s %s\n", ok ? "ok  " : "FAIL", what);
    if (!ok) {
        g_failed++;
    }
}

/* What the stub reader collected on the last ubi_write call. */
static unsigned char *g_seen;
static size_t g_seen_len;
static size_t g_seen_cap;

/*
 * Stands in for the vendored ubiformat entry point ubi.c calls. The real one writes eraseblocks;
 * this keeps the stream so the test can compare it, and drains to EOF so the writer child is
 * never blocked on a full pipe (a short-reading ubiformat is a separate case, covered by the
 * pipe-closed test below).
 */
int ubiformat_main(int argc, char *const argv[])
{
    (void)argc;
    (void)argv;

    g_seen_len = 0;

    unsigned char buf[65536];
    ssize_t n;
    while ((n = read(STDIN_FILENO, buf, sizeof buf)) > 0) {
        if (g_seen_len + (size_t)n > g_seen_cap) {
            g_seen_cap = (g_seen_len + (size_t)n) * 2;
            g_seen = realloc(g_seen, g_seen_cap);
            if (!g_seen) {
                return 1;
            }
        }

        memcpy(g_seen + g_seen_len, buf, (size_t)n);
        g_seen_len += (size_t)n;
    }

    return 0;
}

/** @brief gzip `len` bytes of `data` into a freshly allocated buffer; sets *out_len. */
static unsigned char *gzip_bytes(const unsigned char *data, size_t len, size_t *out_len)
{
    z_stream zs;
    memset(&zs, 0, sizeof zs);

    /* 16 + MAX_WBITS selects gzip framing, matching what the bundle builder writes. */
    if (deflateInit2(&zs, 9, Z_DEFLATED, 16 + MAX_WBITS, 8, Z_DEFAULT_STRATEGY) != Z_OK) {
        return NULL;
    }

    size_t cap = deflateBound(&zs, len) + 32;
    unsigned char *out = malloc(cap);
    if (!out) {
        deflateEnd(&zs);
        return NULL;
    }

    zs.next_in = (unsigned char *)data;
    zs.avail_in = (unsigned int)len;
    zs.next_out = out;
    zs.avail_out = (unsigned int)cap;

    int rc = deflate(&zs, Z_FINISH);
    *out_len = cap - zs.avail_out;
    deflateEnd(&zs);

    if (rc != Z_STREAM_END) {
        free(out);
        return NULL;
    }

    return out;
}

/*
 * A payload with structure worth compressing and enough length to cross the writer's 256 KiB
 * output chunk many times, so the multi-pass path and the chunk boundary are exercised rather
 * than a single inflate call.
 */
static unsigned char *make_payload(size_t len)
{
    unsigned char *data = malloc(len);
    if (!data) {
        return NULL;
    }

    unsigned int state = 0x13579bdf;
    for (size_t i = 0; i < len; i++) {
        state = state * 1103515245u + 12345u;
        /* Runs of repeated bytes between random ones, so the stream both compresses and varies. */
        data[i] = (i % 97 < 60) ? (unsigned char)(i >> 3) : (unsigned char)(state >> 24);
    }

    return data;
}

int main(void)
{
    const size_t payload_len = 3 * 1024 * 1024 + 12345;
    unsigned char *payload = make_payload(payload_len);
    if (!payload) {
        fprintf(stderr, "out of memory building the payload\n");
        return 2;
    }

    size_t member_len = 0;
    unsigned char *member = gzip_bytes(payload, payload_len, &member_len);
    if (!member) {
        fprintf(stderr, "failed to gzip the payload\n");
        return 2;
    }

    printf("  -- the payload arrives intact --\n");

    int rc = ubi_write("/dev/null", member, member_len, payload_len, 1);
    check(rc == 0, "a gzipped member is written without error");
    check(g_seen_len == payload_len, "the inflated length is the length the manifest declares");
    check(g_seen_len == payload_len && memcmp(g_seen, payload, payload_len) == 0,
          "and every byte matches the payload that was compressed");

    /* The member has to be genuinely smaller, or the test is not exercising compression. */
    check(member_len < payload_len / 2, "the member is stored substantially smaller");

    printf("  -- a verbatim member takes the same path --\n");

    rc = ubi_write("/dev/null", payload, payload_len, payload_len, 0);
    check(rc == 0, "an uncompressed member is written without error");
    check(g_seen_len == payload_len && memcmp(g_seen, payload, payload_len) == 0,
          "and arrives byte for byte");

    printf("  -- a damaged member is refused, not written --\n");

    rc = ubi_write("/dev/null", member, member_len / 2, payload_len, 1);
    check(rc != 0, "a member truncated mid-stream fails");

    unsigned char *corrupt = malloc(member_len);
    memcpy(corrupt, member, member_len);
    corrupt[member_len / 2] ^= 0xff;
    rc = ubi_write("/dev/null", corrupt, member_len, payload_len, 1);
    check(rc != 0, "a member with a flipped byte fails");

    /* Only the last four bytes of a gzip member are the CRC; clobbering them leaves the deflate
     * stream valid, so this is the case that needs the trailer to be checked rather than skipped. */
    memcpy(corrupt, member, member_len);
    corrupt[member_len - 3] ^= 0xff;
    rc = ubi_write("/dev/null", corrupt, member_len, payload_len, 1);
    check(rc != 0, "a member whose gzip CRC does not match its content fails");

    rc = ubi_write("/dev/null", member, 0, payload_len, 1);
    check(rc != 0, "an empty member fails");

    printf("  -- the declared length bounds what is written --\n");

    rc = ubi_write("/dev/null", member, member_len, payload_len / 2, 1);
    check(rc != 0, "a member inflating past its declared length fails");
    check(g_seen_len <= payload_len / 2 + 256 * 1024,
          "and stops there rather than streaming on");

    rc = ubi_write("/dev/null", member, member_len, payload_len * 2, 1);
    check(rc != 0, "a member ending before its declared length fails");

    free(corrupt);
    free(member);
    free(payload);
    free(g_seen);

    printf("%s\n", g_failed ? "ubi-inflate: FAILURES" : "ubi-inflate: all checks passed");

    return g_failed ? 1 : 0;
}
