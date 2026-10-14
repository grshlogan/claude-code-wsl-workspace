# MinGW-w64 Windows x64 GUI smoke build

Run as the ordinary `claude` user in `claude-debian12`:

```bash
cd ~/projects/toolchain-smoke/mingw64
./build.sh
```

The APT-owned tools are on the normal system PATH:

- `x86_64-w64-mingw32-gcc`: C, Windows x64 target, POSIX threads.
- `x86_64-w64-mingw32-g++`: C++, Windows x64 target, POSIX threads.
- `x86_64-w64-mingw32-windres`: resource compilation.
- `x86_64-w64-mingw32-objdump`: inspect Windows PE artifacts.

A minimal build command for a Unicode C++ GUI:

```bash
x86_64-w64-mingw32-g++ -std=c++17 -O2 -Wall -Wextra \
  -municode -mwindows -static gui.cpp -o gui.exe -luser32
```

The smoke script builds C and C++ programs, includes a Windows version resource and checks the PE GUI subsystem, x64 architecture and Windows imports. Its C++ example uses `std::thread`. `-static` avoids separately shipped GCC runtime DLLs for these examples. Real framework libraries may still require DLL deployment.

Copy reviewed build artifacts to a Windows-local directory using the established Windows-side WSL file workflow and execute them there. This smoke test compiles and inspects only; it does not execute Windows GUI code inside Debian. Windows interop remains disabled. The initial MinGW installation did not include Wine, GUI framework SDKs, CMake/Ninja or a Rust Windows target. CMake/Ninja and additional GUI development packages were installed afterwards; see `install-gui-build-deps.sh`. Wine and the Rust Windows target remain absent.

Keep real Windows and Linux source checkouts independent and exchange reviewed commits. Do not replace native `gcc`/`g++` commands with cross-compilers globally.
