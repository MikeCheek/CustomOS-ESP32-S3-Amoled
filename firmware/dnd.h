/*
 * dnd.h - Do Not Disturb (fw 3.1) and the quick-reply list.
 *
 * DND is on when it's switched on (tile, or synced from the phone) or during
 * the bedtime window in Settings. While on: no notification popups, no
 * reminder sounds, no wake for notifications.
 * Phone link: phone -> watch {"t":"dnd","on":0|1}; watch -> phone
 * {"e":"dnd","on":0|1} when the tile is used (the phone applies it if the
 * user allowed DND sync). Quick replies: {"t":"qr","l":["...", ...]}.
 */
#pragma once
#include <stdint.h>

bool dnd_active();                     // manual or bedtime
bool dnd_manual();                     // the switch itself
bool dnd_bedtime_now();                // inside the bedtime window (and it's enabled)
void dnd_set(bool on, bool from_phone);

// Notifications on the watch, one switch with three steps (the control
// panel button, Settings > Wake & quiet, the Tile, a home gesture, the app):
// the full pop-up -> just the app's icon -> silenced (Do not disturb) -> ...
// Silenced is Do not disturb itself, so the phone's DND sync still applies.
// Phone link: watch -> phone {"e":"nmode","m":0|1|2} when it changes on the
// watch; phone -> watch {"t":"nmode","m":0|1|2}.
enum NotifMode : uint8_t { NM_FULL, NM_ICON, NM_SILENT };
NotifMode   notif_mode();
void        notif_mode_set(NotifMode m, bool from_phone = false);
NotifMode   notif_mode_next();                 // the next step; returns it
const char *notif_mode_name(NotifMode m);      // "Show in full", "Icon only", "Silenced"
const char *notif_mode_hint(NotifMode m);      // a line saying what it does

// Quick replies: "Dictate" is always first, then the list from the phone
// (or the built-in presets if the phone never sent one).
int         quick_reply_count();
const char *quick_reply(int i);
void        quick_replies_set(const char *const *items, int n);   // saves to NVS
void        quick_replies_load();
