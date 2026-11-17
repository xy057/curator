// Attacca's window in the DAW (link_view.mm): its name, whether Curator is connected (or why
// not), and the projects following this DAW.
#pragma once

#define LINK_QUOTE_NAME_(x) #x
#define LINK_QUOTE_NAME(x) LINK_QUOTE_NAME_ (x)

namespace attacca {

constexpr int statusViewWidth = 320, statusViewHeight = 92;

// Puts the view in [parent] (an NSView), filling it; the handle lets it go again.
void* attachStatusView (void* parent);
void detachStatusView (void* handle);

// The name of the Objective-C class that makes the Audio Unit's view (kAudioUnitProperty_CocoaUI).
const char* statusViewFactoryClass ();

}  // namespace attacca
