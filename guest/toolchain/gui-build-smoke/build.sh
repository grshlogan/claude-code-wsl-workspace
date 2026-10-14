#!/usr/bin/env bash
# Run as claude; compile/inspect both platforms, no network request or GUI launch.
set -euo pipefail
[[ $(id -u) == 1000 ]]
cd -- "$(dirname -- "$0")"
cmake --version | head -n 1
ninja --version
g++ --version | head -n 1
gdb --version | head -n 1
ccache --version | head -n 1
pkg-config --modversion gl x11 xrandr xinerama xcursor xi xext libcurl glib-2.0
export CCACHE_DIR="$PWD/build-cache"
cmake -S . -B build-native -G Ninja -DCMAKE_BUILD_TYPE=Debug \
    -DCMAKE_CXX_COMPILER_LAUNCHER=ccache -DFETCHCONTENT_FULLY_DISCONNECTED=ON
cmake --build build-native --parallel 2
./build-native/deps-smoke
# Compile the same object a second time and verify cache reuse.
cmake --build build-native --target clean
cmake --build build-native --parallel 2
ccache --show-stats
ccache --print-stats | awk '$1 == "direct_cache_hit" || $1 == "preprocessed_cache_hit" { hits += $2 } END { exit !(hits > 0) }'
DEBUGINFOD_URLS= gdb --batch --nx -ex 'set debuginfod enabled off' \
    -ex 'file build-native/deps-smoke' -ex 'info files' > gdb-inspection.txt
cmake -S . -B build-windows -G Ninja -DCMAKE_BUILD_TYPE=Release \
    -DCMAKE_TOOLCHAIN_FILE="$PWD/mingw64.cmake" -DFETCHCONTENT_FULLY_DISCONNECTED=ON
cmake --build build-windows --parallel 2
file build-windows/windows-gui.exe
x86_64-w64-mingw32-objdump -p build-windows/windows-gui.exe > windows-pe.txt
grep -Eq 'Subsystem[[:space:]]+00000002[[:space:]]+\(Windows GUI\)' windows-pe.txt
grep -q 'DLL Name: USER32.dll' windows-pe.txt
if grep -Eqi 'DLL Name: (libgcc|libstdc\+\+|libwinpthread)' windows-pe.txt; then exit 1; fi
printf 'GUI_BUILD_DEPS_CMAKE_NINJA_BOTH_TARGETS_OK\n'
