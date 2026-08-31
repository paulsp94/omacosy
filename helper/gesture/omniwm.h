// omniwm.h — persistent OmniWM IPC client (NDJSON over a Unix socket).
//
// Every `omniwmctl` invocation is a ~36 ms process launch; a request on
// a held connection is ~1 ms (measured 2026-08-29). The gesture daemon
// links this directly so a swipe is one round-trip, and the same code
// builds the `omacosy-omni` CLI (~3 ms launch) for the shell scripts.
#pragma once
#include <stdbool.h>
#include <stddef.h>

typedef struct omniwm omniwm;
typedef struct yyjson_doc yyjson_doc;
typedef struct yyjson_val yyjson_val;
// result.payload of a parsed response, NULL unless ok:true — shared so
// the CLI cannot re-walk the envelope and forget the ok check
yyjson_val* omniwm_payload_of(yyjson_doc* d);

// true when OmniWM's socket + secret exist (IPC enabled, WM running)
bool omniwm_available(void);
omniwm* omniwm_new(void); // NULL when unavailable or connect fails
void omniwm_close(omniwm* c);

// One request, one response line (malloc'd, NUL-terminated JSON, or
// NULL). Reconnects once on a dead socket. `payload_json` may be NULL.
char* omniwm_request(omniwm* c, const char* kind, const char* payload_json);

bool omniwm_focus_name(omniwm* c, const char* raw_name);
bool omniwm_command(omniwm* c, const char* name, const char* args_json);
// malloc'd rawName of the current display's active workspace, or NULL
char* omniwm_active_workspace(omniwm* c);
// same, for the display under the CURSOR (falls back to isCurrent)
char* omniwm_active_workspace_under_cursor(omniwm* c);
// numeric workspace names, ascending; returns count, fills *out (malloc'd)
int omniwm_workspace_numbers(omniwm* c, int** out);
// slot-scoped cycle: 1-9 stays in 1-9, guests (>9) stay in guests, wraps.
// step = +1 next, -1 prev. Returns the target number, or 0 on failure.
int omniwm_cycle(omniwm* c, int step);
// blocks until a windows-changed event reports more windows than
// `baseline`, or timeout. Returns the new count, or -1 on timeout.
int omniwm_wait_window_count_above(int baseline, int timeout_ms);
// current window count via query, or -1
int omniwm_window_count(omniwm* c);
