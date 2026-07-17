/**
 * @file ubi.c
 * @brief userapp (rootfs) UBI write: feed the image to vendored mtd-utils ubiformat over a pipe.
 */
#include <stdio.h>
#include <string.h>
#include <unistd.h>
#include <getopt.h>
#include <signal.h>
#include <sys/wait.h>

#include "ubi.h"

/* ubiformat.c's main(), renamed at compile time (-Dmain=ubiformat_main in native/build.sh) so
 * the whole vendored tool links in as a callable function instead of a second entry point.
 * It parses into a file-scope struct that is not fully re-zeroed per call, so this is sound only
 * because an .mlimg carries a single ubiformat component (the userapp rootfs) - one call per run.
 */
extern int ubiformat_main(int argc, char *const argv[]);

int ubi_write(const char *dev_path, const unsigned char *data, size_t len)
{
    int pipefd[2];
    if (pipe(pipefd) != 0) {
        perror("pipe");
        return -1;
    }

    pid_t child = fork();
    if (child < 0) {
        perror("fork");
        close(pipefd[0]);
        close(pipefd[1]);
        return -1;
    }

    if (child == 0) {
        /* Writer: stream the image into the pipe that ubiformat reads as stdin. A short read on
         * ubiformat's side (it stops at img_ebs) closes the pipe; treat EPIPE as a clean stop.
         */
        signal(SIGPIPE, SIG_IGN);
        close(pipefd[0]);

        size_t off = 0;
        while (off < len) {
            ssize_t n = write(pipefd[1], data + off, len - off);
            if (n < 0) {
                break;
            }
            off += (size_t)n;
        }

        close(pipefd[1]);
        _exit(0);
    }

    /* Parent: point ubiformat's stdin at the pipe, run it, then restore our own stdin. */
    close(pipefd[1]);

    int saved_stdin = dup(STDIN_FILENO);
    if (saved_stdin < 0 || dup2(pipefd[0], STDIN_FILENO) < 0) {
        perror("dup2");
        close(pipefd[0]);
        if (saved_stdin >= 0) {
            close(saved_stdin);
        }
        waitpid(child, NULL, 0);

        return -1;
    }

    close(pipefd[0]);

    char size_arg[32];
    snprintf(size_arg, sizeof size_arg, "%zu", len);
    char *argv[] = {
        "ubiformat", (char *)dev_path, "-f", "-", "-S", size_arg, "-y", NULL,
    };
    int argc = (int)(sizeof argv / sizeof argv[0]) - 1;

    optind = 1;
    int rc = ubiformat_main(argc, argv);

    dup2(saved_stdin, STDIN_FILENO);
    close(saved_stdin);
    waitpid(child, NULL, 0);

    return rc == 0 ? 0 : -1;
}
