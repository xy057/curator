// Curator Link's window in the DAW (link_view.mm): its name, and whether Curator is connected.
#pragma once

#define LINK_QUOTE_NAME_(x) #x
#define LINK_QUOTE_NAME(x) LINK_QUOTE_NAME_ (x)

namespace curator_link {

constexpr int statusViewWidth = 320, statusViewHeight = 72;

// Puts the view in [parent] (an NSView), filling it; the handle lets it go again.
void* attachStatusView (void* parent);
void detachStatusView (void* handle);

// The name of the Objective-C class that makes the Audio Unit's view (kAudioUnitProperty_CocoaUI).
const char* statusViewFactoryClass ();

}  // namespace curator_link
