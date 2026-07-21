/*
 * ml-rfcmd - send one MLM_T_RFCMD to ml-linkd's link.sock (test/debug the HUD->ml-linkd RF seam
 * without the HUD). Runs on the goggle (the socket is local). Mirrors ml-shared/mlm.h's frame.
 *
 *   ml-rfcmd 1 <0|1>    MLM_RF_SET_STANDBY  (0 disarm, 1 arm)
 *   ml-rfcmd 2 <mW>     MLM_RF_SET_POWER    (25 / 100 / 200)
 *   ml-rfcmd 8 <0|1>    MLM_RF_BIND         (0 dry-run, 1 persist; AU must be in pair mode)
 *
 * Build: native/build.sh -> native/build/ml-rfcmd (static aarch64).
 */
#include <stdint.h>
#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include <sys/socket.h>
#include <sys/un.h>
#include <unistd.h>

#define MLM_MAGIC     0x314d4c4du   /* "MLM1" LE */
#define MLM_T_RFCMD   0x000a
#define MLM_LINK_SOCK "/run/missinglynk/link.sock"

int main(int argc, char **argv)
{
    if (argc < 3) {
        fprintf(stderr, "usage: ml-rfcmd <cmd> <arg>   (1=SET_STANDBY 0|1, 2=SET_POWER mW)\n");
        return 2;
    }

    struct __attribute__((packed)) {
        uint32_t magic;
        uint16_t type;
        uint16_t flags;
        uint32_t cmd;
        uint32_t arg;
    } frame = {
        .magic = MLM_MAGIC,
        .type  = MLM_T_RFCMD,
        .flags = 0,
        .cmd   = (uint32_t) strtoul(argv[1], NULL, 0),
        .arg   = (uint32_t) strtoul(argv[2], NULL, 0),
    };

    int s = socket(AF_UNIX, SOCK_DGRAM, 0);
    if (s < 0) {
        perror("socket");
        return 1;
    }

    struct sockaddr_un addr = { .sun_family = AF_UNIX };
    strncpy(addr.sun_path, MLM_LINK_SOCK, sizeof addr.sun_path - 1);
    int ok = sendto(s, &frame, sizeof frame, 0, (struct sockaddr *) &addr, sizeof addr)
             == (ssize_t) sizeof frame;
    close(s);

    printf("ml-rfcmd cmd=%u arg=%u -> %s\n", frame.cmd, frame.arg, ok ? "sent" : "FAILED (ml-linkd down?)");
    return ok ? 0 : 1;
}
