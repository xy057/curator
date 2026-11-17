// Attacca's ARA side: a DAW document read for Curator, and its regions played back.
#pragma once

#include "ARA_Library/PlugIn/ARAPlug.h"

#include <atomic>
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
    const float* channel (int c) const noexcept { return samples_[static_cast<size_t> (c)].data (); }
    int channels () const noexcept { return static_cast<int> (samples_.size ()); }
    int64_t frames () const noexcept { return frames_; }
    // Why the samples can't be had (too long to hold), or empty.
    const std::string& problem () const noexcept { return problem_; }

private:
    std::vector<std::vector<float>> samples_;
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

    void enable (double sampleRate, int channels) noexcept;
    void render (float* const* out, int64_t songSample, int64_t frames, bool playing) noexcept;

private:
    double sampleRate_ { 44100 };
    int channels_ { 2 };
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

    bool doRestoreObjectsFromArchive (ARA::PlugIn::HostArchiveReader* reader, const ARA::PlugIn::RestoreObjectsFilter* filter) noexcept override;
    bool doStoreObjectsToArchive (ARA::PlugIn::HostArchiveWriter* writer, const ARA::PlugIn::StoreObjectsFilter* filter) noexcept override;

    ARA::PlugIn::PlaybackRenderer* doCreatePlaybackRenderer () noexcept override;

private:
    std::string snapshot ();
    void publish ();
    void onMessage (const std::map<std::string, std::string>& message);
    // A file Curator asked for: a recording (by persistent ID), or a track as the song plays
    // it ([stem]: by its ID, from song time [from] for [length] seconds).
    struct ExportJob {
        bool stem { false };
        std::string id;
        double from { 0 }, length { 0 };
    };
    void startPendingExport ();
    void startRecording (const std::string& sourceID);
    void startStem (const ExportJob& job);
    void stopExport (const LinkAudioSource* source);
    // The DAW played for a Capturer's capture, and stopped when it is done, as Curator asks.
    void followCapture () noexcept;
    void lockOutRenderers () noexcept;
    void letRenderersIn () noexcept;

    std::string id_;
    LinkClient& client_;
    int listener_ { 0 };

    // The last state published: a new one is sent only when it differs.
    std::string published_;
    bool dirty_ { true };

    // Files Curator asked for, and the one being written (one at a time): the recordings it
    // reads ([using_], set before it starts), and whether it is still at it.
    std::mutex exportMutex_;
    std::vector<ExportJob> pending_;
    std::thread exporter_;
    std::vector<const LinkAudioSource*> using_;
    std::atomic<bool> busy_ { false };
    std::atomic<bool> cancelExport_ { false };

    // A capture under way (Curator's `play` and `stop`, set on the connection's thread, taken up
    // on the main thread): where the DAW is to play from, whether it is to start or stop, and
    // whether it was started for one.
    std::atomic<double> playFrom_ { 0 };
    std::atomic<bool> wantPlayback_ { false }, wantStop_ { false };
    bool playing_ { false };

    std::atomic<bool> renderersMayAccess_ { true };
    std::atomic<int> renderersAccessing_ { 0 };
    int lockouts_ { 0 };
};

}  // namespace attacca
