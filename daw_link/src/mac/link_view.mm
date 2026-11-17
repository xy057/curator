// Attacca's window in the DAW: its name, whether Curator is connected (or why not), and
// the Curator projects following this DAW. Attacca Capturer's says whether it is capturing,
// or that it needs Attacca on a track.
#include "link_view.h"

#include "../link_capture.h"
#include "../link_client.h"
#include "../link_config.h"

#import <AudioToolbox/AudioToolbox.h>
#import <AudioUnit/AUCocoaUIView.h>
#import <Cocoa/Cocoa.h>

#include <dlfcn.h>

// Each bundle names its classes for itself (LINK_VIEW_SUFFIX): a DAW can load the VST3 and the
// Audio Unit at once, and Objective-C classes are one namespace for the whole process.
#define LINK_JOIN_(a, b) a##b
#define LINK_JOIN(a, b) LINK_JOIN_(a, b)
#define LinkStatusView LINK_JOIN(AttaccaStatusView_, LINK_VIEW_SUFFIX)
#define LinkViewFactory LINK_JOIN(AttaccaViewFactory_, LINK_VIEW_SUFFIX)

namespace {

// The build of the Attacca installed where this one was loaded from (its bundle's
// CFBundleVersion, as it is on disk now; 0 when it can't be read): newer than LINK_BUILD once
// Curator has put a newer one there, which the DAW loads only when it opens again.
int installedBuild ()
{
    Dl_info info {};
    if (!::dladdr (reinterpret_cast<const void*> (&installedBuild), &info) || !info.dli_fname)
        return 0;
    // .../Attacca.vst3/Contents/MacOS/Attacca → .../Attacca.vst3/Contents/Info.plist
    NSString* contents = [[NSString stringWithUTF8String:info.dli_fname].stringByDeletingLastPathComponent stringByDeletingLastPathComponent];
    NSDictionary* plist = [NSDictionary dictionaryWithContentsOfFile:[contents stringByAppendingPathComponent:@"Info.plist"]];
    id build = plist[@"CFBundleVersion"];
    return [build isKindOfClass:NSString.class] ? [(NSString*) build intValue] : 0;
}

}  // namespace

@interface LinkStatusView : NSView
- (void)setBound:(std::function<int ()>)bound;
- (instancetype)initWithFrame:(NSRect)frame capturer:(BOOL)capturer;
@end

@implementation LinkStatusView {
    NSTextField* _dot;
    NSTextField* _status;
    NSTextField* _detail;
    NSTimer* _timer;
    attacca::LinkClient* _client;
    BOOL _capturer;
    std::function<int ()> _bound;
}

- (void)setBound:(std::function<int ()>)bound
{
    _bound = std::move (bound);
    [self update];
}

- (instancetype)initWithFrame:(NSRect)frame
{
    return [self initWithFrame:frame capturer:NO];
}

- (instancetype)initWithFrame:(NSRect)frame capturer:(BOOL)capturer
{
    if (!(self = [super initWithFrame:frame]))
        return nil;
    _capturer = capturer;
    _client = &attacca::LinkClient::retain ();
    self.wantsLayer = YES;
    self.layer.backgroundColor = NSColor.windowBackgroundColor.CGColor;

    NSTextField* title = [NSTextField labelWithString:capturer ? @"Attacca Capturer" : @"Attacca"];
    title.font = [NSFont boldSystemFontOfSize:15];
    _dot = [NSTextField labelWithString:@"\u25CF"];
    _dot.font = [NSFont systemFontOfSize:10];
    _status = [NSTextField labelWithString:@""];
    _status.font = [NSFont systemFontOfSize:12];
    NSStackView* state = [NSStackView stackViewWithViews:@[ _dot, _status ]];
    state.spacing = 5;
    _detail = [NSTextField labelWithString:@""];
    _detail.font = [NSFont systemFontOfSize:11];
    _detail.textColor = NSColor.secondaryLabelColor;
    _detail.lineBreakMode = NSLineBreakByTruncatingTail;
    [_detail setContentCompressionResistancePriority:NSLayoutPriorityDefaultLow forOrientation:NSLayoutConstraintOrientationHorizontal];
    NSStackView* stack = [NSStackView stackViewWithViews:@[ title, state, _detail ]];
    stack.orientation = NSUserInterfaceLayoutOrientationVertical;
    stack.alignment = NSLayoutAttributeLeading;
    stack.spacing = 4;
    stack.translatesAutoresizingMaskIntoConstraints = NO;
    [self addSubview:stack];
    [NSLayoutConstraint activateConstraints:@[
        [stack.leadingAnchor constraintEqualToAnchor:self.leadingAnchor constant:16],
        [stack.trailingAnchor constraintLessThanOrEqualToAnchor:self.trailingAnchor constant:-16],
        [stack.centerYAnchor constraintEqualToAnchor:self.centerYAnchor],
    ]];
    [self update];
    // Weakly held: the timer ends with the view.
    __weak LinkStatusView* weakSelf = self;
    _timer = [NSTimer scheduledTimerWithTimeInterval:1.0 repeats:YES block:^(NSTimer*) { [weakSelf update]; }];
    return self;
}

// Where Curator is: connected (and the projects following this DAW), connecting, open but not
// listening (no discovery file), or not open.
- (void)update
{
    NSString *status, *detail = @"";
    NSColor* dot;
    if (_client->connected ())
    {
        status = @"Connected to Curator";
        dot = NSColor.systemGreenColor;
        NSString* names = [NSString stringWithUTF8String:_client->followers ().c_str ()] ?: @"";
        NSArray<NSString*>* followers = names.length == 0 ? @[] : [names componentsSeparatedByString:@"\n"];
        detail = followers.count == 0 ? @"No project follows this DAW"
                                      : [@"Followed by " stringByAppendingString:[followers componentsJoinedByString:@", "]];
        if (_capturer && attacca::Capturer::busy ())
        {
            detail = @"Capturing for Curator\u2026";
        }
    }
    else if ([NSRunningApplication runningApplicationsWithBundleIdentifier:@LINK_CURATOR_BUNDLE_ID].count == 0)
    {
        status = @"Curator isn\u2019t open";
        dot = NSColor.tertiaryLabelColor;
        detail = @"Connects when Curator opens";
    }
    else if ([NSFileManager.defaultManager fileExistsAtPath:[NSString stringWithUTF8String:(attacca::curatorDataFolder () + "/daw-link.json").c_str ()]])
    {
        status = @"Connecting to Curator\u2026";
        dot = NSColor.systemOrangeColor;
    }
    else
    {
        status = @"Curator isn\u2019t listening";
        dot = NSColor.systemOrangeColor;
        detail = @"Settings \u25B8 General \u25B8 DAW \u25B8 Listen for Attacca";
    }
    // Not linked: Attacca on an insert only, never bound to ARA; the Capturer with no Attacca on
    // a track (an ARA document) in this DAW.
    if (_capturer ? attacca::Capturer::documents () == 0 : (_bound && _bound () == 0))
    {
        dot = NSColor.systemOrangeColor;
        detail = _capturer ? @"Not linked: no Attacca on a track as an ARA extension" : @"Insert only: add Attacca to a track as an ARA extension";
    }
    // Outdated: a newer Attacca is installed (the DAW keeps the one it loaded until it opens
    // again), or Curator bundles a newer one.
    const int loaded = LINK_BUILD, installed = installedBuild (), curator = _client->curatorBuild ();
    if (loaded > 0 && installed > loaded)
    {
        dot = NSColor.systemOrangeColor;
        detail = @"Outdated: reopen the DAW to load the new Attacca";
    }
    else if (loaded > 0 && curator > loaded)
    {
        dot = NSColor.systemOrangeColor;
        detail = @"Outdated: update it in Curator\u2019s Settings";
    }
    _status.stringValue = status;
    _dot.textColor = dot;
    _detail.stringValue = detail;
    _detail.toolTip = detail;
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
    attacca::LinkClient::release ();
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
    // Attacca Capturer's, told by its component's name.
    BOOL capturer = NO;
    CFStringRef name = nullptr;
    if (unit && AudioComponentCopyName (AudioComponentInstanceGetComponent (unit), &name) == noErr && name)
    {
        capturer = [(__bridge NSString*) name containsString:@"Capturer"];
        CFRelease (name);
    }
    LinkStatusView* view = [[LinkStatusView alloc] initWithFrame:NSMakeRect (0, 0, attacca::statusViewWidth, attacca::statusViewHeight) capturer:capturer];
    // Attacca's own: bound to ARA or on an insert only, as the instance says.
    if (!capturer && unit)
    {
        [view setBound:[unit] () -> int {
            UInt32 bound = 0, size = sizeof bound;
            return AudioUnitGetProperty (unit, attacca::audioUnitPropertyBoundToARA, kAudioUnitScope_Global, 0, &bound, &size) == noErr ? static_cast<int> (bound) : -1;
        }];
    }
    return view;
}
@end

namespace attacca {

void* attachStatusView (void* parent, bool capturer, std::function<int ()> bound)
{
    LinkStatusView* view = [[LinkStatusView alloc] initWithFrame:NSMakeRect (0, 0, statusViewWidth, statusViewHeight) capturer:capturer];
    if (bound)
        [view setBound:std::move (bound)];
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

}  // namespace attacca
