// Attacca's ARA side: a DAW document read for Curator, and its regions played back.
#pragma once

#include "ARA_Library/PlugIn/ARAPlug.h"

#include <atomic>
#include <cstdint>
#include <memory>
#include <mutex>
#include <string>
#include <thread>
#include <vector>

namespace attacca {

class LinkClient;

// A recording in the DAW: its samples read into memory once the host lets them be read, so
// its regions play from here (an ARA plug-in on a track plays the track's audio itself) and
// Curator can be given it as a file.
class LinkAudioSource : public ARA::PlugIn::AudioSource {
public:
    using ARA::PlugIn::AudioSource::AudioSource;
    ~LinkAudioSource () override;

    // Starts reading the samples on a thread of its own (the reader made here, as ARA asks).
    void startReading ();
    // Stops reading and lets the reader go (before the host takes sample access away).
    void stopReading ();

    // How many frames are read and may be played or written: below it, [channel] holds them.
    int64_t framesRead () const noexcept { return read_.load (std::memory_order_acquire); }
    const float* channel (int c) const noexcept { return samples_[static_cast<size_t> (c)].get (); }
    int channels () const noexcept { return static_cast<int> (samples_.size ()); }
    int64_t frames () const noexcept { return frames_; }
    // Why the samples can't be had (too long to hold), or empty.
    const std::string& problem () const noexcept { return problem_; }

private:
    // Each channel's [frames_] samples; only those below [read_] are set (and looked at).
    std::vector<std::unique_ptr<float[]>> samples_;
    int64_t frames_ { 0 };
    std::atomic<int64_t> read_ { 0 };
    std::atomic<bool> cancel_ { false };
    std::thread reader_;
    std::unique_ptr<ARA::PlugIn::HostAudioReader> hostReader_;
    std::string problem_;
};

// Plays the regions the host gives an instance, from their sources' samples as read: at the
// source's speed (the plug-in stretches nothing, and says so), resampled when the rates differ.
class LinkPlaybackRenderer : public ARA::PlugIn::PlaybackRenderer {
public:
    using ARA::PlugIn::PlaybackRenderer::PlaybackRenderer;

    // On the audio thread: [frames] frames into the [channels] buffers of [out], as the host
    // gives them for this block at [sampleRate], the first at song sample [songSample].
    void render (float* const* out, int channels, double sampleRate, int64_t songSample, int64_t frames, bool playing) noexcept;
};

// One DAW document as Curator sees it. After every edit the host makes it is read whole (the
// tempo map, bar and key signatures and chords of each musical context, the tracks, the
// recordings and the regions placing them in the song) and, when anything differs, published
// to Curator. Curator may ask for a recording as a file, or a track as the song plays it (a
// stem): either is written from the samples read.
class LinkDocumentController : public ARA::PlugIn::DocumentController {
public:
    LinkDocumentController (const ARA::PlugIn::PlugInEntry* entry, const ARA::ARADocumentControllerHostInstance* instance) noexcept;
    ~LinkDocumentController () override;

    static const ARA::ARAFactory* getARAFactory () noexcept;

    // The DAW asking for updates: ARA's library hears it (willNotifyModelUpdates) only from a DAW
    // that gives its model-update interface; this one hears it from every DAW (ARA has each ask).
    void notifyModelUpdates () noexcept override;

    // Renderers stay out of the model while the host edits it (and while samples are reallocated).
    bool rendererWillAccessModel () noexcept;
    void rendererDidAccessModel () noexcept;

protected:
    void willBeginEditing () noexcept override;
    void didEndEditing () noexcept override;
    void willNotifyModelUpdates () noexcept override;
    void doUpdateMusicalContextContent (ARA::PlugIn::MusicalContext* context, const ARA::ARAContentTimeRange* range, ARA::ContentUpdateScopes flags) noexcept override;

    ARA::PlugIn::AudioSource* doCreateAudioSource (ARA::PlugIn::Document* document, ARA::ARAAudioSourceHostRef hostRef) noexcept override;
    void doUpdateAudioSourceContent (ARA::PlugIn::AudioSource* source, const ARA::ARAContentTimeRange* range, ARA::ContentUpdateScopes flags) noexcept override;
    void willEnableAudioSourceSamplesAccess (ARA::PlugIn::AudioSource* source, bool enable) noexcept override;
    void didEnableAudioSourceSamplesAccess (ARA::PlugIn::AudioSource* source, bool enable) noexcept override;
    void willDestroyAudioSource (ARA::PlugIn::AudioSource* source) noexcept override;

    void willDestroyDocument (ARA::PlugIn::Document* document) noexcept override;

    bool doRestoreObjectsFromArchive (ARA::PlugIn::HostArchiveReader* reader, const ARA::PlugIn::RestoreObjectsFilter* filter) noexcept override;
    bool doStoreObjectsToArchive (ARA::PlugIn::HostArchiveWriter* writer, const ARA::PlugIn::StoreObjectsFilter* filter) noexcept override;

    ARA::PlugIn::PlaybackRenderer* doCreatePlaybackRenderer () noexcept override;

private:
    std::string snapshot ();
    void publish ();
    void onMessage (const std::map<std::string, std::string>& message);
    // A file Curator asked for: a recording (by persistent ID), or a track as the song plays
    // it ([stem]: by its ID, from song time [from] for [length] seconds), on connection [asked].
    struct ExportJob {
        bool stem { false };
        std::string id;
        double from { 0 }, length { 0 };
        uint64_t asked { 0 };
    };
    void startPendingExport ();
    void startRecording (const ExportJob& job);
    void startStem (const ExportJob& job);
    void stopExport (const LinkAudioSource* source);
    void lockOutRenderers () noexcept;
    void letRenderersIn () noexcept;

    std::string id_;
    LinkClient& client_;
    int listener_ { 0 };

    // What Curator asked of the DAW's transport (`play`, `stop`, `seek`; `at`: where, or not a
    // number), noted on the connection's thread and asked of the DAW on its model thread as it
    // asks for updates (askTransport), the latest few in the order they came.
    struct TransportAsk {
        std::string what;
        double at;
    };
    void askTransport ();
    std::mutex transportMutex_;
    std::vector<TransportAsk> transport_;

    // Something changed outside an edit, to be published when the DAW next asks for model
    // updates.
    bool dirty_ { false };

    // Files Curator asked for, and the one being written (one at a time): the recordings it
    // reads ([using_], set before it starts), and whether it is still at it.
    std::mutex exportMutex_;
    std::vector<ExportJob> pending_;
    std::thread exporter_;
    std::vector<const LinkAudioSource*> using_;
    std::atomic<bool> busy_ { false };
    std::atomic<bool> cancelExport_ { false };
    // Which of Curator's connections this is (raised as one ends): a file asked on one gone
    // meanwhile is no one's to write, though it was taken up before word came. Under [exportMutex_].
    uint64_t connection_ { 0 };


    std::atomic<bool> renderersMayAccess_ { true };
    std::atomic<int> renderersAccessing_ { 0 };
    int lockouts_ { 0 };
};

}  // namespace attacca
