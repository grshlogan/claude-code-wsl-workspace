#!/usr/bin/env bash
# Run as the ordinary claude user. Cross-compiles only; does not execute Windows code.
set -euo pipefail
[[ $(id -u) == 1000 ]]
cd -- "$(dirname -- "$0")"
x86_64-w64-mingw32-windres gui.rc -O coff -o gui-res.o
x86_64-w64-mingw32-gcc -std=c17 -O2 -Wall -Wextra -Werror \
    -municode -mwindows -static gui.c gui-res.o -o gui-c.exe -luser32
x86_64-w64-mingw32-g++ -std=c++17 -O2 -Wall -Wextra -Werror \
    -municode -mwindows -static gui.cpp gui-res.o -o gui-cpp.exe -luser32
for executable in gui-c.exe gui-cpp.exe; do
    file "$executable"
    grep -q 'architecture: i386:x86-64' <(x86_64-w64-mingw32-objdump -f "$executable")
    x86_64-w64-mingw32-objdump -p "$executable" > "$executable.headers.txt"
    grep -Eq 'Subsystem[[:space:]]+00000002[[:space:]]+\(Windows GUI\)' "$executable.headers.txt"
    grep -q 'DLL Name: USER32.dll' "$executable.headers.txt"
    grep -q '\.rsrc' <(x86_64-w64-mingw32-objdump -h "$executable")
    if grep -Eqi 'DLL Name: (libgcc|libstdc\+\+|libwinpthread)' "$executable.headers.txt"; then
        printf 'Unexpected GCC runtime DLL dependency in %s\n' "$executable" >&2
        exit 1
    fi
    grep 'DLL Name:' "$executable.headers.txt"
    sha256sum "$executable"
done
printf 'MINGW64_GUI_SMOKE_OK: C, C++, resource, POSIX thread, x64 PE GUI subsystem\n'
