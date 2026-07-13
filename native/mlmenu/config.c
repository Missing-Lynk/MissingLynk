/* config.c - read/write the component config and describe components (see config.h).
 * To add a new component to the menu: enable it in the Python CLI (so it lands in the
 * config file) and add a one-line description below. The menu lists whatever the config
 * contains, in file order.
 */
#include "config.h"
#include <stdio.h>
#include <string.h>

#define CONFIG "/usrdata/missinglynk/config"

const char *describe(const char *name)
{
    if (!strcmp(name, "rtsp")) {
        return "live video server on :554";
    }
    if (!strcmp(name, "indicator")) {
        return "on-screen MissingLynk HUD";
    }
    if (!strcmp(name, "dhcp")) {
        return "hand a USB host an IP";
    }
    if (!strcmp(name, "ecm")) {
        return "USB-ethernet mode for Android";
    }

    return "";
}

int load_config(Comp *comps)
{
    FILE *file = fopen(CONFIG, "r");
    if (file == NULL) {
        return 0;
    }
    char line[128];
    int count = 0;
    while (count < MAX_COMP && fgets(line, sizeof line, file)) {
        if (line[0] == '#' || line[0] == '\n') {
            continue;
        }
        char *sep = strchr(line, '=');
        if (sep == NULL) {
            continue;
        }
        *sep = '\0';

        /* "menu" is always-on infrastructure, not a toggleable component; never list it */
        if (!strcmp(line, "menu")) {
            continue;
        }
        snprintf(comps[count].name, sizeof comps[count].name, "%s", line);
        comps[count].on = (strncmp(sep + 1, "on", 2) == 0);
        count++;
    }
    fclose(file);

    return count;
}

void save_config(const Comp *comps, int count)
{
    FILE *file = fopen(CONFIG, "w");
    if (file == NULL) {
        return;
    }
    fprintf(file, "# MissingLynk component config (managed by the CLI; sourced by start.sh)\n");
    for (int i = 0; i < count; i++) {
        fprintf(file, "%s=%s\n", comps[i].name, comps[i].on ? "on" : "off");
    }
    fclose(file);
}
