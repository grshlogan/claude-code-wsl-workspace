#include <GL/gl.h>
#include <X11/Xlib.h>
#include <X11/extensions/Xrandr.h>
#include <X11/extensions/Xinerama.h>
#include <X11/Xcursor/Xcursor.h>
#include <X11/extensions/XInput2.h>
#include <X11/extensions/shape.h>
#include <curl/curl.h>
#include <glib.h>
#include <iostream>
#include <thread>

int main(int argc, char**) {
    int thread_result = 0;
    std::thread worker([&thread_result] { thread_result = 1; });
    worker.join();
    if (thread_result != 1 || curl_global_init(CURL_GLOBAL_DEFAULT) != CURLE_OK) return 1;
    CURL* curl = curl_easy_init();
    if (!curl) return 2;
    curl_easy_cleanup(curl);
    curl_global_cleanup();
    gchar* text = g_strdup("GUI_BUILD_DEPS_SMOKE_OK");
    std::cout << text << "; curl=" << LIBCURL_VERSION
              << "; glib=" << glib_major_version << '.' << glib_minor_version << '.' << glib_micro_version << '\n';
    g_free(text);
    // Keep all graphics symbols linked without opening a GUI in the default test.
    if (argc > 1) {
        Display* display = XOpenDisplay(nullptr);
        if (!display) return 3;
        int event = 0, error = 0, major = 2, minor = 0;
        (void)XRRQueryExtension(display, &event, &error);
        (void)XineramaIsActive(display);
        (void)XcursorSupportsARGB(display);
        (void)XIQueryVersion(display, &major, &minor);
        (void)XShapeQueryExtension(display, &event, &error);
        (void)glGetString(GL_VERSION);
        XCloseDisplay(display);
    }
    return 0;
}
