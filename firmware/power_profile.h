#pragma once
// Where the battery goes, measured on the watch: how much of the time the
// chip was in light sleep, what kept it awake (the power locks held), and
// how much CPU each part of the firmware used (FreeRTOS run-time stats per
// task, grouped into features) - for today, with the screen off and on
// separately. The app turns it into an estimate per feature (Diagnostics);
// the serial log shows the last 10 minutes with the screen off.
//
// Needs the PlatformIO build's power management and its profiling
// (platformio.ini: CONFIG_PM_PROFILING, run-time stats); without them
// power_profile_available() is false and nothing is reported.
#include <ArduinoJson.h>

void power_profile_update(bool screen_off);   // every loop: samples once a minute, and when the screen turns on/off
void power_profile_new_day();
bool power_profile_available();
// {"v":1,"off":{"t":s,"slp":permille,"cpu":{feature:permille of a core},"lk":[[name,permille],...]},"on":{...}}
void power_profile_json(JsonObject out);
