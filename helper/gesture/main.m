// omacosy-gesture — the trackpad gesture engine.
//
// Absorbed from acsandmann/aerospace-swipe (MIT, notice kept in
// LICENSE.aerospace-swipe) on 2026-08-28, with omacosy's accumulated
// fixes folded in: raw MultitouchSupport frames (macOS 26.3 stopped
// carrying multi-touch data in CGEvent taps), socket recovery and
// binary resolution after docking, wake re-registration, per-direction
// command overrides, and shell execution for any direction. Under
// AeroSpace the horizontal swipes still talk to its socket directly
// (fast path); under OmniWM every direction runs a command. One engine
// for both window managers.
//
#include "Carbon/Carbon.h"
#include "Cocoa/Cocoa.h"
#include "aerospace.h"
#include "config.h"
#include "omniwm.h"
#include <pthread.h>
#import "event_tap.h"
#include "haptic.h"
#include <AppKit/AppKit.h>
#import <ApplicationServices/ApplicationServices.h>
#include <pthread.h>
#include <IOKit/IOKitLib.h>

static aerospace* g_aerospace = NULL;
static CFTypeRef g_haptic = NULL;
static Config g_config;
static pthread_mutex_t g_gesture_mutex = PTHREAD_MUTEX_INITIALIZER;
static CFMutableDictionaryRef g_tracks = NULL;

// --- raw MultitouchSupport detection -----------------------------------
// On macOS 26.3 a CGEvent tap no longer carries multi-touch data (each
// gesture event exposes at most one NSTouch), so the event-tap path can
// never see the configured finger count. Raw contact frames from the
// private MultitouchSupport framework still deliver every finger with
// position and velocity; feed those into the same gesture engine.
typedef struct { float x, y; } mtPoint;
typedef struct { mtPoint pos, vel; } mtReadout;
typedef struct {
	int frame;
	double timestamp;
	int identifier, state, foo3, foo4;
	mtReadout normalized;
	float size;
	int zero1;
	float angle, majorAxis, minorAxis;
	mtReadout mm;
	int zero2[2];
	float unk2;
} MTFinger;
typedef void* MTDeviceRef;
typedef int (*MTContactCallbackFunction)(int, MTFinger*, int, double, int);
CFMutableArrayRef MTDeviceCreateList(void);
void MTRegisterContactFrameCallback(MTDeviceRef, MTContactCallbackFunction);
void MTUnregisterContactFrameCallback(MTDeviceRef, MTContactCallbackFunction);
void MTDeviceStart(MTDeviceRef, int);
void MTDeviceStop(MTDeviceRef);

typedef uint64_t IOHIDRequestType;
enum { kIOHIDRequestTypeListenEvent = 1 };
extern bool IOHIDRequestAccess(IOHIDRequestType);

// Trackpads HOTPLUG (docking, bluetooth): MTDeviceCreateList returns
// fresh refs each call, so device identity is the hardware id. New
// devices get the contact callback; a KNOWN id re-enumerating is
// swapped onto its fresh ref — the previous registration dies with
// the transport (dock detach, bluetooth drop), and skipping the id
// left a silently dead trackpad. The old ref is stopped before the
// fresh one starts, so gestures are never doubled.
extern OSStatus MTDeviceGetDeviceID(MTDeviceRef, uint64_t*);
static int mt_contact_callback(int device, MTFinger* data, int nFingers,
	double timestamp, int frame);
static void gesture_release_device(int key);
static uint64_t g_dev_ids[16];
static MTDeviceRef g_dev_refs[16];
static int g_dev_count = 0;

static void hid_device_appeared(void* refcon, io_iterator_t iter);

static int register_new_devices(void)
{
	CFArrayRef list = MTDeviceCreateList();
	if (!list)
		return 0;
	int added = 0;
	for (CFIndex i = 0; i < CFArrayGetCount(list); ++i) {
		MTDeviceRef dev = (MTDeviceRef)CFArrayGetValueAtIndex(list, i);
		uint64_t did = 0;
		if (MTDeviceGetDeviceID(dev, &did) != 0 || did == 0)
			did = (uint64_t)(uintptr_t)dev;
		int slot = -1;
		for (int j = 0; j < g_dev_count; ++j)
			if (g_dev_ids[j] == did) { slot = j; break; }
		if (slot >= 0) {
			// known id, fresh ref: retire the old registration (its
			// gesture slot too — the callback keys on the ref word)
			MTDeviceRef old = g_dev_refs[slot];
			if (old) {
				MTUnregisterContactFrameCallback(old, mt_contact_callback);
				MTDeviceStop(old);
				gesture_release_device((int)(uintptr_t)old);
				CFRelease(old);
			}
			CFRetain(dev);
			g_dev_refs[slot] = dev;
			MTRegisterContactFrameCallback(dev, mt_contact_callback);
			MTDeviceStart(dev, 0);
			continue;
		}
		if (g_dev_count >= 16)
			continue;
		g_dev_ids[g_dev_count] = did;
		CFRetain(dev);
		g_dev_refs[g_dev_count] = dev;
		g_dev_count++;
		MTRegisterContactFrameCallback(dev, mt_contact_callback);
		MTDeviceStart(dev, 0);
		added++;
	}
	CFRelease(list);
	return added;
}

static void hid_device_appeared(void* refcon, io_iterator_t iter)
{
	(void)refcon;
	io_object_t obj;
	while ((obj = IOIteratorNext(iter)))
		IOObjectRelease(obj); // drain re-arms the notification
	int n = register_new_devices();
	if (n)
		NSLog(@"Multitouch: %d new device(s) on HID attach, %d total.", n, g_dev_count);
	// some trackpads publish their multitouch service a moment after
	// their HID service — one delayed follow-up, event-triggered
	dispatch_after(dispatch_time(DISPATCH_TIME_NOW, 2 * NSEC_PER_SEC),
		dispatch_get_main_queue(), ^{
			int m = register_new_devices();
			if (m)
				NSLog(@"Multitouch: %d late device(s), %d total.", m, g_dev_count);
		});
}

// AeroSpace numbers monitors by arrangement (left to right), so sorting
// CG displays by x-origin gives the same ids. Returns 0 on failure.
static int monitor_under_cursor(void)
{
	CGEventRef ev = CGEventCreate(NULL);
	if (!ev)
		return 0;
	CGPoint p = CGEventGetLocation(ev);
	CFRelease(ev);

	CGDirectDisplayID ids[8];
	uint32_t n = 0;
	if (CGGetActiveDisplayList(8, ids, &n) != kCGErrorSuccess || !n)
		return 0;

	// sort by x-origin (tiny n, insertion sort)
	for (uint32_t i = 1; i < n; ++i)
		for (uint32_t j = i; j > 0; --j)
			if (CGDisplayBounds(ids[j]).origin.x < CGDisplayBounds(ids[j - 1]).origin.x) {
				CGDirectDisplayID t = ids[j];
				ids[j] = ids[j - 1];
				ids[j - 1] = t;
			}

	for (uint32_t i = 0; i < n; ++i)
		if (CGRectContainsPoint(CGDisplayBounds(ids[i]), p))
			return (int)i + 1;
	return 0;
}

// Step to the neighbouring workspace of the monitor the cursor is on
// (native-Spaces semantics: the swipe acts where the pointer is, never
// on the other monitor). Returns false so the caller can fall back to
// focused-monitor stepping when the cursor's monitor or its visible
// workspace can't be resolved.
static bool switch_on_cursor_monitor(const char* ws)
{
	int mon = monitor_under_cursor();
	if (!mon)
		return false;
	int dir = strcmp(ws, "next") == 0 ? 1 : strcmp(ws, "prev") == 0 ? -1 : 0;
	if (!dir)
		return false;

	char mon_str[16];
	snprintf(mon_str, sizeof mon_str, "%d", mon);

	const char* vis_args[] = { "list-workspaces", "--monitor", mon_str, "--visible" };
	char* visible = aerospace_exec(g_aerospace, vis_args, 4, "stdout");
	if (!visible)
		return false;
	visible[strcspn(visible, "\r\n")] = '\0';

	const char* list_args[] = { "list-workspaces", "--monitor", mon_str, "--empty", "no" };
	char* list = aerospace_exec(g_aerospace, list_args, g_config.skip_empty ? 5 : 3, "stdout");
	if (!list) {
		free(visible);
		return false;
	}

	char* names[64];
	int count = 0, cur = -1;
	for (char* tok = strtok(list, "\r\n"); tok && count < 64; tok = strtok(NULL, "\r\n")) {
		if (!*tok)
			continue;
		names[count] = tok;
		if (strcmp(tok, visible) == 0)
			cur = count;
		count++;
	}

	bool ok = false;
	if (count > 0 && cur >= 0) {
		int next = cur + dir;
		if (g_config.wrap_around)
			next = (next + count) % count;
		if (next >= 0 && next < count && next != cur) {
			const char* sw_args[] = { "workspace", names[next] };
			char* result = aerospace_exec(g_aerospace, sw_args, 2, NULL);
			free(result);
			printf("Switched monitor %s to workspace '%s'.\n", mon_str, names[next]);
			ok = true;
		} else {
			ok = true; // at the edge without wrap: consume the swipe, do nothing
		}
	}

	free(visible);
	free(list);
	return ok;
}

// Raw multitouch contacts emit no CGEvents, so omacosy's focus guard
// (which bounces workspace switches made without recent user input)
// can't see a swipe. Stamp a file it checks instead. O_TRUNC on an
// existing file refreshes its mtime — that IS the timestamp.
static void stamp_user_intent(void)
{
	char path[128];
	snprintf(path, sizeof path, "/tmp/omacosy-user-intent-%d", getuid());
	int fd = open(path, O_CREAT | O_WRONLY | O_TRUNC, 0600);
	if (fd >= 0)
		close(fd);
}

static omniwm* g_omni; // held OmniWM IPC connection (lazy)
static pthread_mutex_t g_omni_lock = PTHREAD_MUTEX_INITIALIZER;

static void switch_workspace(const char* ws)
{
	// OmniWM: the slot-scoped cycle runs in-process on a held IPC
	// connection — one round-trip (~1 ms, plus OmniWM's own switch
	// work) instead of shell + omniwmctl (~80 ms). fire_horizontal
	// dispatches concurrently, so the connection is serialized.
	if ((!strcmp(ws, "next") || !strcmp(ws, "prev")) && omniwm_available()) {
		pthread_mutex_lock(&g_omni_lock);
		if (!g_omni)
			g_omni = omniwm_new();
		int target = g_omni ? omniwm_cycle(g_omni, ws[0] == 'n' ? 1 : -1) : 0;
		pthread_mutex_unlock(&g_omni_lock);
		if (target) {
			stamp_user_intent();
			printf("Switched workspace (omniwm) to '%d'.\n", target);
			if (g_config.haptic && g_haptic)
				haptic_actuate(g_haptic, 3);
			return;
		}
		// a stale socket file after OmniWM quit: fall through to the
		// aerospace path below rather than eating the swipe
		fprintf(stderr, "omniwm: cycle failed, falling back to aerospace path\n");
	}
	// omacosy: a direction that looks like a COMMAND is run like the
	// vertical gestures are — OmniWM mode routes horizontal through
	// omniwmctl, keeping this engine's tuned mid-gesture thresholds
	// (OmniWM's own swipe commits late and cannot be tuned). Called
	// from fire_horizontal's dispatch_async, so popen may block here.
	if (strchr(ws, '/')) {
		stamp_user_intent();
		FILE* p = popen(ws, "r");
		if (p) {
			char drain[256];
			while (fread(drain, 1, sizeof drain, p) > 0) { }
			pclose(p);
		}
		else
			fprintf(stderr, "Error: failed to run horizontal swipe command '%s'.\n", ws);
		return;
	}
	stamp_user_intent();
	if (g_config.cursor_monitor) {
		// on a transient resolve failure (mid-switch races) CONSUME
		// the swipe: the old global fallback walked the combined
		// workspace list and jumped monitors under per-monitor sets
		if (switch_on_cursor_monitor(ws) && g_config.haptic && g_haptic)
			haptic_actuate(g_haptic, 3);
		return;
	}

	if (g_config.skip_empty || g_config.wrap_around) {
		char* workspaces = aerospace_list_workspaces(g_aerospace, !g_config.skip_empty);
		if (!workspaces) {
			fprintf(stderr, "Error: Unable to retrieve workspace list.\n");
			return;
		}
		char* result = aerospace_workspace(g_aerospace, g_config.wrap_around, ws, workspaces);
		if (result) {
			fprintf(stderr, "Error: Failed to switch workspace to '%s'.\n", ws);
		} else {
			printf("Switched workspace successfully to '%s'.\n", ws);
		}
		free(workspaces);
		free(result);
	} else {
		char* result = aerospace_switch(g_aerospace, ws);
		if (result) {
			fprintf(stderr, "Error: Failed to switch workspace: '%s'\n", result);
		} else {
			printf("Switched workspace successfully to '%s'.\n", ws);
		}
		free(result);
	}

	if (g_config.haptic && g_haptic)
		haptic_actuate(g_haptic, 3);
}

static void reset_gesture_state(gesture_ctx* ctx)
{
	ctx->state = GS_IDLE;
	ctx->last_fire_dir = 0;
}

static bool overlay_active(void)
{
	char path[128];
	snprintf(path, sizeof path, "/tmp/omacosy-overlay-active-%d", getuid());
	FILE* f = fopen(path, "r");
	if (!f)
		return false;
	int pid = 0;
	int got = fscanf(f, "%d", &pid);
	fclose(f);
	// a flag whose writer died (crash while visible) must not gate
	// horizontal swipes forever
	if (got != 1 || pid <= 0 || kill((pid_t)pid, 0) != 0) {
		unlink(path);
		return false;
	}
	return true;
}

static void fire_gesture(gesture_ctx* ctx, int direction)
{
	if (direction == ctx->last_fire_dir)
		return;
	// the workspace overview is up: finger lift-off after the vertical
	// swipe reads as a horizontal flick and switched workspaces UNDER
	// the overlay (killing its focus). Consume, don't switch.
	if (overlay_active()) {
		ctx->last_fire_dir = direction;
		ctx->state = GS_COMMITTED;
		return;
	}

	ctx->last_fire_dir = direction;
	ctx->state = GS_COMMITTED;

	dispatch_async(dispatch_get_global_queue(DISPATCH_QUEUE_PRIORITY_DEFAULT, 0), ^{
		switch_workspace(direction > 0 ? g_config.swipe_right : g_config.swipe_left);
	});
}

// Vertical swipes run a user command (workspace overview etc.) instead
// of a workspace step. One-shot: commits the gesture so nothing re-fires
// until the fingers lift. Direction codes ±2 keep them distinct from
// the horizontal ±1 so the committed-state reversal re-arm (an x-axis
// concept) can tell them apart.
static void fire_vertical(gesture_ctx* ctx, int direction)
{
	const char* cmd = direction > 0 ? g_config.swipe_up : g_config.swipe_down;
	ctx->last_fire_dir = direction * 2;
	ctx->state = GS_COMMITTED;

	char* owned = strdup(cmd);
	dispatch_async(dispatch_get_global_queue(DISPATCH_QUEUE_PRIORITY_DEFAULT, 0), ^{
		FILE* p = popen(owned, "r");
		if (p)
			pclose(p);
		else
			fprintf(stderr, "Error: failed to run vertical swipe command '%s'.\n", owned);
		free(owned);
	});

	if (g_config.haptic && g_haptic)
		haptic_actuate(g_haptic, 3);
}

static void calculate_touch_averages(touch* touches, int count,
	float* avg_x, float* avg_y, float* avg_vel,
	float* min_x, float* max_x, float* min_y, float* max_y)
{
	*avg_x = *avg_y = *avg_vel = 0;
	*min_x = *min_y = 1;
	*max_x = *max_y = 0;

	for (int i = 0; i < count; ++i) {
		*avg_x += touches[i].x;
		*avg_y += touches[i].y;
		*avg_vel += touches[i].velocity;

		if (touches[i].x < *min_x)
			*min_x = touches[i].x;
		if (touches[i].x > *max_x)
			*max_x = touches[i].x;
		if (touches[i].y < *min_y)
			*min_y = touches[i].y;
		if (touches[i].y > *max_y)
			*max_y = touches[i].y;
	}

	*avg_x /= count;
	*avg_y /= count;
	*avg_vel /= count;
}

static bool handle_committed_state(gesture_ctx* ctx, touch* touches, int count)
{
	bool all_ended = true;
	for (int i = 0; i < count; ++i) {
		if (touches[i].phase != END_PHASE) {
			all_ended = false;
			break;
		}
	}

	if (!count || all_ended) {
		reset_gesture_state(ctx);
		return true;
	}

	// Lift-off in progress: the raw MT path rarely delivers the final
	// zero-finger frame, but the count still collapses on the way out
	// (4→3→2→1, ~8ms apart). Once it falls to half the required
	// fingers, the hand is leaving — re-arm now so a quick same-
	// direction repeat (air time shorter than the frame-gap window)
	// registers as a fresh gesture instead of being consumed.
	if (count <= g_config.fingers / 2) {
		reset_gesture_state(ctx);
		return true;
	}

	float avg_x, avg_y, avg_vel, min_x, max_x, min_y, max_y;
	calculate_touch_averages(touches, count, &avg_x, &avg_y, &avg_vel,
		&min_x, &max_x, &min_y, &max_y);

	float dx = avg_x - ctx->start_x;
	// Reversal re-arm is an x-axis concept — a committed VERTICAL
	// fire (|dir| == 2) stays committed until the fingers lift.
	if (abs(ctx->last_fire_dir) == 1 && (dx * ctx->last_fire_dir) < 0
		&& fabsf(dx) >= g_config.min_travel) {
		ctx->state = GS_ARMED;
		ctx->start_x = avg_x;
		ctx->start_y = avg_y;
		ctx->peak_velx = avg_vel;
		ctx->dir = (avg_vel >= 0) ? 1 : -1;

		for (int i = 0; i < count; ++i)
			ctx->base_x[i] = touches[i].x;
	}

	return true;
}

static void handle_idle_state(gesture_ctx* ctx, touch* touches, int count,
	float avg_x, float avg_y, float avg_vel)
{
	bool fast = fabsf(avg_vel) >= g_config.velocity_pct * FAST_VEL_FACTOR;
	float need = fast ? g_config.min_travel_fast : g_config.min_travel;

	bool moved = true;
	for (int i = 0; i < count && moved; ++i)
		moved &= fabsf(touches[i].x - ctx->base_x[i]) >= need;

	float dx = avg_x - ctx->start_x;
	float dy = avg_y - ctx->start_y;

	// Vertical swipe → one-shot user command (workspace overview).
	// Checked before the horizontal arm: a clearly-vertical motion
	// either fires here or belongs to no gesture at all (the
	// horizontal arm requires |dx| > |dy|). Two independent gates
	// must agree, mirroring the ARMED fire's robustness: (1) the
	// hardware-reported y velocity crosses the same velocity_pct the
	// horizontal fire uses (immune to the stale-anchor problem —
	// base_x/base_y are per-frame steps, refreshed every idle frame,
	// and undefined on the first full-finger frame), and (2) every
	// finger's per-frame step is vertical-dominant and above the
	// step floor. MultitouchSupport's normalized y grows toward the
	// trackpad's far edge, so positive velocity is a swipe UP.
	float avg_vel_y = 0;
	for (int i = 0; i < count; ++i)
		avg_vel_y += touches[i].velocity_y;
	avg_vel_y /= count;
	// post-click finger lifts read as single-frame vertical spikes and
	// re-fired the overview seconds after a card click: demand TWO
	// consecutive qualifying frames and a click-free half second
	static int vert_streak = 0;
	bool vert_ok = fabsf(avg_vel_y) >= g_config.velocity_pct
		&& CGEventSourceSecondsSinceLastEventType(
			kCGEventSourceStateCombinedSessionState, kCGEventLeftMouseDown) > 0.5;
	vert_streak = vert_ok ? vert_streak + 1 : 0;
	if (vert_streak >= 2) {
		float travel_x = 0, travel_y = 0;
		bool stepped = true;
		for (int i = 0; i < count; ++i) {
			float fdy = touches[i].y - ctx->base_y[i];
			if (fabsf(fdy) < g_config.min_travel_fast)
				stepped = false;
			travel_y += fdy;
			travel_x += touches[i].x - ctx->base_x[i];
		}
		if (stepped && fabsf(travel_y) > fabsf(travel_x)) {
			int vdir = avg_vel_y > 0 ? 1 : -1;
			const char* cmd = vdir > 0 ? g_config.swipe_up : g_config.swipe_down;
			if (cmd && *cmd) {
				fire_vertical(ctx, vdir);
				return;
			}
		}
	}

	if (moved && (fast || (fabsf(dx) >= ACTIVATE_PCT && fabsf(dx) > fabsf(dy)))) {
		ctx->state = GS_ARMED;
		ctx->start_x = avg_x;
		ctx->start_y = avg_y;
		ctx->peak_velx = avg_vel;
		ctx->dir = (avg_vel >= 0) ? 1 : -1;
	}
}

static void handle_armed_state(gesture_ctx* ctx, touch* touches, int count,
	float avg_x, float avg_y, float avg_vel)
{
	float dx = avg_x - ctx->start_x;
	float dy = avg_y - ctx->start_y;

	if (fabsf(dy) > fabsf(dx)) {
		reset_gesture_state(ctx);
		return;
	}

	bool fast = fabsf(avg_vel) >= g_config.velocity_pct * FAST_VEL_FACTOR;
	float stepReq = fast ? g_config.min_step_fast : g_config.min_step;

	int mismatch_count = 0;
	for (int i = 0; i < count; ++i) {
		float ddx = touches[i].x - ctx->prev_x[i];
		if (fabsf(ddx) < stepReq || (ddx * dx) < 0) {
			mismatch_count++;
			if (mismatch_count > g_config.swipe_tolerance) {
				reset_gesture_state(ctx);
				return;
			}
		}
	}

	if (fabsf(avg_vel) > fabsf(ctx->peak_velx)) {
		ctx->peak_velx = avg_vel;
		ctx->dir = (avg_vel >= 0) ? 1 : -1;
	}

	if (fabsf(avg_vel) >= g_config.velocity_pct) {
		fire_gesture(ctx, avg_vel > 0 ? 1 : -1);
	} else if (fabsf(dx) >= g_config.distance_pct && fabsf(avg_vel) <= g_config.velocity_pct * g_config.settle_factor) {
		fire_gesture(ctx, dx > 0 ? 1 : -1);
	}
}

// One gesture context PER DEVICE. With two trackpads registered
// (built-in + Magic Trackpad), a shared context let a stray palm on
// the idle pad interleave its frames into the active pad's gesture:
// finger counts oscillated (missed fires) and the idle pad's frames
// kept the frame-gap timestamp fresh, so the lift-off reset below
// never triggered (the direction latch came back). Keyed on the MT
// callback's device word — identity only; one slot per registered
// device, and registration is deduped by hardware id, so the table
// can't grow past the register cap.
typedef struct {
	int key;
	bool used;
	gesture_ctx ctx;
	double last_frame_ts;
} device_gesture;
#define MAX_GESTURE_DEVICES 16
static device_gesture g_device_gestures[MAX_GESTURE_DEVICES];

// call with g_gesture_mutex held
static device_gesture* gesture_for_device(int key)
{
	for (int i = 0; i < MAX_GESTURE_DEVICES; ++i)
		if (g_device_gestures[i].used && g_device_gestures[i].key == key)
			return &g_device_gestures[i];
	for (int i = 0; i < MAX_GESTURE_DEVICES; ++i)
		if (!g_device_gestures[i].used) {
			g_device_gestures[i].used = true;
			g_device_gestures[i].key = key;
			return &g_device_gestures[i];
		}
	return &g_device_gestures[0]; // unreachable: register cap == table size
}

// a retired device ref frees its gesture slot, so ref swaps on
// hotplug can't exhaust the table across dock cycles
static void gesture_release_device(int key)
{
	pthread_mutex_lock(&g_gesture_mutex);
	for (int i = 0; i < MAX_GESTURE_DEVICES; ++i)
		if (g_device_gestures[i].used && g_device_gestures[i].key == key) {
			memset(&g_device_gestures[i], 0, sizeof(g_device_gestures[i]));
			break;
		}
	pthread_mutex_unlock(&g_gesture_mutex);
}

static void gestureCallback(int device, touch* touches, int count)
{
	pthread_mutex_lock(&g_gesture_mutex);

	device_gesture* dg = gesture_for_device(device);
	gesture_ctx* ctx = &dg->ctx;

	// Lift-off doesn't reliably deliver a zero-finger frame on the raw
	// MT path, so GS_COMMITTED (with last_fire_dir latched) could
	// survive between gestures — repeated same-direction swipes were
	// then consumed until an opposite swipe re-armed. Contact frames
	// stream ~8ms apart while touching; a gap means the fingers left:
	// any new touch after silence is a NEW gesture. Per-device: the
	// other pad's frames must not mask this device's silence. 0.12s
	// (≈15 missed frames) — a quick flick-lift-flick spends less air
	// time than the old 0.25s window, which ate the second swipe.
	if (count > 0) {
		double ts = touches[0].timestamp;
		if (dg->last_frame_ts > 0 && ts - dg->last_frame_ts > 0.12 && ctx->state != GS_IDLE)
			reset_gesture_state(ctx);
		dg->last_frame_ts = ts;
	}

	if (ctx->state == GS_COMMITTED) {
		if (handle_committed_state(ctx, touches, count))
			goto unlock;
	}

	if (count != g_config.fingers) {
		if (ctx->state == GS_ARMED)
			ctx->state = GS_IDLE;

		for (int i = 0; i < count; ++i) {
			ctx->prev_x[i] = ctx->base_x[i] = touches[i].x;
			ctx->base_y[i] = touches[i].y;
		}

		goto unlock;
	}

	float avg_x, avg_y, avg_vel, min_x, max_x, min_y, max_y;
	calculate_touch_averages(touches, count, &avg_x, &avg_y, &avg_vel,
		&min_x, &max_x, &min_y, &max_y);

	if (ctx->state == GS_IDLE) {
		handle_idle_state(ctx, touches, count, avg_x, avg_y, avg_vel);
	} else if (ctx->state == GS_ARMED) {
		handle_armed_state(ctx, touches, count, avg_x, avg_y, avg_vel);
	}

	for (int i = 0; i < count; ++i) {
		ctx->prev_x[i] = touches[i].x;
		if (ctx->state == GS_IDLE) {
			ctx->base_x[i] = touches[i].x;
			ctx->base_y[i] = touches[i].y;
		}
	}

unlock:
	pthread_mutex_unlock(&g_gesture_mutex);
}

// MT finger states: 1 start, 2 hover, 3 make, 4 touching, 5 break,
// 6 linger, 7 leave. Count fingers that are on the surface (3-5);
// lift-off shows up as the count dropping, which the engine already
// treats as gesture end.
static int mt_contact_callback(int device, MTFinger* data, int nFingers,
	double timestamp, int frame)
{
	(void)frame;

	int cap = nFingers > 0 ? nFingers : 1;
	touch* buf = malloc(sizeof(touch) * cap);
	int n = 0;

	for (int i = 0; i < nFingers; ++i) {
		if (data[i].state < 3 || data[i].state > 5)
			continue;
		buf[n].x = data[i].normalized.pos.x;
		buf[n].y = data[i].normalized.pos.y;
		buf[n].velocity = data[i].normalized.vel.x;
		buf[n].velocity_y = data[i].normalized.vel.y;
		buf[n].timestamp = timestamp;
		buf[n].phase = 1 << 1; // moved; lift-off is signaled by count dropping
		buf[n].is_palm = false;
		n++;
	}

	dispatch_async(dispatch_get_global_queue(DISPATCH_QUEUE_PRIORITY_DEFAULT, 0), ^{
		gestureCallback(device, buf, n);
		free(buf);
	});

	return 0;
}

static void acquire_lockfile(void)
{
	char* user = getenv("USER");
	if (!user)
		printf("Error: User variable not set.\n"), exit(1);

	char buffer[256];
	snprintf(buffer, 256, "/tmp/omacosy-gesture-%s.lock", user);

	int handle = open(buffer, O_CREAT | O_WRONLY, 0600);
	if (handle == -1) {
		printf("Error: Could not create lock-file.\n");
		exit(1);
	}

	struct flock lockfd = {
		.l_start = 0,
		.l_len = 0,
		.l_pid = getpid(),
		.l_type = F_WRLCK,
		.l_whence = SEEK_SET
	};

	if (fcntl(handle, F_SETLK, &lockfd) == -1) {
		printf("Error: Could not acquire lock-file.\nomacosy-gesture already running?\n");
		exit(1);
	}
}

void waitForAccessibilityAndRestart(void)
{
	while (!AXIsProcessTrusted()) {
		NSLog(@"Waiting for accessibility permission...");
		sleep(1);
	}

	NSLog(@"Accessibility permission granted. Restarting app...");

	NSString* bundlePath = [[NSBundle mainBundle] bundlePath];
	[[NSWorkspace sharedWorkspace] openApplicationAtURL:[NSURL fileURLWithPath:bundlePath] configuration:[NSWorkspaceOpenConfiguration configuration] completionHandler:nil];
	exit(0);
}

int main(int argc, const char* argv[])
{
	signal(SIGCHLD, SIG_IGN);
	signal(SIGPIPE, SIG_IGN);

	acquire_lockfile();

	@autoreleasepool {
		NSDictionary* options = @{(__bridge id)kAXTrustedCheckOptionPrompt : @YES};

		if (!AXIsProcessTrustedWithOptions((__bridge CFDictionaryRef)options)) {
			NSLog(@"Accessibility permission not granted. Prompting user...");
			AXIsProcessTrustedWithOptions((__bridge CFDictionaryRef)options);

			dispatch_async(dispatch_get_global_queue(DISPATCH_QUEUE_PRIORITY_DEFAULT, 0), ^{
				waitForAccessibilityAndRestart();
			});

			CFRunLoopRun();
		}

		NSLog(@"Accessibility permission granted. Continuing app initialization...");

		g_config = load_config();
		NSLog(@"Loaded config: fingers=%d, skip_empty=%s, wrap_around=%s, haptic=%s, swipe_left='%s', swipe_right='%s', swipe_up='%s', swipe_down='%s'",
			g_config.fingers,
			g_config.skip_empty ? "YES" : "NO",
			g_config.wrap_around ? "YES" : "NO",
			g_config.haptic ? "YES" : "NO",
			g_config.swipe_left,
			g_config.swipe_right,
			g_config.swipe_up,
			g_config.swipe_down);

		g_aerospace = aerospace_new(NULL);
		if (!g_aerospace) {
			fprintf(stderr, "Error: Failed to initialize Aerospace client.\n");
			exit(EXIT_FAILURE);
		}

		if (g_config.haptic) {
			g_haptic = haptic_open_default();
			if (!g_haptic)
				fprintf(stderr, "Warning: Failed to initialize haptic actuator. Continuing without haptics.\n");
		}

		g_tracks = CFDictionaryCreateMutable(NULL, 0,
			&kCFTypeDictionaryKeyCallBacks,
			NULL);

		// Raw contact frames need the Input Monitoring permission
		// (this prompts on first run) and a running run loop, which
		// NSApplicationMain provides below.
		IOHIDRequestAccess(kIOHIDRequestTypeListenEvent);

		if (!register_new_devices()) {
			fprintf(stderr, "Error: no multitouch devices found.\n");
			exit(EXIT_FAILURE);
		}
		NSLog(@"Raw multitouch detection active on %d device(s).", g_dev_count);
		// docking / bluetooth trackpads appear AFTER launch: IOKit
		// fires a matching notification the moment a HID device
		// attaches — no polling. The second scan 2s later covers
		// devices whose multitouch service registers a beat after
		// their HID arrival.
		static IONotificationPortRef notify_port;
		static io_iterator_t hid_iter;
		notify_port = IONotificationPortCreate(kIOMainPortDefault);
		CFRunLoopAddSource(CFRunLoopGetMain(),
			IONotificationPortGetRunLoopSource(notify_port), kCFRunLoopDefaultMode);
		if (IOServiceAddMatchingNotification(notify_port, kIOFirstMatchNotification,
				IOServiceMatching("IOHIDDevice"), hid_device_appeared, NULL,
				&hid_iter) == KERN_SUCCESS) {
			hid_device_appeared(NULL, hid_iter); // drain to ARM + catch existing
		} else {
			NSLog(@"HID matching notification failed — new trackpads need a daemon restart");
		}

		// Sleep/wake is the hotplug case IOKit does NOT announce: the
		// built-in trackpad keeps its IOService across sleep, so no
		// HID-attach notification fires — but the MT callback session
		// can die with the sleep anyway, leaving swipes silently dead
		// until a real hotplug. register_new_devices() already swaps
		// every KNOWN device id onto a fresh registration, so waking
		// just runs it: immediately, and once more 2s later for
		// hardware that comes back slowly.
		[[[NSWorkspace sharedWorkspace] notificationCenter]
			addObserverForName:NSWorkspaceDidWakeNotification
			            object:nil
			             queue:[NSOperationQueue mainQueue]
			        usingBlock:^(NSNotification* note) {
				(void)note;
				int n = register_new_devices();
				NSLog(@"Multitouch: wake — re-registered, %d new, %d total.", n, g_dev_count);
				dispatch_after(dispatch_time(DISPATCH_TIME_NOW, 2 * NSEC_PER_SEC),
					dispatch_get_main_queue(), ^{ register_new_devices(); });
			}];

		return NSApplicationMain(argc, argv);
	}
}
