/*
 * mtdtool: A/B slot policy - which partitions form a dual pair, and the refusal that keeps slot
 * A (the stock firmware every recovery path depends on) from being erased or written.
 */
#include "mtdtool.h"

/* True if `name` is one of the A/B dual partitions; sets *is_b for the '1' member.
 */
bool is_pair_member(const char *name, int *is_b)
{
    static const char *bases[] = { "env", "uboot", "kernel", "dtb", "userapp", NULL };
    size_t len = strlen(name);
    if (len < 2) {
        return 0;
    }

    char last = name[len - 1];
    if (last != '0' && last != '1') {
        return 0;
    }

    for (int i = 0; bases[i]; i++) {
        if (strlen(bases[i]) == len - 1 && strncmp(name, bases[i], len - 1) == 0) {
            *is_b = (last == '1');
            return 1;
        }
    }

    return 0;
}

int refuse_slot_a(int fd, const char *target, const char *command)
{
    char name[128];
    if (mtd_partition_name(fd, name, sizeof(name)) != 0) {
        fprintf(stderr, "refusing to %s %s: no partition name for it in %s, so it cannot be "
                        "confirmed to be outside slot A (pass %s to override)\n",
                command, target, MTD_PROC_PATH, ALLOW_SLOT_A_FLAG);
        return -1;
    }

    int is_b = 0;
    if (is_pair_member(name, &is_b) && !is_b) {
        fprintf(stderr, "refusing to %s %s: it is \"%s\", a slot-A partition. Slot A is the "
                        "stock firmware every recovery depends on and is never written; do this "
                        "on the slot-B partition instead (pass %s if you really mean it)\n",
                command, target, name, ALLOW_SLOT_A_FLAG);
        return -1;
    }

    return 0;
}
