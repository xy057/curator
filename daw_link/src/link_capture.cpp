#include "link_capture.h"

#include "json.h"
#include "link_files.h"

#include <fcntl.h>
#include <unistd.h>

#include <algorithm>
#include <chrono>
#include <cstdlib>
#include <thread>
#include <vector>

namespace attacca {

namespace {

// The Capturers in this process, and how many are capturing.
std::mutex registryMutex;
std::vector<Capturer*> registry;
std::atomic<int> capturing { 0 };

// The audio thread hands what it hears over in blocks of at most this many frames.
constexpr int64_t blockFrames = 512;

}  // namespace

// One capture: song samples [start, start + frames) of what the Capturer hears, as a float WAV
// written where each block belongs as it comes (the DAW may play the span in pieces, or twice),
// done once every frame has been heard. The audio thread puts blocks in a ring; a thread of
// its own writes them out.
struct Capture {
    std::string document, path;
    int channels { 2 };
    double rate { 44100 };
    int64_t start { 0 }, frames { 0 };
    int fd { -1 };

    struct Block {
        int64_t at { 0 }, n { 0 };
    };
    size_t slots { 0 };
    std::vector<Block> blocks;
    std::vector<float> samples;
    std::atomic<uint64_t> head { 0 }, tail { 0 };

    std::vector<uint64_t> heard;
    int64_t heardCount { 0 };
    std::atomic<bool> cancel { false };
    std::thread writer;

    // The audio thread's side: the part of [frames] at song sample [song] inside the span.
    void push (const float* const* in, int inChannels, int64_t count, int64_t song) noexcept
    {
        const int64_t first = std::max (song, start), last = std::min (song + count, start + frames);
        for (int64_t s = first; s < last;)
        {
            const int64_t n = std::min (blockFrames, last - s);
            const uint64_t h = head.load (std::memory_order_relaxed);
            if (h - tail.load (std::memory_order_acquire) >= slots)
                return;  // full: what isn't kept is heard again when the DAW plays it again
            const size_t slot = static_cast<size_t> (h % slots);
            blocks[slot] = { s - start, n };
            float* out = samples.data () + slot * static_cast<size_t> (blockFrames * channels);
            const int64_t from = s - song;
            for (int64_t i = 0; i < n; ++i)
            {
                for (int c = 0; c < channels; ++c)
                {
                    // A channel the insert hasn't: its last one again (mono into stereo).
                    const int source = inChannels > 0 ? std::min (c, inChannels - 1) : -1;
                    out[i * channels + c] = source < 0 || !in[source] ? 0.0f : in[source][from + i];
                }
            }
            head.store (h + 1, std::memory_order_release);
            s += n;
        }
    }

    // Marks frames [at, at + n) heard.
    void hear (int64_t at, int64_t n)
    {
        for (int64_t i = at; i < at + n; ++i)
        {
            uint64_t& word = heard[static_cast<size_t> (i >> 6)];
            const uint64_t bit = uint64_t { 1 } << (i & 63);
            if (!(word & bit))
            {
                word |= bit;
                ++heardCount;
            }
        }
    }
};

Capturer::Capturer () : id_ (randomId ()), client_ (LinkClient::retain ())
{
    {
        std::lock_guard<std::mutex> lock (registryMutex);
        registry.push_back (this);
    }
    listener_ = client_.listen ([this] (const Message& m) { onMessage (m); });
    publishAll ();
}

Capturer::~Capturer ()
{
    client_.unlisten (listener_);
    finish ();
    {
        std::lock_guard<std::mutex> lock (registryMutex);
        registry.erase (std::remove (registry.begin (), registry.end (), this), registry.end ());
    }
    publishAll ();
    LinkClient::release ();
}

bool Capturer::busy () noexcept { return capturing.load () > 0; }

void Capturer::prepare (double sampleRate, int channels)
{
    if (sampleRate > 0)
        sampleRate_.store (sampleRate);
    if (channels > 0)
        channels_.store (std::min (channels, 64));
    publishAll ();
}

void Capturer::publishAll ()
{
    // Every Capturer of the process in one message, whichever publishes it.
    JsonWriter w;
    w.object ().field ("t", "capturers").key ("list").array ();
    {
        std::lock_guard<std::mutex> lock (registryMutex);
        for (const auto* c : registry)
            w.object ().field ("id", c->id_).field ("channels", static_cast<double> (c->channels_.load ())).field ("rate", c->sampleRate_.load ()).endObject ();
    }
    w.endArray ().endObject ();
    client_.publish ("capturers", w.text ());
}

void Capturer::process (const float* const* in, int channels, int64_t frames, bool playing, int64_t songSample) noexcept
{
    processing_.fetch_add (1, std::memory_order_acquire);
    if (Capture* capture = live_.load (std::memory_order_acquire); capture && playing && frames > 0)
        capture->push (in, channels, frames, songSample);
    processing_.fetch_sub (1, std::memory_order_release);
}

void Capturer::onMessage (const Message& message)
{
    auto field = [&] (const char* key) -> const std::string* {
        auto found = message.find (key);
        return found == message.end () ? nullptr : &found->second;
    };
    const std::string *t = field ("t"), *capturer = field ("capturer"), *document = field ("document");
    if (!t || !capturer || *capturer != id_ || !document)
        return;
    if (*t == "capture" && field ("from") && field ("length"))
    {
        const double from = std::strtod (field ("from")->c_str (), nullptr), length = std::strtod (field ("length")->c_str (), nullptr);
        if (std::isfinite (from) && std::isfinite (length))
            start (*document, from, length, field ("name") ? *field ("name") : std::string ());
    }
    else if (*t == "cancel")
    {
        finish ();
    }
}

void Capturer::start (const std::string& document, double from, double length, const std::string& name)
{
    std::lock_guard<std::mutex> lock (mutex_);
    auto reply = [this, document] (const std::string& key, const std::string& value) {
        JsonWriter w;
        w.object ().field ("t", "captured").field ("document", document).field ("capturer", id_).field (key.c_str (), value).endObject ();
        client_.send (w.text ());
    };

    // One at a time: one under way ends first.
    if (capture_)
    {
        capture_->cancel.store (true);
        if (capture_->writer.joinable ())
            capture_->writer.join ();
        capture_.reset ();
    }

    auto capture = std::make_unique<Capture> ();
    capture->document = document;
    capture->channels = channels_.load ();
    capture->rate = sampleRate_.load ();
    capture->start = std::llround (from * capture->rate);
    capture->frames = std::llround (length * capture->rate);
    if (capture->frames <= 0)
        return reply ("error", "empty");
    // A RIFF file holds under 4 GB.
    if (capture->frames * capture->channels * 4 > int64_t { 0xffffffff } - 64)
        return reply ("error", "too long");

    const std::string folder = curatorCacheFolder () + "/DAW Link/Captures/" + hashOf (document + "/" + std::to_string (capture->start));
    makeFolders (folder);
    capture->path = folder + "/" + safeName (name.empty () ? "Mix" : name) + ".wav";
    const std::string partial = capture->path + ".part";
    capture->fd = ::open (partial.c_str (), O_CREAT | O_TRUNC | O_RDWR, 0644);
    const std::string header = wavHeader (capture->channels, capture->rate, capture->frames);
    if (capture->fd < 0 || ::write (capture->fd, header.data (), header.size ()) != static_cast<ssize_t> (header.size ()) ||
        ::ftruncate (capture->fd, wavHeaderBytes + capture->frames * capture->channels * 4) != 0)
    {
        if (capture->fd >= 0)
            ::close (capture->fd);
        std::remove (partial.c_str ());
        return reply ("error", "unwritable");
    }

    // Four seconds of blocks between the audio thread and the file; before song time 0, heard
    // already (silence: no DAW plays there).
    capture->slots = static_cast<size_t> (std::max<int64_t> (64, std::llround (capture->rate * 4) / blockFrames));
    capture->blocks.resize (capture->slots);
    capture->samples.resize (capture->slots * static_cast<size_t> (blockFrames * capture->channels));
    capture->heard.assign (static_cast<size_t> ((capture->frames + 63) / 64), 0);
    if (capture->start < 0)
        capture->hear (0, std::min (capture->frames, -capture->start));

    Capture* c = capture.get ();
    capturing.fetch_add (1);
    live_.store (c, std::memory_order_release);
    c->writer = std::thread ([this, c, reply, partial] {
        bool ok = true;
        auto said = std::chrono::steady_clock::now ();
        while (!c->cancel.load () && ok && c->heardCount < c->frames)
        {
            const uint64_t t = c->tail.load (std::memory_order_relaxed);
            if (t == c->head.load (std::memory_order_acquire))
            {
                std::this_thread::sleep_for (std::chrono::milliseconds (5));
            }
            else
            {
                const size_t slot = static_cast<size_t> (t % c->slots);
                const auto block = c->blocks[slot];
                const float* data = c->samples.data () + slot * static_cast<size_t> (blockFrames * c->channels);
                const size_t bytes = static_cast<size_t> (block.n * c->channels) * sizeof (float);
                ok = ::pwrite (c->fd, data, bytes, wavHeaderBytes + block.at * c->channels * 4) == static_cast<ssize_t> (bytes);
                c->hear (block.at, block.n);
                c->tail.store (t + 1, std::memory_order_release);
            }
            if (std::chrono::steady_clock::now () - said > std::chrono::milliseconds (100))
            {
                said = std::chrono::steady_clock::now ();
                JsonWriter progress;
                progress.object ()
                    .field ("t", "progress")
                    .field ("document", c->document)
                    .field ("capturer", id_)
                    .field ("done", static_cast<double> (c->heardCount) / static_cast<double> (c->frames))
                    .endObject ();
                client_.send (progress.text ());
            }
        }
        // The audio thread lets go of it before it goes.
        live_.store (nullptr, std::memory_order_release);
        while (processing_.load (std::memory_order_acquire) != 0)
            std::this_thread::sleep_for (std::chrono::milliseconds (1));
        ok = ::close (c->fd) == 0 && ok;
        c->fd = -1;
        const bool whole = ok && c->heardCount >= c->frames;
        if (whole && std::rename (partial.c_str (), c->path.c_str ()) == 0)
        {
            reply ("path", c->path);
        }
        else
        {
            std::remove (partial.c_str ());
            reply ("error", c->cancel.load () ? "cancelled" : "unwritable");
        }
        capturing.fetch_sub (1);
    });
    capture_ = std::move (capture);
}

void Capturer::finish ()
{
    std::unique_ptr<Capture> capture;
    {
        std::lock_guard<std::mutex> lock (mutex_);
        capture = std::move (capture_);
    }
    if (!capture)
        return;
    capture->cancel.store (true);
    if (capture->writer.joinable ())
        capture->writer.join ();
}

}  // namespace attacca
