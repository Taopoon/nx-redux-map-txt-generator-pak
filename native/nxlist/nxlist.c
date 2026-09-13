// nxlist - list picker / message / wizard screens for NX Redux tool paks.
//
// Built inside the NX Redux workspace (see ../../.github/workflows/native.yaml)
// so it draws with the same toolkit as the launcher's Tools menu: the
// ListView widget (menu bar title + clock/battery, gliding pill rows in
// font.large, bottom button-hint bar). Structure follows
// workspace/all/scraper/scraper.c (Artwork Manager).
//
// Modes
//   list:    nxlist.elf --file <list.txt> --title <t> [--cancel-text EXIT]
//                       [--confirm-text SELECT] --write-location <out>
//            exit 0 = A on a row (label written), 2 = B, 3 = MENU
//   message: nxlist.elf --message <text> [--timeout <secs>|-1]
//            -1 (default) shows until killed (SIGTERM/SIGINT exit cleanly)
//   wizard:  nxlist.elf --wizard [--app-title <t>]
//                       --step "<title>|<cancel>|<listfile>" ...
//                       --exec "<command>"
//            One process for the whole session (no black-outs between
//            screens). Steps are ListViews; A advances, B goes back one step
//            (B on the first step exits 2, MENU exits 3). In step N>1 the
//            title's %s / the file's %d are the previous step's selected
//            label / 0-based index. A on the last step runs
//              <command> '<sel1>' '<sel2>' ...
//            through popen while a status screen is shown. The command's
//            stdout drives the UI:  @MSG <text>     status line while running
//                                   @RESULT <text>  result headline
//                                   @DETAIL <text>  result second line
//            (other lines are forwarded to stderr). The result screen waits
//            for A (OK), then the wizard returns to the first step.
// Common:    --disable-auto-sleep. Unknown flags are ignored (--item-key,
//            --format, --write-value ...).
#include <errno.h>
#include <fcntl.h>
#include <signal.h>
#include <stdbool.h>
#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include <sys/wait.h>
#include <unistd.h>

#include <msettings.h>

#include "api.h"
#include "defines.h"
#include "paths.h"
#include "ui_buttonhintbar.h"
#include "ui_list.h"
#include "ui_listview.h"
#include "ui_menubar.h"
#include "ui_message.h"
#include "utils.h"

#define MAX_ITEMS 4096
#define MAX_STEPS 8
#define LINE_MAX_LEN 1024

static SDL_Surface* screen;
static volatile sig_atomic_t got_signal = 0;

static void on_signal(int sig) {
	(void)sig;
	got_signal = 1;
}

// ---------------------------------------------------------------- lists

typedef struct {
	char** items;
	int count;
} ItemList;

static void list_free(ItemList* l) {
	for (int i = 0; i < l->count; i++)
		free(l->items[i]);
	free(l->items);
	l->items = NULL;
	l->count = 0;
}

// One label per line; CR/LF stripped, blank lines skipped. Returns -1 when
// the file cannot be opened.
static int list_load(ItemList* l, const char* path) {
	list_free(l);
	FILE* f = fopen(path, "r");
	if (!f)
		return -1;
	l->items = calloc(MAX_ITEMS, sizeof(char*));
	char line[LINE_MAX_LEN];
	while (l->count < MAX_ITEMS && fgets(line, sizeof(line), f)) {
		size_t n = strlen(line);
		while (n && (line[n - 1] == '\n' || line[n - 1] == '\r'))
			line[--n] = '\0';
		if (!n)
			continue;
		l->items[l->count++] = strdup(line);
	}
	fclose(f);
	return l->count;
}

static void list_get_row(void* ctx, int i, bool selected, ListViewRow* out) {
	(void)selected;
	ItemList* l = ctx;
	out->label = l->items[i];
}

// --------------------------------------------------------- frame helpers

// Standard NX Redux idle/dirty frame tail (scraper.c main loop).
static void frame_end(ListView* v, bool* dirty, IndicatorType* show_setting, void (*render)(void*), void* ctx) {
	PWR_update(dirty, show_setting, NULL, NULL);
	if (UI_statusBarChanged())
		*dirty = true;
	if (v && UI_listViewBusy(v))
		*dirty = true;
	if (*dirty) {
		render(ctx);
		*dirty = false;
	} else {
		if (v)
			UI_listViewTickIdle(v);
		GFX_sync();
	}
}

static void render_listview(void* ctx) {
	GFX_clear(screen);
	UI_listViewRender((ListView*)ctx, screen);
	GFX_flip(screen);
}

// Menu bar + centred headline (font.large) and optional second line
// (font.small), like UI_renderLoadingOverlay but on a cleared screen.
static void render_text_screen(const char* bar_title, const char* headline, const char* detail, char** hints) {
	GFX_clear(screen);
	UI_renderMenuBar(screen, bar_title);
	int title_h = TTF_FontHeight(font.large);
	int total_h = title_h;
	if (detail && detail[0])
		total_h += SCALE1(4) + TTF_FontHeight(font.small);
	int y = (screen->h - total_h) / 2;
	GFX_blitMessage(font.large, (char*)headline, screen, &(SDL_Rect){0, y, screen->w, title_h});
	if (detail && detail[0]) {
		y += title_h + SCALE1(4);
		GFX_blitMessage(font.small, (char*)detail, screen, &(SDL_Rect){0, y, screen->w, TTF_FontHeight(font.small)});
	}
	if (hints)
		UI_renderButtonHintBar(screen, hints);
	GFX_flip(screen);
}

// ------------------------------------------------------------- list mode

static int run_list(const char* file, const char* title, const char* cancel_text,
					const char* confirm_text, const char* write_location) {
	static ItemList list;
	if (list_load(&list, file) < 0) {
		fprintf(stderr, "nxlist: cannot read %s\n", file);
		return 1;
	}
	static char* hint_pairs[5];
	hint_pairs[0] = "B";
	hint_pairs[1] = (char*)cancel_text;
	hint_pairs[2] = "A";
	hint_pairs[3] = (char*)confirm_text;
	hint_pairs[4] = NULL;

	static ListView view;
	UI_listViewReset(&view, list.count, list.items);
	view.title = title;
	view.font = font.large;
	view.count = list.count;
	view.get_row = list_get_row;
	view.ctx = &list;
	view.list_id = (const void*)list.items;
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
					fprintf(out, "%s\n", list.items[act.index]);
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
		frame_end(&view, &dirty, &show_setting, render_listview, &view);
	}
	return rc;
}

// ---------------------------------------------------------- message mode

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

// ----------------------------------------------------------- wizard mode

typedef struct {
	const char* title_tpl; // "%s" = previous step's selected label
	const char* cancel_text;
	const char* file_tpl; // "%d" = previous step's selected index
	char title[LINE_MAX_LEN];
	char file[LINE_MAX_LEN];
	char* hints[5];
	ItemList list;
	ListView view;
	int selected; // committed selection (index into list)
} Step;

static Step steps[MAX_STEPS];
static int step_count = 0;
static const char* app_title = "";
static const char* exec_cmd = NULL;

// Expand %s (label) / %d (index) of the previous step; "%%" stays "%".
static void expand(const char* tpl, const char* label, int index, char* out, size_t size) {
	size_t o = 0;
	for (const char* p = tpl; *p && o + 1 < size; p++) {
		if (p[0] == '%' && p[1] == 's') {
			o += snprintf(out + o, size - o, "%s", label ? label : "");
			p++;
		} else if (p[0] == '%' && p[1] == 'd') {
			o += snprintf(out + o, size - o, "%d", index);
			p++;
		} else if (p[0] == '%' && p[1] == '%') {
			out[o++] = '%';
			p++;
		} else {
			out[o++] = *p;
		}
		if (o >= size)
			o = size - 1;
	}
	out[o] = '\0';
}

// Parse "<title>|<cancel>|<file>" into a step.
static bool step_parse(Step* s, const char* spec) {
	char* copy = strdup(spec);
	char* a = copy;
	char* b = strchr(a, '|');
	if (!b)
		return false;
	*b++ = '\0';
	char* c = strchr(b, '|');
	if (!c)
		return false;
	*c++ = '\0';
	s->title_tpl = a;
	s->cancel_text = b;
	s->file_tpl = c;
	s->selected = -1;
	return true;
}

// (Re)load step k's list for the current previous-step selection and reset
// its ListView. Returns false when the list file is missing/empty.
static bool step_enter(int k) {
	Step* s = &steps[k];
	const char* prev_label = NULL;
	int prev_index = -1;
	if (k > 0) {
		Step* p = &steps[k - 1];
		prev_index = p->selected;
		prev_label = (prev_index >= 0) ? p->list.items[prev_index] : "";
	}
	expand(s->title_tpl, prev_label, prev_index, s->title, sizeof(s->title));
	expand(s->file_tpl, prev_label, prev_index, s->file, sizeof(s->file));

	if (list_load(&s->list, s->file) <= 0) {
		fprintf(stderr, "nxlist: step %d list %s missing or empty\n", k + 1, s->file);
		return false;
	}
	s->hints[0] = "B";
	s->hints[1] = (char*)s->cancel_text;
	s->hints[2] = "A";
	s->hints[3] = "SELECT";
	s->hints[4] = NULL;

	UI_listViewReset(&s->view, s->list.count, s->list.items);
	s->view.title = s->title;
	s->view.font = font.large;
	s->view.count = s->list.count;
	s->view.get_row = list_get_row;
	s->view.ctx = &s->list;
	s->view.list_id = (const void*)s->list.items;
	s->view.hint_pairs = s->hints;
	s->view.empty_title = "Nothing to select";
	return true;
}

// Single-quote a string for /bin/sh.
static void shell_quote(const char* in, char* out, size_t size) {
	size_t o = 0;
	if (o + 1 < size)
		out[o++] = '\'';
	for (const char* p = in; *p && o + 5 < size; p++) {
		if (*p == '\'') {
			memcpy(out + o, "'\\''", 4);
			o += 4;
		} else {
			out[o++] = *p;
		}
	}
	if (o + 1 < size)
		out[o++] = '\'';
	out[o] = '\0';
}

typedef struct {
	char status[LINE_MAX_LEN];
	char result[LINE_MAX_LEN];
	char detail[LINE_MAX_LEN];
} RunState;

static void render_running(void* ctx) {
	RunState* r = ctx;
	render_text_screen(app_title, r->status, NULL, NULL);
}

// Consume one complete stdout line from the child.
static void handle_child_line(RunState* r, char* line, bool* dirty) {
	if (!strncmp(line, "@MSG ", 5)) {
		snprintf(r->status, sizeof(r->status), "%s", line + 5);
		*dirty = true;
	} else if (!strncmp(line, "@RESULT ", 8)) {
		snprintf(r->result, sizeof(r->result), "%s", line + 8);
	} else if (!strncmp(line, "@DETAIL ", 8)) {
		snprintf(r->detail, sizeof(r->detail), "%s", line + 8);
	} else {
		fprintf(stderr, "%s\n", line);
	}
}

// Run exec_cmd with the committed selections as arguments, showing the
// status screen and keeping the frame loop (PWR_update, indicators) alive.
// Fills r->result/detail; returns the command's exit status.
static int run_exec(RunState* r) {
	char cmd[8192];
	size_t o = snprintf(cmd, sizeof(cmd), "%s", exec_cmd);
	for (int k = 0; k < step_count && o < sizeof(cmd) - 4; k++) {
		char q[LINE_MAX_LEN * 2];
		shell_quote(steps[k].list.items[steps[k].selected], q, sizeof(q));
		o += snprintf(cmd + o, sizeof(cmd) - o, " %s", q);
	}
	fprintf(stderr, "nxlist: exec %s\n", cmd);

	snprintf(r->status, sizeof(r->status), "Working...");
	r->result[0] = r->detail[0] = '\0';

	FILE* fp = popen(cmd, "r");
	if (!fp) {
		snprintf(r->result, sizeof(r->result), "Failed to start command");
		snprintf(r->detail, sizeof(r->detail), "%s", strerror(errno));
		return 1;
	}
	int fd = fileno(fp);
	fcntl(fd, F_SETFL, fcntl(fd, F_GETFL) | O_NONBLOCK);

	char buf[LINE_MAX_LEN];
	size_t len = 0;
	bool eof = false;
	bool dirty = true;
	IndicatorType show_setting = INDICATOR_NONE;

	while (!eof && !got_signal) {
		GFX_startFrame();
		PAD_poll();

		// drain whatever the child wrote since the last frame
		for (;;) {
			ssize_t n = read(fd, buf + len, sizeof(buf) - 1 - len);
			if (n > 0) {
				len += (size_t)n;
				buf[len] = '\0';
				char* nl;
				while ((nl = memchr(buf, '\n', len))) {
					*nl = '\0';
					handle_child_line(r, buf, &dirty);
					size_t rest = len - (size_t)(nl + 1 - buf);
					memmove(buf, nl + 1, rest);
					len = rest;
					buf[len] = '\0';
				}
				if (len == sizeof(buf) - 1) // overlong line: drop it
					len = 0;
			} else if (n == 0) {
				eof = true;
				break;
			} else {
				if (errno != EAGAIN && errno != EINTR)
					eof = true;
				break;
			}
		}
		frame_end(NULL, &dirty, &show_setting, render_running, r);
	}
	if (len) {
		buf[len] = '\0';
		handle_child_line(r, buf, &dirty);
	}
	int status = pclose(fp);
	int code = WIFEXITED(status) ? WEXITSTATUS(status) : 1;
	if (!r->result[0])
		snprintf(r->result, sizeof(r->result), code == 0 ? "Done" : "Failed (exit %d)", code);
	return code;
}

static void render_result(void* ctx) {
	RunState* r = ctx;
	static char* ok_hints[] = {"A", "OK", NULL};
	render_text_screen(app_title, r->result, r->detail, ok_hints);
}

// Result screen: wait for A (or B).
static void wait_ok(RunState* r) {
	bool dirty = true;
	IndicatorType show_setting = INDICATOR_NONE;
	PAD_reset();
	while (!got_signal) {
		GFX_startFrame();
		PAD_poll();
		if (PAD_justPressed(BTN_A) || PAD_justPressed(BTN_B))
			break;
		frame_end(NULL, &dirty, &show_setting, render_result, r);
	}
}

static int run_wizard(void) {
	if (step_count == 0 || !exec_cmd) {
		fprintf(stderr, "nxlist: --wizard needs at least one --step and --exec\n");
		return 1;
	}
	if (!step_enter(0))
		return 1;

	int k = 0;
	bool dirty = true;
	IndicatorType show_setting = INDICATOR_NONE;
	static RunState run;

	while (!got_signal) {
		Step* s = &steps[k];
		GFX_startFrame();
		PAD_poll();

		ListViewAction act = UI_listViewHandleInput(&s->view);
		if (act.type == LISTVIEW_MENU)
			return 3;
		if (act.type == LISTVIEW_BACK) {
			if (k == 0)
				return 2;
			k--;
			dirty = true;
			continue;
		}
		if (act.type == LISTVIEW_ACTIVATED && act.index >= 0) {
			s->selected = act.index;
			if (k + 1 < step_count) {
				if (step_enter(k + 1))
					k++;
				dirty = true;
				continue;
			}
			run_exec(&run);
			wait_ok(&run);
			k = 0;
			dirty = true;
			continue;
		}
		frame_end(&s->view, &dirty, &show_setting, render_listview, &s->view);
	}
	return 2;
}

// ------------------------------------------------------------------ main

int main(int argc, char* argv[]) {
	const char* file = NULL;
	const char* title = "";
	const char* cancel_text = "BACK";
	const char* confirm_text = "SELECT";
	const char* write_location = NULL;
	const char* message = NULL;
	int timeout_secs = -1;
	bool disable_auto_sleep = false;
	bool wizard = false;

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
		} else if (!strcmp(a, "--wizard")) {
			wizard = true;
		} else if (!strcmp(a, "--app-title") && v) {
			app_title = v;
			i++;
		} else if (!strcmp(a, "--step") && v) {
			if (step_count < MAX_STEPS && step_parse(&steps[step_count], v))
				step_count++;
			else
				fprintf(stderr, "nxlist: bad --step '%s'\n", v);
			i++;
		} else if (!strcmp(a, "--exec") && v) {
			exec_cmd = v;
			i++;
		} else if (!strcmp(a, "--disable-auto-sleep")) {
			disable_auto_sleep = true;
		} else if (!strcmp(a, "--item-key") || !strcmp(a, "--format") || !strcmp(a, "--write-value")) {
			i++; // minui-list flags we accept and ignore
		}
		// anything else: ignored
	}

	if (!wizard && !message && !file) {
		fprintf(stderr, "usage: nxlist.elf --file <list> --write-location <out> | --message <text> | --wizard --step ... --exec ...\n");
		return 1;
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

	int rc;
	if (wizard)
		rc = run_wizard();
	else if (message)
		rc = run_message(message, timeout_secs);
	else
		rc = run_list(file, title, cancel_text, confirm_text, write_location);

	QuitSettings();
	PWR_quit();
	PAD_quit();
	GFX_quit();
	return rc;
}
