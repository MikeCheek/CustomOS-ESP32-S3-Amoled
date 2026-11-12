// Where the battery goes, measured on the watch - see power_profile.h.
#include "power_profile.h"
#include "config.h"
#include <Arduino.h>
#include <stdio.h>
#include <stdlib.h>
#include <string.h>

#if defined(ESP_PLATFORM)
#include <freertos/FreeRTOS.h>
#include <freertos/task.h>
#include <esp_heap_caps.h>
#include <esp_timer.h>
#include <esp_pm.h>
#include <sdkconfig.h>
#endif

#if defined(ESP_PLATFORM) && configUSE_TRACE_FACILITY && configGENERATE_RUN_TIME_STATS
#define PP_TASKS 1
#else
#define PP_TASKS 0
#endif
#if defined(ESP_PLATFORM) && defined(CONFIG_PM_ENABLE) && defined(CONFIG_PM_PROFILING)
#define PP_PM 1
#else
#define PP_PM 0
#endif

// What each task's CPU time counts as (by the task's name).
enum Feature { PF_LOOP, PF_MOTION, PF_BT, PF_WIFI, PF_DISPLAY, PF_WAKEWORD, PF_SOUND, PF_UPDATE, PF_SYSTEM, PF_N };
static const char *const PF_KEYS[PF_N] = {"loop", "motion", "bt", "wifi", "display", "wakeword", "sound", "update", "system"};
static const char *const PF_LOG[PF_N] = {"main loop", "motion", "Bluetooth", "Wi-Fi", "display", "wake word", "sound", "update", "system"};

static const int LOCKS = 10;
struct Win {
    uint64_t wall_us;        // time covered
    uint64_t mode_us;        // of that, time the PM stats cover (all modes) ...
    uint64_t sleep_us;       // ... and in light sleep
    uint64_t cpu_us[PF_N];   // CPU time per feature (both cores)
    char lock_name[LOCKS][16];
    uint64_t lock_us[LOCKS]; // time each power lock was held
};
static Win s_today[2];   // [0] screen off, [1] screen on
static Win s_recent;     // screen off, since the last log line

static bool s_have_prev = false, s_prev_off = false;
static uint32_t s_last_ms = 0;
static uint64_t s_prev_wall = 0;

static void win_add_lock(Win &w, const char *name, uint64_t us) {
    if (!us) return;
    for (int i = 0; i < LOCKS; i++)
        if (w.lock_name[i][0] && !strcmp(w.lock_name[i], name)) { w.lock_us[i] += us; return; }
    for (int i = 0; i < LOCKS; i++)
        if (!w.lock_name[i][0]) {
            strlcpy(w.lock_name[i], name, sizeof(w.lock_name[i]));
            w.lock_us[i] = us;
            return;
        }
}

#if PP_TASKS
static Feature feature_of(const char *n) {
    if (!strcmp(n, "loopTask")) return PF_LOOP;
    if (!strcmp(n, "imu_smp")) return PF_MOTION;
    if (strstr(n, "nimble") || !strncmp(n, "bt", 2) || !strncmp(n, "BT", 2) || strstr(n, "ble")) return PF_BT;
    if (strstr(n, "wifi") || !strcmp(n, "tiT") || strstr(n, "netif")) return PF_WIFI;
    if (!strcmp(n, "lcd_send")) return PF_DISPLAY;
    if (!strncmp(n, "wake_", 5) || strstr(n, "AFE") || strstr(n, "afe")) return PF_WAKEWORD;
    if (strstr(n, "sfx") || strstr(n, "audio") || strstr(n, "mp3") || strstr(n, "rec_")) return PF_SOUND;
    if (!strcmp(n, "fwup")) return PF_UPDATE;
    return PF_SYSTEM;
}

struct TaskPrev { TaskHandle_t h; uint64_t rt; };
static const int TASKS_MAX = 48;
static TaskPrev s_tp[TASKS_MAX];
static int s_tp_n = 0;

// CPU time per feature since the last call
static void tasks_delta(uint64_t out[PF_N]) {
    UBaseType_t cap = uxTaskGetNumberOfTasks() + 4;
    TaskStatus_t *st = (TaskStatus_t *)heap_caps_malloc(cap * sizeof(TaskStatus_t), MALLOC_CAP_SPIRAM | MALLOC_CAP_8BIT);
    if (!st) return;
    configRUN_TIME_COUNTER_TYPE total = 0;
    UBaseType_t n = uxTaskGetSystemState(st, cap, &total);
    TaskPrev next[TASKS_MAX];
    int nn = 0;
    for (UBaseType_t i = 0; i < n; i++) {
        uint64_t rt = (uint64_t)st[i].ulRunTimeCounter;
        for (int k = 0; k < s_tp_n; k++) {
            if (s_tp[k].h != st[i].xHandle) continue;
            // counter arithmetic in its own width: a 32-bit one wraps (~71 min)
            configRUN_TIME_COUNTER_TYPE d = (configRUN_TIME_COUNTER_TYPE)rt - (configRUN_TIME_COUNTER_TYPE)s_tp[k].rt;
            if (strncmp(st[i].pcTaskName, "IDLE", 4)) out[feature_of(st[i].pcTaskName)] += (uint64_t)d;
            break;
        }
        if (nn < TASKS_MAX) next[nn++] = {st[i].xHandle, rt};
    }
    memcpy(s_tp, next, sizeof(TaskPrev) * nn);
    s_tp_n = nn;
    heap_caps_free(st);
}
#endif

#if PP_PM
struct LockPrev { char name[16]; uint64_t us; };
static const int LOCKS_PREV = 24;
static LockPrev s_lp[LOCKS_PREV];
static int s_lp_n = 0;
static uint64_t s_prev_sleep = 0, s_prev_mode = 0;
static char s_dump[3072];

static bool is_lock_type(const char *t) {
    return !strcmp(t, "CPU_FREQ_MAX") || !strcmp(t, "APB_FREQ_MAX") || !strcmp(t, "NO_SLEEP") || !strcmp(t, "NO_LIGHT_SLEEP");
}
static bool is_mode(const char *t) {
    return !strcmp(t, "SLEEP") || !strcmp(t, "APB_MIN") || !strcmp(t, "APB_MAX") || !strcmp(t, "CPU_MAX");
}

// esp_pm_dump_locks(): a line per lock ("name type arg active count time_us pct%")
// and per mode ("SLEEP 40 M time_us pct%"), totals since boot. Deltas since
// the last call: light-sleep time, all-mode time, and each lock's.
static void pm_delta(uint64_t &sleep_d, uint64_t &mode_d, Win *a, Win *b) {
    memset(s_dump, 0, sizeof(s_dump));
    FILE *f = fmemopen(s_dump, sizeof(s_dump) - 1, "w");
    if (!f) return;
    esp_pm_dump_locks(f);
    fclose(f);
    uint64_t sleep = 0, mode = 0;
    LockPrev next[LOCKS_PREV];
    int nn = 0;
    char *save_line = nullptr;
    for (char *line = strtok_r(s_dump, "\n", &save_line); line; line = strtok_r(nullptr, "\n", &save_line)) {
        char *tok[10];
        int nt = 0;
        char *save_tok = nullptr;
        for (char *t = strtok_r(line, " \t", &save_tok); t && nt < 10; t = strtok_r(nullptr, " \t", &save_tok)) tok[nt++] = t;
        if (nt < 4) continue;
        // the time is the number just before the "NN%" column
        int pct = -1;
        for (int i = nt - 1; i >= 2; i--)
            if (tok[i][strlen(tok[i]) - 1] == '%') { pct = i; break; }
        if (pct < 2) continue;
        uint64_t us = strtoull(tok[pct - 1], nullptr, 10);
        if (is_mode(tok[0])) {
            mode += us;
            if (!strcmp(tok[0], "SLEEP")) sleep = us;
        } else if (nt >= 7 && is_lock_type(tok[1])) {
            if (!strncmp(tok[0], "rtos", 4)) continue;   // the scheduler's own: just "a task is running"
            uint64_t prev = 0;
            bool seen = false;
            for (int k = 0; k < s_lp_n; k++)
                if (!strcmp(s_lp[k].name, tok[0])) { prev = s_lp[k].us; seen = true; break; }
            if (seen && us >= prev) {
                if (a) win_add_lock(*a, tok[0], us - prev);
                if (b) win_add_lock(*b, tok[0], us - prev);
            }
            if (nn < LOCKS_PREV) {
                strlcpy(next[nn].name, tok[0], sizeof(next[nn].name));
                next[nn].us = us;
                nn++;
            }
        }
    }
    memcpy(s_lp, next, sizeof(LockPrev) * nn);
    s_lp_n = nn;
    if (mode >= s_prev_mode && sleep >= s_prev_sleep) {
        mode_d = mode - s_prev_mode;
        sleep_d = sleep - s_prev_sleep;
    }
    s_prev_mode = mode;
    s_prev_sleep = sleep;
}
#endif

bool power_profile_available() { return PP_TASKS || PP_PM; }

static int permille(uint64_t part, uint64_t whole) {
    return whole ? (int)((part * 1000 + whole / 2) / whole) : 0;
}

static void log_recent() {
    Win &w = s_recent;
    char line[200];
    int n = snprintf(line, sizeof(line), "[pwr] screen off %lu min: asleep %d%%", (unsigned long)(w.wall_us / 60000000ULL),
                     w.mode_us ? permille(w.sleep_us, w.mode_us) / 10 : -1);
    // CPU, biggest first (% of one core)
    bool used[PF_N] = {false};
    for (int k = 0; k < 4 && n < (int)sizeof(line) - 24; k++) {
        int best = -1;
        for (int i = 0; i < PF_N; i++)
            if (!used[i] && (best < 0 || w.cpu_us[i] > w.cpu_us[best])) best = i;
        if (best < 0 || !w.cpu_us[best]) break;
        used[best] = true;
        n += snprintf(line + n, sizeof(line) - n, "%s %s %.1f%%", k ? "," : "; CPU", PF_LOG[best],
                      100.0 * (double)w.cpu_us[best] / (double)w.wall_us);
    }
    // the locks held longest (what kept it awake)
    bool lused[LOCKS] = {false};
    for (int k = 0; k < 3 && n < (int)sizeof(line) - 24; k++) {
        int best = -1;
        for (int i = 0; i < LOCKS; i++)
            if (w.lock_name[i][0] && !lused[i] && (best < 0 || w.lock_us[i] > w.lock_us[best])) best = i;
        if (best < 0 || w.lock_us[best] * 50 < w.wall_us) break;   // under 2%: not worth a mention
        lused[best] = true;
        n += snprintf(line + n, sizeof(line) - n, "%s %s %d%%", k ? "," : "; held", w.lock_name[best],
                      permille(w.lock_us[best], w.wall_us) / 10);
    }
    DEBUG_PRINTF("%s\n", line);
    memset(&s_recent, 0, sizeof(s_recent));
}

// Everything since the last sample goes to the state it was taken in.
static void sample(bool off) {
#if defined(ESP_PLATFORM)
    uint64_t now = (uint64_t)esp_timer_get_time();
#else
    uint64_t now = (uint64_t)micros();
#endif
    Win &w = s_today[off ? 0 : 1];
    Win *r = off ? &s_recent : nullptr;
    uint64_t cpu[PF_N] = {0};
#if PP_TASKS
    tasks_delta(cpu);
#endif
    uint64_t sleep_d = 0, mode_d = 0;
#if PP_PM
    pm_delta(sleep_d, mode_d, s_have_prev ? &w : nullptr, s_have_prev ? r : nullptr);
#endif
    if (s_have_prev && now > s_prev_wall) {
        uint64_t wall = now - s_prev_wall;
        w.wall_us += wall;
        w.mode_us += mode_d;
        w.sleep_us += sleep_d;
        for (int i = 0; i < PF_N; i++) w.cpu_us[i] += cpu[i];
        if (r) {
            r->wall_us += wall;
            r->mode_us += mode_d;
            r->sleep_us += sleep_d;
            for (int i = 0; i < PF_N; i++) r->cpu_us[i] += cpu[i];
        }
    }
    s_prev_wall = now;
    s_have_prev = true;
    if (s_recent.wall_us >= 600000000ULL) log_recent();   // every 10 minutes off
}

void power_profile_update(bool screen_off) {
    if (!power_profile_available()) return;
    uint32_t ms = millis();
    if (!s_have_prev) {
        s_prev_off = screen_off;
        s_last_ms = ms;
        sample(screen_off);   // the baseline
        return;
    }
    if (screen_off != s_prev_off) {
        sample(s_prev_off);   // up to now, in the state it was in
        s_prev_off = screen_off;
        s_last_ms = ms;
        return;
    }
    if (ms - s_last_ms >= 60000) {
        s_last_ms = ms;
        sample(screen_off);
    }
}

void power_profile_new_day() {
    memset(s_today, 0, sizeof(s_today));
}

void power_profile_json(JsonObject out) {
    out["v"] = 1;
    static const char *const KEYS[2] = {"off", "on"};
    for (int s = 0; s < 2; s++) {
        const Win &w = s_today[s];
        if (!w.wall_us) continue;
        JsonObject o = out[KEYS[s]].to<JsonObject>();
        o["t"] = (uint32_t)(w.wall_us / 1000000ULL);
        if (w.mode_us) o["slp"] = permille(w.sleep_us, w.mode_us);
        JsonObject c = o["cpu"].to<JsonObject>();
        for (int i = 0; i < PF_N; i++)
            if (w.cpu_us[i]) c[PF_KEYS[i]] = permille(w.cpu_us[i], w.wall_us);
        JsonArray lk = o["lk"].to<JsonArray>();
        bool used[LOCKS] = {false};
        for (int k = 0; k < 6; k++) {
            int best = -1;
            for (int i = 0; i < LOCKS; i++)
                if (w.lock_name[i][0] && !used[i] && (best < 0 || w.lock_us[i] > w.lock_us[best])) best = i;
            if (best < 0 || !w.lock_us[best]) break;
            used[best] = true;
            JsonArray e = lk.add<JsonArray>();
            e.add(w.lock_name[best]);
            e.add(permille(w.lock_us[best], w.wall_us));
        }
    }
}
