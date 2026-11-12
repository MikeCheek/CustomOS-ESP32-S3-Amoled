#!/usr/bin/env python3
"""The watch's partition table as the binary the ESP32 reads at 0x8000.

    python tools/partitions_bin.py [firmware/partitions.csv] [partitions.bin]

The same bytes as ESP-IDF's gen_esp32part.py (32-byte entries, an MD5
entry, padded with 0xFF to 3 KB), without needing ESP-IDF or PlatformIO:
for flashing a 3.5+ build over USB onto a watch that still has the old
3 MB slots - the firmware alone doesn't change the table (README, Building).
"""
import hashlib
import struct
import sys

TYPES = {"app": 0x00, "data": 0x01}
SUBTYPES = {
    "app": {"factory": 0x00, "test": 0x20, **{f"ota_{i}": 0x10 + i for i in range(16)}},
    "data": {"ota": 0x00, "phy": 0x01, "nvs": 0x02, "coredump": 0x03, "nvs_keys": 0x04,
             "efuse": 0x05, "undefined": 0x06, "esphttpd": 0x80, "fat": 0x81, "spiffs": 0x82, "littlefs": 0x83},
}


def num(s):
    s = s.strip().lower()
    mult = 1
    if s.endswith("k"):
        mult, s = 1024, s[:-1]
    elif s.endswith("m"):
        mult, s = 1024 * 1024, s[:-1]
    return int(s, 0) * mult


def table(csv_text):
    out = b""
    offset = 0x9000
    for line in csv_text.splitlines():
        line = line.split("#", 1)[0].strip()
        if not line:
            continue
        f = [x.strip() for x in line.split(",")]
        name, typ, sub, off, size = f[:5]
        flags = f[5] if len(f) > 5 else ""
        t = TYPES[typ]
        st = SUBTYPES[typ][sub]
        o = num(off) if off else offset
        if t == 0x00 and o % 0x10000:  # apps start on 64 KB
            o = (o + 0xFFFF) & ~0xFFFF
        sz = num(size)
        fl = 1 if "encrypted" in flags else 0
        out += struct.pack("<2sBBLL16sL", b"\xAA\x50", t, st, o, sz, name.encode()[:16], fl)
        offset = o + sz
    out += b"\xEB\xEB" + b"\xFF" * 14 + hashlib.md5(out).digest()
    return out + b"\xFF" * (0xC00 - len(out))


if __name__ == "__main__":
    src = sys.argv[1] if len(sys.argv) > 1 else "firmware/partitions.csv"
    dst = sys.argv[2] if len(sys.argv) > 2 else "partitions.bin"
    data = table(open(src).read())
    open(dst, "wb").write(data)
    print(f"{dst}: {len(data)} bytes")
