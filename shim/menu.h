#pragma once
#include <stdint.h>

struct menu_entry {
	const char *title;	/* large, e.g. "iOS 16" */
	const char *detail;	/* small line under it */
	int enabled;		/* disabled entries are drawn dim and skipped */
	const uint8_t *icon;	/* MENU_ICON x MENU_ICON RGB picture (shim/art.S), drawn instead of the text; 0 = text */
	int small;		/* a small button in the bottom right corner (Restart, Power off), title only */
};

#define MENU_ICON	600
extern const uint8_t menu_icon_ios27[], menu_icon_macos27[], menu_icon_android[];

/*
 * Draw the boot menu and return the chosen index. sel = preselected entry; the menu
 * boots it after timeout_ms (0 = wait for a key) unless a key is pressed first.
 */
int menu_choose(const struct menu_entry *e, int n, int sel, unsigned timeout_ms);

/* Clear to the menu background and show one centred line, e.g. "Booting iOS 16". */
void menu_booting(const char *what);
