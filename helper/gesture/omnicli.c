// omacosy-omni — the scripts' door to OmniWM's socket. A plain C binary
// launches in ~3 ms where omniwmctl (Swift) needs ~36 ms; omacosy-ws and
// omacosy-spawn call this so a Super+Tab or Super+Enter costs one
// round-trip, not three process launches and three python parses.
#include "omniwm.h"
#include "yyjson.h"
#include <stdio.h>
#include <stdlib.h>
#include <string.h>

static int usage(void)
{
	fprintf(stderr,
		"usage: omacosy-omni active | numbers | focus <raw-name> | next | prev\n"
		"       omacosy-omni command <name> [args-json]\n"
		"       omacosy-omni query <name> [fields-csv]      (raw response line)\n"
		"       omacosy-omni preselect-for-focused [mult]   (down/right by aspect)\n"
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
			for (char* tok = strtok(csv, ","); tok; tok = strtok(NULL, ","))
				o += (size_t)snprintf(fields + o, sizeof fields - o, "%s\"%s\"", o ? "," : "", tok);
			free(csv);
		}
		snprintf(payload, sizeof payload, "{\"name\":\"%s\",\"selectors\":{},\"fields\":[%s]}", argv[2], fields);
		char* r = omniwm_request(c, "query", payload);
		if (r) { puts(r); free(r); } else rc = 1;
	} else if (!strcmp(op, "window-count")) {
		int n = omniwm_window_count(c);
		if (n >= 0) printf("%d\n", n); else rc = 1;
	} else if (!strcmp(op, "preselect-for-focused")) {
		// OmniWM's own orientation rule on the focused tile:
		// height * multiplier > width -> vertical split -> new goes below
		double mult = argc > 2 ? atof(argv[2]) : 1.4;
		char* r = omniwm_request(c, "query", "{\"name\":\"focused-window\",\"selectors\":{},\"fields\":[]}");
		const char* dir = NULL;
		if (r) {
			yyjson_doc* d = yyjson_read(r, strlen(r), 0);
			if (d) {
				yyjson_val* w = yyjson_obj_get(yyjson_obj_get(yyjson_obj_get(yyjson_doc_get_root(d), "result"), "payload"), "window");
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
