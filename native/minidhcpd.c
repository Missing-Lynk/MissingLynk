/*
 * minidhcpd - a minimal single-client DHCP server for the goggle's USB-ethernet
 * gadget (usb0). The goggle has no DHCP server (busybox lacks the udhcpd applet), so
 * a USB host (the phone, or a PC) that runs DHCP gets no address. This hands every
 * client one fixed lease so it can reach the goggle at 192.168.3.100.
 *
 * It answers DHCPDISCOVER -> OFFER and DHCPREQUEST -> ACK with OFFER_IP, broadcasting
 * the reply (the client has no IP yet). Bound to IFACE only, so it never serves wlan0.
 *
 * Build: native/build.sh (arm64 glibc<=2.25 container). Run on the goggle as root.
 */
#define _GNU_SOURCE
#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include <unistd.h>
#include <stdint.h>
#include <ifaddrs.h>
#include <sys/socket.h>
#include <netinet/in.h>
#include <arpa/inet.h>

#define DEFAULT_IFACE "usb0"
#define SERVER_IP  "192.168.3.100"
#define OFFER_IP   "192.168.3.123"
#define MASK_IP    "255.255.255.0"
#define LEASE_SECS 86400

#define DHCP_HDR 236   /* fixed BOOTP header, before the 4-byte magic cookie */
#define BUF_SZ   1024

/* DHCP message types (option 53) */
#define DHCP_DISCOVER 1
#define DHCP_OFFER    2
#define DHCP_REQUEST  3
#define DHCP_ACK      5

/* the address handed to the client; overridable via argv[2] so the caller can vary it
 * by gadget mode (RNDIS vs ECM), making the lease reveal the active mode.
 */
static uint32_t g_offer;

/* the server's own address in replies: SERVER_IP unless an explicit interface was given,
 * then that interface's address (device profiles differ, e.g. the air unit's 192.168.4.100).
 */
static uint32_t g_server;

/* find the interface that currently holds SERVER_IP (usb0 for RNDIS, usb1 for ECM),
 * so the caller need not know which gadget mode is active. Returns name in buf or NULL.
 */
static const char *find_iface(char *buf, size_t len)
{
    struct ifaddrs *list = NULL;
    if (getifaddrs(&list) != 0) {
        return NULL;
    }

    uint32_t want = inet_addr(SERVER_IP);
    const char *result = NULL;
    struct ifaddrs *ifa;
    for (ifa = list; ifa != NULL; ifa = ifa->ifa_next) {
        if (ifa->ifa_addr == NULL || ifa->ifa_addr->sa_family != AF_INET) {
            continue;
        }

        struct sockaddr_in *sin = (struct sockaddr_in *)ifa->ifa_addr;
        if (sin->sin_addr.s_addr == want) {
            snprintf(buf, len, "%s", ifa->ifa_name);
            result = buf;
            break;
        }
    }

    freeifaddrs(list);
    return result;
}

/* the IPv4 address currently assigned to @p iface_name, or 0 when it has none */
static uint32_t iface_ipv4(const char *iface_name)
{
    uint32_t found = 0;

    struct ifaddrs *list = NULL;
    if (getifaddrs(&list) != 0) {
        return 0;
    }

    struct ifaddrs *ifa;
    for (ifa = list; ifa != NULL; ifa = ifa->ifa_next) {
        if (ifa->ifa_addr == NULL || ifa->ifa_addr->sa_family != AF_INET) {
            continue;
        }

        if (strcmp(ifa->ifa_name, iface_name) == 0) {
            found = ((struct sockaddr_in *)ifa->ifa_addr)->sin_addr.s_addr;
            break;
        }
    }

    freeifaddrs(list);
    return found;
}

/* return the option-53 message type in the options area, or -1 if absent */
static int request_type(const unsigned char *opt, int len)
{
    int i = 0;
    while (i + 1 < len) {
        unsigned char code = opt[i];
        if (code == 255) {
            /* end */
            break;
        }

        if (code == 0) {
            /* pad */
            i++;
            continue;
        }

        unsigned char olen = opt[i + 1];
        if (code == 53 && olen >= 1) {
            return opt[i + 2];
        }

        i += 2 + olen;
    }

    return -1;
}

static unsigned char *put_option(unsigned char *cursor, unsigned char code,
                                 unsigned char len, const void *val)
{
    cursor[0] = code;
    cursor[1] = len;
    memcpy(cursor + 2, val, len);

    return cursor + 2 + len;
}

/* build an OFFER/ACK reply for the given request; return its length */
static int build_reply(const unsigned char *req, unsigned char reply_type,
                       unsigned char *out)
{
    uint32_t server = g_server;
    uint32_t offer = g_offer;
    uint32_t mask = inet_addr(MASK_IP);
    uint32_t lease = htonl(LEASE_SECS);

    memset(out, 0, BUF_SZ);
    out[0] = 2;                       /* BOOTREPLY */
    out[1] = req[1];                  /* htype */
    out[2] = req[2];                  /* hlen */
    memcpy(out + 4, req + 4, 4);      /* xid */
    memcpy(out + 10, req + 10, 2);    /* flags */
    memcpy(out + 16, &offer, 4);      /* yiaddr */
    memcpy(out + 20, &server, 4);     /* siaddr */
    memcpy(out + 24, req + 24, 4);    /* giaddr */
    memcpy(out + 28, req + 28, 16);   /* chaddr */

    out[236] = 99;                    /* magic cookie */
    out[237] = 130;
    out[238] = 83;
    out[239] = 99;

    unsigned char *cursor = out + 240;
    cursor = put_option(cursor, 53, 1, &reply_type);   /* message type */
    cursor = put_option(cursor, 54, 4, &server);       /* server identifier */
    cursor = put_option(cursor, 51, 4, &lease);        /* lease time */
    cursor = put_option(cursor, 1, 4, &mask);          /* subnet mask -> on-link route to /24 */
    /* deliberately NO router (opt 3) and NO DNS (opt 6): this is a point-to-point link
     * to the device, so the client must keep its own default route + DNS (wifi/mobile)
     * and only gain an on-link route to the gadget /24.
     */
    *cursor++ = 255;                              /* end */

    return (int)(cursor - out);
}

static int open_socket(const char *iface)
{
    int fd = socket(AF_INET, SOCK_DGRAM, 0);
    if (fd < 0) {
        perror("socket");
        return -1;
    }

    int one = 1;
    setsockopt(fd, SOL_SOCKET, SO_REUSEADDR, &one, sizeof one);
    setsockopt(fd, SOL_SOCKET, SO_BROADCAST, &one, sizeof one);
    setsockopt(fd, SOL_SOCKET, SO_BINDTODEVICE, iface, strlen(iface) + 1);

    struct sockaddr_in addr;
    memset(&addr, 0, sizeof addr);
    addr.sin_family = AF_INET;
    addr.sin_addr.s_addr = htonl(INADDR_ANY);
    addr.sin_port = htons(67);
    if (bind(fd, (struct sockaddr *)&addr, sizeof addr) < 0) {
        perror("bind");
        close(fd);

        return -1;
    }

    return fd;
}

int main(int argc, char **argv)
{
    setvbuf(stderr, NULL, _IONBF, 0);

    /* usage: minidhcpd [iface|auto] [offer_ip] */
    char autobuf[32];
    const char *iface;
    if (argc > 1 && strcmp(argv[1], "auto") != 0 && strcmp(argv[1], "-") != 0) {
        iface = argv[1];
    } else {
        iface = find_iface(autobuf, sizeof autobuf);
        if (iface == NULL) {
            iface = DEFAULT_IFACE;
        }
    }

    /* server = the bound interface's own address (falls back to SERVER_IP while the
     * interface has none); offer = the server's /24 with host octet 123, unless argv[2]
     * pins it. Derived, so one binary serves every device profile's gadget subnet.
     */
    uint32_t iface_addr = iface_ipv4(iface);
    g_server = iface_addr != 0 ? iface_addr : inet_addr(SERVER_IP);
    g_offer = (argc > 2) ? inet_addr(argv[2])
                         : ((g_server & inet_addr(MASK_IP)) | htonl(123));

    int fd = open_socket(iface);
    if (fd < 0) {
        return 1;
    }

    char offer_buf[32];
    char server_buf[32];
    snprintf(offer_buf, sizeof offer_buf, "%s", inet_ntoa(*(struct in_addr *)&g_offer));
    snprintf(server_buf, sizeof server_buf, "%s", inet_ntoa(*(struct in_addr *)&g_server));
    fprintf(stderr, "minidhcpd: offering %s on %s (server %s)\n", offer_buf, iface, server_buf);

    struct sockaddr_in bcast;
    memset(&bcast, 0, sizeof bcast);
    bcast.sin_family = AF_INET;
    bcast.sin_addr.s_addr = htonl(INADDR_BROADCAST);
    bcast.sin_port = htons(68);

    unsigned char req[BUF_SZ];
    unsigned char out[BUF_SZ];
    for (;;) {
        ssize_t n = recvfrom(fd, req, sizeof req, 0, NULL, NULL);
        if (n < DHCP_HDR + 4 || req[0] != 1) {
            continue;   /* too short or not a BOOTREQUEST */
        }

        int type = request_type(req + DHCP_HDR + 4, (int)n - (DHCP_HDR + 4));
        unsigned char reply_type;
        if (type == DHCP_DISCOVER) {
            reply_type = DHCP_OFFER;
        } else if (type == DHCP_REQUEST) {
            reply_type = DHCP_ACK;
        } else {
            continue;
        }

        int len = build_reply(req, reply_type, out);
        if (sendto(fd, out, len, 0, (struct sockaddr *)&bcast, sizeof bcast) < 0) {
            perror("sendto");
        } else {
            fprintf(stderr, "minidhcpd: %s -> %s\n",
                    reply_type == DHCP_OFFER ? "OFFER" : "ACK", offer_buf);
        }
    }

    return 0;
}
