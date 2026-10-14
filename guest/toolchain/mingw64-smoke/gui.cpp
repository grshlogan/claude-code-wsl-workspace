#include <windows.h>
#include <string>
#include <thread>

int WINAPI wWinMain(HINSTANCE, HINSTANCE, PWSTR, int) {
    std::wstring text;
    std::thread worker([&text] { text = L"MinGW-w64 C++ GUI and POSIX threads build passed."; });
    worker.join();
    MessageBoxW(nullptr, text.c_str(), L"Claude toolchain smoke", MB_OK);
    return 0;
}
