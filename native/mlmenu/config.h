/* config.h - the MissingLynk component config the menu reads and toggles.
 * Same key=value file the Python CLI writes (/usrdata/missinglynk/config).
 */
#ifndef MLMENU_CONFIG_H
#define MLMENU_CONFIG_H

#define MAX_COMP 16

typedef struct {
    char name[32];
    int on;
} Comp;

int  load_config(Comp *comps);              /* fills comps in file order, returns count */
void save_config(const Comp *comps, int count); /* rewrites the file (same format as the CLI) */
const char *describe(const char *name);     /* one-line description for the menu */

#endif
