// Attacca's window in the DAW (link_view.mm): its name, whether Curator is connected (or why
// not), and the projects following this DAW.
#pragma once

#include <functional>

#define LINK_QUOTE_NAME_(x) #x
#define LINK_QUOTE_NAME(x) LINK_QUOTE_NAME_ (x)

namespace attacca {

constexpr int statusViewWidth = 320, statusViewHeight = 92;

// Puts the view in [parent] (an NSView), filling it; the handle lets it go again.
// [capturer]: Attacca Capturer's window (link_capture.h), else Attacca's. [bound] says whether
// Attacca's instance is bound to ARA (1), on an insert only (0), or not yet known (-1).
void* attachStatusView (void* parent, bool capturer = false, std::function<int ()> bound = {});
void detachStatusView (void* handle);

// The name of the Objective-C class that makes the Audio Unit's view (kAudioUnitProperty_CocoaUI).
const char* statusViewFactoryClass ();

// The Audio Unit property (global scope, a UInt32) saying whether the instance is bound to ARA.
constexpr unsigned audioUnitPropertyBoundToARA = 70001;

}  // namespace attacca
