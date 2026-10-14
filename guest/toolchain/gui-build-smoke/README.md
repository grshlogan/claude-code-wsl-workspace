# Native Linux and Windows GUI build tool smoke

GUI development packages are installed in the `claude-debian12` guest.

```bash
cd ~/projects/toolchain-smoke/gui-build-deps
./build.sh
```

The script uses the ordinary `claude` user. It verifies native G++, CMake/Ninja, OpenGL, X11/Xrandr/Xinerama/Xcursor/Xi/Xext, curl and GLib, then builds a Windows x64 GUI through the existing MinGW toolchain. It also checks ccache reuse and GDB file inspection without debuginfod access. It does not open a GUI or send HTTP requests.

Available tool versions: G++ 12.2.0, CMake 3.25.1, Ninja 1.11.1, GDB 13.1, ccache 4.7.5, curl 7.88.1 and GLib 2.74.6. Linux development libraries must not be linked into a Windows executable.

For a real native project, from its independent guest checkout:

```bash
cmake -S . -B build/linux -G Ninja -DCMAKE_BUILD_TYPE=Debug \
  -DCMAKE_CXX_COMPILER_LAUNCHER=ccache
cmake --build build/linux --parallel 2
```

Use project-specific configuration options and a reviewed MinGW toolchain for Windows builds. The sample `mingw64.cmake` shows compiler/resource-tool selection and Windows-only target library searches. This smoke test only verifies that the toolchain can build a Windows GUI executable; it does not establish that any real application has passed acceptance.
