#pragma once
// Big static arrays in PSRAM, for the Arduino IDE build.
//
//   PS_ARRAY(Item, s_items, [MAX_ITEMS]);       instead of   static Item s_items[MAX_ITEMS];
//   PS_ARRAY(char, s_paths, [DEPTH][PATH_MAX]);
//
// Internal RAM is what Bluetooth and Wi-Fi need to start. The PlatformIO
// build moves every file's static buffers to PSRAM at link time
// (pio/app_bss_to_psram.py), so there this is a plain static array. The
// stock Arduino core's linker script has no PSRAM section for statics, so
// there the array is allocated in PSRAM (zeroed, like a static) before
// setup() runs, and the name is a reference to it: code using it doesn't
// change, sizeof() included.
//
// Only for element types that zeroed memory is a valid value of (no
// constructors, no default member values) - checked at compile time.

#include <stddef.h>
#include <stdlib.h>
#include <type_traits>
#include <esp_heap_caps.h>

#if defined(PIO_BUILD)

#define PS_ARRAY(T, name, dims) static T name dims

#else

template <typename A>
static A &ps_static_array() {
    static_assert(std::is_trivially_default_constructible<A>::value && std::is_trivially_destructible<A>::value,
                  "PS_ARRAY: the element type needs a constructor - keep it a plain static array");
    void *p = heap_caps_calloc(1, sizeof(A), MALLOC_CAP_SPIRAM | MALLOC_CAP_8BIT);
    if (!p) p = calloc(1, sizeof(A));   // no PSRAM: internal RAM, as a static would be
    if (!p) abort();
    return *static_cast<A *>(p);
}

#define PS_ARRAY(T, name, dims)                  \
    typedef T name##_ps_array_t dims;            \
    static name##_ps_array_t &name = ps_static_array<name##_ps_array_t>()

#endif
