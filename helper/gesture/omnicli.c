// omacosy-omni — the scripts' door to OmniWM's socket. A plain C binary
// launches in ~3 ms where omniwmctl (Swift) needs ~36 ms; omacosy-ws and
// omacosy-spawn call this so a Super+Tab or Super+Enter costs one
// round-trip, not three process launches and three python parses.
#include "omniwm.h"
#include "yyjson.h"
#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include <unistd.h>

// Is the focused window in OmniWM's own fullscreen (Super+F)? The query has
// no field for it, so the frame decides: tiles never overlap, and a
// fullscreen window covers every other tile of its workspace. 1 yes, 0 no,
// -1 no answer. frame gets the focused window's frame.
static int focused_covers_a_tile(omniwm* c, double frame[4])
{
	char* r = omniwm_request(c, "query",
		"{\"name\":\"windows\",\"selectors\":{},\"fields\":[\"id\",\"frame\",\"mode\",\"workspace\",\"is-focused\",\"hidden-reason\"]}");
	if (!r) return -1;
	int yes = -1;
	yyjson_doc* d = yyjson_read(r, strlen(r), 0);
	if (d) {
		yyjson_val* list = yyjson_obj_get(omniwm_payload_of(d), "windows");
		yyjson_val *w, *me = NULL;
		size_t i, n;
		yyjson_arr_foreach(list, i, n, w)
			if (yyjson_get_bool(yyjson_obj_get(w, "isFocused"))) me = w;
		const char* mode = me ? yyjson_get_str(yyjson_obj_get(me, "mode")) : NULL;
		if (me && mode && !strcmp(mode, "tiling")) {
			yyjson_val* f = yyjson_obj_get(me, "frame");
			frame[0] = yyjson_get_num(yyjson_obj_get(f, "x"));
			frame[1] = yyjson_get_num(yyjson_obj_get(f, "y"));
			frame[2] = yyjson_get_num(yyjson_obj_get(f, "width"));
			frame[3] = yyjson_get_num(yyjson_obj_get(f, "height"));
			const char* ws = yyjson_get_str(yyjson_obj_get(yyjson_obj_get(me, "workspace"), "id"));
			yes = 0;
			yyjson_arr_foreach(list, i, n, w) {
				if (w == me) continue;
				const char* m = yyjson_get_str(yyjson_obj_get(w, "mode"));
				const char* o = yyjson_get_str(yyjson_obj_get(yyjson_obj_get(w, "workspace"), "id"));
				if (!m || strcmp(m, "tiling") || !ws || !o || strcmp(ws, o)) continue;
				yyjson_val* hidden = yyjson_obj_get(w, "hiddenReason");
				if (hidden && !yyjson_is_null(hidden)) continue;
				yyjson_val* g = yyjson_obj_get(w, "frame");
				double x = yyjson_get_num(yyjson_obj_get(g, "x"));
				double y = yyjson_get_num(yyjson_obj_get(g, "y"));
				double wd = yyjson_get_num(yyjson_obj_get(g, "width"));
				double ht = yyjson_get_num(yyjson_obj_get(g, "height"));
				// contains, not just touches: two tiles passing each other mid-animation overlap, neither holds the other
				if (wd > 0 && ht > 0 && x >= frame[0] && y >= frame[1]
					&& x + wd <= frame[0] + frame[2] && y + ht <= frame[1] + frame[3]) {
					yes = 1;
					break;
				}
			}
		}
		yyjson_doc_free(d);
	}
	free(r);
	return yes;
}

static int usage(void)
{
	fprintf(stderr,
		"usage: omacosy-omni active | numbers | focus <raw-name> | next | prev\n"
		"       omacosy-omni command <name> [args-json]\n"
		"       omacosy-omni query <name> [fields-csv]      (raw response line)\n"
		"       omacosy-omni preselect-for-focused [mult]   (down/right by aspect)\n"
		"       omacosy-omni leave-fullscreen               (Super+F off, tile settled)\n"
		"       omacosy-omni slot <1-9> [move]               (cursor display's set)\n"
		"       omacosy-omni focus-window <window-id>\n"
		"       omacosy-omni window-count | wait-window <baseline> [timeout-ms]\n");
	return 3;
}

int main(int argc, char** argv)
{
	if (argc < 2) return usage();
	const char* op = argv[1];
	if (!strcmp(op, "wait-window")) {
		if (argc < 3) return usage();
		int n = omniwm_wait_window_count_above(atoi(argv[2]), argc > 3 ? atoi(argv[3]) : 2000);
		if (n < 0) return 1;
		printf("%d\n", n);
		return 0;
	}
	omniwm* c = omniwm_new();
	if (!c) { fprintf(stderr, "omacosy-omni: OmniWM socket unavailable\n"); return 2; }
	int rc = 0;
	if (!strcmp(op, "active")) {
		char* a = omniwm_active_workspace(c);
		if (a) printf("%s\n", a); else rc = 1;
		free(a);
	} else if (!strcmp(op, "numbers")) {
		int* nums = NULL;
		int n = omniwm_workspace_numbers(c, &nums);
		for (int i = 0; i < n; i++) printf("%d%s", nums[i], i + 1 < n ? " " : "\n");
		free(nums);
		if (!n) rc = 1;
	} else if (!strcmp(op, "focus") && argc > 2) {
		rc = omniwm_focus_name(c, argv[2]) ? 0 : 1;
	} else if (!strcmp(op, "next") || !strcmp(op, "prev")) {
		int t = omniwm_cycle(c, op[0] == 'n' ? 1 : -1);
		if (t) printf("%d\n", t); else rc = 1;
	} else if (!strcmp(op, "command") && argc > 2) {
		rc = omniwm_command(c, argv[2], argc > 3 ? argv[3] : NULL) ? 0 : 1;
	} else if (!strcmp(op, "query") && argc > 2) {
		char payload[1024], fields[512] = "";
		if (argc > 3) { // csv -> json array
			char* csv = strdup(argv[3]);
			size_t o = 0;
			for (char* tok = strtok(csv, ","); tok; tok = strtok(NULL, ",")) {
				// snprintf returns the WOULD-BE length: unchecked, a long
				// csv walks o past the buffer and the next write is out
				// of bounds (reproduced as SIGBUS in review)
				int n = snprintf(fields + o, sizeof fields - o, "%s\"%s\"", o ? "," : "", tok);
				if (n < 0 || (o += (size_t)n) >= sizeof fields - 1) break;
			}
			free(csv);
		}
		snprintf(payload, sizeof payload, "{\"name\":\"%s\",\"selectors\":{},\"fields\":[%s]}", argv[2], fields);
		char* r = omniwm_request(c, "query", payload);
		if (r) { puts(r); free(r); } else rc = 1;
	} else if (!strcmp(op, "slot") && argc > 2) {
		// Super+N semantics: slot N of the display under the CURSOR —
		// the aerospace-era translation OmniWM's name-global hotkeys
		// lost (its "4" always means the main set's 4). Guest set is
		// named 1N by convention, so base falls out of the cursor
		// display's active workspace.
		char* cur_s = omniwm_active_workspace_under_cursor(c);
		rc = 1;
		if (cur_s) {
			int base = atoi(cur_s) > 9 ? 10 : 0;
			free(cur_s);
			int target = base + atoi(argv[2]);
			if (argc > 3 && !strcmp(argv[3], "move")) {
				char args[64];
				snprintf(args, sizeof args, "{\"workspaceNumber\":%d}", target);
				rc = omniwm_command(c, "move-to-workspace", args) ? 0 : 1;
			} else {
				char name[16];
				snprintf(name, sizeof name, "%d", target);
				rc = omniwm_focus_name(c, name) ? 0 : 1;
			}
		}
	} else if (!strcmp(op, "throw-window") || !strcmp(op, "throw-workspace")) {
		// aerospace-era semantics: the TWIN slot on the other monitor
		// (4 <-> 14), so the twin workspace keeps its meaning — never a
		// whole-workspace move, which conflicts with per-monitor
		// assignment. throw-window moves the focused window;
		// throw-workspace walks every window on the current workspace
		// (focus by id, then move — OmniWM has no move-by-id).
		char* cur_s = omniwm_active_workspace(c);
		rc = 1;
		if (cur_s) {
			int cur = atoi(cur_s);
			int twin = cur <= 9 ? cur + 10 : cur - 10;
			char args[64];
			snprintf(args, sizeof args, "{\"workspaceNumber\":%d}", twin);
			if (!strcmp(op, "throw-window")) {
				rc = omniwm_command(c, "move-to-workspace", args) ? 0 : 1;
			} else {
				char* r = omniwm_request(c, "query",
					"{\"name\":\"windows\",\"selectors\":{},\"fields\":[\"id\",\"workspace\"]}");
				if (r) {
					yyjson_doc* d = yyjson_read(r, strlen(r), 0);
					if (d) {
						yyjson_val* list = yyjson_obj_get(omniwm_payload_of(d), "windows");
						size_t i, m; yyjson_val* w; rc = 0;
						yyjson_arr_foreach(list, i, m, w) {
							const char* ws = yyjson_get_str(yyjson_obj_get(yyjson_obj_get(w, "workspace"), "rawName"));
							const char* wid = yyjson_get_str(yyjson_obj_get(w, "id"));
							if (!ws || !wid || atoi(ws) != cur) continue;
							char fp[256];
							snprintf(fp, sizeof fp, "{\"name\":\"focus\",\"windowId\":\"%s\"}", wid);
							char* fr = omniwm_request(c, "window", fp);
							free(fr);
							usleep(60000); // focus settle before the move
							if (!omniwm_command(c, "move-to-workspace", args)) rc = 1;
						}
						yyjson_doc_free(d);
					}
					free(r);
				}
			}
			free(cur_s);
		}
	} else if (!strcmp(op, "focus-window") && argc > 2) {
		char payload[512];
		snprintf(payload, sizeof payload, "{\"name\":\"focus\",\"windowId\":\"%s\"}", argv[2]);
		char* r = omniwm_request(c, "window", payload);
		rc = r && strstr(r, "\"ok\":true") ? 0 : 1;
		free(r);
	} else if (!strcmp(op, "window-count")) {
		int n = omniwm_window_count(c);
		if (n >= 0) printf("%d\n", n); else rc = 1;
	} else if (!strcmp(op, "leave-fullscreen")) {
		// A window opened beside a Super+F window lands in that window's
		// hidden tile, drawn on top, while the fullscreen one stays (OmniWM
		// 0.7.2). Ending the fullscreen first makes it the ordinary case.
		//
		// The wait is a bounded frame check, not a listener, because OmniWM
		// sends no event for a fullscreen exit. Measured 2026-09-25 (0.7.2,
		// 1440x900, a 2-tile workspace, 3 runs): with layout-changed, focus and
		// windows-changed subscribed before toggle-fullscreen, all three stay
		// silent while the focused frame animates 1424 -> 708 in ~165-200 ms.
		// layout-changed is published only when the workspace-bar projection
		// changes (SurfaceReconciler) and by setWorkspaceLayout;
		// toggleFullscreen only requests a relayout. So poll the focused frame
		// until it no longer covers a tile and reads the same twice, 1 s cap.
		double f[4], last[4] = { 0, 0, 0, 0 };
		if (focused_covers_a_tile(c, f) == 1) {
			rc = omniwm_command(c, "toggle-fullscreen", NULL) ? 0 : 1;
			for (int waited = 0; !rc && waited < 1000; waited += 30) {
				usleep(30000);
				if (focused_covers_a_tile(c, f) == 0 && !memcmp(f, last, sizeof f)) break;
				memcpy(last, f, sizeof f);
			}
		}
	} else if (!strcmp(op, "preselect-for-focused")) {
		// OmniWM's own orientation rule on the focused tile:
		// height * multiplier > width -> vertical split -> new goes below
		double mult = argc > 2 ? atof(argv[2]) : 1.4;
		char* r = omniwm_request(c, "query", "{\"name\":\"focused-window\",\"selectors\":{},\"fields\":[]}");
		const char* dir = NULL;
		if (r) {
			yyjson_doc* d = yyjson_read(r, strlen(r), 0);
			if (d) {
				yyjson_val* w = yyjson_obj_get(omniwm_payload_of(d), "window");
				yyjson_val* f = yyjson_obj_get(w, "frame");
				const char* mode = yyjson_get_str(yyjson_obj_get(w, "mode"));
				if (f && !(mode && !strcmp(mode, "floating"))) {
					double wd = yyjson_get_num(yyjson_obj_get(f, "width"));
					double ht = yyjson_get_num(yyjson_obj_get(f, "height"));
					if (wd > 0 && ht > 0) dir = ht * mult > wd ? "down" : "right";
				}
				yyjson_doc_free(d);
			}
			free(r);
		}
		if (dir) {
			char args[64];
			snprintf(args, sizeof args, "{\"direction\":\"%s\"}", dir);
			rc = omniwm_command(c, "preselect", args) ? 0 : 1;
			printf("%s\n", dir);
		}
	} else rc = usage();
	omniwm_close(c);
	return rc;
}
