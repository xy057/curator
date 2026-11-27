// A DAW in miniature that checks Attacca as built:
// `link_host "<path>/Attacca.vst3" "<path>/Attacca Capturer.vst3"`, and on macOS
// "<path>/Attacca.component" after them.
//
// It stands in for both ends the plug-in talks to. As Curator, it listens where a discovery file
// in a home of its own says (HOME, on Windows LOCALAPPDATA, is pointed at a temporary folder, so
// the real Curator is never reached); as the DAW, it loads the VST3, makes an ARA document with a
// tempo map, bar and key signatures, a track and a recording placed in the song, and checks what
// Curator is told: the document, the recording written as a file when asked for, the region
// played back where the song has it, the transport, and the document closed. The Audio Unit
// (Logic's; macOS) is registered in this process only and checked for its ARA factory and its
// playback. Exits non-zero, saying why, on the first failure.
#include "../src/link_socket.h"

#if defined(__APPLE__)
#include "ARA_API/ARAAudioUnit.h"
#endif
#include "ARA_API/ARAInterface.h"
#include "ExamplesCommon/PlugInHosting/VST3Loader.h"

#if defined(__APPLE__)
#include <AudioToolbox/AudioToolbox.h>
#include <objc/message.h>
#include <objc/runtime.h>
#elif defined(_WIN32)
#include <windows.h>
#endif

#include "ARA_API/ARAVST3.h"

ARA_DISABLE_VST3_WARNINGS_BEGIN
#include "pluginterfaces/base/ipluginbase.h"
#include "pluginterfaces/gui/iplugview.h"
#include "pluginterfaces/gui/iplugviewcontentscalesupport.h"
#include "pluginterfaces/vst/ivstaudioprocessor.h"
#include "pluginterfaces/vst/ivstcomponent.h"
#include "pluginterfaces/vst/ivsteditcontroller.h"
#include "pluginterfaces/vst/ivstprocesscontext.h"
ARA_DISABLE_VST3_WARNINGS_END

#include "../src/json.h"
#include "../src/link_client.h"
#include "../src/link_files.h"
#include "public.sdk/source/common/memorystream.h"

#if !defined(_WIN32)
#include <sys/wait.h>
#include <unistd.h>
#endif

#include <algorithm>
#include <atomic>
#include <chrono>
#include <clocale>
#include <cmath>
#include <condition_variable>
#include <cstdio>
#include <cstdlib>
#include <cstring>
#include <filesystem>
#include <fstream>
#include <functional>
#include <map>
#include <mutex>
#include <new>
#include <string>
#include <thread>
#include <utility>
#include <vector>

using namespace ARA;
using attacca::fileOf;
using attacca::readFlatObject;
namespace net = attacca::net;

namespace {

constexpr double sourceRate = 44100;
constexpr ARASampleCount sourceFrames = 5 * 44100;
constexpr double toneHz = 441;

// The recording: a sine whose phase says where in it a sample is.
constexpr double pi = 3.14159265358979323846;
float toneAt (ARASamplePosition frame) { return static_cast<float> (0.5 * std::sin (2 * pi * toneHz * static_cast<double> (frame) / sourceRate)); }

// How this system writes a path, and where under the test's home (HOME; Windows: LOCALAPPDATA)
// Curator keeps its files and what can be made again (app/lib/app_folders.dart): where the
// plug-in must look for the one and write the other.
#if defined(_WIN32)
const std::string slash = "\\";
std::string dataUnder (const std::string& home) { return home + "\\Curator"; }
std::string cacheUnder (const std::string& home) { return home + "\\Curator\\Cache"; }
#else
const std::string slash = "/";
std::string dataUnder (const std::string& home) { return home + "/Library/Application Support/Curator"; }
std::string cacheUnder (const std::string& home) { return home + "/Library/Caches/Curator"; }
#endif

long thisProcess ()
{
#if defined(_WIN32)
    return static_cast<long> (::GetCurrentProcessId ());
#else
    return static_cast<long> (::getpid ());
#endif
}

// The number of a process that has ended: a child of this one, waited for.
long processGone ()
{
#if defined(_WIN32)
    wchar_t command[] = L"cmd.exe /c exit";
    STARTUPINFOW startup {};
    startup.cb = sizeof startup;
    PROCESS_INFORMATION made {};
    if (!::CreateProcessW (nullptr, command, nullptr, nullptr, FALSE, CREATE_NO_WINDOW, nullptr, nullptr, &startup, &made))
        return 0;
    ::WaitForSingleObject (made.hProcess, INFINITE);
    ::CloseHandle (made.hThread);
    ::CloseHandle (made.hProcess);
    return static_cast<long> (made.dwProcessId);
#else
    const pid_t gone = ::fork ();
    if (gone == 0)
        ::_exit (0);
    int ended = 0;
    ::waitpid (gone, &ended, 0);
    return static_cast<long> (gone);
#endif
}

// The program of the VST3 bundle at [bundle], as a DAW loads it: on macOS the bundle itself; on
// Windows the DLL in its folder for this processor.
std::string programOf (const std::string& bundle)
{
#if defined(_WIN32)
#if defined(__aarch64__) || defined(_M_ARM64)
    const char* processor = "arm64-win";
#else
    const char* processor = "x86_64-win";
#endif
    const size_t name = bundle.find_last_of ("\\/");
    return bundle + "\\Contents\\" + processor + "\\" + bundle.substr (name == std::string::npos ? 0 : name + 1);
#else
    return bundle;
#endif
}

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

// While it is there, [what] fails if it takes longer than [seconds], rather than hang (a deadlock).
class Watchdog {
public:
    Watchdog (double seconds, std::string what)
    : thread_ ([this, seconds, what = std::move (what)] {
          std::unique_lock<std::mutex> lock (mutex_);
          if (wake_.wait_for (lock, std::chrono::duration<double> (seconds), [this] { return done_; }))
              return;
          std::fprintf (stderr, "link_host: FAILED: %s (stuck for %g s)\n", what.c_str (), seconds);
          std::_Exit (1);
      })
    {
    }
    ~Watchdog ()
    {
        {
            std::lock_guard<std::mutex> lock (mutex_);
            done_ = true;
        }
        wake_.notify_all ();
        thread_.join ();
    }

private:
    std::mutex mutex_;
    std::condition_variable wake_;
    bool done_ { false };
    std::thread thread_;
};

// A locale whose decimal mark is a comma set for numbers (LC_NUMERIC), as a DAW may set the
// user's: its name, or null where this system has none (the C locale then set again).
const char* commaLocale ()
{
    for (const char* name : { "de_DE.UTF-8", "de_DE", "de-DE", "German_Germany.1252" })
    {
        if (std::setlocale (LC_NUMERIC, name) && std::localeconv ()->decimal_point[0] == ',')
            return name;
    }
    std::setlocale (LC_NUMERIC, "C");
    return nullptr;
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
// The thread the plug-in last asked the DAW to play on, and what the DAW does, once, inside that
// call (on its model thread, as ARA has it closing documents).
std::thread::id startedOn;
std::function<void ()> whileStarting;
void ARA_CALL startPlayback (ARAPlaybackControllerHostRef)
{
    ask ("start");
    std::function<void ()> then;
    {
        std::lock_guard<std::mutex> lock (playbackMutex);
        startedOn = std::this_thread::get_id ();
        then = std::exchange (whileStarting, nullptr);
    }
    if (then)
        then ();
}
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
    net::Socket listener { net::none };
    // A connection a bundle: Attacca's, and Attacca Capturer's (a VST3 of its own).
    std::vector<net::Socket> connections;
    std::vector<std::string> pending;
    // The connection the last message came on.
    size_t from { 0 };

    // Where the discovery file is, and the port it names.
    std::string discovery;
    int port { 0 };

    // The discovery file written as the Curator whose process is [process] would.
    void announce (long process)
    {
        std::ofstream (fileOf (discovery + ".part")) << "{\"port\":" << port << ",\"token\":\"t0k3n\",\"pid\":" << process << "}";
        std::filesystem::rename (fileOf (discovery + ".part"), fileOf (discovery));
    }

    // Whether something asks to connect within [seconds].
    bool knocked (double seconds) { return net::readable (listener, static_cast<int> (seconds * 1000)); }

    // Listens, the discovery file (in Curator's data folder under [home]) saying so as the
    // process [process].
    void listen (const std::string& home, long process)
    {
        net::begin ();
        listener = net::open ();
        port = listener >= 0 ? net::listen (listener) : 0;
        if (port == 0)
            fail ("can't listen on the loopback address");
        std::filesystem::create_directories (fileOf (dataUnder (home)));
        discovery = dataUnder (home) + slash + "daw-link.json";
        announce (process);
    }

    // The next message whose "t" is [type] (others are passed over), on any connection, within
    // [seconds]; [idle] runs while waiting, as a host's main thread would go on.
    std::map<std::string, std::string> next (const std::string& type, double seconds, const std::function<void ()>& idle = {})
    {
        const auto end = std::chrono::steady_clock::now () + std::chrono::duration<double> (seconds);
        while (std::chrono::steady_clock::now () < end)
        {
            if (net::readable (listener, 0))
            {
                connections.push_back (net::accept (listener));
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
                if (connections[c] >= 0 && net::readable (connections[c], 10))
                {
                    char buffer[65536];
                    const long long n = net::receive (connections[c], buffer, sizeof buffer);
                    if (n <= 0)
                    {
                        // A bundle whose last instance went lets go (what it sent is read first).
                        net::close (connections[c]);
                        connections[c] = net::none;
                    }
                    else
                    {
                        pending[c].append (buffer, static_cast<size_t> (n));
                    }
                }
            }
            if (connections.empty ())
                std::this_thread::sleep_for (std::chrono::milliseconds (20));
            if (idle)
                idle ();
        }
        fail ("no \"" + type + "\" message within " + std::to_string (seconds) + " s");
    }

    // Attacca's connection ended from here, as when Curator quits, and the one it then makes anew
    // taken as its first again (its hello read; what follows it waiting there).
    void drop ()
    {
        net::close (connections[0]);
        connections[0] = net::none;
        pending[0].clear ();
        next ("hello", 5);
        connections[0] = connections[from];
        pending[0] = std::move (pending[from]);
        connections.erase (connections.begin () + static_cast<std::ptrdiff_t> (from));
        pending.erase (pending.begin () + static_cast<std::ptrdiff_t> (from));
        from = 0;
    }

    // [line] said on connection [to] (the first: Attacca's).
    void say (const std::string& line, size_t to = 0)
    {
        const std::string data = line + "\n";
        if (to >= connections.size () || net::send (connections[to], data.data (), data.size ()) != static_cast<long long> (data.size ()))
            fail ("can't write to Attacca");
    }

    std::vector<std::string> lines;
};

bool contains (const std::string& text, const std::string& part) { return text.find (part) != std::string::npos; }

// MARK: The DAW's side of a VST3

// The VST3 bundle at [path] loaded as a DAW loads one, for its factory.
Steinberg::IPluginFactory* factoryOf (const char* path)
{
    using Factory = Steinberg::IPluginFactory* (PLUGIN_API*) ();
#if defined(_WIN32)
    const HMODULE library = ::LoadLibraryA (programOf (path).c_str ());
    if (auto start = library ? reinterpret_cast<bool (PLUGIN_API*) ()> (reinterpret_cast<void*> (::GetProcAddress (library, "InitDll"))) : nullptr)
        start ();
    auto getFactory = library ? reinterpret_cast<Factory> (reinterpret_cast<void*> (::GetProcAddress (library, "GetPluginFactory"))) : nullptr;
#else
    CFURLRef url = CFURLCreateFromFileSystemRepresentation (nullptr, reinterpret_cast<const UInt8*> (path), static_cast<CFIndex> (std::strlen (path)), true);
    CFBundleRef bundle = CFBundleCreate (nullptr, url);
    CFRelease (url);
    // (The bundle stays loaded: the factory is its code.)
    auto getFactory = bundle ? reinterpret_cast<Factory> (CFBundleGetFunctionPointerForName (bundle, CFSTR ("GetPluginFactory"))) : nullptr;
#endif
    return getFactory ? getFactory () : nullptr;
}

// The DAW's window a plug-in's view is put in (macOS: an NSView, made through the Objective-C
// runtime, this file being C++; Windows: a window never shown), how many views are in it, and
// the window let go.
#if defined(_WIN32)
const Steinberg::FIDString viewType = Steinberg::kPlatformTypeHWND;

void* newWindow ()
{
    return ::CreateWindowExW (0, L"STATIC", L"", WS_OVERLAPPED, 0, 0, 320, 124, nullptr, nullptr, ::GetModuleHandleW (nullptr), nullptr);
}

unsigned long viewsIn (void* window)
{
    unsigned long count = 0;
    for (HWND child = ::GetWindow (static_cast<HWND> (window), GW_CHILD); child; child = ::GetWindow (child, GW_HWNDNEXT))
        ++count;
    return count;
}

void releaseWindow (void* window) { ::DestroyWindow (static_cast<HWND> (window)); }
#else
const Steinberg::FIDString viewType = Steinberg::kPlatformTypeNSView;

void* newWindow ()
{
    return reinterpret_cast<id (*) (id, SEL)> (objc_msgSend) (reinterpret_cast<id> (objc_getClass ("NSView")), sel_registerName ("new"));
}

unsigned long viewsIn (void* window)
{
    const id subviews = reinterpret_cast<id (*) (id, SEL)> (objc_msgSend) (static_cast<id> (window), sel_registerName ("subviews"));
    return reinterpret_cast<unsigned long (*) (id, SEL)> (objc_msgSend) (subviews, sel_registerName ("count"));
}

void releaseWindow (void* window)
{
    reinterpret_cast<void (*) (id, SEL)> (objc_msgSend) (static_cast<id> (window), sel_registerName ("release"));
}
#endif

#if defined(__APPLE__)
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

#endif  // __APPLE__

// The VST3's window, as a DAW opens it: the controller's editor view, put in the DAW's window and taken out.
void checkVst3View (const char* path, Curator& curator)
{
    using namespace Steinberg;
    IPluginFactory* factory = factoryOf (path);
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
    check (view && view->isPlatformTypeSupported (viewType) == kResultTrue, "it has a window for this system");
    ViewRect rect;
    check (view->getSize (&rect) == kResultOk && rect.getWidth () > 0 && rect.getHeight () > 0, "the window has a size");
    void* parent = newWindow ();
    check (parent && view->attached (parent, viewType) == kResultOk && viewsIn (parent) == 1, "the window opens in the DAW's");
#if defined(_WIN32)
    // Windows: on a denser screen the DAW says how many pixels a point is, and the window is
    // that many times its size.
    {
        IPlugViewContentScaleSupport* scale = nullptr;
        ViewRect scaled;
        check (view->queryInterface (IPlugViewContentScaleSupport::iid, reinterpret_cast<void**> (&scale)) == kResultOk && scale &&
               scale->setContentScaleFactor (1.5f) == kResultTrue && view->getSize (&scaled) == kResultOk &&
               scaled.getWidth () == rect.getWidth () * 3 / 2 && scaled.getHeight () == rect.getHeight () * 3 / 2,
               "at 150 % it is half as big again");
        if (scale)
            scale->release ();
        check (view->onSize (&scaled) == kResultOk, "and takes the size the DAW gives it");
    }
#endif
    view->removed ();
    check (viewsIn (parent) == 0, "and closes");
    view->release ();
    releaseWindow (parent);
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
}

#if defined(__APPLE__)
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
        check (window != nullptr && viewsIn (window) == 1, "and makes it");
        if (maker)
            releaseWindow (maker);
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
#endif  // __APPLE__

}  // namespace

// Attacca Capturer (a VST3 of its own, so no DAW offers it as an ARA extension), as a DAW runs it
// on its output: its own connection to Curator; Attacca's own capture (Connect Attacca…'s, by ARA)
// works beside it; asked to capture (Record from DAW…), with the document's Attacca asked to
// have the DAW play from a second before, what it hears is kept by song time however the span is
// played (here its end first); asked to stop, the DAW is asked to stop.
void checkCapturer (const char* path, Curator& curator, const std::string& document, const std::string& cache, const std::function<void ()>& idle)
{
    using namespace Steinberg;
    IPluginFactory* factory = factoryOf (path);
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
    // The DAW playing (or stopped) song samples [from, to): [sound] at each, or what is to be heard.
    auto feed = [&] (int64_t from, int64_t to, bool playing, const std::function<float (int64_t, int)>& sound) {
        context.state = playing ? Vst::ProcessContext::kPlaying : 0;
        for (int64_t song = from; song < to; song += block)
        {
            for (int i = 0; i < block; ++i)
            {
                left[static_cast<size_t> (i)] = sound (song + i, 0);
                right[static_cast<size_t> (i)] = sound (song + i, 1);
            }
            context.projectTimeSamples = song;
            processor->process (data);
            through = through && outLeft == left && outRight == right;
            std::this_thread::sleep_for (std::chrono::microseconds (200));
        }
    };
    auto play = [&] (int64_t from, int64_t to) { feed (from, to, true, heard); };
    // Asked to capture: what the DAW played and still rings from before (loud, over the span) isn't
    // kept; once stopped and quiet a quarter of a second it is ready, and Curator has it play.
    auto settle = [&] {
        auto junk = [] (int64_t, int) { return 0.9f; };
        for (auto end = std::chrono::steady_clock::now () + std::chrono::milliseconds (400); std::chrono::steady_clock::now () < end;)
            feed (24000, 96000, true, junk);
        curator.say ("{\"t\":\"stop\",\"document\":\"" + document + "\"}");
        feed (0, 24000, false, junk);  // its tail, stopped
        feed (0, 24000, false, [] (int64_t, int) { return 0.00001f; });
        auto ready = curator.next ("ready", 5, idle);
        check (ready["capturer"] == savedCapturer && curator.from == capturerLine, "ready once the DAW stopped and fell quiet");
        curator.say ("{\"t\":\"play\",\"document\":\"" + document + "\",\"at\":-0.5}");  // a second before, by Curator
    };
    clearPlaybackAsked ();
    curator.say ("{\"t\":\"capture\",\"document\":\"" + document + "\",\"capturer\":\"" + savedCapturer + "\",\"from\":0.5,\"length\":1,\"name\":\"Mix\"}", capturerLine);
    settle ();
    const auto started = waitForAsked (3, idle);
    check (started.size () >= 3 && started[0] == "stop" && started[1] == "at 0.000000" && started[2] == "start", "the DAW stopped, then asked to play from a second before");
    play (48000, 96000);  // the span's end first
    play (0, 48000);
    check (through, "what it hears passed through untouched");
    auto captured = curator.next ("captured", 10, idle);
    check (captured["error"].empty () && captured["capturer"] == savedCapturer, "captured without an error " + captured["error"]);
    const std::string file = captured["path"];
    check (contains (file, cache + slash + "DAW Link" + slash + "Captures" + slash) && contains (file, slash + "Mix.wav"), "into Curator's cache, by the name asked");
    {
        std::ifstream wav (fileOf (file), std::ios::binary);
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
    const auto stopped = waitForAsked (4, idle);
    check (stopped.size () == 4 && stopped.back () == "stop", "the DAW asked to stop once it is heard whole");

    // A recording's region the DAW plays (song 0.75 s to 1 s) of a file as long as the recording
    // (song 0.5 s for 1 s): done once the region was heard, the rest silence, the file lined up.
    curator.say ("{\"t\":\"capture\",\"document\":\"" + document + "\",\"capturer\":\"" + savedCapturer +
                 "\",\"from\":0.5,\"length\":1,\"start\":0.75,\"end\":1,\"name\":\"Region\"}", capturerLine);
    settle ();
    play (36000, 48000);
    auto region = curator.next ("captured", 10, idle);
    check (region["error"].empty () && contains (region["path"], slash + "Region.wav"), "a region: done once it is heard " + region["error"]);
    {
        std::ifstream wav (fileOf (region["path"]), std::ios::binary);
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

    // A block with nothing coming in (the DAW's input switched off): silence out, not what the
    // output's buffers last held.
    {
        std::fill (outLeft.begin (), outLeft.end (), 0.5f);
        std::fill (outRight.begin (), outRight.end (), 0.5f);
        in.numChannels = 0;
        processor->process (data);
        in.numChannels = 2;
        const auto silent = [] (const std::vector<float>& v) { return std::all_of (v.begin (), v.end (), [] (float f) { return f == 0; }); };
        check (silent (outLeft) && silent (outRight), "nothing coming in: silence out");
    }

    // A capture under way when Curator's connection ends is let go (its file with it): no one
    // waits for it, and the Capturer would else say it captures until the DAW played the span.
    {
        curator.say ("{\"t\":\"capture\",\"document\":\"" + document + "\",\"capturer\":\"" + savedCapturer + "\",\"from\":0.5,\"length\":1,\"name\":\"Dropped\"}", capturerLine);
        const std::filesystem::path captures = fileOf (cache + slash + "DAW Link" + slash + "Captures");
        auto partial = [&] {
            std::error_code error;
            for (auto it = std::filesystem::recursive_directory_iterator (captures, error); !error && it != std::filesystem::recursive_directory_iterator (); it.increment (error))
            {
                if (it->path ().filename () == "Dropped.wav.part")
                    return true;
            }
            return false;
        };
        auto within = [&] (double seconds, const std::function<bool ()>& done) {
            for (auto end = std::chrono::steady_clock::now () + std::chrono::duration<double> (seconds); std::chrono::steady_clock::now () < end;)
            {
                if (done ())
                    return true;
                idle ();
                std::this_thread::sleep_for (std::chrono::milliseconds (20));
            }
            return done ();
        };
        check (within (3, partial), "a capture begun");
        net::close (curator.connections[capturerLine]);
        curator.connections[capturerLine] = net::none;
        check (within (3, [&] { return !partial (); }), "a capture let go as Curator's connection ends");
        curator.next ("capturers", 5, idle);  // connected again: its Capturers said anew
    }

    processor->setProcessing (false);
    component->setActive (false);
    processor->release ();
    component->terminate ();
    component->release ();
    curator.next ("capturers", 5);
    check (contains (curator.lines.back (), "\"list\":[]"), "Curator is told it is gone");
}

int main (int argc, const char* argv[])
{
#if defined(__APPLE__)
    constexpr int bundles = 3;
#else
    constexpr int bundles = 2;
#endif
    if (argc != 1 + bundles)
    {
        std::fprintf (stderr, "usage: link_host \"<path>/Attacca.vst3\" \"<path>/Attacca Capturer.vst3\"%s\n", bundles == 3 ? " \"<path>/Attacca.component\"" : "");
        return 2;
    }
    // A file's name from a recording's or a track's: marks no file may have left out, and cut to
    // 60 bytes between characters, never inside one.
    {
        std::string strings;
        for (int i = 0; i < 25; ++i)
            strings += "\xe5\xbc\xa6";  // 弦, three bytes
        const std::string named = attacca::safeName (strings);
        check (named.size () == 60 && named == strings.substr (0, 60), "a long name cut between characters");
        check (attacca::safeName ("../Take\xe5 1: \xe5\xbc\xa6/a") == "Take 1 \xe5\xbc\xa6" "a", "a name's marks and stray bytes left out");
#if defined(_WIN32)
        check (attacca::safeName ("con.txt") == "_con.txt" && attacca::safeName ("COM1") == "_COM1" && attacca::safeName ("com\xc2\xb9") == "_com\xc2\xb9" &&
                   attacca::safeName ("LPT\xc2\xb3.mix") == "_LPT\xc2\xb3.mix" && attacca::safeName ("COM10") == "COM10" && attacca::safeName ("CON2") == "CON2",
               "never a name Windows keeps for a device (COM1, COM\xc2\xb9)");
#endif
    }

    // A home of its own, where the plug-in looks for Curator's files: nothing of the real one is
    // read or written.
    std::error_code homeError;
    const std::filesystem::path homeFolder = std::filesystem::temp_directory_path (homeError) / ("attacca-host." + attacca::randomId ());
    if (homeError || !std::filesystem::create_directories (homeFolder, homeError))
        fail ("no temporary folder");
    const std::u8string homeText = homeFolder.u8string ();
    const std::string home (homeText.begin (), homeText.end ());
#if defined(_WIN32)
    ::SetEnvironmentVariableW (L"LOCALAPPDATA", homeFolder.c_str ());
#else
    ::setenv ("HOME", home.c_str (), 1);
#endif
    const std::string cache = cacheUnder (home);
    std::printf ("Attacca host test (home %s)\n", home.c_str ());

    // The discovery file first as one a Curator left behind: its process gone.
    const long gone = processGone ();
    check (gone > 0, "a process that has ended");
    Curator curator;
    curator.listen (home, gone);

    VST3Binary binary = VST3LoadBinary (programOf (argv[1]).c_str ());
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
    check (!curator.knocked (1.3), "a discovery file left by a Curator that is gone isn't followed");
    curator.announce (thisProcess ());

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
    check (LINK_VERSION > 0 && hello["build"] == std::to_string (LINK_VERSION), "its own version, the one it was built with");
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
    check (contains (line, "\"interfaces\":[\"audio\",\"archiving\",\"content\",\"updates\",\"playback\"]"), "the ARA interfaces the DAW gives: all of them");

    // A DAW that gives only what ARA requires of every host (no song, no word of changes, no
    // transport): its document says so, with no tempo map, and Curator tells by that.
    {
        const ARADocumentControllerHostInstance bareHost = {
            ARA_IMPLEMENTED_STRUCT_SIZE (ARADocumentControllerHostInstance, playbackControllerInterface),
            reinterpret_cast<ARAAudioAccessControllerHostRef> (10), &audioAccess,
            reinterpret_cast<ARAArchivingControllerHostRef> (11), &archiving,
            nullptr, nullptr, nullptr, nullptr, nullptr, nullptr };
        const ARADocumentProperties bareProperties = { ARA_IMPLEMENTED_STRUCT_SIZE (ARADocumentProperties, name), "Bare" };
        const auto* bare = factory->createDocumentControllerWithDocument (&bareHost, &bareProperties);
        const auto* bareInterface = bare->documentControllerInterface;
        bareInterface->beginEditing (bare->documentControllerRef);
        const auto bareContext = bareInterface->createMusicalContext (bare->documentControllerRef, reinterpret_cast<ARAMusicalContextHostRef> (6), &contextProperties);
        bareInterface->endEditing (bare->documentControllerRef);
        std::string said;
        for (int i = 0; i < 4 && !contains (said, "\"name\":\"Bare\""); ++i)
        {
            curator.next ("document", 5);
            said = curator.lines.back ();
        }
        check (contains (said, "\"name\":\"Bare\"") && contains (said, "\"playback\":false,\"interfaces\":[\"audio\",\"archiving\"]") && contains (said, "\"tempo\":[]"),
               "a DAW giving only what ARA requires: said, with no tempo map");
        bareInterface->beginEditing (bare->documentControllerRef);
        bareInterface->destroyMusicalContext (bare->documentControllerRef, bareContext);
        bareInterface->endEditing (bare->documentControllerRef);
        bareInterface->destroyDocumentController (bare->documentControllerRef);
        curator.next ("closed", 5);
    }

    // Its samples let be read after the edit ended (as DAWs do): told once the DAW asks for updates.
    check (contains (line, "\"access\":false"), "not readable yet as the edit ends");
    curator.next ("document", 5, [&] { dc->notifyModelUpdates (controller); });
    check (contains (curator.lines.back (), "\"access\":true"), "readable once the DAW lets it be read");

    std::printf ("Curator's transport drives the DAW's\n");
    check (contains (line, "\"playback\":true"), "the DAW lets it (a playback controller)");
    clearPlaybackAsked ();
    curator.say ("{\"t\":\"seek\",\"document\":\"" + id + "\",\"at\":2.5}");
    curator.say ("{\"t\":\"play\",\"document\":\"" + id + "\",\"at\":1}");
    curator.say ("{\"t\":\"stop\",\"document\":\"" + id + "\"}");
    curator.say ("{\"t\":\"play\",\"document\":\"elsewhere\",\"at\":1}");
    const auto driven = waitForAsked (4, [&] { dc->notifyModelUpdates (controller); });
    check (driven == std::vector<std::string> ({ "at 2.500000", "at 1.000000", "start", "stop" }) && startedOn == std::this_thread::get_id (),
           "moved, played from there and stopped, as the DAW asks for updates, on its own thread; another document's passed over");

    // Under a locale whose decimal mark is a comma (as a DAW may set): numbers read and written as
    // JSON has them all the same.
    if (const char* comma = commaLocale ())
    {
        clearPlaybackAsked ();
        curator.say ("{\"t\":\"seek\",\"document\":\"" + id + "\",\"at\":2.5}");
        const auto seeked = waitForAsked (1, [&] { dc->notifyModelUpdates (controller); });
        const std::vector<std::string> sought { "at " + std::to_string (2.5) };  // as the DAW says it here
        attacca::JsonWriter written;
        written.array ().number (0.5).number (-1.25).number (3).endArray ();
        std::setlocale (LC_NUMERIC, "C");
        check (seeked == sought && written.text () == "[0.5,-1.25,3]", std::string ("under ") + comma + ", numbers read and written with a point");
    }
    else
    {
        std::printf ("  --  no locale with a decimal comma here: numbers under one not checked\n");
    }

    // A DAW that gives its song and transport but no word of changes (no model-update interface):
    // it asks for updates all the same, as ARA has every DAW do, and is asked then.
    {
        const ARADocumentControllerHostInstance quietHost = {
            ARA_IMPLEMENTED_STRUCT_SIZE (ARADocumentControllerHostInstance, playbackControllerInterface),
            reinterpret_cast<ARAAudioAccessControllerHostRef> (10), &audioAccess,
            reinterpret_cast<ARAArchivingControllerHostRef> (11), &archiving,
            reinterpret_cast<ARAContentAccessControllerHostRef> (12), &contentAccess,
            nullptr, nullptr,
            reinterpret_cast<ARAPlaybackControllerHostRef> (14), &playbackControl };
        const ARADocumentProperties quietProperties = { ARA_IMPLEMENTED_STRUCT_SIZE (ARADocumentProperties, name), "Quiet" };
        const auto* quiet = factory->createDocumentControllerWithDocument (&quietHost, &quietProperties);
        const auto* quietInterface = quiet->documentControllerInterface;
        quietInterface->beginEditing (quiet->documentControllerRef);
        quietInterface->endEditing (quiet->documentControllerRef);
        std::map<std::string, std::string> told;
        for (int i = 0; i < 4 && told["name"] != "Quiet"; ++i)
            told = curator.next ("document", 5);
        check (told["name"] == "Quiet", "a DAW giving no word of changes: its document said");
        clearPlaybackAsked ();
        curator.say ("{\"t\":\"play\",\"document\":\"" + told["id"] + "\",\"at\":3}");
        const auto quietAsked = waitForAsked (2, [&] { quietInterface->notifyModelUpdates (quiet->documentControllerRef); });
        check (quietAsked == std::vector<std::string> ({ "at 3.000000", "start" }), "and asked to play as it asks for updates");

        // A stop, then Curator's dragged (a seek every 60 ms) while the DAW is slow to ask for
        // updates: more seeks than are kept, all there before it asks. (Quiet's play after them,
        // once asked, says the link has passed every one of them on: it hands lines on in order.)
        clearPlaybackAsked ();
        curator.say ("{\"t\":\"stop\",\"document\":\"" + id + "\"}");
        for (int i = 1; i <= 20; ++i)
            curator.say ("{\"t\":\"seek\",\"document\":\"" + id + "\",\"at\":" + std::to_string (i / 10.0) + "}");
        curator.say ("{\"t\":\"play\",\"document\":\"" + told["id"] + "\",\"at\":4}");
        for (int i = 0; i < 500 && playbackAsked ().size () < 2; ++i)
        {
            quietInterface->notifyModelUpdates (quiet->documentControllerRef);
            std::this_thread::sleep_for (std::chrono::milliseconds (10));
        }
        const auto passedOn = playbackAsked ();
        clearPlaybackAsked ();
        const auto dragged = waitForAsked (2, [&] { dc->notifyModelUpdates (controller); });
        check (passedOn == std::vector<std::string> ({ "at 4.000000", "start" }) && dragged == std::vector<std::string> ({ "stop", "at 2.000000" }),
               "a stop, then a long drag: stopped, then moved to where the drag ended");
        quietInterface->destroyDocumentController (quiet->documentControllerRef);
        curator.next ("closed", 5);
    }

    // Documents closed on the DAW's model thread (where ARA has it close them, and where the
    // plug-in asks it) with a play Curator asked of them pending: Same inside the DAW's call
    // asking for Symphony's, Kept after it, an instance keeping Attacca's side of it. Nothing
    // waits, neither is asked for what was pending, and Curator is told of both as they close.
    {
        auto open = [&] (const char* name) {
            const ARADocumentProperties properties = { ARA_IMPLEMENTED_STRUCT_SIZE (ARADocumentProperties, name), name };
            const auto* made = factory->createDocumentControllerWithDocument (&hostInstance, &properties);
            made->documentControllerInterface->beginEditing (made->documentControllerRef);
            made->documentControllerInterface->endEditing (made->documentControllerRef);
            std::map<std::string, std::string> told;
            for (int i = 0; i < 4 && told["name"] != name; ++i)
                told = curator.next ("document", 5);
            if (told["name"] != name)
                fail (std::string ("Curator isn't told of ") + name);
            return std::pair (made, told["id"]);
        };
        const auto [same, sameId] = open ("Same");
        const auto [kept, keptId] = open ("Kept");
        VST3Effect keeper = VST3CreateEffect (binary, nullptr);
        if (!VST3BindToARADocumentController (keeper, kept->documentControllerRef, kARAPlaybackRendererRole))
            fail ("an instance not bound to Kept");
        clearPlaybackAsked ();
        std::atomic<bool> closedInside { false };
        {
            std::lock_guard<std::mutex> lock (playbackMutex);
            whileStarting = [&, same = same] {
                same->documentControllerInterface->destroyDocumentController (same->documentControllerRef);
                closedInside = true;
            };
        }
        const Watchdog watchdog (10, "documents closed with a play asked of them pending");
        for (const std::string& document : { keptId, sameId })
            curator.say ("{\"t\":\"play\",\"document\":\"" + document + "\",\"at\":1}");
        curator.say ("{\"t\":\"play\",\"document\":\"" + id + "\",\"at\":2}");
        const auto asked = waitForAsked (2, [&] { dc->notifyModelUpdates (controller); });
        check (asked == std::vector<std::string> ({ "at 2.000000", "start" }) && startedOn == std::this_thread::get_id () && closedInside,
               "a document closed inside the DAW's call on its own thread, a play asked of it pending");
        kept->documentControllerInterface->destroyDocumentController (kept->documentControllerRef);
        auto first = curator.next ("closed", 5), second = curator.next ("closed", 5);
        check (first["id"] == sameId && second["id"] == keptId, "and one an instance keeps: Curator is told of each as it closes");
        for (int i = 0; i < 10; ++i)
        {
            dc->notifyModelUpdates (controller);
            std::this_thread::sleep_for (std::chrono::milliseconds (10));
        }
        check (playbackAsked () == asked, "neither asked for what was pending");
        VST3DestroyEffect (keeper);
    }

    // The line's handlers, on a line of the test's own (no plug-in's handler can be held up on
    // purpose): one let go of on another thread while its call is under way is waited for; one
    // let go of during a delivery, from inside another, isn't called for it; a handler may let go
    // of itself and send on the same line from inside; and one that throws (out of memory) ends
    // neither the DAW nor the delivery.
    {
        attacca::LinkClient& link = attacca::LinkClient::retain ();
        link.publish ("probe", "{\"t\":\"probe\"}");
        curator.next ("probe", 5);
        const size_t probeLine = curator.from;
        std::atomic<int> holder { 0 }, other { 0 }, late { 0 };
        std::atomic<bool> inside { false }, ended { false };
        auto holds = [] (const attacca::Message& m) { const std::string* t = attacca::fieldOf (m, "t"); return t && *t == "hold"; };
        const int thrower = link.listen ([&] (const attacca::Message& m) {
            if (holds (m))
                throw std::bad_alloc ();
        });
        holder = link.listen ([&] (const attacca::Message& m) {
            if (!holds (m))
                return;
            inside = true;
            link.unlisten (other);
            link.unlisten (holder);
            link.send ("{\"t\":\"held\"}");
            std::this_thread::sleep_for (std::chrono::milliseconds (300));
            ended = true;
        });
        other = link.listen ([&] (const attacca::Message& m) { late += holds (m) ? 1 : 0; });
        const Watchdog watchdog (10, "the line's handlers let go of during a call");
        curator.say ("{\"t\":\"hold\"}", probeLine);
        for (int i = 0; i < 500 && !inside; ++i)
            std::this_thread::sleep_for (std::chrono::milliseconds (10));
        link.unlisten (holder);
        link.unlisten (thrower);
        check (inside && ended && late == 0,
               "a handler let go of during its call is waited for; one let go of during a delivery isn't called; one before them that threw passed over");
        curator.next ("held", 5);
        check (curator.from == probeLine, "one sends on the same line from inside");
        attacca::LinkClient::release ();
    }

    std::printf ("Curator asks for the recording\n");
    curator.say ("{\"t\":\"export\",\"document\":\"" + id + "\",\"source\":\"take-1\"}");
    auto exported = curator.next ("exported", 10, [&] { dc->notifyModelUpdates (controller); });
    check (exported["error"].empty (), "written without an error " + exported["error"]);
    const std::string path = exported["path"];
    check (contains (path, cache + slash + "DAW Link" + slash) && contains (path, slash + "Take 1.wav"), "into Curator's cache, by the recording's name");
    {
        std::ifstream wav (fileOf (path), std::ios::binary);
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

        // Asked for again while Curator plays the first (it has the file open): a file by the
        // same name, whole. Windows lets nothing take an open file's place, so it is put in a
        // folder beside the first, which is left as it was.
        std::ifstream playing (fileOf (path), std::ios::binary);
        curator.say ("{\"t\":\"export\",\"document\":\"" + id + "\",\"source\":\"take-1\"}");
        auto again = curator.next ("exported", 10, [&] { dc->notifyModelUpdates (controller); });
        std::error_code sizeError;
        check (again["error"].empty () && contains (again["path"], slash + "Take 1.wav") &&
               std::filesystem::file_size (fileOf (again["path"]), sizeError) == bytes.size (), "asked for again while the first is open, written whole " + again["error"]);
#if defined(_WIN32)
        check (again["path"] != path && std::filesystem::file_size (fileOf (path), sizeError) == bytes.size (), "beside the one open, which is left alone");
#endif
    }

    // A recording the DAW says has no channels: none to read, so none to write.
    {
        dc->beginEditing (controller);
        const ARAAudioSourceProperties emptyProperties = { ARA_IMPLEMENTED_STRUCT_SIZE (ARAAudioSourceProperties, merits64BitSamples),
                                                           "Nothing", "nothing", sourceFrames, sourceRate, 0, kARAFalse, kARAChannelArrangementUndefined, nullptr };
        const auto empty = dc->createAudioSource (controller, reinterpret_cast<ARAAudioSourceHostRef> (7), &emptyProperties);
        dc->endEditing (controller);
        dc->enableAudioSourceSamplesAccess (controller, empty, kARATrue);
        curator.say ("{\"t\":\"export\",\"document\":\"" + id + "\",\"source\":\"nothing\"}");
        auto none = curator.next ("exported", 10, [&] { dc->notifyModelUpdates (controller); });
        check (none["error"] == "unreadable", "a recording of no channels: unreadable, nothing written " + none["path"]);
        dc->enableAudioSourceSamplesAccess (controller, empty, kARAFalse);
        dc->beginEditing (controller);
        dc->destroyAudioSource (controller, empty);
        dc->endEditing (controller);
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
    check (contains (stemPath, cache + slash + "DAW Link" + slash + "Stems" + slash) && contains (stemPath, slash + "Strings.wav"), "into Curator's cache, by the track's name");
    {
        std::ifstream wav (fileOf (stemPath), std::ios::binary);
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
    checkCapturer (argv[2], curator, id, cache, [&] { dc->notifyModelUpdates (controller); });

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

    std::printf ("Curator goes with what it asked of the DAW waiting\n");
    clearPlaybackAsked ();
    curator.say ("{\"t\":\"play\",\"document\":\"" + id + "\",\"at\":1}");
    curator.drop ();
    for (int i = 0; i < 10; ++i)
    {
        dc->notifyModelUpdates (controller);
        std::this_thread::sleep_for (std::chrono::milliseconds (10));
    }
    check (playbackAsked ().empty (), "the DAW isn't asked it once Curator is gone, nor when it is back");

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

#if defined(__APPLE__)
    checkAudioUnit (argv[3], hostInstance);
#endif

    std::filesystem::remove_all (homeFolder, homeError);
    std::printf ("Attacca host test passed\n");
    return 0;
}
