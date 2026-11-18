// Attacca's window in the DAW (macOS: mac/link_view.mm; Windows: win/link_view.cpp): its name,
// whether Curator is connected (or why not), and the projects following this DAW.
#pragma once

#include <functional>
#include <string>

#define LINK_QUOTE_NAME_(x) #x
#define LINK_QUOTE_NAME(x) LINK_QUOTE_NAME_ (x)

namespace attacca {

constexpr int statusViewWidth = 320, statusViewHeight = 124;

// Puts the view in [parent] (macOS: an NSView; Windows: an HWND), filling it; the handle lets
// it go again. Its size is [statusViewWidth] by [statusViewHeight] points; on Windows the DAW
// may make it more pixels than that (a denser screen), and what it shows grows with it.
// [capturer]: Attacca Capturer's window (link_capture.h), else Attacca's. [bound] says whether
// Attacca's instance is bound to ARA (1), on an insert only (0), or not yet known (-1);
// [capturerId] the Capturer's ID (whether it is linked: [LinkClient::linked]).
void* attachStatusView (void* parent, bool capturer = false, std::function<int ()> bound = {}, std::function<std::string ()> capturerId = {});
void detachStatusView (void* handle);
#if defined(_WIN32)
// Windows: the view made [width] by [height] pixels, when the DAW's window is (a child there
// doesn't follow its parent by itself).
void resizeStatusView (void* handle, int width, int height);
#endif

// The name of the Objective-C class that makes the Audio Unit's view (kAudioUnitProperty_CocoaUI).
const char* statusViewFactoryClass ();

// The Audio Unit property (global scope, a UInt32) saying whether the instance is bound to ARA.
constexpr unsigned audioUnitPropertyBoundToARA = 70001;
// The Audio Unit property (global scope, a CFStringRef the caller releases): Attacca Capturer's ID.
constexpr unsigned audioUnitPropertyCapturerID = 70002;

}  // namespace attacca
