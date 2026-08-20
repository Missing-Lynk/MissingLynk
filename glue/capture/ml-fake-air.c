/*
 * ml-fake-air.c - on-goggle stand-in for the air unit's UDP control plane.
 *
 * Speaks the air side of the two goggle-facing channels against a live ml-linkd, so link events
 * (air loss, TX return, re-handshake, params ack) can be driven on a bench with no air unit:
 *
 *   :20001 hello  - ml-linkd sends 520-byte zero hellos at ~3 Hz until its 3-way is done; the
 *                   air answers with a type-1 identity frame (byte 0 = 0x01) and the goggle
 *                   echoes a type-2 ACK. Replied here per hello received.
 *   :10000 params - 24-byte-header message plane. MEDIA_PARAMS_REQUEST (0x01) is answered with
 *                   MEDIA_PARAMS reply (0x02); a 0x02 is also sent on a 2 s timer so telemetry
 *                   liveness holds when ml-linkd's own poll is gated. Everything else received
 *                   (SetLdCfg, SetTranParm, IDR request, camera sets) is counted and ignored.
 *
 * Runs bound to the air unit's address (default 10.0.0.100), which the caller adds as a local
 * alias first:
 *   ip addr add 10.0.0.100/32 dev lo
 * Local delivery then routes ml-linkd's sends to these sockets and replies originate from the
 * address ml-linkd expects, with the RF chip and its driver untouched.
 *
 * Link-outage control, for scripting drop/return cycles:
 *   SIGUSR1  go quiet (no replies, no timer traffic) -> ml-linkd trips air-loss after 5 s
 *   SIGUSR2  resume                                  -> "TX unit returned", hello 3-way, re-ack
 *
 * One line per state change and per first-of-kind message on stdout, timestamped with uptime.
 *
 *   ml-fake-air [--air-ip 10.0.0.100] [--goggle-ip 10.0.0.1]
 *
 * Build (static): aarch64-linux-gnu-gcc -O2 -Wall -static -o ml-fake-air ml-fake-air.c
 */
#include <arpa/inet.h>
#include <errno.h>
#include <signal.h>
#include <stdint.h>
#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include <sys/socket.h>
#include <time.h>
#include <unistd.h>

#define HELLO_PORT   20001
#define PARAMS_PORT  10000
#define PKT_MAX      600
#define MP_HDR_LEN   24
#define REPLY_IVL_MS 2000

#define MP_REQUEST 0x01
#define MP_REPLY   0x02

static volatile sig_atomic_t g_quiet;

static void on_usr1(int sig) { (void)sig; g_quiet = 1; }
static void on_usr2(int sig) { (void)sig; g_quiet = 0; }

static long now_ms(void)
{
    struct timespec t;

    clock_gettime(CLOCK_MONOTONIC, &t);
    return t.tv_sec * 1000L + t.tv_nsec / 1000000L;
}

static void say(const char *msg)
{
    printf("[fake-air] %ld.%03ld %s\n", now_ms() / 1000, now_ms() % 1000, msg);
    fflush(stdout);
}

static int bound_udp(const char *ip, int port)
{
    struct sockaddr_in a = { .sin_family = AF_INET, .sin_port = htons(port) };
    int s = socket(AF_INET, SOCK_DGRAM, 0);

    inet_pton(AF_INET, ip, &a.sin_addr);
    if (s < 0 || bind(s, (struct sockaddr *)&a, sizeof a) < 0) {
        fprintf(stderr, "[fake-air] bind %s:%d: %s (is the address aliased onto lo?)\n",
                ip, port, strerror(errno));
        exit(1);
    }

    return s;
}

/* 24-byte message-plane header: type LE u32 @0, timestamp us LE u32 @8, body length LE u32 @16. */
static size_t mp_frame(uint8_t *f, uint32_t type)
{
    uint32_t stamp = (uint32_t)(now_ms() * 1000);

    memset(f, 0, MP_HDR_LEN);
    memcpy(f + 0, &type, 4);
    memcpy(f + 8, &stamp, 4);

    return MP_HDR_LEN;
}

int main(int argc, char **argv)
{
    const char *air_ip = "10.0.0.100", *goggle_ip = "10.0.0.1";
    struct sockaddr_in gg_hello = { .sin_family = AF_INET, .sin_port = htons(HELLO_PORT) };
    struct sockaddr_in gg_params = { .sin_family = AF_INET, .sin_port = htons(PARAMS_PORT) };
    long last_reply = 0;
    int was_quiet = 0;
    unsigned hellos = 0, requests = 0, others = 0;
    int hs, ps;

    for (int i = 1; i < argc; i++) {
        if (strcmp(argv[i], "--air-ip") == 0 && i + 1 < argc) {
            air_ip = argv[++i];
        } else if (strcmp(argv[i], "--goggle-ip") == 0 && i + 1 < argc) {
            goggle_ip = argv[++i];
        } else {
            fprintf(stderr, "usage: %s [--air-ip IP] [--goggle-ip IP]\n", argv[0]);
            return 2;
        }
    }

    inet_pton(AF_INET, goggle_ip, &gg_hello.sin_addr);
    inet_pton(AF_INET, goggle_ip, &gg_params.sin_addr);

    hs = bound_udp(air_ip, HELLO_PORT);
    ps = bound_udp(air_ip, PARAMS_PORT);

    signal(SIGUSR1, on_usr1);
    signal(SIGUSR2, on_usr2);

    say("up: answering :20001 hellos and :10000 params (USR1 = link drop, USR2 = return)");

    for (;;) {
        uint8_t buf[PKT_MAX], out[PKT_MAX];
        struct timeval tv = { .tv_sec = 0, .tv_usec = 200000 };
        fd_set rd;
        long now;
        ssize_t n;

        if (g_quiet != was_quiet) {
            was_quiet = g_quiet;
            say(g_quiet ? "LINK DROP: going quiet" : "LINK RETURN: resuming");
        }

        FD_ZERO(&rd);
        FD_SET(hs, &rd);
        FD_SET(ps, &rd);
        select((hs > ps ? hs : ps) + 1, &rd, NULL, NULL, &tv);
        now = now_ms();

        /* :20001 - a hello from the goggle gets the type-1 identity; the type-2 ACK it echoes
         * back lands here too and is drained without a response (the 3-way ends with it). */
        while ((n = recv(hs, buf, sizeof buf, MSG_DONTWAIT)) > 0) {
            if (g_quiet || (n > 0 && buf[0] == 0x02)) {
                continue;
            }
            hellos++;
            memset(out, 0, 32);
            out[0] = 0x01;
            sendto(hs, out, 32, MSG_DONTWAIT, (struct sockaddr *)&gg_hello, sizeof gg_hello);
            if (hellos == 1) {
                say("hello answered (type-1 identity sent)");
            }
        }

        /* :10000 - answer MEDIA_PARAMS_REQUEST immediately; count and ignore the rest. */
        while ((n = recv(ps, buf, sizeof buf, MSG_DONTWAIT)) > 0) {
            uint32_t type = 0;

            if (g_quiet || n < 4) {
                continue;
            }
            memcpy(&type, buf, 4);
            if (type == MP_REQUEST) {
                requests++;
                sendto(ps, out, mp_frame(out, MP_REPLY), MSG_DONTWAIT,
                       (struct sockaddr *)&gg_params, sizeof gg_params);
                last_reply = now;
                if (requests == 1) {
                    say("MEDIA_PARAMS_REQUEST answered (0x02 sent)");
                }
            } else {
                others++;
                if (others == 1) {
                    char m[64];
                    snprintf(m, sizeof m, "ignoring goggle->air type 0x%02x", type);
                    say(m);
                }
            }
        }

        /* Unsolicited 0x02 on a 2 s cadence keeps :10000 liveness fresh while ml-linkd's own
         * poll is READY-gated, and is what flips air-loss back to "TX unit returned". */
        if (!g_quiet && now - last_reply >= REPLY_IVL_MS) {
            sendto(ps, out, mp_frame(out, MP_REPLY), MSG_DONTWAIT,
                   (struct sockaddr *)&gg_params, sizeof gg_params);
            last_reply = now;
        }
    }
}
