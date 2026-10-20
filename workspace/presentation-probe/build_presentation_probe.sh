#!/bin/sh
set -eu
presentation_dir=$(CDPATH= cd -- "$(dirname -- "$0")" && pwd)
presentation_source="$presentation_dir/d3dmetal-native-source"
presentation_objects="$presentation_dir/build-objects"
mkdir -p "$presentation_objects"
# UTM GFXT service subset only. Deliberately omit dmn_init/com_hooks/share/sparse.
# Cache this unchanged subset; at most three compiler jobs run simultaneously.
presentation_jobs=0
for presentation_file in dmn_log.cpp dmn_gfxt_os.cpp dmn_gfxt_event.cpp \
  dmn_gfxt_registry.cpp dmn_gfxt_path.cpp dmn_gfxt_allocation.cpp \
  dmn_gfxt_library.cpp dmn_gfxt_monitor.cpp dmn_gfxt_adapter.mm \
  dmn_window.mm dmn_gfxt_swapchain.mm; do
  presentation_input="$presentation_source/src/$presentation_file"
  presentation_object="$presentation_objects/$presentation_file.o"
  if test ! -f "$presentation_object" || test "$presentation_input" -nt "$presentation_object"; then
    /usr/bin/clang++ -std=c++17 -O1 -Wall -Wextra -fshort-wchar -fno-objc-arc \
      -I"$presentation_source/include" -I"$presentation_source/src" \
      -c "$presentation_input" -o "$presentation_object" &
    presentation_jobs=$((presentation_jobs + 1))
    if test "$presentation_jobs" -eq 3; then wait; presentation_jobs=0; fi
  fi
done
wait
/usr/bin/clang++ -std=c++17 -O1 -Wall -Wextra -fshort-wchar -fno-objc-arc \
  -I"$presentation_source/include" -I"$presentation_source/src" \
  -c "$presentation_dir/native_presentation_host.mm" -o "$presentation_objects/native_presentation_host.o"
/usr/bin/clang++ "$presentation_objects"/*.o \
  -framework Foundation -framework AppKit -framework Metal -framework QuartzCore -framework CoreGraphics -framework ImageIO \
  -o "$presentation_dir/native_presentation_host"
file "$presentation_dir/native_presentation_host"
