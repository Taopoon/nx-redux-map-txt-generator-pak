// nxlist - list picker / message screen for NX Redux tool paks.
//
// Built inside the NX Redux workspace (see ../../.github/workflows/native.yaml)
// so it draws with the same toolkit as the launcher's Tools menu: the
// ListView widget (menu bar title + clock/battery, gliding pill rows in
// font.large, bottom button-hint bar). Structure follows
// workspace/all/scraper/scraper.c (Artwork Manager).
//
// CLI (subset of minui-list / minui-presenter so launch.sh barely changes):
//   nxlist.elf --file <list.txt> --title <t> [--cancel-text EXIT]
//              [--confirm-text SELECT] --write-location <out>
//              [--disable-auto-sleep]
//     exit 0 = A on a row (label written to --write-location)
//     exit 2 = B, exit 3 = MENU
//   nxlist.elf --message <text> [--timeout <secs>|-1]
//     -1 (default) shows until killed (SIGTERM/SIGINT exit cleanly)
// Unknown flags are ignored (--item-key, --format, --write-value ...).
#include <signal.h>
#include <stdbool.h>
#include <stdio.h>
#include <stdlib.h>
#include <string.h>

#include <msettings.h>

#include "api.h"
#include "defines.h"
#include "paths.h"
#include "ui_list.h"
#include "ui_listview.h"
#include "ui_message.h"
#include "utils.h"

#define MAX_ITEMS 4096

static SDL_Surface* screen;
static volatile sig_atomic_t got_signal = 0;

static char* items[MAX_ITEMS];
static int item_count = 0;

static void on_signal(int sig) {
	(void)sig;
	got_signal = 1;
}

// One label per line; CR/LF stripped, blank lines skipped.
static int read_items(const char* path) {
	FILE* f = fopen(path, "r");
	if (!f)
		return -1;
	char line[1024];
	while (item_count < MAX_ITEMS && fgets(line, sizeof(line), f)) {
		size_t n = strlen(line);
		while (n && (line[n - 1] == '\n' || line[n - 1] == '\r'))
			line[--n] = '\0';
		if (!n)
			continue;
		items[item_count++] = strdup(line);
	}
	fclose(f);
	return item_count;
}

static void list_get_row(void* ctx, int i, bool selected, ListViewRow* out) {
	(void)ctx;
	(void)selected;
	out->label = items[i];
}

static int run_list(const char* title, const char* cancel_text, const char* confirm_text,
					const char* write_location) {
	// hint_pairs must outlive UI_listViewRender (see ui_listview.h)
	static char* hint_pairs[5];
	hint_pairs[0] = "B";
	hint_pairs[1] = (char*)cancel_text;
	hint_pairs[2] = "A";
	hint_pairs[3] = (char*)confirm_text;
	hint_pairs[4] = NULL;

	static ListView view;
	UI_listViewReset(&view, item_count, items);
	view.title = title;
	view.font = font.large;
	view.count = item_count;
	view.get_row = list_get_row;
	view.ctx = NULL;
	view.list_id = (const void*)items;
	view.hint_pairs = hint_pairs;
	view.empty_title = "Nothing to select";

	int rc = 2;
	bool dirty = true;
	IndicatorType show_setting = INDICATOR_NONE;

	while (!got_signal) {
		GFX_startFrame();
		PAD_poll();

		ListViewAction act = UI_listViewHandleInput(&view);
		if (act.type == LISTVIEW_ACTIVATED && act.index >= 0) {
			if (write_location) {
				FILE* out = fopen(write_location, "w");
				if (out) {
					fprintf(out, "%s\n", items[act.index]);
					fclose(out);
				}
			}
			rc = 0;
			break;
		}
		if (act.type == LISTVIEW_BACK) {
			rc = 2;
			break;
		}
		if (act.type == LISTVIEW_MENU) {
			rc = 3;
			break;
		}

		PWR_update(&dirty, &show_setting, NULL, NULL);
		if (UI_statusBarChanged())
			dirty = true;
		if (UI_listViewBusy(&view))
			dirty = true;

		if (dirty) {
			GFX_clear(screen);
			UI_listViewRender(&view, screen);
			GFX_flip(screen);
			dirty = false;
		} else {
			UI_listViewTickIdle(&view);
			GFX_sync();
		}
	}
	return rc;
}

static int run_message(const char* message, int timeout_secs) {
	bool dirty = true;
	IndicatorType show_setting = INDICATOR_NONE;
	uint32_t start = SDL_GetTicks();

	while (!got_signal) {
		if (timeout_secs >= 0 && SDL_GetTicks() - start >= (uint32_t)timeout_secs * 1000u)
			break;
		GFX_startFrame();
		PAD_poll();
		PWR_update(&dirty, &show_setting, NULL, NULL);
		if (dirty) {
			GFX_clear(screen);
			UI_renderCenteredMessage(screen, message);
			GFX_flip(screen);
			dirty = false;
		} else {
			GFX_sync();
		}
	}
	return 0;
}

int main(int argc, char* argv[]) {
	const char* file = NULL;
	const char* title = "";
	const char* cancel_text = "BACK";
	const char* confirm_text = "SELECT";
	const char* write_location = NULL;
	const char* message = NULL;
	int timeout_secs = -1;
	bool disable_auto_sleep = false;

	for (int i = 1; i < argc; i++) {
		const char* a = argv[i];
		const char* v = (i + 1 < argc) ? argv[i + 1] : NULL;
		if (!strcmp(a, "--file") && v) {
			file = v;
			i++;
		} else if (!strcmp(a, "--title") && v) {
			title = v;
			i++;
		} else if (!strcmp(a, "--cancel-text") && v) {
			cancel_text = v;
			i++;
		} else if (!strcmp(a, "--confirm-text") && v) {
			confirm_text = v;
			i++;
		} else if (!strcmp(a, "--write-location") && v) {
			write_location = v;
			i++;
		} else if (!strcmp(a, "--message") && v) {
			message = v;
			i++;
		} else if (!strcmp(a, "--timeout") && v) {
			timeout_secs = atoi(v);
			i++;
		} else if (!strcmp(a, "--disable-auto-sleep")) {
			disable_auto_sleep = true;
		} else if (!strcmp(a, "--item-key") || !strcmp(a, "--format") || !strcmp(a, "--write-value")) {
			i++; // minui-list flags we accept and ignore
		}
		// anything else: ignored
	}

	if (!message) {
		if (!file) {
			fprintf(stderr, "usage: nxlist.elf --file <list> --write-location <out> | --message <text>\n");
			return 1;
		}
		if (read_items(file) < 0) {
			fprintf(stderr, "nxlist: cannot read %s\n", file);
			return 1;
		}
	}

	signal(SIGTERM, on_signal);
	signal(SIGINT, on_signal);

	PATHS_init(PLATFORM);
	screen = GFX_init(MODE_MAIN);
	InitSettings();
	PAD_init();
	PWR_init();
	if (disable_auto_sleep)
		PWR_disableAutosleep();

	int rc = message ? run_message(message, timeout_secs)
					 : run_list(title, cancel_text, confirm_text, write_location);

	QuitSettings();
	PWR_quit();
	PAD_quit();
	GFX_quit();
	return rc;
}
