# pio/app_bss_to_psram.py - PlatformIO extra script (platformio.ini).
#
# Moves the firmware's own static buffers (zero-initialised .bss) from
# internal RAM to PSRAM, just before the link.
#
# Every app, game and face keeps a few hundred bytes to a few KB of
# static state (lists, history, text, sample buffers): together ~100 KB
# that otherwise sit in internal RAM - which Bluetooth and Wi-Fi need to
# start (on the watch: "not enough internal RAM for Bluetooth"). None of
# it is touched by interrupt code (nothing in firmware/ is IRAM_ATTR), so
# it can live in PSRAM, which the linker script places .ext_ram.bss in
# when CONFIG_SPIRAM_ALLOW_BSS_SEG_EXTERNAL_MEMORY is set (and zeroes at
# boot, like .bss).
#
# Files that hold what must stay internal are left alone: spinlocks and
# atomics (no atomic instructions on PSRAM), FreeRTOS task control blocks
# (StaticTask_t must be internal), and the drivers that hand buffers to
# DMA. What happened is written to .pio/app_bss_to_psram.log (CI prints it).

import os
import re
import subprocess
from pathlib import Path

Import("env")  # noqa: F821 - provided by PlatformIO

KEEP_INTERNAL = {
    "hal_ble.cpp",        # __atomic_* counters shared with the NimBLE task
    "hal_display.cpp",    # portMUX spinlock, the sender's StaticTask_t
    "hal_imu.cpp",        # portMUX spinlock (the sample ring)
    "hal_audio.cpp",      # StaticTask_t x3, I2S
    "hal_wifi_xfer.cpp",  # StaticTask_t, atomics
    "app_video.cpp",      # StaticTask_t
    "voice_sr.cpp",       # StaticTask_t x2, the wake word's audio feed
}


def _log(msg):
    print("[app bss->psram] " + msg)
    try:
        d = Path(env.subst("$PROJECT_DIR")) / ".pio"  # noqa: F821
        d.mkdir(exist_ok=True)
        with open(d / "app_bss_to_psram.log", "a") as f:
            f.write(msg + "\n")
    except OSError:
        pass


def _has_ext_bss():
    platform = env.PioPlatform()  # noqa: F821
    libs_dir = platform.get_package_dir("framework-arduinoespressif32-libs")
    mcu = env.BoardConfig().get("build.mcu", "esp32s3")  # noqa: F821
    ld = Path(libs_dir or "") / mcu / "ld" / "sections.ld"
    return ld.is_file() and ".ext_ram.bss" in ld.read_text(errors="ignore")


def move_bss(target, source, env):
    if not _has_ext_bss():
        _log("linker script has no .ext_ram.bss section - left in internal RAM")
        return
    cc = env.subst("$CC")
    if not cc.endswith("gcc"):
        _log("unexpected compiler name %r - left as is" % cc)
        return
    objcopy, objdump = cc[:-3] + "objcopy", cc[:-3] + "objdump"
    tool_env = dict(os.environ)
    tool_env.update(env["ENV"])
    src_dir = os.path.abspath(env.subst("$BUILD_DIR/src"))
    files = moved = total = 0
    for node in source:
        path = os.path.abspath(node.get_abspath() if hasattr(node, "get_abspath") else str(node))
        if not path.endswith(".o") or not path.startswith(src_dir + os.sep):
            continue
        name = os.path.basename(path)[:-2]     # "app_menu.cpp"
        if name in KEEP_INTERNAL:
            continue
        try:
            listing = subprocess.run([objdump, "-h", path], env=tool_env, check=True,
                                     capture_output=True, text=True).stdout
            secs = re.findall(r"^\s*\d+\s+(\.bss(?:\.\S+)?)\s+([0-9a-fA-F]+)", listing, re.M)
            if not secs:
                continue
            args = [objcopy]
            for sec, size in secs:
                args += ["--rename-section", "%s=.ext_ram%s" % (sec, sec)]
                total += int(size, 16)
            subprocess.run(args + [path], env=tool_env, check=True, capture_output=True, text=True)
            files += 1
            moved += len(secs)
        except Exception as e:  # never break the build over this: that file stays internal
            _log("%s left in internal RAM (%s)" % (name, e))
    if not files and not any(os.path.abspath(str(n)).startswith(src_dir + os.sep) for n in source):
        _log("no firmware objects among the link's %d inputs (e.g. %s)" % (len(source), source[0] if source else "-"))
    _log("%d sections from %d files moved to PSRAM (%d bytes)" % (moved, files, total))


env.AddPreAction("$BUILD_DIR/${PROGNAME}.elf", move_bss)  # noqa: F821
