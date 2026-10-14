#include <windows.h>

int WINAPI wWinMain(HINSTANCE instance, HINSTANCE previous, PWSTR command, int show) {
    (void)instance;
    (void)previous;
    (void)command;
    (void)show;
    MessageBoxW(NULL, L"MinGW-w64 C GUI build passed.", L"Claude toolchain smoke", MB_OK);
    return 0;
}
