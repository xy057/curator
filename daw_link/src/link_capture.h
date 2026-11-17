// Attacca Capturer: an insert (on the DAW's output, in its last slot) that keeps what it hears
// by song time, for Curator. With Attacca on a track, Curator's recording is taken from here,
// as the mix sounds, and Attacca's own capture (a recording or a track written from the samples
// the DAW hands it) is off while a Capturer is in the DAW (see docs/daw-link.md).
#pragma once

#include "link_client.h"

#include <atomic>
#include <memory>
#include <mutex>
#include <string>

namespace attacca {

struct Capture;

class Capturer {
public:
    Capturer ();
    ~Capturer ();

    // What it is given to process, before it does (not on the audio thread).
    void prepare (double sampleRate, int channels);

    // On the audio thread, lock-free: [frames] frames of [channels] at song sample [songSample]
    // (the first heard), kept while a capture is under way and the DAW is [playing], once it
    // listens: after the DAW stopped and fell quiet (it says `ready`, and Curator has it play).
    void process (const float* const* in, int channels, int64_t frames, bool playing, int64_t songSample) noexcept;

    // Its ID: a new one, until the DAW gives back the one it had ([setId], from its saved state,
    // so the Attacca it was linked to finds it again).
    std::string id () const;
    void setId (const std::string& id);
    // Its name in Attacca's Capturer menu: the DAW's channel it is on ("Stereo Out"), if said.
    void setName (const std::string& name);

    // Whether one in this bundle is capturing now.
    static bool busy () noexcept;

private:
    void onMessage (const Message& message);
    // Curator asks: song time [from] for [length] seconds, for [document], as [name].wav; only
    // song time [played, playedEnd) is to be heard (what the DAW plays there: a recording's
    // region), the rest of the file silence.
    void start (const std::string& document, double from, double length, const std::string& name, double played, double playedEnd);
    // A capture under way ends (its file goes); one done is let go.
    void finish ();
    void publishAll ();

    std::string id_, name_;  // under the registry's lock
    LinkClient& client_;
    int listener_ { 0 };

    std::atomic<double> sampleRate_ { 44100 };
    std::atomic<int> channels_ { 2 };

    std::mutex mutex_;  // starting and finishing, never the audio thread
    std::unique_ptr<Capture> capture_;
    std::atomic<Capture*> live_ { nullptr };
    std::atomic<int> processing_ { 0 };
};

}  // namespace attacca
