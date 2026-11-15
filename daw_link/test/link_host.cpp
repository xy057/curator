// A DAW in miniature that checks Curator Link as built:
// `link_host "<path>/Curator Link.vst3" "<path>/Curator Link.component"`.
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

#include "../src/json.h"

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
#include <string>
#include <thread>
#include <vector>

using namespace ARA;
using curator_link::readFlatObject;

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
    int connection { -1 };
    std::string pending;

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

    // The next message whose "t" is [type] (others are passed over), within [seconds]; [idle]
    // runs while waiting, as a host's main thread would go on.
    std::map<std::string, std::string> next (const std::string& type, double seconds, const std::function<void ()>& idle = {})
    {
        const auto end = std::chrono::steady_clock::now () + std::chrono::duration<double> (seconds);
        while (std::chrono::steady_clock::now () < end)
        {
            if (connection < 0)
            {
                pollfd p { listener, POLLIN, 0 };
                if (::poll (&p, 1, 20) > 0)
                    connection = ::accept (listener, nullptr, nullptr);
            }
            size_t at;
            while (connection >= 0 && (at = pending.find ('\n')) != std::string::npos)
            {
                const std::string line = pending.substr (0, at);
                pending.erase (0, at + 1);
                std::map<std::string, std::string> message;
                if (!readFlatObject (line, message))
                    fail ("a line that isn't a JSON object: " + line);
                lines.push_back (line);
                if (message["t"] == type)
                    return message;
            }
            if (connection >= 0)
            {
                pollfd p { connection, POLLIN, 0 };
                if (::poll (&p, 1, 20) > 0)
                {
                    char buffer[65536];
                    const ssize_t n = ::recv (connection, buffer, sizeof buffer, 0);
                    if (n <= 0)
                        fail ("Curator Link hung up");
                    pending.append (buffer, static_cast<size_t> (n));
                }
            }
            if (idle)
                idle ();
        }
        fail ("no \"" + type + "\" message within " + std::to_string (seconds) + " s");
    }

    void say (const std::string& line)
    {
        const std::string data = line + "\n";
        if (::send (connection, data.data (), data.size (), 0) != static_cast<ssize_t> (data.size ()))
            fail ("can't write to Curator Link");
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
    auto factoryFunction = reinterpret_cast<AudioComponentFactoryFunction> (CFBundleGetFunctionPointerForName (bundle, CFSTR ("CuratorLinkFactory")));
    check (factoryFunction != nullptr, "the component exports CuratorLinkFactory");
    const AudioComponentDescription description { kAudioUnitType_Effect, 'CrLk', 'Crtr', 0, 0 };
    AudioComponent component = AudioComponentRegister (&description, CFSTR ("Curator: Curator Link (test)"), 1, factoryFunction);
    AudioComponentInstance unit = nullptr;
    check (component && AudioComponentInstanceNew (component, &unit) == noErr, "an instance made");

    ARAAudioUnitFactory araFactory { kARAAudioUnitMagic, nullptr };
    UInt32 size = sizeof araFactory;
    check (AudioUnitGetProperty (unit, kAudioUnitProperty_ARAFactory, kAudioUnitScope_Global, 0, &araFactory, &size) == noErr && araFactory.outFactory &&
           std::strcmp (araFactory.outFactory->plugInName, "Curator Link") == 0, "it gives the ARA factory");
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

    ARAAudioUnitPlugInExtensionBinding binding { kARAAudioUnitMagic, controller, nullptr, kARAPlaybackRendererRole, kARAPlaybackRendererRole };
    size = sizeof binding;
    check (AudioUnitGetProperty (unit, kAudioUnitProperty_ARAPlugInExtensionBindingWithRoles, kAudioUnitScope_Global, 0, &binding, &size) == noErr &&
           binding.outPlugInExtension && binding.outPlugInExtension->playbackRendererInterface, "bound as playback renderer");
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
}

}  // namespace

int main (int argc, const char* argv[])
{
    if (argc != 3)
    {
        std::fprintf (stderr, "usage: link_host \"<path>/Curator Link.vst3\" \"<path>/Curator Link.component\"\n");
        return 2;
    }
    char homeTemplate[] = "/tmp/curator-link-host.XXXXXX";
    const char* home = ::mkdtemp (homeTemplate);
    if (!home)
        fail ("no temporary folder");
    ::setenv ("HOME", home, 1);
    std::printf ("Curator Link host test (home %s)\n", home);

    Curator curator;
    curator.listen (home);

    VST3Binary binary = VST3LoadBinary (argv[1]);
    if (!binary)
        fail (std::string ("can't load ") + argv[1]);
    const ARAFactory* factory = VST3GetARAFactory (binary, nullptr);
    check (factory != nullptr, "the VST3 gives an ARA factory");
    check (std::strcmp (factory->plugInName, "Curator Link") == 0, "named Curator Link");
    check (factory->lowestSupportedApiGeneration <= kARAAPIGeneration_2_0_Final && factory->highestSupportedApiGeneration >= kARAAPIGeneration_2_0_Final, "speaks ARA 2");

    const ARAInterfaceConfiguration config = { ARA_IMPLEMENTED_STRUCT_SIZE (ARAInterfaceConfiguration, assertFunctionAddress), kARAAPIGeneration_2_0_Final, nullptr };
    factory->initializeARAWithConfiguration (&config);

    const ARADocumentControllerHostInstance hostInstance = {
        ARA_IMPLEMENTED_STRUCT_SIZE (ARADocumentControllerHostInstance, playbackControllerInterface),
        reinterpret_cast<ARAAudioAccessControllerHostRef> (10), &audioAccess,
        reinterpret_cast<ARAArchivingControllerHostRef> (11), &archiving,
        reinterpret_cast<ARAContentAccessControllerHostRef> (12), &contentAccess,
        reinterpret_cast<ARAModelUpdateControllerHostRef> (13), &modelUpdates,
        nullptr, nullptr };
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
    const std::string& line = curator.lines.back ();
    check (document["name"] == "Symphony", "the document's name");
    check (contains (line, "\"tempo\":[[0,0],[2,4],[6,10]]"), "the tempo map, seconds and quarters");
    check (contains (line, "\"bars\":[[4,4,0],[3,4,8]]"), "the bar signatures");
    check (contains (line, "\"name\":\"C major\""), "the key signature");
    check (contains (line, "\"name\":\"Strings\"") && contains (line, "\"color\":\"#ff8000\""), "the track, by name and colour");
    check (contains (line, "{\"id\":\"take-1\",\"name\":\"Take 1\",\"rate\":44100,\"frames\":220500,\"channels\":1"), "the recording");
    check (contains (line, "\"source\":\"take-1\",\"start\":1,\"length\":3,\"from\":0.5,\"span\":3"), "the region placing it in the song");

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
    VST3UnloadBinary (binary);

    checkAudioUnit (argv[2], hostInstance);

    std::string clean = std::string ("rm -rf '") + home + "'";
    std::system (clean.c_str ());
    std::printf ("Curator Link host test passed\n");
    return 0;
}
