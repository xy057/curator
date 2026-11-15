// Curator Link's window in the DAW: its name, and whether Curator is connected.
#include "link_view.h"

#include "../link_client.h"

#import <AudioUnit/AUCocoaUIView.h>
#import <Cocoa/Cocoa.h>

// Each bundle names its classes for itself (LINK_VIEW_SUFFIX): a DAW can load the VST3 and the
// Audio Unit at once, and Objective-C classes are one namespace for the whole process.
#define LINK_JOIN_(a, b) a##b
#define LINK_JOIN(a, b) LINK_JOIN_(a, b)
#define LinkStatusView LINK_JOIN(CuratorLinkStatusView_, LINK_VIEW_SUFFIX)
#define LinkViewFactory LINK_JOIN(CuratorLinkViewFactory_, LINK_VIEW_SUFFIX)

@interface LinkStatusView : NSView
@end

@implementation LinkStatusView {
    NSTextField* _status;
    NSTimer* _timer;
    curator_link::LinkClient* _client;
}

- (instancetype)initWithFrame:(NSRect)frame
{
    if (!(self = [super initWithFrame:frame]))
        return nil;
    _client = &curator_link::LinkClient::retain ();
    self.wantsLayer = YES;
    self.layer.backgroundColor = NSColor.windowBackgroundColor.CGColor;

    NSTextField* title = [NSTextField labelWithString:@"Curator Link"];
    title.font = [NSFont boldSystemFontOfSize:15];
    _status = [NSTextField labelWithString:@""];
    _status.font = [NSFont systemFontOfSize:12];
    _status.textColor = NSColor.secondaryLabelColor;
    NSStackView* stack = [NSStackView stackViewWithViews:@[ title, _status ]];
    stack.orientation = NSUserInterfaceLayoutOrientationVertical;
    stack.alignment = NSLayoutAttributeLeading;
    stack.spacing = 4;
    stack.translatesAutoresizingMaskIntoConstraints = NO;
    [self addSubview:stack];
    [NSLayoutConstraint activateConstraints:@[
        [stack.leadingAnchor constraintEqualToAnchor:self.leadingAnchor constant:16],
        [stack.centerYAnchor constraintEqualToAnchor:self.centerYAnchor],
    ]];
    [self update];
    // Weakly held: the timer ends with the view.
    __weak LinkStatusView* weakSelf = self;
    _timer = [NSTimer scheduledTimerWithTimeInterval:1.0 repeats:YES block:^(NSTimer*) { [weakSelf update]; }];
    return self;
}

- (void)update
{
    _status.stringValue = _client->connected () ? @"Connected to Curator" : @"Waiting for Curator";
}

- (void)viewWillMoveToWindow:(NSWindow*)window
{
    if (window == nil)
    {
        [_timer invalidate];
        _timer = nil;
    }
    [super viewWillMoveToWindow:window];
}

- (void)dealloc
{
    [_timer invalidate];
    curator_link::LinkClient::release ();
}
@end

// The Audio Unit's view, as Logic asks for it (kAudioUnitProperty_CocoaUI).
@interface LinkViewFactory : NSObject <AUCocoaUIBase>
@end

@implementation LinkViewFactory
- (unsigned)interfaceVersion
{
    return 0;
}

- (NSView*)uiViewForAudioUnit:(AudioUnit)unit withSize:(NSSize)size
{
    return [[LinkStatusView alloc] initWithFrame:NSMakeRect (0, 0, curator_link::statusViewWidth, curator_link::statusViewHeight)];
}
@end

namespace curator_link {

void* attachStatusView (void* parent)
{
    NSView* view = [[LinkStatusView alloc] initWithFrame:NSMakeRect (0, 0, statusViewWidth, statusViewHeight)];
    view.autoresizingMask = NSViewWidthSizable | NSViewHeightSizable;
    [(__bridge NSView*) parent addSubview:view];
    return (__bridge_retained void*) view;
}

void detachStatusView (void* handle)
{
    NSView* view = (__bridge_transfer NSView*) handle;
    [view removeFromSuperview];
}

const char* statusViewFactoryClass ()
{
    return LINK_QUOTE_NAME (LinkViewFactory);
}

}  // namespace curator_link
