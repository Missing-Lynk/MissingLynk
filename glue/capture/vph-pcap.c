/**
 * @file vph-pcap.c
 * @brief Write the air unit's outgoing :10001 video packets to a pcap, passively.
 *
 * AF_PACKET/ETH_P_ALL on sdio0 while ml-air-camera keeps running, so it costs no bring-up and does
 * not disturb a live session. Unlike vph-sniff, which reads the VPH header out of first fragments
 * and reports sizes, this keeps every byte including subsequent fragments, so the host can
 * reassemble the datagrams and recover the elementary stream.
 *
 * The 4096-byte MTU fragments an access unit across several IP packets; reassembly is left to the
 * host (glue/capture/vph-es.py), which has the memory and the tooling for it.
 *
 * Cross-build (static, aarch64):
 *   docker run --rm --platform linux/arm64 -v "$PWD":/w -w /w alpine:3.24 sh -euc \
 *     'apk add -q build-base linux-headers; gcc -O2 -Wall -static -o glue/build/vph-pcap \
 *      glue/capture/vph-pcap.c'
 *
 * Usage: vph-pcap [-i iface] [-s seconds] [-b bytes] -w out.pcap
 */
#include <arpa/inet.h>
#include <errno.h>
#include <linux/if_ether.h>
#include <linux/if_packet.h>
#include <net/if.h>
#include <stdint.h>
#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include <sys/ioctl.h>
#include <sys/socket.h>
#include <sys/time.h>
#include <unistd.h>

#define PROG "vph-pcap"
#define SNAPLEN 65535

/* 24 bytes, in this order: the two 16-bit version fields and the separate thiszone/sigfigs words
 * are what make it 24 rather than 20, and a short header shifts every record that follows. */
struct pcap_hdr {
    uint32_t magic;
    uint16_t version_major, version_minor;
    int32_t thiszone;
    uint32_t sigfigs, snaplen, network;
};

struct pcap_rec {
    uint32_t ts_sec, ts_usec, incl_len, orig_len;
};

int main(int argc, char **argv)
{
    const char *iface = "sdio0";
    const char *out = NULL;
    int seconds = 3;
    long max_bytes = 8 * 1024 * 1024;
    int port = 0;
    int opt;

    while ((opt = getopt(argc, argv, "i:s:b:p:w:")) != -1) {
        switch (opt) {
        case 'i': iface = optarg; break;
        case 's': seconds = atoi(optarg); break;
        case 'b': max_bytes = atol(optarg); break;
        case 'p': port = atoi(optarg); break;
        case 'w': out = optarg; break;
        default:
            fprintf(stderr, "usage: %s [-i iface] [-s seconds] [-b bytes] [-p port]"
                            " -w out.pcap\n", argv[0]);
            return 2;
        }
    }

    if (out == NULL) {
        fprintf(stderr, "usage: %s [-i iface] [-s seconds] [-b bytes] -w out.pcap\n", argv[0]);
        return 2;
    }

    int fd = socket(AF_PACKET, SOCK_RAW, htons(ETH_P_ALL));
    if (fd < 0) {
        fprintf(stderr, PROG ": socket: %s\n", strerror(errno));
        return 1;
    }

    struct ifreq ifr;
    memset(&ifr, 0, sizeof ifr);
    snprintf(ifr.ifr_name, sizeof ifr.ifr_name, "%s", iface);
    if (ioctl(fd, SIOCGIFINDEX, &ifr) != 0) {
        fprintf(stderr, PROG ": %s: %s\n", iface, strerror(errno));
        return 1;
    }

    struct sockaddr_ll sll;
    memset(&sll, 0, sizeof sll);
    sll.sll_family = AF_PACKET;
    sll.sll_protocol = htons(ETH_P_ALL);
    sll.sll_ifindex = ifr.ifr_ifindex;
    if (bind(fd, (struct sockaddr *)&sll, sizeof sll) != 0) {
        fprintf(stderr, PROG ": bind %s: %s\n", iface, strerror(errno));
        return 1;
    }

    FILE *f = fopen(out, "wb");
    if (f == NULL) {
        fprintf(stderr, PROG ": %s: %s\n", out, strerror(errno));
        return 1;
    }

    /* LINKTYPE_RAW (101): sdio0 hands us bare IP, no link header. */
    struct pcap_hdr gh = { 0xa1b2c3d4u, 2, 4, 0, 0, SNAPLEN, 101 };
    fwrite(&gh, sizeof gh, 1, f);

    struct timeval start;
    gettimeofday(&start, NULL);

    uint8_t buf[SNAPLEN];
    long written = 0;
    long packets = 0;

    for (;;) {
        struct timeval now;
        gettimeofday(&now, NULL);
        if (now.tv_sec - start.tv_sec >= seconds || written >= max_bytes) {
            break;
        }

        ssize_t n = recv(fd, buf, sizeof buf, 0);
        if (n <= 0) {
            continue;
        }

        /* Port filter, so a control-plane capture is not drowned by the video stream: keep only
         * unfragmented IPv4 UDP with a matching source or destination port. Fragmented datagrams
         * are dropped outright - the control plane fits one packet, and video is what we are
         * excluding. */
        if (port != 0) {
            if (n < 28 || (buf[0] >> 4) != 4 || buf[9] != 17) {
                continue;
            }

            unsigned ihl = (unsigned)(buf[0] & 0x0f) * 4;
            unsigned frag = (unsigned)((buf[6] << 8) | buf[7]);
            if (ihl < 20 || (size_t)n < ihl + 8 || (frag & 0x3fff) != 0) {
                continue;
            }

            unsigned sport = (unsigned)((buf[ihl] << 8) | buf[ihl + 1]);
            unsigned dport = (unsigned)((buf[ihl + 2] << 8) | buf[ihl + 3]);
            if (sport != (unsigned)port && dport != (unsigned)port) {
                continue;
            }
        }

        struct pcap_rec rec = { (uint32_t)now.tv_sec, (uint32_t)now.tv_usec,
                                (uint32_t)n, (uint32_t)n };
        fwrite(&rec, sizeof rec, 1, f);
        fwrite(buf, (size_t)n, 1, f);
        written += n;
        packets++;
    } /* until the time or byte budget runs out */

    fclose(f);
    fprintf(stderr, PROG ": %ld packets, %ld bytes -> %s\n", packets, written, out);

    return 0;
}
