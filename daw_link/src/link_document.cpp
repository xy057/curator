#include "link_document.h"

#include "json.h"
#include "link_client.h"
#include "link_config.h"

#include <algorithm>
#include <chrono>
#include <cctype>
#include <cmath>
#include <cstdio>
#include <cstring>
#include <functional>
#include <random>
#include <sys/stat.h>

namespace curator_link {

namespace {

// Longest recording held: three hours of stereo at 48 kHz (a little over 4 GB of samples).
constexpr int64_t maxSamples = int64_t { 3 } * 3600 * 48000 * 2;
constexpr int64_t chunkFrames = 32768;

std::string hexOf (const void* pointer)
{
    char buffer[24];
    std::snprintf (buffer, sizeof buffer, "%llx", static_cast<unsigned long long> (reinterpret_cast<uintptr_t> (pointer)));
    return buffer;
}

std::string randomId ()
{
    std::random_device device;
    char buffer[24];
    std::snprintf (buffer, sizeof buffer, "%08x%08x", device (), device ());
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

// A file name of [text]: letters, digits, spaces and a few marks; at most 60 bytes.
std::string safeName (const std::string& text)
{
    std::string out;
    for (unsigned char c : text)
    {
        if (std::isalnum (c) || c == ' ' || c == '-' || c == '_' || c == '.' || c >= 0x80)
            out += static_cast<char> (c);
        if (out.size () >= 60)
            break;
    }
    while (!out.empty () && (out.front () == '.' || out.front () == ' '))
        out.erase (out.begin ());
    return out.empty () ? std::string ("Recording") : out;
}

void makeFolders (const std::string& path)
{
    for (size_t i = 1; i <= path.size (); ++i)
    {
        if (i == path.size () || path[i] == '/')
            ::mkdir (path.substr (0, i).c_str (), 0755);
    }
}

void put16 (std::FILE* f, uint16_t v) { const unsigned char b[2] { static_cast<unsigned char> (v), static_cast<unsigned char> (v >> 8) }; std::fwrite (b, 1, 2, f); }
void put32 (std::FILE* f, uint32_t v)
{
    const unsigned char b[4] { static_cast<unsigned char> (v), static_cast<unsigned char> (v >> 8), static_cast<unsigned char> (v >> 16), static_cast<unsigned char> (v >> 24) };
    std::fwrite (b, 1, 4, f);
}

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
    frames_ = getSampleCount ();
    samples_.clear ();
    if (channels <= 0 || frames_ <= 0)
        return;
    if (frames_ * channels > maxSamples)
    {
        problem_ = "too long";
        frames_ = 0;
        return;
    }
    try
    {
        samples_.assign (static_cast<size_t> (channels), std::vector<float> (static_cast<size_t> (frames_)));
    }
    catch (...)
    {
        samples_.clear ();
        frames_ = 0;
        problem_ = "out of memory";
        return;
    }
    // ARA lets a reader be made only in calls about this source (or in endEditing); it may be
    // used from any thread after that.
    hostReader_ = std::make_unique<ARA::PlugIn::HostAudioReader> (this);
    cancel_.store (false);
    reader_ = std::thread ([this, channels] {
        std::vector<void*> buffers (static_cast<size_t> (channels));
        for (int64_t at = 0; at < frames_ && !cancel_.load (); at += chunkFrames)
        {
            const int64_t n = std::min (chunkFrames, frames_ - at);
            for (int c = 0; c < channels; ++c)
                buffers[static_cast<size_t> (c)] = samples_[static_cast<size_t> (c)].data () + at;
            // The host clears the buffers when it can't read, and tells the user why.
            hostReader_->readAudioSamples (at, n, buffers.data ());
            read_.store (at + n, std::memory_order_release);
        }
    });
}

void LinkAudioSource::stopReading ()
{
    cancel_.store (true);
    if (reader_.joinable ())
        reader_.join ();
    hostReader_.reset ();
}

// MARK: - LinkPlaybackRenderer

void LinkPlaybackRenderer::enable (double sampleRate, int channels) noexcept
{
    sampleRate_ = sampleRate > 0 ? sampleRate : 44100;
    channels_ = channels;
}

void LinkPlaybackRenderer::render (float* const* out, int64_t songSample, int64_t frames, bool playing) noexcept
{
    for (int c = 0; c < channels_; ++c)
        std::memset (out[c], 0, sizeof (float) * static_cast<size_t> (frames));
    if (!playing || channels_ <= 0)
        return;

    auto* controller = getDocumentController<LinkDocumentController> ();
    if (!controller->rendererWillAccessModel ())
        return;
    for (const auto* region : getPlaybackRegions ())
    {
        const auto* modification = region->getAudioModification ();
        const auto* source = modification->getAudioSource<const LinkAudioSource> ();
        const int64_t available = source->framesRead ();
        const int sourceChannels = source->channels ();
        if (available <= 0 || sourceChannels <= 0)
            continue;

        const double rate = source->getSampleRate ();
        // Song time to the source's: where the region starts in each, and the region's ends.
        const double regionStart = region->getStartInPlaybackTime ();
        const double regionEnd = region->getEndInPlaybackTime ();
        const double offset = region->getStartInAudioModificationTime () - regionStart;
        const double sourceStart = std::max (0.0, region->getStartInAudioModificationTime ());
        const double sourceEnd = region->getEndInAudioModificationTime ();

        for (int64_t i = 0; i < frames; ++i)
        {
            const double song = static_cast<double> (songSample + i) / sampleRate_;
            if (song < regionStart || song >= regionEnd)
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
            if (sourceChannels == channels_)
            {
                for (int c = 0; c < channels_; ++c)
                    out[c][i] += sample (c);
            }
            else
            {
                // Another layout: the source's channels averaged, the same in each output channel.
                float mono = 0;
                for (int c = 0; c < sourceChannels; ++c)
                    mono += sample (c);
                mono /= static_cast<float> (sourceChannels);
                for (int c = 0; c < channels_; ++c)
                    out[c][i] += mono;
            }
        }
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
    client_.unlisten (listener_);
    stopExport (nullptr);
    JsonWriter closed;
    closed.object ().field ("t", "closed").field ("id", id_).endObject ();
    client_.retract (id_, closed.text ());
    LinkClient::release ();
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

void LinkDocumentController::willNotifyModelUpdates () noexcept
{
    // The host calls this on its main thread every so often: a request Curator made since is
    // taken up here, where the model may be read.
    {
        std::lock_guard<std::mutex> lock (exportMutex_);
        if (exporting_.load () == nullptr && exporter_.joinable ())
            exporter_.join ();
    }
    startPendingExport ();
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
    // Curator Link keeps nothing in the DAW's project: all it knows, the DAW tells it again.
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

bool LinkDocumentController::rendererWillAccessModel () noexcept
{
    renderersAccessing_.fetch_add (1, std::memory_order_acquire);
    if (renderersMayAccess_.load (std::memory_order_acquire))
        return true;
    renderersAccessing_.fetch_sub (1, std::memory_order_release);
    return false;
}

void LinkDocumentController::rendererDidAccessModel () noexcept
{
    renderersAccessing_.fetch_sub (1, std::memory_order_release);
}

// Both on the host's main thread, and nested (samples made anew inside an edit).
void LinkDocumentController::lockOutRenderers () noexcept
{
    if (lockouts_++ > 0)
        return;
    renderersMayAccess_.store (false, std::memory_order_release);
    while (renderersAccessing_.load (std::memory_order_acquire) > 0)
        std::this_thread::yield ();
}

void LinkDocumentController::letRenderersIn () noexcept
{
    if (lockouts_ > 0 && --lockouts_ == 0)
        renderersMayAccess_.store (true, std::memory_order_release);
}

// MARK: Publishing

std::string LinkDocumentController::snapshot ()
{
    JsonWriter w;
    auto* document = getDocument ();
    w.object ().field ("t", "document").field ("id", id_);
    name (w, "name", document->getName ());

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
    std::string state = snapshot ();
    dirty_ = false;
    if (state == published_)
        return;
    published_ = state;
    client_.publish (id_, std::move (state));
}

// MARK: Recordings for Curator

void LinkDocumentController::onMessage (const Message& message)
{
    // On the connection's thread: only noted here, taken up on the host's main thread.
    auto t = message.find ("t");
    auto document = message.find ("document");
    auto source = message.find ("source");
    if (t == message.end () || t->second != "export" || document == message.end () || document->second != id_ || source == message.end ())
        return;
    std::lock_guard<std::mutex> lock (exportMutex_);
    pending_.push_back (source->second);
}

void LinkDocumentController::startPendingExport ()
{
    std::string sourceID;
    {
        std::lock_guard<std::mutex> lock (exportMutex_);
        if (exporter_.joinable () || pending_.empty ())
            return;
        sourceID = pending_.front ();
        pending_.erase (pending_.begin ());
    }

    auto reply = [this, sourceID] (const std::string& key, const std::string& value) {
        JsonWriter w;
        w.object ().field ("t", "exported").field ("document", id_).field ("source", sourceID).field (key.c_str (), value).endObject ();
        client_.send (w.text ());
    };

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

    const std::string folder = curatorCacheFolder () + "/DAW Link";
    makeFolders (folder);
    char hash[16];
    std::snprintf (hash, sizeof hash, "%08zx", std::hash<std::string> {} (sourceID) & 0xffffffffu);
    const char* sourceName = found->getName ();
    const std::string path = folder + "/" + safeName (sourceName ? sourceName : "") + " " + hash + ".wav";
    const double rate = found->getSampleRate ();

    std::lock_guard<std::mutex> lock (exportMutex_);
    cancelExport_.store (false);
    exporting_.store (found);
    exporter_ = std::thread ([this, found, path, rate, reply, sourceID] {
        // Written once every sample is read, into a file beside it, then put in place.
        while (found->framesRead () < found->frames () && !cancelExport_.load ())
            std::this_thread::sleep_for (std::chrono::milliseconds (50));
        const std::string partial = path + ".part";
        std::FILE* f = cancelExport_.load () ? nullptr : std::fopen (partial.c_str (), "wb");
        bool ok = f != nullptr;
        if (f)
        {
            const int channels = found->channels ();
            const int64_t frames = found->frames ();
            const uint64_t bytes = static_cast<uint64_t> (frames) * static_cast<uint64_t> (channels) * 4;
            // A RIFF file holds under 4 GB: the length is read as at most that.
            const uint32_t dataBytes = static_cast<uint32_t> (std::min<uint64_t> (bytes, 0xffffffffu - 64));
            const int64_t written = static_cast<int64_t> (dataBytes / (static_cast<uint32_t> (channels) * 4));
            std::fwrite ("RIFF", 1, 4, f);
            put32 (f, 4 + (8 + 16) + (8 + 4) + 8 + dataBytes);
            std::fwrite ("WAVE", 1, 4, f);
            std::fwrite ("fmt ", 1, 4, f);
            put32 (f, 16);
            put16 (f, 3);  // IEEE float
            put16 (f, static_cast<uint16_t> (channels));
            put32 (f, static_cast<uint32_t> (std::lround (rate)));
            put32 (f, static_cast<uint32_t> (std::lround (rate)) * static_cast<uint32_t> (channels) * 4);
            put16 (f, static_cast<uint16_t> (channels * 4));
            put16 (f, 32);
            std::fwrite ("fact", 1, 4, f);
            put32 (f, 4);
            put32 (f, static_cast<uint32_t> (written));
            std::fwrite ("data", 1, 4, f);
            put32 (f, dataBytes);

            std::vector<float> block (static_cast<size_t> (chunkFrames * channels));
            auto lastSaid = std::chrono::steady_clock::now ();
            for (int64_t at = 0; at < written && ok; at += chunkFrames)
            {
                if (cancelExport_.load ())
                {
                    ok = false;
                    break;
                }
                const int64_t n = std::min (chunkFrames, written - at);
                for (int64_t i = 0; i < n; ++i)
                    for (int c = 0; c < channels; ++c)
                        block[static_cast<size_t> (i * channels + c)] = found->channel (c)[at + i];
                ok = std::fwrite (block.data (), sizeof (float), static_cast<size_t> (n * channels), f) == static_cast<size_t> (n * channels);
                if (std::chrono::steady_clock::now () - lastSaid > std::chrono::milliseconds (100))
                {
                    lastSaid = std::chrono::steady_clock::now ();
                    JsonWriter progress;
                    progress.object ().field ("t", "progress").field ("document", id_).field ("source", sourceID)
                        .field ("done", static_cast<double> (at + n) / static_cast<double> (written)).endObject ();
                    client_.send (progress.text ());
                }
            }
            ok = std::fclose (f) == 0 && ok;
        }
        if (ok && std::rename (partial.c_str (), path.c_str ()) == 0)
        {
            reply ("path", path);
        }
        else
        {
            std::remove (partial.c_str ());
            reply ("error", cancelExport_.load () ? "cancelled" : "unwritable");
        }
        exporting_.store (nullptr);
    });
}

void LinkDocumentController::stopExport (const LinkAudioSource* source)
{
    std::lock_guard<std::mutex> lock (exportMutex_);
    if (!exporter_.joinable ())
        return;
    if (source && exporting_.load () != source && exporting_.load () != nullptr)
        return;
    cancelExport_.store (true);
    exporter_.join ();
}

// MARK: Factory

namespace {

class LinkFactoryConfig : public ARA::PlugIn::FactoryConfig {
public:
    const char* getFactoryID () const noexcept override { return LINK_FACTORY_ID; }
    const char* getPlugInName () const noexcept override { return LINK_NAME; }
    const char* getManufacturerName () const noexcept override { return LINK_VENDOR; }
    const char* getInformationURL () const noexcept override { return LINK_URL; }
    const char* getVersion () const noexcept override { return LINK_VERSION; }
    const char* getDocumentArchiveID () const noexcept override { return LINK_ARCHIVE_ID; }
};

}  // namespace

const ARA::ARAFactory* LinkDocumentController::getARAFactory () noexcept
{
    return ARA::PlugIn::PlugInEntry::getPlugInEntry<LinkFactoryConfig, LinkDocumentController> ()->getFactory ();
}

}  // namespace curator_link
