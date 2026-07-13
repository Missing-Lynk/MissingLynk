/*
 * ml-rf-replay.c - on-device RF-session replayer.
 *
 * Plays a record file produced by `pcap-to-rfdump.py` (from a real pcap) or
 * `make-synth-session.py` (synthetic) to localhost with the captured
 * inter-datagram timing, so pipeline tests run entirely on the goggle: no USB-ethernet in
 * the loop (the gadget wedges under sustained host->goggle UDP ingress and cuts the stream).
 *
 * Record format (all LE): u32 delta_us (gap since previous record), u16 dport, u16 len,
 * then len payload bytes.
 *
 *   ml-rf-replay /tmp/session.rfdump [target-ip] [--loop]
 *
 * Build (static, runs on the stock-ish Alpine slot B):
 *   aarch64-linux-gnu-gcc -O2 -Wall -static -o ml-rf-replay ml-rf-replay.c
 */
#include <arpa/inet.h>
#include <fcntl.h>
#include <sys/mman.h>
#include <sys/stat.h>
#include <stdint.h>
#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include <sys/socket.h>
#include <time.h>
#include <unistd.h>

int main(int argc, char **argv)
{
    if (argc < 2) {
        fprintf(stderr, "usage: %s <dumpfile> [target-ip] [--loop]\n", argv[0]);
        return 2;
    }

    const char *path = argv[1];
    const char *target = "127.0.0.1";
    int loop = 0;
    for (int i = 2; i < argc; i++) {
        if (strcmp(argv[i], "--loop") == 0) {
            loop = 1;
        } else {
            target = argv[i];
        }
    }

    /* mmap instead of malloc+read: the goggle has ~135 MB RAM and the OOM killer picks the
     * process with the largest unreclaimable anon RSS - which a 12 MB malloc'd dump makes us.
     * File-backed mmap pages are clean and evictable, so we survive memory pressure. */
    int dfd = open(path, O_RDONLY);
    if (dfd < 0) {
        perror(path);
        return 1;
    }

    struct stat st;
    if (fstat(dfd, &st) != 0 || st.st_size < 8) {
        fprintf(stderr, "ml-rf-replay: bad file\n");
        return 1;
    }

    long sz = st.st_size;
    uint8_t *data = mmap(NULL, sz, PROT_READ, MAP_PRIVATE, dfd, 0);
    if (data == MAP_FAILED) {
        perror("mmap");
        return 1;
    }

    close(dfd);

    int s = socket(AF_INET, SOCK_DGRAM, 0);
    int sndbuf = 4 << 20;
    setsockopt(s, SOL_SOCKET, SO_SNDBUF, &sndbuf, sizeof sndbuf);
    struct sockaddr_in a = { .sin_family = AF_INET };
    if (inet_pton(AF_INET, target, &a.sin_addr) != 1) {
        fprintf(stderr, "ml-rf-replay: bad target %s\n", target);
        return 2;
    }

    do {
        long off = 0;
        unsigned n = 0;
        while (off + 8 <= sz) {
            uint32_t delta_us;
            uint16_t dport, len;
            memcpy(&delta_us, data + off, 4);
            memcpy(&dport, data + off + 4, 2);
            memcpy(&len, data + off + 6, 2);

            off += 8;
            if (off + len > sz) {
                break;
            }

            if (delta_us > 0) {
                struct timespec ts = { delta_us / 1000000, (delta_us % 1000000) * 1000L };
                nanosleep(&ts, NULL);
            }

            a.sin_port = htons(dport);
            sendto(s, data + off, len, 0, (struct sockaddr *)&a, sizeof a);
            off += len;
            n++;
        }

        fprintf(stderr, "ml-rf-replay: pass done, %u datagrams -> %s\n", n, target);
    } while (loop);

    munmap(data, sz);
    return 0;
}
