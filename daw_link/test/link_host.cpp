// A DAW in miniature that checks Attacca as built:
// `link_host "<path>/Attacca.vst3" "<path>/Attacca.component"`.
//
// It stands in for both ends the plug-in talks to. As Curator, it listens where a discovery file
// in a home of its own says (HOME is pointed at a temporary folder, so the real Curator is never
// reached); as the DAW, it loads the VST3, makes an ARA document with a tempo map, bar and key
// signatures, a track and a recording placed in the song, and checks what Curator is told: the
// document, the recording written as a file when asked for, the region played back where the song
// has it, the transport, and the document closed. The Audio Unit (Logic's) is registered in this
// process only and checked for its ARA factory and its playback. Exits non-zero, saying why, on the
// first failure.
#include "ARA_API/ARAAudioUnit.h"
#include "ARA_API/ARAInterface.h"
#include "ExamplesCommon/PlugInHosting/VST3Loader.h"

#include <AudioToolbox/AudioToolbox.h>
#include <objc/message.h>
#include <objc/runtime.h>

#include "ARA_API/ARAVST3.h"

ARA_DISABLE_VST3_WARNINGS_BEGIN
#include "pluginterfaces/base/ipluginbase.h"
#include "pluginterfaces/gui/iplugview.h"
#include "pluginterfaces/vst/ivstaudioprocessor.h"
#include "pluginterfaces/vst/ivstcomponent.h"
#include "pluginterfaces/vst/ivsteditcontroller.h"
#include "pluginterfaces/vst/ivstprocesscontext.h"
ARA_DISABLE_VST3_WARNINGS_END

#include "../src/json.h"
#include "../src/link_files.h"
#include "public.sdk/source/common/memorystream.h"

#include <arpa/inet.h>
#include <netinet/in.h>
#include <poll.h>
#include <sys/socket.h>
#include <sys/stat.h>
#include <unistd.h>

#include <chrono>
#include <cmath>
#include <cstdio>
#include <cstdlib>
#include <cstring>
#include <fstream>
#include <functional>
#include <map>
#include <mutex>
#include <string>
#include <thread>
#include <vector>

using namespace ARA;
using attacca::readFlatObject;

namespace {

constexpr double sourceRate = 44100;
constexpr ARASampleCount sourceFrames = 5 * 44100;
constexpr double toneHz = 441;

// The recording: a sine whose phase says where in it a sample is.
float toneAt (ARASamplePosition frame) { return static_cast<float> (0.5 * std::sin (2 * M_PI * toneHz * static_cast<double> (frame) / sourceRate)); }

[[noreturn]] void fail (const std::string& why)
{
    std::fprintf (stderr, "link_host: FAILED: %s\n", why.c_str ());
    std::exit (1);
}

void check (bool ok, const std::string& what)
{
    if (!ok)
        fail (what);
    std::printf ("  ok  %s\n", what.c_str ());
}

// MARK: The host's side of ARA

ARAAudioReaderHostRef ARA_CALL createAudioReader (ARAAudioAccessControllerHostRef, ARAAudioSourceHostRef, ARABool use64)
{
    return reinterpret_cast<ARAAudioReaderHostRef> (use64 ? 2 : 1);
}
ARABool ARA_CALL readAudioSamples (ARAAudioAccessControllerHostRef, ARAAudioReaderHostRef reader, ARASamplePosition at, ARASampleCount count, void* const buffers[])
{
    for (ARASampleCount i = 0; i < count; ++i)
    {
        if (reader == reinterpret_cast<ARAAudioReaderHostRef> (2))
            static_cast<double*> (buffers[0])[i] = toneAt (at + i);
        else
            static_cast<float*> (buffers[0])[i] = toneAt (at + i);
    }
    return kARATrue;
}
void ARA_CALL destroyAudioReader (ARAAudioAccessControllerHostRef, ARAAudioReaderHostRef) {}
const ARAAudioAccessControllerInterface audioAccess = { ARA_IMPLEMENTED_STRUCT_SIZE (ARAAudioAccessControllerInterface, destroyAudioReader),
                                                        &createAudioReader, &readAudioSamples, &destroyAudioReader };

ARASize ARA_CALL archiveSize (ARAArchivingControllerHostRef, ARAArchiveReaderHostRef) { return 0; }
ARABool ARA_CALL readArchive (ARAArchivingControllerHostRef, ARAArchiveReaderHostRef, ARASize, ARASize, ARAByte[]) { return kARAFalse; }
ARABool ARA_CALL writeArchive (ARAArchivingControllerHostRef, ARAArchiveWriterHostRef, ARASize, ARASize, const ARAByte[]) { return kARATrue; }
void ARA_CALL archivingProgress (ARAArchivingControllerHostRef, float) {}
ARAPersistentID ARA_CALL archiveID (ARAArchivingControllerHostRef, ARAArchiveReaderHostRef) { return nullptr; }
const ARAArchivingControllerInterface archiving = { ARA_IMPLEMENTED_STRUCT_SIZE (ARAArchivingControllerInterface, getDocumentArchiveID),
                                                    &archiveSize, &readArchive, &writeArchive, &archivingProgress, &archivingProgress, &archiveID };

// What the plug-in asked the DAW's transport to do (Curator's transport driving it, a capture),
// from the connection's thread.
std::mutex playbackMutex;
std::vector<std::string> playbackAskedList;
void ask (std::string what)
{
    std::lock_guard<std::mutex> lock (playbackMutex);
    playbackAskedList.push_back (std::move (what));
}
std::vector<std::string> playbackAsked ()
{
    std::lock_guard<std::mutex> lock (playbackMutex);
    return playbackAskedList;
}
void clearPlaybackAsked ()
{
    std::lock_guard<std::mutex> lock (playbackMutex);
    playbackAskedList.clear ();
}
// Waits (running [idle]) until the DAW was asked [count] things since cleared; what it was asked.
std::vector<std::string> waitForAsked (size_t count, const std::function<void ()>& idle)
{
    for (int i = 0; i < 100 && playbackAsked ().size () < count; ++i)
    {
        if (idle)
            idle ();
        std::this_thread::sleep_for (std::chrono::milliseconds (10));
    }
    return playbackAsked ();
}
void ARA_CALL startPlayback (ARAPlaybackControllerHostRef) { ask ("start"); }
void ARA_CALL stopPlayback (ARAPlaybackControllerHostRef) { ask ("stop"); }
void ARA_CALL setPosition (ARAPlaybackControllerHostRef, ARATimePosition at) { ask ("at " + std::to_string (at)); }
void ARA_CALL setCycle (ARAPlaybackControllerHostRef, ARATimePosition, ARATimeDuration) {}
void ARA_CALL enableCycle (ARAPlaybackControllerHostRef, ARABool) {}
const ARAPlaybackControllerInterface playbackControl = { ARA_IMPLEMENTED_STRUCT_SIZE (ARAPlaybackControllerInterface, requestEnableCycle),
                                                          &startPlayback, &stopPlayback, &setPosition, &setCycle, &enableCycle };

// The song: 120 to quarter 4 (2 s), then 90 (six quarters in 4 s); 4/4, then 3/4 from quarter 8.
const ARAContentTempoEntry tempo[] = { { 0.0, 0.0 }, { 2.0, 4.0 }, { 6.0, 10.0 } };
const ARAContentBarSignature bars[] = { { 4, 4, 0.0 }, { 3, 4, 8.0 } };
const ARAContentKeySignature keys[] = { { 0, { 1, 0, 1, 0, 1, 1, 0, 1, 0, 1, 0, 1 }, "C major", 0.0 } };
const auto tempoReader = reinterpret_cast<ARAContentReaderHostRef> (30);
const auto barsReader = reinterpret_cast<ARAContentReaderHostRef> (31);
const auto keysReader = reinterpret_cast<ARAContentReaderHostRef> (32);

ARABool ARA_CALL contextContentAvailable (ARAContentAccessControllerHostRef, ARAMusicalContextHostRef, ARAContentType type)
{
    return type == kARAContentTypeTempoEntries || type == kARAContentTypeBarSignatures || type == kARAContentTypeKeySignatures;
}
ARAContentGrade ARA_CALL contextContentGrade (ARAContentAccessControllerHostRef, ARAMusicalContextHostRef, ARAContentType) { return kARAContentGradeAdjusted; }
ARAContentReaderHostRef ARA_CALL createContextReader (ARAContentAccessControllerHostRef, ARAMusicalContextHostRef, ARAContentType type, const ARAContentTimeRange*)
{
    switch (type)
    {
        case kARAContentTypeTempoEntries: return tempoReader;
        case kARAContentTypeBarSignatures: return barsReader;
        case kARAContentTypeKeySignatures: return keysReader;
        default: return nullptr;
    }
}
ARABool ARA_CALL sourceContentAvailable (ARAContentAccessControllerHostRef, ARAAudioSourceHostRef, ARAContentType) { return kARAFalse; }
ARAContentGrade ARA_CALL sourceContentGrade (ARAContentAccessControllerHostRef, ARAAudioSourceHostRef, ARAContentType) { return kARAContentGradeInitial; }
ARAContentReaderHostRef ARA_CALL createSourceReader (ARAContentAccessControllerHostRef, ARAAudioSourceHostRef, ARAContentType, const ARAContentTimeRange*) { return nullptr; }
ARAInt32 ARA_CALL eventCount (ARAContentAccessControllerHostRef, ARAContentReaderHostRef reader)
{
    if (reader == tempoReader)
        return 3;
    if (reader == barsReader)
        return 2;
    return reader == keysReader ? 1 : 0;
}
const void* ARA_CALL eventData (ARAContentAccessControllerHostRef, ARAContentReaderHostRef reader, ARAInt32 i)
{
    if (reader == tempoReader)
        return &tempo[i];
    if (reader == barsReader)
        return &bars[i];
    return reader == keysReader ? &keys[i] : nullptr;
}
void ARA_CALL destroyContentReader (ARAContentAccessControllerHostRef, ARAContentReaderHostRef) {}
const ARAContentAccessControllerInterface contentAccess = { ARA_IMPLEMENTED_STRUCT_SIZE (ARAContentAccessControllerInterface, destroyContentReader),
                                                            &contextContentAvailable, &contextContentGrade, &createContextReader,
                                                            &sourceContentAvailable, &sourceContentGrade, &createSourceReader,
                                                            &eventCount, &eventData, &destroyContentReader };

void ARA_CALL analysisProgress (ARAModelUpdateControllerHostRef, ARAAudioSourceHostRef, ARAAnalysisProgressState, float) {}
void ARA_CALL sourceChanged (ARAModelUpdateControllerHostRef, ARAAudioSourceHostRef, const ARAContentTimeRange*, ARAContentUpdateFlags) {}
void ARA_CALL modificationChanged (ARAModelUpdateControllerHostRef, ARAAudioModificationHostRef, const ARAContentTimeRange*, ARAContentUpdateFlags) {}
void ARA_CALL regionChanged (ARAModelUpdateControllerHostRef, ARAPlaybackRegionHostRef, const ARAContentTimeRange*, ARAContentUpdateFlags) {}
void ARA_CALL documentChanged (ARAModelUpdateControllerHostRef) {}
const ARAModelUpdateControllerInterface modelUpdates = { ARA_IMPLEMENTED_STRUCT_SIZE (ARAModelUpdateControllerInterface, notifyDocumentDataChanged),
                                                         &analysisProgress, &sourceChanged, &modificationChanged, &regionChanged, &documentChanged };

// MARK: Curator's side

struct Curator {
    int listener { -1 };
    // A connection a bundle: Attacca's, and Attacca Capturer's (a VST3 of its own).
    std::vector<int> connections;
    std::vector<std::string> pending;
    // The connection the last message came on.
    size_t from { 0 };

    void listen (const std::string& home)
    {
        listener = ::socket (AF_INET, SOCK_STREAM, 0);
        sockaddr_in address {};
        address.sin_family = AF_INET;
        address.sin_addr.s_addr = htonl (INADDR_LOOPBACK);
        if (::bind (listener, reinterpret_cast<sockaddr*> (&address), sizeof address) != 0 || ::listen (listener, 4) != 0)
            fail ("can't listen on the loopback address");
        socklen_t length = sizeof address;
        ::getsockname (listener, reinterpret_cast<sockaddr*> (&address), &length);
        const std::string folder = home + "/Library/Application Support/Curator";
        for (const std::string part : { home + "/Library", home + "/Library/Application Support", folder })
            ::mkdir (part.c_str (), 0755);
        std::ofstream (folder + "/daw-link.json") << "{\"port\":" << ntohs (address.sin_port) << ",\"token\":\"t0k3n\",\"pid\":" << ::getpid () << "}";
    }

    // The next message whose "t" is [type] (others are passed over), on any connection, within
    // [seconds]; [idle] runs while waiting, as a host's main thread would go on.
    std::map<std::string, std::string> next (const std::string& type, double seconds, const std::function<void ()>& idle = {})
    {
        const auto end = std::chrono::steady_clock::now () + std::chrono::duration<double> (seconds);
        while (std::chrono::steady_clock::now () < end)
        {
            pollfd p { listener, POLLIN, 0 };
            if (::poll (&p, 1, 0) > 0)
            {
                connections.push_back (::accept (listener, nullptr, nullptr));
                pending.emplace_back ();
            }
            for (size_t c = 0; c < connections.size (); ++c)
            {
                size_t at;
                while ((at = pending[c].find ('\n')) != std::string::npos)
                {
                    const std::string line = pending[c].substr (0, at);
                    pending[c].erase (0, at + 1);
                    std::map<std::string, std::string> message;
                    if (!readFlatObject (line, message))
                        fail ("a line that isn't a JSON object: " + line);
                    lines.push_back (line);
                    if (message["t"] == type)
                    {
                        from = c;
                        return message;
                    }
                }
            }
            for (size_t c = 0; c < connections.size (); ++c)
            {
                pollfd q { connections[c], POLLIN, 0 };
                if (connections[c] >= 0 && ::poll (&q, 1, 10) > 0)
                {
                    char buffer[65536];
                    const ssize_t n = ::recv (connections[c], buffer, sizeof buffer, 0);
                    if (n <= 0)
                    {
                        // A bundle whose last instance went lets go (what it sent is read first).
                        ::close (connections[c]);
                        connections[c] = -1;
                    }
                    else
                    {
                        pending[c].append (buffer, static_cast<size_t> (n));
                    }
                }
            }
            if (connections.empty ())
                ::poll (nullptr, 0, 20);
            if (idle)
                idle ();
        }
        fail ("no \"" + type + "\" message within " + std::to_string (seconds) + " s");
    }

    // [line] said on connection [to] (the first: Attacca's).
    void say (const std::string& line, size_t to = 0)
    {
        const std::string data = line + "\n";
        if (to >= connections.size () || ::send (connections[to], data.data (), data.size (), 0) != static_cast<ssize_t> (data.size ()))
            fail ("can't write to Attacca");
    }

    std::vector<std::string> lines;
};

bool contains (const std::string& text, const std::string& part) { return text.find (part) != std::string::npos; }


// MARK: The Audio Unit

Boolean playingNow = true;
Float64 sampleNow = 0;

OSStatus transportState (void*, Boolean* playing, Boolean* recording, Boolean* changed, Float64* sample, Boolean* cycling, Float64*, Float64*) noexcept
{
    if (recording)
        *recording = false;
    if (playing)
        *playing = playingNow;
    if (changed)
        *changed = false;
    if (sample)
        *sample = sampleNow;
    if (cycling)
        *cycling = false;
    return noErr;
}

OSStatus beatAndTempo (void*, Float64* beat, Float64* tempo) noexcept
{
    if (beat)
        *beat = sampleNow / sourceRate * 2;
    if (tempo)
        *tempo = 120;
    return noErr;
}

// An NSView made, and how many views are in one, through the Objective-C runtime (this file is C++).
id newView ()
{
    return reinterpret_cast<id (*) (id, SEL)> (objc_msgSend) (reinterpret_cast<id> (objc_getClass ("NSView")), sel_registerName ("new"));
}

unsigned long subviewCount (id view)
{
    const id subviews = reinterpret_cast<id (*) (id, SEL)> (objc_msgSend) (view, sel_registerName ("subviews"));
    return reinterpret_cast<unsigned long (*) (id, SEL)> (objc_msgSend) (subviews, sel_registerName ("count"));
}

void releaseObject (id object)
{
    reinterpret_cast<void (*) (id, SEL)> (objc_msgSend) (object, sel_registerName ("release"));
}

// The VST3's window, as a DAW opens it: the controller's editor view, put in an NSView and taken out.
void checkVst3View (const char* path, Curator& curator)
{
    using namespace Steinberg;
    CFURLRef url = CFURLCreateFromFileSystemRepresentation (nullptr, reinterpret_cast<const UInt8*> (path), static_cast<CFIndex> (std::strlen (path)), true);
    CFBundleRef bundle = CFBundleCreate (nullptr, url);
    CFRelease (url);
    auto getFactory = bundle ? reinterpret_cast<IPluginFactory* (*) ()> (CFBundleGetFunctionPointerForName (bundle, CFSTR ("GetPluginFactory"))) : nullptr;
    IPluginFactory* factory = getFactory ? getFactory () : nullptr;
    check (factory != nullptr, "the VST3 gives its factory");
    // Attacca alone in its bundle, ARA only: no DAW offers it as an insert (OnlyARA).
    {
        IPluginFactory2* factory2 = nullptr;
        bool onlyAttacca = true, onlyARA = false;
        if (factory->queryInterface (IPluginFactory2::iid, reinterpret_cast<void**> (&factory2)) == kResultOk && factory2)
        {
            for (int32 i = 0; i < factory2->countClasses (); ++i)
            {
                PClassInfo2 info;
                if (factory2->getClassInfo2 (i, &info) != kResultOk)
                    continue;
                onlyAttacca = onlyAttacca && std::strcmp (info.name, "Attacca") == 0;
                if (std::strcmp (info.category, kVstAudioEffectClass) == 0)
                    onlyARA = std::strstr (info.subCategories, "OnlyARA") != nullptr;
            }
            factory2->release ();
        }
        check (onlyAttacca, "Attacca alone in its bundle");
        check (onlyARA, "ARA only, not an insert");
    }
    // The controller as the factory lists it (as a DAW finds it), not by an ID written here.
    TUID controllerID {};
    bool listed = false;
    for (int32 i = 0; i < factory->countClasses () && !listed; ++i)
    {
        PClassInfo info;
        if (factory->getClassInfo (i, &info) == kResultOk && std::strcmp (info.category, kVstComponentControllerClass) == 0)
        {
            std::memcpy (controllerID, info.cid, sizeof (TUID));
            listed = true;
        }
    }
    check (listed, "its controller listed");
    void* object = nullptr;
    check (factory->createInstance (controllerID, Vst::IEditController_iid, &object) == kResultOk && object, "its controller made");
    auto* controller = static_cast<Vst::IEditController*> (object);
    controller->initialize (nullptr);
    IPlugView* view = controller->createView (Vst::ViewType::kEditor);
    check (view && view->isPlatformTypeSupported (kPlatformTypeNSView) == kResultTrue, "it has a window for macOS");
    ViewRect rect;
    check (view->getSize (&rect) == kResultOk && rect.getWidth () > 0 && rect.getHeight () > 0, "the window has a size");
    const id parent = newView ();
    check (view->attached (parent, kPlatformTypeNSView) == kResultOk && subviewCount (parent) == 1, "the window opens in the DAW's");
    view->removed ();
    check (subviewCount (parent) == 0, "and closes");
    view->release ();
    releaseObject (parent);
    controller->terminate ();
    controller->release ();

    // The Attacca Capturer linked (its window's Capturer menu) kept in an instance's state: given
    // back by the DAW, Curator is told the link; and saved again as it is.
    TUID attaccaID {};
    for (int32 i = 0; i < factory->countClasses (); ++i)
    {
        PClassInfo info;
        if (factory->getClassInfo (i, &info) == kResultOk && std::strcmp (info.category, kVstAudioEffectClass) == 0)
            std::memcpy (attaccaID, info.cid, sizeof (TUID));
    }
    Vst::IComponent* component = nullptr;
    check (factory->createInstance (attaccaID, Vst::IComponent::iid, reinterpret_cast<void**> (&component)) == kResultOk && component, "an instance made");
    component->initialize (nullptr);
    const std::string kept = attacca::stateOf ("cap-kept");
    auto* given = new MemoryStream (const_cast<char*> (kept.data ()), static_cast<TSize> (kept.size ()));
    check (component->setState (given) == kResultOk, "its state given back");
    given->release ();
    auto link = curator.next ("link", 5);
    check (link["capturer"] == "cap-kept", "Curator told the Capturer linked");
    auto* saved = new MemoryStream ();
    check (component->getState (saved) == kResultOk && std::string (saved->getData (), static_cast<size_t> (saved->getSize ())) == kept, "and saved as it is");
    saved->release ();
    component->terminate ();
    component->release ();
    factory->release ();
    CFRelease (bundle);
}

// Registered in this process alone (nothing is installed), made, given its host's transport and
// bound to a document of its own ARA factory as playback renderer: it must play the region as the
// VST3 does.
void checkAudioUnit (const char* path, const ARADocumentControllerHostInstance& hostInstance)
{
    std::printf ("The Audio Unit plays it too\n");
    CFURLRef url = CFURLCreateFromFileSystemRepresentation (nullptr, reinterpret_cast<const UInt8*> (path), static_cast<CFIndex> (std::strlen (path)), true);
    CFBundleRef bundle = CFBundleCreate (nullptr, url);
    CFRelease (url);
    if (!bundle || !CFBundleLoadExecutable (bundle))
        fail (std::string ("can't load ") + path);
    auto factoryFunction = reinterpret_cast<AudioComponentFactoryFunction> (CFBundleGetFunctionPointerForName (bundle, CFSTR ("AttaccaFactory")));
    check (factoryFunction != nullptr, "the component exports AttaccaFactory");
    const AudioComponentDescription description { kAudioUnitType_Effect, 'Atca', 'Crtr', 0, 0 };
    AudioComponent component = AudioComponentRegister (&description, CFSTR ("Curator: Attacca (test)"), 1, factoryFunction);
    AudioComponentInstance unit = nullptr;
    check (component && AudioComponentInstanceNew (component, &unit) == noErr, "an instance made");

    ARAAudioUnitFactory araFactory { kARAAudioUnitMagic, nullptr };
    UInt32 size = sizeof araFactory;
    check (AudioUnitGetProperty (unit, kAudioUnitProperty_ARAFactory, kAudioUnitScope_Global, 0, &araFactory, &size) == noErr && araFactory.outFactory &&
           std::strcmp (araFactory.outFactory->plugInName, "Attacca") == 0, "it gives the ARA factory");
    const ARAFactory* factory = araFactory.outFactory;
    const ARAInterfaceConfiguration config = { ARA_IMPLEMENTED_STRUCT_SIZE (ARAInterfaceConfiguration, assertFunctionAddress), kARAAPIGeneration_2_0_Final, nullptr };
    factory->initializeARAWithConfiguration (&config);

    const ARADocumentProperties documentProperties = { ARA_IMPLEMENTED_STRUCT_SIZE (ARADocumentProperties, name), "Song" };
    const auto* instance = factory->createDocumentControllerWithDocument (&hostInstance, &documentProperties);
    const auto controller = instance->documentControllerRef;
    const auto* dc = instance->documentControllerInterface;
    dc->beginEditing (controller);
    const ARAMusicalContextProperties contextProperties = { ARA_IMPLEMENTED_STRUCT_SIZE (ARAMusicalContextProperties, color), nullptr, 0, nullptr };
    const auto context = dc->createMusicalContext (controller, reinterpret_cast<ARAMusicalContextHostRef> (3), &contextProperties);
    const ARARegionSequenceProperties trackProperties = { ARA_IMPLEMENTED_STRUCT_SIZE (ARARegionSequenceProperties, color), "Track", 0, context, nullptr };
    const auto track = dc->createRegionSequence (controller, reinterpret_cast<ARARegionSequenceHostRef> (4), &trackProperties);
    const ARAAudioSourceProperties sourceProperties = { ARA_IMPLEMENTED_STRUCT_SIZE (ARAAudioSourceProperties, merits64BitSamples),
                                                        "Take", "take-au", sourceFrames, sourceRate, 1, kARAFalse, kARAChannelArrangementUndefined, nullptr };
    const auto source = dc->createAudioSource (controller, reinterpret_cast<ARAAudioSourceHostRef> (1), &sourceProperties);
    const ARAAudioModificationProperties modificationProperties = { ARA_IMPLEMENTED_STRUCT_SIZE (ARAAudioModificationProperties, persistentID), "Take", "take-au-edit" };
    const auto modification = dc->createAudioModification (controller, source, reinterpret_cast<ARAAudioModificationHostRef> (2), &modificationProperties);
    const ARAPlaybackRegionProperties regionProperties = { ARA_IMPLEMENTED_STRUCT_SIZE (ARAPlaybackRegionProperties, color), kARAPlaybackTransformationNoChanges,
                                                           0.5, 3.0, 1.0, 3.0, nullptr, track, "Take", nullptr };
    const auto region = dc->createPlaybackRegion (controller, modification, reinterpret_cast<ARAPlaybackRegionHostRef> (5), &regionProperties);
    dc->endEditing (controller);
    dc->enableAudioSourceSamplesAccess (controller, source, kARATrue);

    // Whether it is bound to ARA, for its window: not yet (as on an insert only), then bound.
    auto bound = [&] {
        UInt32 value = 2, length = sizeof value;
        return AudioUnitGetProperty (unit, 70001 /* audioUnitPropertyBoundToARA */, kAudioUnitScope_Global, 0, &value, &length) == noErr ? static_cast<int> (value) : -1;
    };
    check (bound () == 0, "unbound, it says so (an insert only)");
    ARAAudioUnitPlugInExtensionBinding binding { kARAAudioUnitMagic, controller, nullptr, kARAPlaybackRendererRole, kARAPlaybackRendererRole };
    size = sizeof binding;
    check (AudioUnitGetProperty (unit, kAudioUnitProperty_ARAPlugInExtensionBindingWithRoles, kAudioUnitScope_Global, 0, &binding, &size) == noErr &&
           binding.outPlugInExtension && binding.outPlugInExtension->playbackRendererInterface, "bound as playback renderer");
    check (bound () == 1, "and says it is bound");
    binding.outPlugInExtension->playbackRendererInterface->addPlaybackRegion (binding.outPlugInExtension->playbackRendererRef, region);

    HostCallbackInfo callbacks {};
    callbacks.beatAndTempoProc = &beatAndTempo;
    callbacks.transportStateProc2 = &transportState;
    AudioUnitSetProperty (unit, kAudioUnitProperty_HostCallbacks, kAudioUnitScope_Global, 0, &callbacks, sizeof callbacks);
    AudioStreamBasicDescription mono { sourceRate, kAudioFormatLinearPCM, static_cast<AudioFormatFlags> (kAudioFormatFlagsNativeFloatPacked) | kAudioFormatFlagIsNonInterleaved, 4, 1, 4, 1, 32, 0 };
    AudioUnitSetProperty (unit, kAudioUnitProperty_StreamFormat, kAudioUnitScope_Input, 0, &mono, sizeof mono);
    check (AudioUnitSetProperty (unit, kAudioUnitProperty_StreamFormat, kAudioUnitScope_Output, 0, &mono, sizeof mono) == noErr, "mono output at 44.1 kHz");
    constexpr UInt32 block = 512;
    AudioUnitSetProperty (unit, kAudioUnitProperty_MaximumFramesPerSlice, kAudioUnitScope_Global, 0, &block, sizeof block);
    check (AudioUnitInitialize (unit) == noErr, "initialized");

    AudioUnitCocoaViewInfo viewInfo {};
    size = sizeof viewInfo;
    check (AudioUnitGetProperty (unit, kAudioUnitProperty_CocoaUI, kAudioUnitScope_Global, 0, &viewInfo, &size) == noErr && viewInfo.mCocoaAUViewBundleLocation &&
           viewInfo.mCocoaAUViewClass[0], "it names its window's maker");
    {
        char name[128] {};
        CFStringGetCString (viewInfo.mCocoaAUViewClass[0], name, sizeof name, kCFStringEncodingUTF8);
        const id maker = reinterpret_cast<id (*) (id, SEL)> (objc_msgSend) (reinterpret_cast<id> (objc_getClass (name)), sel_registerName ("new"));
        check (maker != nullptr, "which is in the bundle");
        const id window = maker ? reinterpret_cast<id (*) (id, SEL, AudioUnit, CGSize)> (objc_msgSend) (maker, sel_registerName ("uiViewForAudioUnit:withSize:"), unit, CGSize { 0, 0 })
                                : nullptr;
        check (window != nullptr && subviewCount (window) == 1, "and makes it");
        if (maker)
            releaseObject (maker);
        CFRelease (viewInfo.mCocoaAUViewBundleLocation);
        CFRelease (viewInfo.mCocoaAUViewClass[0]);
    }
    // The samples are read on the plug-in's own thread once access is given: a moment.
    std::this_thread::sleep_for (std::chrono::milliseconds (500));

    std::vector<float> out (block);
    double worst = 0;
    bool silentBefore = true;
    for (int64_t at = 0; at < static_cast<int64_t> (2 * sourceRate); at += block)
    {
        sampleNow = static_cast<Float64> (at);
        AudioBufferList buffers;
        buffers.mNumberBuffers = 1;
        buffers.mBuffers[0] = { 1, block * 4, out.data () };
        AudioUnitRenderActionFlags flags = 0;
        AudioTimeStamp time {};
        time.mSampleTime = sampleNow;
        time.mFlags = kAudioTimeStampSampleTimeValid;
        if (AudioUnitRender (unit, &flags, &time, 0, block, &buffers) != noErr)
            fail ("the Audio Unit doesn't render");
        const float* rendered = static_cast<const float*> (buffers.mBuffers[0].mData);
        for (UInt32 i = 0; i < block; ++i)
        {
            const int64_t song = at + i;
            if (song < static_cast<int64_t> (sourceRate))
                silentBefore = silentBefore && rendered[i] == 0;
            else
                worst = std::max<double> (worst, std::fabs (rendered[i] - toneAt (song - static_cast<int64_t> (sourceRate) + static_cast<int64_t> (sourceRate / 2))));
        }
    }
    check (silentBefore, "silence before the region");
    check (worst < 1e-6, "the recording from 0.5 s, at 1 s in the song");

    AudioUnitUninitialize (unit);
    binding.outPlugInExtension->playbackRendererInterface->removePlaybackRegion (binding.outPlugInExtension->playbackRendererRef, region);
    AudioComponentInstanceDispose (unit);
    dc->enableAudioSourceSamplesAccess (controller, source, kARAFalse);
    dc->beginEditing (controller);
    dc->destroyPlaybackRegion (controller, region);
    dc->destroyAudioModification (controller, modification);
    dc->destroyAudioSource (controller, source);
    dc->destroyRegionSequence (controller, track);
    dc->destroyMusicalContext (controller, context);
    dc->endEditing (controller);
    dc->destroyDocumentController (controller);
    factory->uninitializeARA ();

    // Attacca Capturer as an Audio Unit: in the same bundle, made and set up, with a window.
    auto capturerFactory = reinterpret_cast<AudioComponentFactoryFunction> (CFBundleGetFunctionPointerForName (bundle, CFSTR ("AttaccaCapturerFactory")));
    check (capturerFactory != nullptr, "the component exports AttaccaCapturerFactory");
    const AudioComponentDescription capturerDescription { kAudioUnitType_Effect, 'Atcp', 'Crtr', 0, 0 };
    AudioComponent capturerComponent = AudioComponentRegister (&capturerDescription, CFSTR ("Curator: Attacca Capturer (test)"), 1, capturerFactory);
    AudioComponentInstance capturer = nullptr;
    check (capturerComponent && AudioComponentInstanceNew (capturerComponent, &capturer) == noErr && AudioUnitInitialize (capturer) == noErr, "Attacca Capturer made and set up");
    AudioUnitCocoaViewInfo view {};
    UInt32 viewSize = sizeof view;
    check (AudioUnitGetProperty (capturer, kAudioUnitProperty_CocoaUI, kAudioUnitScope_Global, 0, &view, &viewSize) == noErr && view.mCocoaAUViewClass[0], "with a window");
    if (view.mCocoaAUViewBundleLocation)
        CFRelease (view.mCocoaAUViewBundleLocation);
    if (view.mCocoaAUViewClass[0])
        CFRelease (view.mCocoaAUViewClass[0]);
    AudioUnitUninitialize (capturer);
    AudioComponentInstanceDispose (capturer);
}

}  // namespace

// Attacca Capturer (a VST3 of its own, so no DAW offers it as an ARA extension), as a DAW runs it
// on its output: its own connection to Curator; Attacca's own capture (Follow DAW…'s, by ARA)
// works beside it; asked to capture (Record from DAW…), with the document's Attacca asked to
// have the DAW play from a second before, what it hears is kept by song time however the span is
// played (here its end first); asked to stop, the DAW is asked to stop.
void checkCapturer (const char* path, Curator& curator, const std::string& document, const std::function<void ()>& idle)
{
    using namespace Steinberg;
    CFURLRef url = CFURLCreateFromFileSystemRepresentation (nullptr, reinterpret_cast<const UInt8*> (path), static_cast<CFIndex> (std::strlen (path)), true);
    CFBundleRef bundle = CFBundleCreate (nullptr, url);
    CFRelease (url);
    auto getFactory = bundle ? reinterpret_cast<IPluginFactory* (*) ()> (CFBundleGetFunctionPointerForName (bundle, CFSTR ("GetPluginFactory"))) : nullptr;
    IPluginFactory* factory = getFactory ? getFactory () : nullptr;
    check (factory != nullptr, "the VST3 gives its factory");
    TUID capturerID {};
    bool listed = false, ara = false;
    for (int32 i = 0; i < factory->countClasses (); ++i)
    {
        PClassInfo info;
        if (factory->getClassInfo (i, &info) != kResultOk)
            continue;
        ara = ara || std::strcmp (info.category, kARAMainFactoryClass) == 0;
        if (std::strcmp (info.category, kVstAudioEffectClass) == 0 && std::strcmp (info.name, "Attacca Capturer") == 0)
        {
            std::memcpy (capturerID, info.cid, sizeof (TUID));
            listed = true;
        }
    }
    check (listed && !ara, "Attacca Capturer in a bundle of its own, no ARA there");
    Vst::IComponent* component = nullptr;
    check (factory->createInstance (capturerID, Vst::IComponent::iid, reinterpret_cast<void**> (&component)) == kResultOk && component, "made");
    check (component->initialize (nullptr) == kResultOk, "initialized");
    Vst::IAudioProcessor* processor = nullptr;
    check (component->queryInterface (Vst::IAudioProcessor::iid, reinterpret_cast<void**> (&processor)) == kResultOk && processor, "an audio processor");
    constexpr double rate = 48000;
    constexpr int32 block = 480;
    Vst::ProcessSetup setup { Vst::kRealtime, Vst::kSample32, block, rate };
    check (processor->setupProcessing (setup) == kResultOk, "set up at 48 kHz");
    component->setActive (true);
    processor->setProcessing (true);

    // (Said again once the DAW has set it up: the last one says its rate.)
    std::string line;
    for (int i = 0; i < 3 && !contains (line, "\"rate\":48000"); ++i)
    {
        curator.next ("capturers", 5);
        line = curator.lines.back ();
    }
    const size_t capturerLine = curator.from;
    check (capturerLine != 0, "on a connection of its own");
    const std::string key = "\"list\":[{\"id\":\"";
    const size_t at = line.find (key);
    check (at != std::string::npos, "Curator is told of it");
    const std::string capturer = line.substr (at + key.size (), line.find ('"', at + key.size ()) - at - key.size ());
    check (contains (line, "\"channels\":2,\"rate\":48000"), "with its channels and rate");

    // Its ID kept in the DAW's project: saved, then given back (as the project opens again), it is
    // that one again, so the Attacca linked to it finds it.
    {
        auto* saved = new MemoryStream ();
        check (component->getState (saved) == kResultOk && std::string (saved->getData (), static_cast<size_t> (saved->getSize ())) == attacca::stateOf (capturer),
               "its ID saved in its state");
        saved->release ();
        const std::string kept = attacca::stateOf ("cap-saved");
        auto* given = new MemoryStream (const_cast<char*> (kept.data ()), static_cast<TSize> (kept.size ()));
        component->setState (given);
        given->release ();
        std::string again;
        for (int i = 0; i < 3 && !contains (again, "\"id\":\"cap-saved\""); ++i)
        {
            curator.next ("capturers", 5);
            again = curator.lines.back ();
        }
        check (contains (again, "\"id\":\"cap-saved\""), "given back, that one again");
    }
    const std::string savedCapturer = "cap-saved";

    curator.say ("{\"t\":\"export\",\"document\":\"" + document + "\",\"source\":\"take-1\"}");
    auto beside = curator.next ("exported", 10, idle);
    check (beside["error"].empty (), "Attacca's own capture works beside it");

    // Song 0.5 s for 1 s: frames 24000 to 72000; the input a ramp telling song samples apart.
    auto heard = [] (int64_t song, int c) { return static_cast<float> ((song % 9973) / 9973.0) * (c == 0 ? 1.0f : -1.0f); };
    clearPlaybackAsked ();
    curator.say ("{\"t\":\"capture\",\"document\":\"" + document + "\",\"capturer\":\"" + savedCapturer + "\",\"from\":0.5,\"length\":1,\"name\":\"Mix\"}", capturerLine);
    curator.say ("{\"t\":\"play\",\"document\":\"" + document + "\",\"at\":-0.5}");  // a second before, by Curator
    const auto started = waitForAsked (2, idle);
    check (started.size () >= 2 && started[0] == "at 0.000000" && started[1] == "start", "the DAW asked to play from a second before");

    std::vector<float> left (block), right (block), outLeft (block), outRight (block);
    float* ins[2] { left.data (), right.data () };
    float* outs[2] { outLeft.data (), outRight.data () };
    Vst::AudioBusBuffers in {}, out {};
    in.numChannels = out.numChannels = 2;
    in.channelBuffers32 = ins;
    out.channelBuffers32 = outs;
    Vst::ProcessContext context {};
    context.state = Vst::ProcessContext::kPlaying;
    context.sampleRate = rate;
    Vst::ProcessData data {};
    data.processMode = Vst::kRealtime;
    data.symbolicSampleSize = Vst::kSample32;
    data.numSamples = block;
    data.numInputs = data.numOutputs = 1;
    data.inputs = &in;
    data.outputs = &out;
    data.processContext = &context;
    bool through = true;
    auto play = [&] (int64_t from, int64_t to) {
        for (int64_t song = from; song < to; song += block)
        {
            for (int i = 0; i < block; ++i)
            {
                left[static_cast<size_t> (i)] = heard (song + i, 0);
                right[static_cast<size_t> (i)] = heard (song + i, 1);
            }
            context.projectTimeSamples = song;
            processor->process (data);
            through = through && outLeft == left && outRight == right;
            std::this_thread::sleep_for (std::chrono::microseconds (200));
        }
    };
    play (48000, 96000);  // the span's end first
    play (0, 48000);
    check (through, "what it hears passed through untouched");
    auto captured = curator.next ("captured", 10, idle);
    check (captured["error"].empty () && captured["capturer"] == savedCapturer, "captured without an error " + captured["error"]);
    const std::string file = captured["path"];
    check (contains (file, "/Library/Caches/Curator/DAW Link/Captures/") && contains (file, "/Mix.wav"), "into Curator's cache, by the name asked");
    {
        std::ifstream wav (file, std::ios::binary);
        std::vector<char> bytes ((std::istreambuf_iterator<char> (wav)), std::istreambuf_iterator<char> ());
        check (bytes.size () == 56 + static_cast<size_t> (48000) * 2 * 4, "a stereo float WAV as long as asked");
        bool same = true;
        for (int64_t k = 0; k < 48000; k += 7)
        {
            float l, r;
            std::memcpy (&l, bytes.data () + 56 + k * 8, 4);
            std::memcpy (&r, bytes.data () + 56 + k * 8 + 4, 4);
            same = same && l == heard (24000 + k, 0) && r == heard (24000 + k, 1);
        }
        check (same, "each frame where the song has it");
    }
    curator.say ("{\"t\":\"stop\",\"document\":\"" + document + "\"}");
    const auto stopped = waitForAsked (3, idle);
    check (stopped.size () == 3 && stopped.back () == "stop", "the DAW asked to stop once it is heard whole");

    // A recording's region the DAW plays (song 0.75 s to 1 s) of a file as long as the recording
    // (song 0.5 s for 1 s): done once the region was heard, the rest silence, the file lined up.
    curator.say ("{\"t\":\"capture\",\"document\":\"" + document + "\",\"capturer\":\"" + savedCapturer +
                 "\",\"from\":0.5,\"length\":1,\"start\":0.75,\"end\":1,\"name\":\"Region\"}", capturerLine);
    std::this_thread::sleep_for (std::chrono::milliseconds (300));  // (taken up on the Capturer's connection)
    play (36000, 48000);
    auto region = curator.next ("captured", 10, idle);
    check (region["error"].empty () && contains (region["path"], "/Region.wav"), "a region: done once it is heard " + region["error"]);
    {
        std::ifstream wav (region["path"], std::ios::binary);
        std::vector<char> bytes ((std::istreambuf_iterator<char> (wav)), std::istreambuf_iterator<char> ());
        bool right = bytes.size () == 56 + static_cast<size_t> (48000) * 2 * 4;
        for (int64_t k = 0; right && k < 48000; k += 7)
        {
            float l;
            std::memcpy (&l, bytes.data () + 56 + k * 8, 4);
            right = l == (k >= 12000 && k < 24000 ? heard (24000 + k, 0) : 0.0f);
        }
        check (right, "as long as the recording, silent outside the region");
    }

    processor->setProcessing (false);
    component->setActive (false);
    processor->release ();
    component->terminate ();
    component->release ();
    curator.next ("capturers", 5);
    check (contains (curator.lines.back (), "\"list\":[]"), "Curator is told it is gone");
    CFRelease (bundle);
}

int main (int argc, const char* argv[])
{
    if (argc != 4)
    {
        std::fprintf (stderr, "usage: link_host \"<path>/Attacca.vst3\" \"<path>/Attacca.component\" \"<path>/Attacca Capturer.vst3\"\n");
        return 2;
    }
    char homeTemplate[] = "/tmp/attacca-host.XXXXXX";
    const char* home = ::mkdtemp (homeTemplate);
    if (!home)
        fail ("no temporary folder");
    ::setenv ("HOME", home, 1);
    std::printf ("Attacca host test (home %s)\n", home);

    Curator curator;
    curator.listen (home);

    VST3Binary binary = VST3LoadBinary (argv[1]);
    if (!binary)
        fail (std::string ("can't load ") + argv[1]);
    const ARAFactory* factory = VST3GetARAFactory (binary, nullptr);
    check (factory != nullptr, "the VST3 gives an ARA factory");
    check (std::strcmp (factory->plugInName, "Attacca") == 0, "named Attacca");
    check (factory->lowestSupportedApiGeneration <= kARAAPIGeneration_2_0_Final && factory->highestSupportedApiGeneration >= kARAAPIGeneration_2_0_Final, "speaks ARA 2");

    const ARAInterfaceConfiguration config = { ARA_IMPLEMENTED_STRUCT_SIZE (ARAInterfaceConfiguration, assertFunctionAddress), kARAAPIGeneration_2_0_Final, nullptr };
    factory->initializeARAWithConfiguration (&config);

    // Attacca on an insert first, never bound to ARA (as a DAW has it before the extension).
    VST3Effect insert = VST3CreateEffect (binary, nullptr);
    VST3StartRendering (insert, 2, 512, sourceRate);

    const ARADocumentControllerHostInstance hostInstance = {
        ARA_IMPLEMENTED_STRUCT_SIZE (ARADocumentControllerHostInstance, playbackControllerInterface),
        reinterpret_cast<ARAAudioAccessControllerHostRef> (10), &audioAccess,
        reinterpret_cast<ARAArchivingControllerHostRef> (11), &archiving,
        reinterpret_cast<ARAContentAccessControllerHostRef> (12), &contentAccess,
        reinterpret_cast<ARAModelUpdateControllerHostRef> (13), &modelUpdates,
        reinterpret_cast<ARAPlaybackControllerHostRef> (14), &playbackControl };
    const ARADocumentProperties documentProperties = { ARA_IMPLEMENTED_STRUCT_SIZE (ARADocumentProperties, name), "Symphony" };
    const auto* instance = factory->createDocumentControllerWithDocument (&hostInstance, &documentProperties);
    const auto controller = instance->documentControllerRef;
    const auto* dc = instance->documentControllerInterface;

    const ARAColor strings { 1.0f, 0.5f, 0.0f };
    dc->beginEditing (controller);
    const ARAMusicalContextProperties contextProperties = { ARA_IMPLEMENTED_STRUCT_SIZE (ARAMusicalContextProperties, color), nullptr, 0, nullptr };
    const auto context = dc->createMusicalContext (controller, reinterpret_cast<ARAMusicalContextHostRef> (3), &contextProperties);
    const ARARegionSequenceProperties trackProperties = { ARA_IMPLEMENTED_STRUCT_SIZE (ARARegionSequenceProperties, color), "Strings", 0, context, &strings };
    const auto track = dc->createRegionSequence (controller, reinterpret_cast<ARARegionSequenceHostRef> (4), &trackProperties);
    const ARAAudioSourceProperties sourceProperties = { ARA_IMPLEMENTED_STRUCT_SIZE (ARAAudioSourceProperties, merits64BitSamples),
                                                        "Take 1", "take-1", sourceFrames, sourceRate, 1, kARAFalse, kARAChannelArrangementUndefined, nullptr };
    const auto source = dc->createAudioSource (controller, reinterpret_cast<ARAAudioSourceHostRef> (1), &sourceProperties);
    const ARAAudioModificationProperties modificationProperties = { ARA_IMPLEMENTED_STRUCT_SIZE (ARAAudioModificationProperties, persistentID), "Take 1", "take-1-edit" };
    const auto modification = dc->createAudioModification (controller, source, reinterpret_cast<ARAAudioModificationHostRef> (2), &modificationProperties);
    // The recording from 0.5 s in, at 1 s in the song, for 3 s.
    const ARAPlaybackRegionProperties regionProperties = { ARA_IMPLEMENTED_STRUCT_SIZE (ARAPlaybackRegionProperties, color), kARAPlaybackTransformationNoChanges,
                                                           0.5, 3.0, 1.0, 3.0, nullptr, track, "Take 1", nullptr };
    const auto region = dc->createPlaybackRegion (controller, modification, reinterpret_cast<ARAPlaybackRegionHostRef> (5), &regionProperties);
    dc->endEditing (controller);
    dc->enableAudioSourceSamplesAccess (controller, source, kARATrue);

    std::printf ("Curator is told of the document\n");
    auto hello = curator.next ("hello", 5);
    check (hello["token"] == "t0k3n", "it says the token back");
    check (hello["protocol"] == "1", "protocol 1");
    auto document = curator.next ("document", 5);
    const std::string id = document["id"];
    const std::string line = curator.lines.back ();  // a copy: more lines come
    check (document["name"] == "Symphony", "the document's name");
    check (contains (line, "\"tempo\":[[0,0],[2,4],[6,10]]"), "the tempo map, seconds and quarters");
    check (contains (line, "\"bars\":[[4,4,0],[3,4,8]]"), "the bar signatures");
    check (contains (line, "\"name\":\"C major\""), "the key signature");
    check (contains (line, "\"name\":\"Strings\"") && contains (line, "\"color\":\"#ff8000\""), "the track, by name and colour");
    check (contains (line, "{\"id\":\"take-1\",\"name\":\"Take 1\",\"rate\":44100,\"frames\":220500,\"channels\":1"), "the recording");
    check (contains (line, "\"source\":\"take-1\",\"start\":1,\"length\":3,\"from\":0.5,\"span\":3"), "the region placing it in the song");

    std::printf ("Curator's transport drives the DAW's\n");
    check (contains (line, "\"playback\":true"), "the DAW lets it (a playback controller)");
    clearPlaybackAsked ();
    curator.say ("{\"t\":\"seek\",\"document\":\"" + id + "\",\"at\":2.5}");
    curator.say ("{\"t\":\"play\",\"document\":\"" + id + "\",\"at\":1}");
    curator.say ("{\"t\":\"stop\",\"document\":\"" + id + "\"}");
    curator.say ("{\"t\":\"play\",\"document\":\"elsewhere\",\"at\":1}");
    const auto driven = waitForAsked (4, {});
    check (driven == std::vector<std::string> ({ "at 2.500000", "at 1.000000", "start", "stop" }), "moved, played from there and stopped, at once; another document's passed over");

    std::printf ("Curator asks for the recording\n");
    curator.say ("{\"t\":\"export\",\"document\":\"" + id + "\",\"source\":\"take-1\"}");
    auto exported = curator.next ("exported", 10, [&] { dc->notifyModelUpdates (controller); });
    check (exported["error"].empty (), "written without an error " + exported["error"]);
    const std::string path = exported["path"];
    check (contains (path, std::string (home) + "/Library/Caches/Curator/DAW Link/") && contains (path, "/Take 1.wav"), "into Curator's cache, by the recording's name");
    {
        std::ifstream wav (path, std::ios::binary);
        std::vector<char> bytes ((std::istreambuf_iterator<char> (wav)), std::istreambuf_iterator<char> ());
        check (bytes.size () == 56 + static_cast<size_t> (sourceFrames) * 4, "a float WAV of every frame");
        check (std::memcmp (bytes.data (), "RIFF", 4) == 0 && std::memcmp (bytes.data () + 8, "WAVE", 4) == 0, "RIFF WAVE");
        uint16_t format, channels;
        uint32_t rate;
        std::memcpy (&format, bytes.data () + 20, 2);
        std::memcpy (&channels, bytes.data () + 22, 2);
        std::memcpy (&rate, bytes.data () + 24, 4);
        check (format == 3 && channels == 1 && rate == 44100, "IEEE float, mono, 44.1 kHz");
        bool same = true;
        for (ARASamplePosition i = 0; i < sourceFrames; i += 997)
        {
            float v;
            std::memcpy (&v, bytes.data () + 56 + i * 4, 4);
            same = same && v == toneAt (i);
        }
        check (same, "the samples the host gave");
    }

    std::printf ("Curator asks for the track as a stem\n");
    const std::string tracksKey = "\"tracks\":[{\"id\":\"";
    const size_t idAt = line.find (tracksKey);
    check (idAt != std::string::npos, "the track has an ID");
    const size_t idStart = idAt + tracksKey.size ();
    const std::string trackID = line.substr (idStart, line.find ('"', idStart) - idStart);
    // From 0.5 s in the song for 2 s: silence until the region starts at 1 s, then the recording
    // from 0.5 s, so frame i is the recording's frame i.
    curator.say ("{\"t\":\"stem\",\"document\":\"" + id + "\",\"track\":\"" + trackID + "\",\"from\":0.5,\"length\":2}");
    auto stemmed = curator.next ("stemmed", 10, [&] { dc->notifyModelUpdates (controller); });
    check (stemmed["error"].empty () && stemmed["track"] == trackID, "written without an error " + stemmed["error"]);
    const std::string stemPath = stemmed["path"];
    check (contains (stemPath, std::string (home) + "/Library/Caches/Curator/DAW Link/Stems/") && contains (stemPath, "/Strings.wav"), "into Curator's cache, by the track's name");
    {
        std::ifstream wav (stemPath, std::ios::binary);
        std::vector<char> bytes ((std::istreambuf_iterator<char> (wav)), std::istreambuf_iterator<char> ());
        constexpr int64_t stemFrames = 2 * 44100;
        check (bytes.size () == 56 + static_cast<size_t> (stemFrames) * 4, "a float WAV as long as asked");
        bool silent = true;
        double worst = 0;
        for (int64_t i = 0; i < stemFrames; ++i)
        {
            float v;
            std::memcpy (&v, bytes.data () + 56 + i * 4, 4);
            if (i < 22050)
                silent = silent && v == 0;
            else
                worst = std::max<double> (worst, std::fabs (v - toneAt (i)));
        }
        check (silent, "silence before the region");
        check (worst < 1e-5, "the region where the song plays it");
    }

    std::printf ("Attacca Capturer captures the mix (Record from DAW…)\n");
    checkCapturer (argv[3], curator, id, [&] { dc->notifyModelUpdates (controller); });

    std::printf ("The region plays where the song has it\n");
    VST3Effect effect = VST3CreateEffect (binary, nullptr);
    const auto* plugIn = VST3BindToARADocumentController (effect, controller, kARAPlaybackRendererRole);
    check (plugIn && plugIn->playbackRendererInterface, "an instance bound as playback renderer");
    plugIn->playbackRendererInterface->addPlaybackRegion (plugIn->playbackRendererRef, region);
    constexpr int block = 512;
    VST3StartRendering (effect, 1, block, sourceRate);
    std::vector<float> out (block);
    float* buffers[1] { out.data () };
    double worst = 0;
    bool silentBefore = true;
    for (int64_t at = 0; at < static_cast<int64_t> (2 * sourceRate); at += block)
    {
        VST3RenderBuffer (effect, block, sourceRate, at, buffers);
        for (int i = 0; i < block; ++i)
        {
            const int64_t song = at + i;
            if (song < static_cast<int64_t> (sourceRate))
                silentBefore = silentBefore && out[static_cast<size_t> (i)] == 0;
            else
                worst = std::max<double> (worst, std::fabs (out[static_cast<size_t> (i)] - toneAt (song - static_cast<int64_t> (sourceRate) + static_cast<int64_t> (sourceRate / 2))));
        }
    }
    check (silentBefore, "silence before the region");
    check (worst < 1e-6, "the recording from 0.5 s, at 1 s in the song");
    auto transport = curator.next ("transport", 3);
    check (transport["playing"] == "true" && std::atof (transport["seconds"].c_str ()) >= 0, "the transport, playing");

    VST3StopRendering (effect);
    plugIn->playbackRendererInterface->removePlaybackRegion (plugIn->playbackRendererRef, region);
    VST3DestroyEffect (effect);

    std::printf ("The document closes\n");
    dc->enableAudioSourceSamplesAccess (controller, source, kARAFalse);
    dc->beginEditing (controller);
    dc->destroyPlaybackRegion (controller, region);
    dc->destroyAudioModification (controller, modification);
    dc->destroyAudioSource (controller, source);
    dc->destroyRegionSequence (controller, track);
    dc->destroyMusicalContext (controller, context);
    dc->endEditing (controller);
    dc->destroyDocumentController (controller);
    auto closed = curator.next ("closed", 5);
    check (closed["id"] == id, "Curator is told it is gone");

    factory->uninitializeARA ();
    std::printf ("The VST3's window\n");
    checkVst3View (argv[1], curator);
    VST3UnloadBinary (binary);

    checkAudioUnit (argv[2], hostInstance);

    std::string clean = std::string ("rm -rf '") + home + "'";
    std::system (clean.c_str ());
    std::printf ("Attacca host test passed\n");
    return 0;
}
