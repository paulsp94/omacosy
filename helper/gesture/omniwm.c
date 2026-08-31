#include "omniwm.h"
#include "yyjson.h"
#include <errno.h>
#include <pwd.h>
#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include <sys/socket.h>
#include <sys/time.h>
#include <sys/un.h>
#include <unistd.h>
#include <CoreGraphics/CoreGraphics.h>

#define PROTOCOL_VERSION 11

struct omniwm {
	int fd;
	char token[80];
	char* rbuf;
	size_t rlen, rcap;
	unsigned seq;
	int* names; // cached workspace numbers
	int nnames;
};

static void socket_path(char* out, size_t n)
{
	const char* env = getenv("OMNIWM_SOCKET");
	if (env && *env) { snprintf(out, n, "%s", env); return; }
	const char* home = getenv("HOME");
	if (!home || !*home) { struct passwd* pw = getpwuid(getuid()); home = pw ? pw->pw_dir : "/"; }
	snprintf(out, n, "%s/Library/Caches/com.barut.OmniWM/ipc.sock", home);
}

bool omniwm_available(void)
{
	char p[512], s[520];
	socket_path(p, sizeof p);
	snprintf(s, sizeof s, "%s.secret", p);
	return access(p, R_OK) == 0 && access(s, R_OK) == 0;
}

static bool connect_socket(omniwm* c)
{
	char p[512], s[520];
	socket_path(p, sizeof p);
	snprintf(s, sizeof s, "%s.secret", p);
	FILE* f = fopen(s, "r");
	if (!f) return false;
	if (!fgets(c->token, sizeof c->token, f)) { fclose(f); return false; }
	fclose(f);
	c->token[strcspn(c->token, "\r\n")] = 0;
	int fd = socket(AF_UNIX, SOCK_STREAM, 0);
	if (fd < 0) return false;
	int one = 1;
	setsockopt(fd, SOL_SOCKET, SO_NOSIGPIPE, &one, sizeof one);
	struct timeval tv = { 2, 0 };
	setsockopt(fd, SOL_SOCKET, SO_RCVTIMEO, &tv, sizeof tv);
	setsockopt(fd, SOL_SOCKET, SO_SNDTIMEO, &tv, sizeof tv);
	struct sockaddr_un addr = { 0 };
	addr.sun_family = AF_UNIX;
	snprintf(addr.sun_path, sizeof addr.sun_path, "%s", p);
	if (connect(fd, (struct sockaddr*)&addr, sizeof addr) != 0) { close(fd); return false; }
	c->fd = fd;
	c->rlen = 0;
	return true;
}

omniwm* omniwm_new(void)
{
	if (!omniwm_available()) return NULL;
	omniwm* c = calloc(1, sizeof *c);
	c->fd = -1;
	c->rcap = 65536;
	c->rbuf = malloc(c->rcap);
	if (!connect_socket(c)) { omniwm_close(c); return NULL; }
	return c;
}

void omniwm_close(omniwm* c)
{
	if (!c) return;
	if (c->fd >= 0) close(c->fd);
	free(c->rbuf);
	free(c->names);
	free(c);
}

// read one NUL-terminated line (malloc'd, newline stripped) or NULL
static char* read_line(int fd, char* rbuf, size_t* rlen, size_t* rcap)
{
	for (;;) {
		char* nl = memchr(rbuf, '\n', *rlen);
		if (nl) {
			size_t n = (size_t)(nl - rbuf);
			char* line = malloc(n + 1);
			memcpy(line, rbuf, n);
			line[n] = 0;
			memmove(rbuf, nl + 1, *rlen - n - 1);
			*rlen -= n + 1;
			return line;
		}
		if (*rlen == *rcap) { *rcap *= 2; rbuf = realloc(rbuf, *rcap); }
		ssize_t r = recv(fd, rbuf + *rlen, *rcap - *rlen, 0);
		if (r <= 0) return NULL;
		*rlen += (size_t)r;
	}
}

static bool send_all(int fd, const char* s, size_t n)
{
	while (n) {
		ssize_t w = send(fd, s, n, 0);
		if (w <= 0) return false;
		s += w; n -= (size_t)w;
	}
	return true;
}

static char* request_once(omniwm* c, const char* kind, const char* payload_json)
{
	char req[8192];
	int n = payload_json
		? snprintf(req, sizeof req, "{\"version\":%d,\"id\":\"g%u\",\"kind\":\"%s\",\"authorizationToken\":\"%s\",\"payload\":%s}\n",
			PROTOCOL_VERSION, ++c->seq, kind, c->token, payload_json)
		: snprintf(req, sizeof req, "{\"version\":%d,\"id\":\"g%u\",\"kind\":\"%s\",\"authorizationToken\":\"%s\"}\n",
			PROTOCOL_VERSION, ++c->seq, kind, c->token);
	if (n <= 0 || (size_t)n >= sizeof req) return NULL;
	if (!send_all(c->fd, req, (size_t)n)) return NULL;
	return read_line(c->fd, c->rbuf, &c->rlen, &c->rcap);
}

char* omniwm_request(omniwm* c, const char* kind, const char* payload_json)
{
	if (!c) return NULL;
	char* r = c->fd >= 0 ? request_once(c, kind, payload_json) : NULL;
	if (r) return r;
	// dead socket (OmniWM restarted): reconnect once, retry once
	if (c->fd >= 0) close(c->fd);
	c->fd = -1;
	if (!connect_socket(c)) return NULL;
	return request_once(c, kind, payload_json);
}

static bool response_ok(const char* line)
{
	if (!line) return false;
	yyjson_doc* d = yyjson_read(line, strlen(line), 0);
	if (!d) return false;
	bool ok = yyjson_get_bool(yyjson_obj_get(yyjson_doc_get_root(d), "ok"));
	yyjson_doc_free(d);
	return ok;
}

bool omniwm_focus_name(omniwm* c, const char* raw_name)
{
	char payload[256];
	snprintf(payload, sizeof payload,
		"{\"name\":\"focus-name\",\"workspaceTarget\":{\"kind\":\"raw-id\",\"value\":\"%s\"}}", raw_name);
	char* r = omniwm_request(c, "workspace", payload);
	bool ok = response_ok(r);
	free(r);
	return ok;
}

bool omniwm_command(omniwm* c, const char* name, const char* args_json)
{
	char payload[4096];
	if (args_json)
		snprintf(payload, sizeof payload, "{\"name\":\"%s\",\"arguments\":%s}", name, args_json);
	else
		snprintf(payload, sizeof payload, "{\"name\":\"%s\"}", name);
	char* r = omniwm_request(c, "command", payload);
	bool ok = response_ok(r);
	free(r);
	return ok;
}

yyjson_val* omniwm_payload_of(yyjson_doc* d)
{
	yyjson_val* root = yyjson_doc_get_root(d);
	if (!yyjson_get_bool(yyjson_obj_get(root, "ok"))) return NULL;
	return yyjson_obj_get(yyjson_obj_get(root, "result"), "payload");
}

char* omniwm_active_workspace(omniwm* c)
{
	char* r = omniwm_request(c, "query", "{\"name\":\"active-workspace\",\"selectors\":{},\"fields\":[]}");
	if (!r) return NULL;
	char* out = NULL;
	yyjson_doc* d = yyjson_read(r, strlen(r), 0);
	if (d) {
		yyjson_val* p = omniwm_payload_of(d);
		const char* name = yyjson_get_str(yyjson_obj_get(yyjson_obj_get(p, "workspace"), "rawName"));
		if (name) out = strdup(name);
		yyjson_doc_free(d);
	}
	free(r);
	return out;
}

static int cmp_int(const void* a, const void* b) { return *(const int*)a - *(const int*)b; }

int omniwm_workspace_numbers(omniwm* c, int** out)
{
	char* r = omniwm_request(c, "query", "{\"name\":\"workspaces\",\"selectors\":{},\"fields\":[\"raw-name\"]}");
	if (!r) return 0;
	int n = 0;
	int* nums = NULL;
	yyjson_doc* d = yyjson_read(r, strlen(r), 0);
	if (d) {
		yyjson_val* list = yyjson_obj_get(omniwm_payload_of(d), "workspaces");
		size_t idx, max;
		yyjson_val* w;
		nums = malloc(sizeof(int) * (yyjson_arr_size(list) + 1));
		yyjson_arr_foreach(list, idx, max, w) {
			const char* s = yyjson_get_str(yyjson_obj_get(w, "rawName"));
			if (s && *s && strspn(s, "0123456789") == strlen(s)) nums[n++] = atoi(s);
		}
		yyjson_doc_free(d);
	}
	free(r);
	if (n) qsort(nums, (size_t)n, sizeof(int), cmp_int);
	*out = nums;
	return n;
}

// the workspace to cycle is the one under the CURSOR: OmniWM's
// "current display" follows the focused window, and on an empty
// workspace there is none — a swipe over the empty screen would cycle
// the OTHER monitor. Same rule the aerospace-era cursor_monitor patch
// enforced. Falls back to isCurrent when the frames don't resolve.
static char* active_workspace_under_cursor(omniwm* c)
{
	CGEventRef e = CGEventCreate(NULL);
	CGPoint pt = CGEventGetLocation(e); // CG: y grows DOWN from main's top
	CFRelease(e);
	char* r = omniwm_request(c, "query", "{\"name\":\"displays\",\"selectors\":{},\"fields\":[]}");
	if (!r) return NULL;
	char* out = NULL;
	char* fallback = NULL;
	yyjson_doc* d = yyjson_read(r, strlen(r), 0);
	if (d) {
		yyjson_val* list = yyjson_obj_get(omniwm_payload_of(d), "displays");
		size_t i, m;
		yyjson_val* disp;
		// OmniWM frames are APPKIT (y grows up; verified: the laptop
		// reports y=1440 where CG says -982) — lift the CG cursor into
		// AppKit space off the main display's height before testing
		double main_h = 0;
		yyjson_arr_foreach(list, i, m, disp) {
			if (yyjson_get_bool(yyjson_obj_get(disp, "isMain")))
				main_h = yyjson_get_num(yyjson_obj_get(yyjson_obj_get(disp, "frame"), "height"));
		}
		double ak_y = main_h - pt.y;
		yyjson_arr_foreach(list, i, m, disp) {
			const char* ws = yyjson_get_str(yyjson_obj_get(yyjson_obj_get(disp, "activeWorkspace"), "rawName"));
			if (!ws) continue;
			yyjson_val* f = yyjson_obj_get(disp, "frame");
			double x = yyjson_get_num(yyjson_obj_get(f, "x"));
			double y = yyjson_get_num(yyjson_obj_get(f, "y"));
			double w = yyjson_get_num(yyjson_obj_get(f, "width"));
			double h = yyjson_get_num(yyjson_obj_get(f, "height"));
			if (pt.x >= x && pt.x < x + w && ak_y >= y && ak_y < y + h && !out)
				out = strdup(ws);
			if (yyjson_get_bool(yyjson_obj_get(disp, "isCurrent")) && !fallback)
				fallback = strdup(ws);
		}
		yyjson_doc_free(d);
	}
	free(r);
	if (out) { free(fallback); return out; }
	return fallback;
}

int omniwm_cycle(omniwm* c, int step)
{
	char* cur_s = active_workspace_under_cursor(c);
	if (!cur_s) return 0;
	int cur = atoi(cur_s);
	free(cur_s);
	// the workspace set is static config — fetch once, refetch only if
	// the current workspace is not in it
	bool known = false;
	for (int i = 0; i < c->nnames; i++) if (c->names[i] == cur) known = true;
	if (!known) {
		free(c->names);
		c->names = NULL;
		c->nnames = omniwm_workspace_numbers(c, &c->names);
	}
	int set[64], k = 0, idx = 0;
	for (int i = 0; i < c->nnames && k < 64; i++)
		if ((c->names[i] <= 9) == (cur <= 9)) { if (c->names[i] == cur) idx = k; set[k++] = c->names[i]; }
	if (!k) return 0;
	int target = set[((idx + step) % k + k) % k];
	char name[16];
	snprintf(name, sizeof name, "%d", target);
	return omniwm_focus_name(c, name) ? target : 0;
}

int omniwm_window_count(omniwm* c)
{
	char* r = omniwm_request(c, "query", "{\"name\":\"windows\",\"selectors\":{},\"fields\":[\"id\"]}");
	if (!r) return -1;
	int n = -1;
	yyjson_doc* d = yyjson_read(r, strlen(r), 0);
	if (d) {
		yyjson_val* list = yyjson_obj_get(omniwm_payload_of(d), "windows");
		if (list) n = (int)yyjson_arr_size(list);
		yyjson_doc_free(d);
	}
	free(r);
	return n;
}

int omniwm_wait_window_count_above(int baseline, int timeout_ms)
{
	// a dedicated connection: subscriptions turn the stream into events
	omniwm* s = omniwm_new();
	if (!s) return -1;
	char* ack = omniwm_request(s, "subscribe",
		"{\"channels\":[\"windows-changed\"],\"allChannels\":false,\"sendInitial\":false}");
	free(ack);
	struct timeval tv = { timeout_ms / 1000, (timeout_ms % 1000) * 1000 };
	setsockopt(s->fd, SOL_SOCKET, SO_RCVTIMEO, &tv, sizeof tv);
	int result = -1;
	for (;;) {
		char* line = read_line(s->fd, s->rbuf, &s->rlen, &s->rcap);
		if (!line) break; // timeout or dead
		yyjson_doc* d = yyjson_read(line, strlen(line), 0);
		if (d) {
			yyjson_val* list = yyjson_obj_get(omniwm_payload_of(d), "windows");
			int n = list ? (int)yyjson_arr_size(list) : -1;
			yyjson_doc_free(d);
			if (n > baseline) { result = n; free(line); break; }
		}
		free(line);
	}
	omniwm_close(s);
	return result;
}
