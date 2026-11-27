#include "link_document.h"
#include "link_files.h"

#include "json.h"
#include "link_client.h"
#include "link_config.h"

#include <algorithm>
#include <chrono>
#include <cctype>
#include <cmath>
#include <cstdio>
#include <cstring>
#include <fstream>
#include <functional>
#include <new>
#include <random>
#include <system_error>
#include <utility>

namespace attacca {

namespace {

// Longest recording held: three hours of stereo at 48 kHz (a little over 4 GB of samples).
constexpr int64_t maxSamples = int64_t { 3 } * 3600 * 48000 * 2;
constexpr int64_t chunkFrames = 32768;

// The most of Curator's asks of the transport kept until the DAW next asks for updates: the oldest
// go first. Seeks one after another (one every 60 ms while Curator's is dragged) are kept as the
// last, so it takes that many plays and stops to fill it.
constexpr size_t maxTransportAsks = 16;

std::string hexOf (const void* pointer)
{
    char buffer[24];
    std::snprintf (buffer, sizeof buffer, "%llx", static_cast<unsigned long long> (reinterpret_cast<uintptr_t> (pointer)));
    return buffer;
}

void color (JsonWriter& w, const char* key, const ARA::ARAColor* c)
{
    w.key (key);
    if (!c)
    {
        w.null ();
        return;
    }
    auto byte = [] (float v) { return static_cast<int> (std::lround (std::clamp (v, 0.0f, 1.0f) * 255)); };
    char buffer[8];
    std::snprintf (buffer, sizeof buffer, "#%02x%02x%02x", byte (c->r), byte (c->g), byte (c->b));
    w.string (buffer);
}

void name (JsonWriter& w, const char* key, const char* text)
{
    w.key (key);
    if (text)
        w.string (text);
    else
        w.null ();
}

// The frames [first, last) of a block of [frames] at [rate], its first frame at song sample
// [origin], that song time [from, to) can reach, with a frame to spare either side: no frame
// outside them plays any of it, so none needs a look. (One that isn't a number: the whole block.)
std::pair<int64_t, int64_t> framesWithin (double from, double to, double rate, double origin, int64_t frames)
{
    const double first = std::floor (from * rate - origin) - 1, last = std::ceil (to * rate - origin) + 1;
    const double n = static_cast<double> (frames);
    return { first > 0 ? static_cast<int64_t> (std::min (first, n)) : 0, last < n ? static_cast<int64_t> (std::max (last, 0.0)) : frames };
}

// A region as it plays its source: [start, end) of the song, [offset] from song time to the
// source's, over what the source holds of it ([sourceStart, sourceEnd)).
struct RegionPlay
{
    const LinkAudioSource* source;
    double start, end, offset, sourceStart, sourceEnd;

    static RegionPlay of (const ARA::PlugIn::PlaybackRegion* region) noexcept
    {
        return { region->getAudioModification ()->getAudioSource<const LinkAudioSource> (), region->getStartInPlaybackTime (),
                 region->getEndInPlaybackTime (), region->getStartInAudioModificationTime () - region->getStartInPlaybackTime (),
                 std::max (0.0, region->getStartInAudioModificationTime ()), region->getEndInAudioModificationTime () };
    }

    // The song's time between which it may be heard: within the region and the source.
    double from () const noexcept { return std::max (start, sourceStart - offset); }
    double to () const noexcept { return std::min (end, sourceEnd - offset); }

    // What it plays at frames [first, last) of a block, frame i at song time songAt (i), into
    // [channels]: add (i, c, value) for each. Its source's first [available] frames are heard,
    // at its own speed, resampled linearly; a source of another layout averaged into every
    // channel.
    template <typename SongAt, typename Add>
    void mix (int64_t available, int channels, int64_t first, int64_t last, SongAt songAt, Add add) const noexcept
    {
        const double rate = source->getSampleRate ();
        const int sourceChannels = source->channels ();
        for (int64_t i = first; i < last; ++i)
        {
            const double song = songAt (i);
            if (song < start || song >= end)
                continue;
            const double at = song + offset;
            if (at < sourceStart || at >= sourceEnd)
                continue;
            const double position = at * rate;
            const int64_t index = static_cast<int64_t> (position);
            if (index < 0 || index >= available)
                continue;
            const float fraction = static_cast<float> (position - static_cast<double> (index));
            const int64_t next = std::min (index + 1, available - 1);
            auto sample = [&] (int c) {
                const float* data = source->channel (c);
                return data[index] + (data[next] - data[index]) * fraction;
            };
            if (sourceChannels == channels)
            {
                for (int c = 0; c < channels; ++c)
                    add (i, c, sample (c));
            }
            else
            {
                float mono = 0;
                for (int c = 0; c < sourceChannels; ++c)
                    mono += sample (c);
                mono /= static_cast<float> (sourceChannels);
                for (int c = 0; c < channels; ++c)
                    add (i, c, mono);
            }
        }
    }
};

}  // namespace

// MARK: - LinkAudioSource

LinkAudioSource::~LinkAudioSource ()
{
    stopReading ();
}

void LinkAudioSource::startReading ()
{
    stopReading ();
    problem_.clear ();
    read_.store (0, std::memory_order_release);
    const int channels = static_cast<int> (getChannelCount ());
    samples_.clear ();
    // (With no channels, no frames: none to be read, played or written.)
    frames_ = channels > 0 ? getSampleCount () : 0;
    if (frames_ <= 0)
        return;
    if (frames_ * channels > maxSamples)
    {
        problem_ = "too long";
        frames_ = 0;
        return;
    }
    // Room for it, left as it comes: the DAW's main thread isn't held while gigabytes are
    // cleared, and memory is taken up only as far as the recording is read.
    for (int c = 0; c < channels; ++c)
    {
        std::unique_ptr<float[]> room (new (std::nothrow) float[static_cast<size_t> (frames_)]);
        if (!room)
        {
            samples_.clear ();
            frames_ = 0;
            problem_ = "out of memory";
            return;
        }
        samples_.push_back (std::move (room));
    }
    auto read = [this, channels] {
        std::vector<void*> buffers (static_cast<size_t> (channels));
        for (int64_t at = 0; at < frames_ && !cancel_.load (); at += chunkFrames)
        {
            const int64_t n = std::min (chunkFrames, frames_ - at);
            for (int c = 0; c < channels; ++c)
                buffers[static_cast<size_t> (c)] = samples_[static_cast<size_t> (c)].get () + at;
            // The host clears the buffers when it can't read, and tells the user why.
            hostReader_->readAudioSamples (at, n, buffers.data ());
            read_.store (at + n, std::memory_order_release);
        }
    };
    // ARA lets a reader be made only in calls about this source (or in endEditing); it may be
    // used from any thread after that.
    try
    {
        hostReader_ = std::make_unique<ARA::PlugIn::HostAudioReader> (this);
        cancel_.store (false);
        reader_ = std::thread (std::move (read));
    }
    catch (const std::exception&)
    {
        // No reader or thread to be had (the DAW goes on): the samples can't be either.
        hostReader_.reset ();
        samples_.clear ();
        frames_ = 0;
        problem_ = "out of memory";
    }
}

void LinkAudioSource::stopReading ()
{
    cancel_.store (true);
    if (reader_.joinable ())
        reader_.join ();
    hostReader_.reset ();
}

// MARK: - LinkPlaybackRenderer

void LinkPlaybackRenderer::render (float* const* out, int channels, double sampleRate, int64_t songSample, int64_t frames, bool playing) noexcept
{
    // (As many channels as the host gives buffers for this block, whatever it was set up with.)
    if (!out || channels <= 0 || frames <= 0)
        return;
    for (int c = 0; c < channels; ++c)
    {
        if (!out[c])
            return;
    }
    for (int c = 0; c < channels; ++c)
        std::memset (out[c], 0, sizeof (float) * static_cast<size_t> (frames));
    if (!playing)
        return;
    const double songRate = sampleRate > 0 ? sampleRate : 44100;

    auto* controller = getDocumentController<LinkDocumentController> ();
    if (!controller->rendererWillAccessModel ())
        return;
    for (const auto* region : getPlaybackRegions ())
    {
        const auto play = RegionPlay::of (region);
        const int64_t available = play.source->framesRead ();
        if (available <= 0 || play.source->channels () <= 0)
            continue;
        // Only the frames the region can reach: a track of many regions costs a block little.
        const auto [first, last] = framesWithin (play.from (), play.to (), songRate, static_cast<double> (songSample), frames);
        play.mix (
            available, channels, first, last, [&] (int64_t i) { return static_cast<double> (songSample + i) / songRate; },
            [out] (int64_t i, int c, float v) { out[c][i] += v; });
    }
    controller->rendererDidAccessModel ();
}

// MARK: - LinkDocumentController

LinkDocumentController::LinkDocumentController (const ARA::PlugIn::PlugInEntry* entry, const ARA::ARADocumentControllerHostInstance* instance) noexcept
: ARA::PlugIn::DocumentController (entry, instance),
  id_ (randomId ()),
  client_ (LinkClient::retain ())
{
    listener_ = client_.listen ([this] (const Message& m) { onMessage (m); });
}

LinkDocumentController::~LinkDocumentController ()
{
    // (Closed already: willDestroyDocument comes first, from the host's destroyDocumentController.)
    LinkClient::release ();
}

void LinkDocumentController::willDestroyDocument (ARA::PlugIn::Document*) noexcept
{
    // The host is done with the document (its interfaces are good only until now), though an
    // instance may keep this controller a while: Curator is told now and asks nothing more of
    // it, and what it asked that the DAW wasn't asked yet never is.
    client_.unlisten (listener_);
    {
        std::lock_guard<std::mutex> lock (transportMutex_);
        transport_.clear ();
    }
    stopExport (nullptr);
    JsonWriter closed;
    closed.object ().field ("t", "closed").field ("id", id_).endObject ();
    client_.retract (id_, closed.text ());
}

void LinkDocumentController::willBeginEditing () noexcept
{
    lockOutRenderers ();
}

void LinkDocumentController::didEndEditing () noexcept
{
    letRenderersIn ();
    // Content may be read now, from endEditing, for every object.
    publish ();
}

void LinkDocumentController::notifyModelUpdates () noexcept
{
    // A DAW that gives no word of changes still asks (ARA has every DAW ask, outside its edits),
    // but ARA's library takes it up only for one that does: what Curator asked (the transport, a
    // file) would else never be.
    if (!getHostModelUpdateController ())
        willNotifyModelUpdates ();
    ARA::PlugIn::DocumentController::notifyModelUpdates ();
}

void LinkDocumentController::willNotifyModelUpdates () noexcept
{
    // The host calls this on its main thread every so often: what Curator asked since is taken
    // up here, where the model may be read and the DAW asked.
    askTransport ();
    {
        std::lock_guard<std::mutex> lock (exportMutex_);
        if (!busy_.load () && exporter_.joinable ())
            exporter_.join ();
    }
    startPendingExport ();
    // What changed outside an edit (a recording's samples let be read, or no longer) is told here.
    if (dirty_ && lockouts_ == 0)
        publish ();
}

void LinkDocumentController::doUpdateMusicalContextContent (ARA::PlugIn::MusicalContext*, const ARA::ARAContentTimeRange*, ARA::ContentUpdateScopes) noexcept
{
    dirty_ = true;
}

void LinkDocumentController::doUpdateAudioSourceContent (ARA::PlugIn::AudioSource*, const ARA::ARAContentTimeRange*, ARA::ContentUpdateScopes) noexcept
{
    // The samples change only while they can't be read; they are read again when they can.
}

ARA::PlugIn::AudioSource* LinkDocumentController::doCreateAudioSource (ARA::PlugIn::Document* document, ARA::ARAAudioSourceHostRef hostRef) noexcept
{
    return new LinkAudioSource (document, hostRef);
}

void LinkDocumentController::willEnableAudioSourceSamplesAccess (ARA::PlugIn::AudioSource* source, bool enable) noexcept
{
    if (enable)
        return;
    auto* link = static_cast<LinkAudioSource*> (source);
    stopExport (link);
    link->stopReading ();
}

void LinkDocumentController::didEnableAudioSourceSamplesAccess (ARA::PlugIn::AudioSource* source, bool enable) noexcept
{
    // A DAW may do this outside an edit: Curator is told (`access`, `problem`) when the edit
    // ends, or else when the DAW next asks for model updates.
    dirty_ = true;
    if (!enable)
        return;
    auto* link = static_cast<LinkAudioSource*> (source);
    // The samples are made anew: no renderer may be reading them meanwhile.
    stopExport (link);
    lockOutRenderers ();
    link->startReading ();
    letRenderersIn ();
}

void LinkDocumentController::willDestroyAudioSource (ARA::PlugIn::AudioSource* source) noexcept
{
    auto* link = static_cast<LinkAudioSource*> (source);
    stopExport (link);
    link->stopReading ();
}

bool LinkDocumentController::doRestoreObjectsFromArchive (ARA::PlugIn::HostArchiveReader*, const ARA::PlugIn::RestoreObjectsFilter*) noexcept
{
    // Attacca keeps nothing in the DAW's project: all it knows, the DAW tells it again.
    return true;
}

bool LinkDocumentController::doStoreObjectsToArchive (ARA::PlugIn::HostArchiveWriter*, const ARA::PlugIn::StoreObjectsFilter*) noexcept
{
    return true;
}

ARA::PlugIn::PlaybackRenderer* LinkDocumentController::doCreatePlaybackRenderer () noexcept
{
    return new LinkPlaybackRenderer (this);
}

// A renderer says it is in, then looks whether it may be; the host's thread says it may not, then
// looks whether one is in. All four sequentially consistent: with anything weaker each could miss
// the other's word, and a renderer would read samples being made anew.
bool LinkDocumentController::rendererWillAccessModel () noexcept
{
    renderersAccessing_.fetch_add (1);
    if (renderersMayAccess_.load ())
        return true;
    renderersAccessing_.fetch_sub (1);
    return false;
}

void LinkDocumentController::rendererDidAccessModel () noexcept
{
    renderersAccessing_.fetch_sub (1);
}

// Both on the host's main thread, and nested (samples made anew inside an edit).
void LinkDocumentController::lockOutRenderers () noexcept
{
    if (lockouts_++ > 0)
        return;
    renderersMayAccess_.store (false);
    while (renderersAccessing_.load () > 0)
        std::this_thread::yield ();
}

void LinkDocumentController::letRenderersIn () noexcept
{
    if (lockouts_ > 0 && --lockouts_ == 0)
        renderersMayAccess_.store (true);
}

// MARK: Publishing

std::string LinkDocumentController::snapshot ()
{
    JsonWriter w;
    auto* document = getDocument ();
    w.object ().field ("t", "document").field ("id", id_);
    name (w, "name", document->getName ());
    // Whether the DAW lets Attacca drive its transport (Curator's then does, while following).
    w.field ("playback", getHostPlaybackController () != nullptr);
    // What the DAW gives Attacca of ARA's host interfaces: by these Curator tells whether the
    // DAW can do what it asks of it, never by the DAW's name. Samples ("audio") and the
    // project's archive every ARA host gives; the song ("content": tempo, bars, keys), word of
    // changes ("updates") and its transport ("playback") a host may leave out.
    w.key ("interfaces").array ();
    w.string ("audio").string ("archiving");
    if (getHostContentAccessController ())
        w.string ("content");
    if (getHostModelUpdateController ())
        w.string ("updates");
    if (getHostPlaybackController ())
        w.string ("playback");
    w.endArray ();

    w.key ("contexts").array ();
    for (const auto* context : document->getMusicalContexts ())
    {
        w.object ().field ("id", hexOf (context)).field ("order", static_cast<double> (context->getOrderIndex ()));
        name (w, "name", context->getName ());

        // The tempo map: pairs of seconds and quarters from the song's start, the tempo
        // constant between them (and before the first, after the last, as next to them).
        w.key ("tempo").array ();
        if (const ARA::PlugIn::HostContentReader<ARA::kARAContentTypeTempoEntries> tempo { context })
        {
            for (ARA::ARAInt32 i = 0; i < tempo.getEventCount (); ++i)
            {
                const auto e = tempo[i];
                w.array ().number (e.timePosition).number (e.quarterPosition).endArray ();
            }
        }
        w.endArray ();

        w.key ("bars").array ();
        if (const ARA::PlugIn::HostContentReader<ARA::kARAContentTypeBarSignatures> bars { context })
        {
            for (ARA::ARAInt32 i = 0; i < bars.getEventCount (); ++i)
            {
                const auto e = bars[i];
                w.array ().number (e.numerator).number (e.denominator).number (e.position).endArray ();
            }
        }
        w.endArray ();

        w.key ("keys").array ();
        if (const ARA::PlugIn::HostContentReader<ARA::kARAContentTypeKeySignatures> keys { context })
        {
            for (ARA::ARAInt32 i = 0; i < keys.getEventCount (); ++i)
            {
                const auto e = keys[i];
                w.object ().field ("root", static_cast<double> (e.root)).field ("at", e.position);
                name (w, "name", e.name);
                w.key ("intervals").array ();
                for (auto used : e.intervals)
                    w.number (used);
                w.endArray ().endObject ();
            }
        }
        w.endArray ();

        w.key ("chords").array ();
        if (const ARA::PlugIn::HostContentReader<ARA::kARAContentTypeSheetChords> chords { context })
        {
            for (ARA::ARAInt32 i = 0; i < chords.getEventCount (); ++i)
            {
                const auto e = chords[i];
                w.object ().field ("root", static_cast<double> (e.root)).field ("bass", static_cast<double> (e.bass)).field ("at", e.position);
                name (w, "name", e.name);
                w.endObject ();
            }
        }
        w.endArray ();
        w.endObject ();
    }
    w.endArray ();

    w.key ("tracks").array ();
    for (const auto* track : document->getRegionSequences ())
    {
        w.object ().field ("id", hexOf (track)).field ("order", static_cast<double> (track->getOrderIndex ()));
        name (w, "name", track->getName ());
        color (w, "color", track->getColor ());
        w.field ("context", hexOf (track->getMusicalContext ())).endObject ();
    }
    w.endArray ();

    w.key ("sources").array ();
    for (const auto* source : document->getAudioSources<LinkAudioSource> ())
    {
        w.object ().field ("id", source->getPersistentID ());
        name (w, "name", source->getName ());
        w.field ("rate", source->getSampleRate ())
            .field ("frames", static_cast<double> (source->getSampleCount ()))
            .field ("channels", static_cast<double> (source->getChannelCount ()))
            .field ("access", source->isSampleAccessEnabled ());
        if (!source->problem ().empty ())
            w.field ("problem", source->problem ());
        w.endObject ();
    }
    w.endArray ();

    w.key ("regions").array ();
    for (const auto* source : document->getAudioSources ())
    {
        for (const auto* modification : source->getAudioModifications ())
        {
            for (const auto* region : modification->getPlaybackRegions ())
            {
                w.object ().field ("id", hexOf (region));
                name (w, "name", region->getEffectiveName ());
                color (w, "color", region->getEffectiveColor ());
                // In ARA 2 every region is on a track, the track in a musical context.
                if (const auto* track = region->getRegionSequence ())
                    w.field ("track", hexOf (track)).field ("context", hexOf (track->getMusicalContext ()));
                w.field ("source", source->getPersistentID ())
                    .field ("start", region->getStartInPlaybackTime ())
                    .field ("length", region->getDurationInPlaybackTime ())
                    .field ("from", region->getStartInAudioModificationTime ())
                    .field ("span", region->getDurationInAudioModificationTime ())
                    .endObject ();
            }
        }
    }
    w.endArray ();

    w.endObject ();
    return w.text ();
}

void LinkDocumentController::publish ()
{
    dirty_ = false;
    client_.publish (id_, snapshot ());  // sent only when it differs from the last (LinkClient::publish)
}

// MARK: Files for Curator

namespace {

// Writes a 32-bit float WAV of [frames] frames of [channels] at [rate] to [path], through a file
// beside it put in place at the end ([putInPlace]: where it is then, usually [path]); [fill] gives
// [n] frames from frame [at], interleaved, and [progress] hears the share written. Empty when it
// can't be written or [cancel] is set.
std::string writeFloatWav (const std::string& path, int channels, double rate, int64_t frames, const std::atomic<bool>& cancel,
                    const std::function<void (float* block, int64_t at, int64_t n)>& fill, const std::function<void (double done)>& progress)
{
    const std::string partial = path + ".part";
    std::ofstream f;
    if (!cancel.load ())
        f.open (fileOf (partial), std::ios::binary | std::ios::trunc);
    bool ok = f.is_open ();
    if (ok)
    {
        const uint64_t bytes = static_cast<uint64_t> (frames) * static_cast<uint64_t> (channels) * 4;
        // A RIFF file holds under 4 GB: the length is read as at most that.
        const uint32_t dataBytes = static_cast<uint32_t> (std::min<uint64_t> (bytes, 0xffffffffu - 64));
        const int64_t written = static_cast<int64_t> (dataBytes / (static_cast<uint32_t> (channels) * 4));
        const std::string header = wavHeader (channels, rate, written);
        f.write (header.data (), static_cast<std::streamsize> (header.size ()));

        std::vector<float> block (static_cast<size_t> (chunkFrames * channels));
        auto lastSaid = std::chrono::steady_clock::now ();
        for (int64_t at = 0; at < written && ok; at += chunkFrames)
        {
            if (cancel.load ())
            {
                ok = false;
                break;
            }
            const int64_t n = std::min (chunkFrames, written - at);
            fill (block.data (), at, n);
            f.write (reinterpret_cast<const char*> (block.data ()), static_cast<std::streamsize> (sizeof (float) * static_cast<size_t> (n * channels)));
            ok = f.good ();
            if (std::chrono::steady_clock::now () - lastSaid > std::chrono::milliseconds (100))
            {
                lastSaid = std::chrono::steady_clock::now ();
                progress (static_cast<double> (at + n) / static_cast<double> (written));
            }
        }
        f.close ();
        ok = !f.fail () && ok;
    }
    if (const std::string put = ok ? putInPlace (partial, path) : std::string (); !put.empty ())
        return put;
    removeFile (partial);
    return {};
}

}  // namespace

void LinkDocumentController::onMessage (const Message& message)
{
    // On the connection's thread: only noted here, taken up on the host's main thread.
    auto field = [&] (const char* key) { return fieldOf (message, key); };
    const std::string* t = field ("t");
    // Curator gone: what it asked is no longer awaited (it failed it as `disconnected`), so the
    // DAW isn't asked it after all, and a file being written for it stops (the DAW's main thread
    // lets its writer go as it next asks for updates).
    if (t && *t == "disconnected")
    {
        {
            std::lock_guard<std::mutex> lock (transportMutex_);
            transport_.clear ();
        }
        std::lock_guard<std::mutex> lock (exportMutex_);
        pending_.clear ();
        cancelExport_.store (true);
        return;
    }
    const std::string* document = field ("document");
    if (!t || !document || *document != id_)
        return;
    // Curator's transport (following this DAW, or capturing the mix) driving the DAW's: asked of
    // the DAW on its model thread (askTransport), never from here.
    if (*t == "play" || *t == "stop" || *t == "seek")
    {
        const double at = numberOf (message, "at", NAN);
        // (A seek to nowhere asks nothing.)
        if (*t == "seek" && !std::isfinite (at))
            return;
        std::lock_guard<std::mutex> lock (transportMutex_);
        // A seek after a seek: only where the last goes matters, and a play or stop before them
        // is never pushed out by them.
        if (*t == "seek" && !transport_.empty () && transport_.back ().what == "seek")
        {
            transport_.back ().at = at;
            return;
        }
        if (transport_.size () >= maxTransportAsks)
            transport_.erase (transport_.begin ());
        transport_.push_back ({ *t, at });
        return;
    }
    ExportJob job;
    if (*t == "export" && field ("source"))
    {
        job.id = *field ("source");
    }
    else if (*t == "stem" && field ("track") && field ("from") && field ("length"))
    {
        job.stem = true;
        job.id = *field ("track");
        job.from = numberOf (message, "from", 0);
        job.length = numberOf (message, "length", 0);
        if (!std::isfinite (job.from) || !std::isfinite (job.length))
            return;
    }
    else
    {
        return;
    }
    std::lock_guard<std::mutex> lock (exportMutex_);
    pending_.push_back (job);
}

// What Curator asked of the transport since, asked of the DAW now, in the order it came. Here, on
// the DAW's model thread, not on the connection's: a DAW may have its main thread carry out what
// it is asked and wait for it, while closing a document there, which waits for any call of the
// document's handler under way (LinkClient::unlisten). Here the DAW does one, then the other,
// and is never asked for a document it has closed.
void LinkDocumentController::askTransport ()
{
    std::vector<TransportAsk> asked;
    {
        std::lock_guard<std::mutex> lock (transportMutex_);
        asked.swap (transport_);
    }
    auto* playback = getHostPlaybackController ();
    if (!playback)
        return;
    for (const auto& [what, at] : asked)
    {
        if (what != "stop" && std::isfinite (at))
            playback->requestSetPlaybackPosition (std::max (0.0, at));
        if (what == "play")
            playback->requestStartPlayback ();
        else if (what == "stop")
            playback->requestStopPlayback ();
    }
}

void LinkDocumentController::startPendingExport ()
{
    ExportJob job;
    {
        std::lock_guard<std::mutex> lock (exportMutex_);
        if (exporter_.joinable () || pending_.empty ())
            return;
        job = pending_.front ();
        pending_.erase (pending_.begin ());
    }
    if (job.stem)
        startStem (job);
    else
        startRecording (job.id);
}

void LinkDocumentController::startRecording (const std::string& sourceID)
{
    auto reply = [this, sourceID] (const char* key, const std::string& value) { client_.answer ("exported", id_, "source", sourceID, key, value); };

    LinkAudioSource* found = nullptr;
    for (auto* source : getDocument ()->getAudioSources<LinkAudioSource> ())
    {
        if (source->getPersistentID () == sourceID)
            found = source;
    }
    if (!found)
        return reply ("error", "gone");
    if (!found->problem ().empty ())
        return reply ("error", found->problem ());
    if (found->frames () <= 0 || !found->isSampleAccessEnabled ())
        return reply ("error", "unreadable");

    // A folder for each recording (by its ID), the file named as the DAW names the recording:
    // Curator calls the take it makes of it by the file's name.
    const std::string folder = nativePath (curatorCacheFolder () + "/DAW Link/" + hashOf (sourceID));
    makeFolders (folder);
    const char* sourceName = found->getName ();
    const std::string path = nativePath (folder + "/" + safeName (sourceName ? sourceName : "") + ".wav");

    auto write = [this, found, path, reply, sourceID] {
        // Written once every sample is read.
        while (found->framesRead () < found->frames () && !cancelExport_.load ())
            std::this_thread::sleep_for (std::chrono::milliseconds (50));
        const int channels = found->channels ();
        const std::string written = writeFloatWav (
            path, channels, found->getSampleRate (), found->frames (), cancelExport_,
            [found, channels] (float* block, int64_t at, int64_t n) {
                for (int64_t i = 0; i < n; ++i)
                    for (int c = 0; c < channels; ++c)
                        block[static_cast<size_t> (i * channels + c)] = found->channel (c)[at + i];
            },
            [this, sourceID] (double done) {
                client_.progress (id_, "source", sourceID, done);
            });
        if (!written.empty ())
            reply ("path", written);
        else
            reply ("error", cancelExport_.load () ? "cancelled" : "unwritable");
        busy_.store (false);
    };
    std::lock_guard<std::mutex> lock (exportMutex_);
    cancelExport_.store (false);
    using_ = { found };
    busy_.store (true);
    try
    {
        exporter_ = std::thread (std::move (write));
    }
    catch (const std::system_error&)
    {
        // No thread to be had for it (the DAW goes on).
        busy_.store (false);
        using_.clear ();
        reply ("error", "out of memory");
    }
}

void LinkDocumentController::startStem (const ExportJob& job)
{
    const std::string trackID = job.id;
    auto reply = [this, trackID] (const char* key, const std::string& value) { client_.answer ("stemmed", id_, "track", trackID, key, value); };

    const ARA::PlugIn::RegionSequence* track = nullptr;
    for (const auto* t : getDocument ()->getRegionSequences ())
    {
        if (hexOf (t) == trackID)
            track = t;
    }
    if (!track)
        return reply ("error", "gone");

    // What the track plays, copied out of the model: the thread writing it reads no more of it.
    std::vector<RegionPlay> pieces;
    std::vector<const LinkAudioSource*> sources;
    double rate = 0;
    int channels = 0;
    for (const auto* region : track->getPlaybackRegions ())
    {
        const auto* source = region->getAudioModification ()->getAudioSource<const LinkAudioSource> ();
        if (!source->problem ().empty ())
            return reply ("error", source->problem ());
        if (source->frames () <= 0 || !source->isSampleAccessEnabled ())
            return reply ("error", "unreadable");
        pieces.push_back (RegionPlay::of (region));
        if (std::find (sources.begin (), sources.end (), source) == sources.end ())
            sources.push_back (source);
        rate = std::max (rate, source->getSampleRate ());
        channels = std::max (channels, source->channels ());
    }
    if (pieces.empty ())
        return reply ("error", "empty");
    const int64_t frames = static_cast<int64_t> (std::llround (job.length * rate));
    if (frames <= 0)
        return reply ("error", "empty");
    if (frames * channels > maxSamples)
        return reply ("error", "too long");

    // A folder for each track of each document open, the file named as the DAW names the track.
    const std::string folder = nativePath (curatorCacheFolder () + "/DAW Link/Stems/" + hashOf (id_ + "/" + trackID));
    makeFolders (folder);
    const char* trackName = track->getName ();
    const std::string path = nativePath (folder + "/" + safeName (trackName && *trackName ? trackName : "Track") + ".wav");
    const double from = job.from;

    auto write = [this, pieces, sources, path, reply, trackID, rate, channels, frames, from] {
        for (const auto* source : sources)
        {
            while (source->framesRead () < source->frames () && !cancelExport_.load ())
                std::this_thread::sleep_for (std::chrono::milliseconds (50));
        }
        // As the song plays the track, from [from] on: each region at its source's own speed,
        // resampled linearly, a source of another layout averaged into every channel.
        const std::string written = writeFloatWav (
            path, channels, rate, frames, cancelExport_,
            [&pieces, rate, channels, from] (float* block, int64_t at, int64_t n) {
                std::fill (block, block + n * channels, 0.0f);
                for (const auto& p : pieces)
                {
                    const auto [first, last] = framesWithin (p.from (), p.to (), rate, from * rate + static_cast<double> (at), n);
                    p.mix (
                        p.source->frames (), channels, first, last, [&] (int64_t i) { return from + static_cast<double> (at + i) / rate; },
                        [block, channels] (int64_t i, int c, float v) { block[i * channels + c] += v; });
                }
            },
            [this, trackID] (double done) {
                client_.progress (id_, "track", trackID, done);
            });
        if (!written.empty ())
            reply ("path", written);
        else
            reply ("error", cancelExport_.load () ? "cancelled" : "unwritable");
        busy_.store (false);
    };
    std::lock_guard<std::mutex> lock (exportMutex_);
    cancelExport_.store (false);
    using_ = sources;
    busy_.store (true);
    try
    {
        exporter_ = std::thread (std::move (write));
    }
    catch (const std::system_error&)
    {
        // No thread to be had for it (the DAW goes on).
        busy_.store (false);
        using_.clear ();
        reply ("error", "out of memory");
    }
}

void LinkDocumentController::stopExport (const LinkAudioSource* source)
{
    std::lock_guard<std::mutex> lock (exportMutex_);
    if (!exporter_.joinable ())
        return;
    // Only a file made of [source] stops for it (one finished is let go either way).
    if (source && busy_.load () && std::find (using_.begin (), using_.end (), source) == using_.end ())
        return;
    cancelExport_.store (true);
    exporter_.join ();
    using_.clear ();
}

// MARK: Factory

namespace {

class LinkFactoryConfig : public ARA::PlugIn::FactoryConfig {
public:
    const char* getFactoryID () const noexcept override { return LINK_FACTORY_ID; }
    const char* getPlugInName () const noexcept override { return LINK_NAME; }
    const char* getManufacturerName () const noexcept override { return LINK_VENDOR; }
    const char* getInformationURL () const noexcept override { return LINK_URL; }
    const char* getVersion () const noexcept override { return LINK_VERSION_TEXT; }
    const char* getDocumentArchiveID () const noexcept override { return LINK_ARCHIVE_ID; }
};

}  // namespace

const ARA::ARAFactory* LinkDocumentController::getARAFactory () noexcept
{
    return ARA::PlugIn::PlugInEntry::getPlugInEntry<LinkFactoryConfig, LinkDocumentController> ()->getFactory ();
}

}  // namespace attacca
