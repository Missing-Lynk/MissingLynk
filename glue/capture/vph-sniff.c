/**
 * @file vph-sniff.c
 * @brief Report the air's outgoing video packets from the air itself, without disturbing anything.
 *
 * Answering "what does our downlink actually look like" normally means ML_AIR_DUMP, which costs a
 * camera bring-up. A second bring-up in one boot writes no DRAM (done/au-b-pipeline-dead-20260802),
 * so that dump has to be the boot's first, i.e. a boot spent on measuring rather than on flying.
 * This reads the same bytes off sdio0 while ml-air-camera keeps running untouched.
 *
 * Access units are larger than the 4096-byte sdio0 MTU and therefore IP-fragmented, but every field
 * this reports lives in the 36-byte video_packet_header, which rides in the first fragment. So no
 * reassembly is needed: non-first fragments are skipped and StreamLen is taken from the header
 * rather than measured.
 *
 * Two things it exists to answer, both of which decide whether a vendor goggle survives our stream:
 *   - the access-unit size distribution, against the vendor's observed ceiling of 18000 bytes
 *     (2037 captured vendor AUs, none above it, exactly one on it);
 *   - whether the Resolution word ever changes, because AR_LDRT_RX_WirelessParserThread stops the
 *     receive pipeline for good when it does ("Parser resolution from %ux%u to %ux%u, stop rx
 *     pipeline and drop all stream, please restart pipeline!!!").
 *
 * It also hexdumps the head of each IDR access unit, which is what glue/capture/check-idr-head.py
 * runs the vendor's twelve-byte acceptance check against.
 *
 * Build (static, aarch64, same Alpine pin as the rootfs):
 *   docker run --rm --platform linux/arm64 -v "$PWD":/w -w /w alpine:3.24 sh -euc \
 *     'apk add -q build-base linux-headers; gcc -O2 -Wall -static -o glue/build/vph-sniff \
 *        glue/capture/vph-sniff.c'
 *
 * Run on the air, where it needs CAP_NET_RAW (it runs as root):
 *   vph-sniff [-i sdio0] [-n packets] [-s seconds]
 */
#define _GNU_SOURCE
#include <arpa/inet.h>
#include <linux/if_ether.h>
#include <linux/if_packet.h>
#include <net/if.h>
#include <netinet/in.h>
#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include <sys/socket.h>
#include <time.h>
#include <unistd.h>

#define VIDEO_PORT     10001
#define VPH_LEN        36
#define VPH_MAGIC      0x12345678u
#define VPH_TAIL_MAGIC 0x87654321u

/* The vendor's observed ceiling. Not a spec, an empirical bound from a full slot-A session; an AU
 * above it is the condition we are looking for, not a proven fault. */
#define VENDOR_AU_MAX  18000

static uint32_t rd32(const uint8_t *p)
{
    return (uint32_t)p[0] | ((uint32_t)p[1] << 8) | ((uint32_t)p[2] << 16) | ((uint32_t)p[3] << 24);
}

int main(int argc, char **argv)
{
    const char *ifname = "sdio0";
    long want = 0;
    long secs = 0;
    int opt;

    while ((opt = getopt(argc, argv, "i:n:s:")) != -1) {
        switch (opt) {
        case 'i': {
            ifname = optarg;
        } break;
        case 'n': {
            want = atol(optarg);
        } break;
        case 's': {
            secs = atol(optarg);
        } break;
        default: {
            fprintf(stderr, "usage: %s [-i iface] [-n packets] [-s seconds]\n", argv[0]);
            return 2;
        }
        }
    } /* for each option */

    /* ETH_P_ALL, not ETH_P_IP: sdio0 is a raw-IP netdev (ARPHRD_NONE, no link header), and
     * protocol-matched binds do not reliably deliver its frames. ETH_P_ALL takes everything and we
     * find the IP header ourselves below. */
    int fd = socket(AF_PACKET, SOCK_RAW, htons(ETH_P_ALL));
    if (fd < 0) {
        perror("socket(AF_PACKET)");
        return 1;
    }

    struct sockaddr_ll ll;
    memset(&ll, 0, sizeof ll);
    ll.sll_family = AF_PACKET;
    ll.sll_protocol = htons(ETH_P_ALL);
    ll.sll_ifindex = (int)if_nametoindex(ifname);
    if (ll.sll_ifindex == 0) {
        fprintf(stderr, "no interface %s\n", ifname);
        return 1;
    }

    if (bind(fd, (struct sockaddr *)&ll, sizeof ll) != 0) {
        perror("bind");
        return 1;
    }

    /* Distribution state. Sizes are bucketed rather than stored so this stays O(1) on a unit with a
     * few MB of headroom, and the tail is what matters anyway. */
    unsigned long n_seen = 0, n_over = 0, n_bad = 0;
    unsigned long chn_count[8] = {0};
    uint32_t max_len = 0, min_len = 0xffffffffu;
    unsigned long long sum_len = 0;
    uint32_t res_first = 0, res_changes = 0;
    time_t t0 = time(NULL);
    uint8_t buf[9000];

    printf("# iface %s, video port %d, vendor AU ceiling %d\n", ifname, VIDEO_PORT, VENDOR_AU_MAX);
    printf("# chn frame_id idr stream_len resolution\n");
    fflush(stdout);

    for (;;) {
        ssize_t n = recv(fd, buf, sizeof buf, 0);
        if (n < 0) {
            perror("recv");
            break;
        }

        if (n < 20) {
            continue;
        }

        /* SOCK_RAW keeps whatever link header the device has, and sdio0 has none while other
         * interfaces have 14 bytes of Ethernet. Find the IPv4 header rather than assume. */
        const uint8_t *ip = NULL;
        for (int off = 0; off <= 14; off += 14) {
            if (n > off + 20 && (buf[off] >> 4) == 4 && (buf[off] & 0x0f) >= 5) {
                ip = buf + off;
                n -= off;
                break;
            }
        } /* for each candidate link-header length */

        if (ip == NULL) {
            continue;
        }

        int ihl = (ip[0] & 0x0f) * 4;
        if (ihl < 20 || n < ihl + 8) {
            continue;
        }

        if (ip[9] != IPPROTO_UDP) {
            continue;
        }

        /* Only the first fragment carries the UDP and video headers. */
        uint16_t frag = (uint16_t)((ip[6] << 8) | ip[7]);
        if ((frag & 0x1fff) != 0) {
            continue;
        }

        const uint8_t *udp = ip + ihl;
        if (((udp[2] << 8) | udp[3]) != VIDEO_PORT) {
            continue;
        }

        const uint8_t *vph = udp + 8;
        if (n < ihl + 8 + VPH_LEN) {
            continue;
        }

        if (rd32(vph) != VPH_MAGIC || rd32(vph + 28) != VPH_TAIL_MAGIC) {
            n_bad++;
            continue;
        }

        uint32_t len = rd32(vph + 4);
        uint32_t chn = rd32(vph + 8);
        uint32_t idr = rd32(vph + 12);
        uint32_t fid = rd32(vph + 16);
        uint32_t res = rd32(vph + 24);

        n_seen++;
        sum_len += len;
        if (len > max_len) {
            max_len = len;
        }
        if (len < min_len) {
            min_len = len;
        }
        if (len > VENDOR_AU_MAX) {
            n_over++;
        }
        if (chn < 8) {
            chn_count[chn]++;
        }

        if (n_seen == 1) {
            res_first = res;
        } else if (res != res_first) {
            res_changes++;
        }

        /* Every oversized AU and every IDR is worth a line of its own; the steady state is not. */
        if (idr || len > VENDOR_AU_MAX) {
            printf("%u %u %u %u 0x%08x%s\n", chn, fid, idr, len, res,
                   len > VENDOR_AU_MAX ? "   OVER-CEILING" : "");
        }

        /* The head of an IDR access unit is what the vendor byte-checks. Print enough for
         * check-idr-head.py, from the payload that follows the 36-byte header. */
        if (idr) {
            const uint8_t *es = vph + VPH_LEN;
            ssize_t avail = n - (ihl + 8 + VPH_LEN);

            printf("# idr chn %u head:", chn);
            for (ssize_t i = 0; i < 48 && i < avail; i++) {
                printf(" %02x", es[i]);
            }
            printf("\n");
        }

        fflush(stdout);

        if (want && (long)n_seen >= want) {
            break;
        }
        if (secs && time(NULL) - t0 >= secs) {
            break;
        }
    } /* for each captured packet */

    printf("# packets %lu, bad-magic %lu, resolution 0x%08x, resolution-changes %u\n",
           n_seen, n_bad, res_first, res_changes);
    if (n_seen) {
        printf("# stream_len min %u max %u mean %llu, over %d: %lu (%.2f%%)\n",
               min_len, max_len, sum_len / n_seen, VENDOR_AU_MAX, n_over,
               100.0 * (double)n_over / (double)n_seen);
    }
    for (int i = 0; i < 8; i++) {
        if (chn_count[i]) {
            printf("# chn %d: %lu packets\n", i, chn_count[i]);
        }
    }

    close(fd);

    return 0;
}
