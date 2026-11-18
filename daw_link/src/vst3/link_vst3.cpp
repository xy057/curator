// Attacca as a VST3 plug-in with ARA (Cubase, Nuendo, Studio One, REAPER, …).
#include "../link_capture.h"
#include "../link_client.h"
#include "../link_config.h"
#include "../link_document.h"
#include "../link_files.h"
#include "../mac/link_view.h"

#include "ARA_API/ARAVST3.h"

ARA_DISABLE_VST3_WARNINGS_BEGIN
#include "base/source/fstring.h"
#include "pluginterfaces/base/ibstream.h"
#include "pluginterfaces/vst/ivstchannelcontextinfo.h"
#include "pluginterfaces/vst/ivstprocesscontext.h"
#include "public.sdk/source/common/pluginview.h"
#include "public.sdk/source/main/pluginfactory.h"
#include "public.sdk/source/vst/vstaudioeffect.h"
#include "public.sdk/source/vst/vsteditcontroller.h"
ARA_DISABLE_VST3_WARNINGS_END

#include <atomic>
#include <cstring>
#include <functional>
#include <memory>
#include <mutex>
#include <utility>

using namespace Steinberg;

namespace attacca {

ARA_DISABLE_VST3_WARNINGS_BEGIN

// The window the DAW opens for the plug-in: its name, and whether Curator is connected.
class LinkView : public CPluginView {
public:
    LinkView (bool capturer, std::shared_ptr<std::atomic<int>> bound, std::function<std::string ()> capturerId = {})
        : CPluginView (nullptr), capturer_ (capturer), bound_ (std::move (bound)), capturerId_ (std::move (capturerId))
    {
        rect = ViewRect (0, 0, statusViewWidth, statusViewHeight);
    }
    ~LinkView () override { removed (); }

    tresult PLUGIN_API isPlatformTypeSupported (FIDString type) override
    {
        return type && std::strcmp (type, kPlatformTypeNSView) == 0 ? kResultTrue : kResultFalse;
    }

    tresult PLUGIN_API attached (void* parent, FIDString type) override
    {
        if (isPlatformTypeSupported (type) != kResultTrue || !parent)
            return kResultFalse;
        auto bound = bound_;
        handle_ = attachStatusView (parent, capturer_, bound ? std::function<int ()> ([bound] { return bound->load (); }) : std::function<int ()> (), capturerId_);
        return CPluginView::attached (parent, type);
    }

    tresult PLUGIN_API removed () override
    {
        if (handle_)
            detachStatusView (handle_);
        handle_ = nullptr;
        return CPluginView::removed ();
    }

private:
    void* handle_ = nullptr;
    bool capturer_;
    std::shared_ptr<std::atomic<int>> bound_;
    std::function<std::string ()> capturerId_;
};

// What Attacca's audio side tells its editing side: whether it is bound to ARA ("bound": 1 or 0).
constexpr const char* boundMessage = "attacca.bound";
// What Attacca Capturer's audio side tells its editing side: its ID ("id", UTF-8); and back, the
// DAW's channel it is on ("name", UTF-8).
constexpr const char* capturerIdMessage = "attacca.capturer";
constexpr const char* channelMessage = "attacca.channel";

// A UTF-8 text sent in a message's binary attribute [key], and read back.
void putText (Vst::IMessage* message, const char* key, const std::string& text) { message->getAttributes ()->setBinary (key, text.data (), static_cast<uint32> (text.size ())); }
bool getText (Vst::IMessage* message, const char* key, std::string& text)
{
    const void* data = nullptr;
    uint32 size = 0;
    if (!message->getAttributes () || message->getAttributes ()->getBinary (key, data, size) != kResultOk)
        return false;
    text.assign (static_cast<const char*> (data), size);
    return true;
}

// Whether [message] is the one called [id].
bool isMessage (Vst::IMessage* message, const char* id) { return message && message->getMessageID () && std::strcmp (message->getMessageID (), id) == 0; }

// A plug-in's saved state ([stateOf]) written to and read from the DAW's stream.
tresult writeState (IBStream* stream, const std::string& text)
{
    const std::string state = stateOf (text);
    int32 written = 0;
    return stream && stream->write (const_cast<char*> (state.data ()), static_cast<int32> (state.size ()), &written) == kResultOk && written == static_cast<int32> (state.size ())
               ? kResultOk
               : kResultFalse;
}
bool readState (IBStream* stream, std::string& text)
{
    std::string state;
    char buffer[512];
    int32 read = 0;
    while (stream && stream->read (buffer, sizeof buffer, &read) == kResultOk && read > 0 && state.size () < 8192)
        state.append (buffer, static_cast<size_t> (read));
    return textOfState (state, text);
}

// The editing side: no parameters, only the window (Attacca's; its Capturer's makes its own).
class LinkController : public Vst::EditController {
public:
    IPlugView* PLUGIN_API createView (FIDString name) override
    {
        return name && std::strcmp (name, Vst::ViewType::kEditor) == 0 ? new LinkView (false, bound_) : nullptr;
    }

    // Attacca's audio side says whether it is bound to ARA: an instance never bound is on an
    // insert only, and its window says so.
    tresult PLUGIN_API notify (Vst::IMessage* message) override
    {
        int64 bound = 0;
        if (isMessage (message, boundMessage) && message->getAttributes () && message->getAttributes ()->getInt ("bound", bound) == kResultOk)
        {
            bound_->store (bound != 0 ? 1 : 0);
            return kResultOk;
        }
        return EditController::notify (message);
    }

protected:
    std::shared_ptr<std::atomic<int>> bound_ = std::make_shared<std::atomic<int>> (-1);
};

// Attacca Capturer's editing side: its window (told the Capturer's ID by its audio side, to say
// whether it is linked), and the DAW's channel it is on passed to its audio side (its name in
// Attacca's Capturer menu).
class CaptureController : public LinkController, public Vst::ChannelContext::IInfoListener {
public:
    IPlugView* PLUGIN_API createView (FIDString name) override
    {
        auto id = id_;
        return name && std::strcmp (name, Vst::ViewType::kEditor) == 0 ? new LinkView (true, nullptr, [id] {
            std::lock_guard<std::mutex> lock (id->first);
            return id->second;
        })
                                                                     : nullptr;
    }

    tresult PLUGIN_API notify (Vst::IMessage* message) override
    {
        std::string id;
        if (isMessage (message, capturerIdMessage) && getText (message, "id", id))
        {
            std::lock_guard<std::mutex> lock (id_->first);
            id_->second = id;
            return kResultOk;
        }
        return LinkController::notify (message);
    }

    tresult PLUGIN_API setChannelContextInfos (Vst::IAttributeList* list) override
    {
        Vst::String128 name {};
        if (!list || list->getString (Vst::ChannelContext::kChannelNameKey, name, sizeof (name)) != kResultTrue)
            return kResultOk;
        String text (name);
        text.toMultiByte (kCP_Utf8);
        if (IPtr<Vst::IMessage> message = owned (allocateMessage ()))
        {
            message->setMessageID (channelMessage);
            putText (message, "name", text.text8 () ? text.text8 () : "");
            sendMessage (message);
        }
        return kResultOk;
    }

    OBJ_METHODS (CaptureController, LinkController)
    DEFINE_INTERFACES
        DEF_INTERFACE (Vst::ChannelContext::IInfoListener)
    END_DEFINE_INTERFACES (LinkController)
    REFCOUNT_METHODS (LinkController)

private:
    std::shared_ptr<std::pair<std::mutex, std::string>> id_ = std::make_shared<std::pair<std::mutex, std::string>> ();
};

// What both audio sides are: one stereo bus in and one out (any layout, the same each way),
// 32-bit samples.
class LinkEffect : public Vst::AudioEffect {
public:
    tresult PLUGIN_API initialize (FUnknown* context) override
    {
        const tresult result = AudioEffect::initialize (context);
        if (result != kResultOk)
            return result;
        addAudioInput (STR16 ("Stereo In"), Vst::SpeakerArr::kStereo);
        addAudioOutput (STR16 ("Stereo Out"), Vst::SpeakerArr::kStereo);
        return kResultOk;
    }

    tresult PLUGIN_API setBusArrangements (Vst::SpeakerArrangement* inputs, int32 numIns, Vst::SpeakerArrangement* outputs, int32 numOuts) override
    {
        // One bus each way, as many channels in as out.
        if (numIns == 1 && numOuts == 1 && inputs[0] == outputs[0] && Vst::SpeakerArr::getChannelCount (outputs[0]) != 0)
            return AudioEffect::setBusArrangements (inputs, numIns, outputs, numOuts);
        return kResultFalse;
    }

    tresult PLUGIN_API canProcessSampleSize (int32 size) override { return size == Vst::kSample32 ? kResultTrue : kResultFalse; }

protected:
    // What comes in, passed out as it is.
    static void passThrough (Vst::ProcessData& data)
    {
        if (!data.inputs || data.numInputs == 0 || !data.outputs || data.numOutputs == 0)
            return;
        auto &in = data.inputs[0], &out = data.outputs[0];
        for (int32 c = 0; c < out.numChannels && c < in.numChannels; ++c)
        {
            if (out.channelBuffers32[c] != in.channelBuffers32[c])
                std::memcpy (out.channelBuffers32[c], in.channelBuffers32[c], sizeof (float) * static_cast<size_t> (data.numSamples));
        }
    }
};

// The audio side: plays the regions it is given (as an ARA playback renderer), else passes
// what comes in; tells Curator where the DAW is playing.
class LinkProcessor : public LinkEffect, public ARA::IPlugInEntryPoint, public ARA::IPlugInEntryPoint2 {
public:
    static const FUID classID () { return FUID (0xAFB4775C, 0x839D4BA3, 0x8447247E, 0x8ED44D1E); }
    static const FUID controllerID () { return FUID (0x83F3EE18, 0x3745449B, 0x87759A19, 0x5CFB7E21); }

    LinkProcessor () : client_ (LinkClient::retain ())
    {
        setControllerClass (controllerID ());
        processContextRequirements.needTransportState ().needProjectTimeMusic ().needTempo ();
    }
    ~LinkProcessor () override { LinkClient::release (); }

    static FUnknown* create (void*) { return static_cast<Vst::IAudioProcessor*> (new LinkProcessor); }
    static FUnknown* createController (void*) { return static_cast<Vst::IEditController*> (new LinkController); }

    tresult PLUGIN_API process (Vst::ProcessData& data) override
    {
        if (const auto* context = data.processContext)
        {
            const bool playing = (context->state & Vst::ProcessContext::kPlaying) != 0;
            const double rate = context->sampleRate > 0 ? context->sampleRate : processSetup.sampleRate;
            const double seconds = rate > 0 ? static_cast<double> (context->projectTimeSamples) / rate : 0;
            const double quarters = (context->state & Vst::ProcessContext::kProjectTimeMusicValid) ? context->projectTimeMusic : -1;
            const double tempo = (context->state & Vst::ProcessContext::kTempoValid) ? context->tempo : 0;
            client_.setTransport (playing, seconds, quarters, tempo);
        }

        if (!data.outputs || data.numOutputs == 0 || data.outputs[0].numChannels == 0)
            return kResultTrue;
        auto& out = data.outputs[0];
        if (auto* renderer = extension_.getPlaybackRenderer<LinkPlaybackRenderer> ())
        {
            const bool playing = data.processContext && (data.processContext->state & Vst::ProcessContext::kPlaying);
            const int64 at = data.processContext ? data.processContext->projectTimeSamples : 0;
            const double rate = data.processContext && data.processContext->sampleRate > 0 ? data.processContext->sampleRate : processSetup.sampleRate;
            renderer->render (out.channelBuffers32, out.numChannels, rate, at, data.numSamples, playing);
        }
        else
            passThrough (data);
        return kResultTrue;
    }

    const ARA::ARAFactory* PLUGIN_API getFactory () override { return LinkDocumentController::getARAFactory (); }

    const ARA::ARAPlugInExtensionInstance* PLUGIN_API bindToDocumentController (ARA::ARADocumentControllerRef) override
    {
        return nullptr;  // ARA 1 only; an ARA 2 host binds with roles
    }

    const ARA::ARAPlugInExtensionInstance* PLUGIN_API bindToDocumentControllerWithRoles (ARA::ARADocumentControllerRef controller, ARA::ARAPlugInInstanceRoleFlags known,
                                                                                          ARA::ARAPlugInInstanceRoleFlags assigned) override
    {
        const auto* instance = extension_.bindToARA (controller, known, assigned);
        tellBound ();
        return instance;
    }

    // Connected to its editing side (by the DAW, once both are made): told whether it is bound.
    tresult PLUGIN_API connect (Vst::IConnectionPoint* other) override
    {
        const tresult result = AudioEffect::connect (other);
        tellBound ();
        return result;
    }

    // The Attacca Capturer linked (in its window's Capturer menu) kept in the DAW's project.
    tresult PLUGIN_API getState (IBStream* stream) override { return writeState (stream, client_.linkedCapturer ()); }
    tresult PLUGIN_API setState (IBStream* stream) override
    {
        std::string id;
        if (readState (stream, id))
            client_.setLinkedCapturer (id);
        return kResultOk;
    }

    OBJ_METHODS (LinkProcessor, AudioEffect)
    DEFINE_INTERFACES
        DEF_INTERFACE (IPlugInEntryPoint)
        DEF_INTERFACE (IPlugInEntryPoint2)
    END_DEFINE_INTERFACES (AudioEffect)
    REFCOUNT_METHODS (AudioEffect)

private:
    // Its editing side told whether it is bound to ARA (for its window).
    void tellBound ()
    {
        if (IPtr<Vst::IMessage> message = owned (allocateMessage ()))
        {
            message->setMessageID (boundMessage);
            message->getAttributes ()->setInt ("bound", extension_.isBoundToARA () ? 1 : 0);
            sendMessage (message);
        }
    }

    LinkClient& client_;
    ARA::PlugIn::PlugInExtension extension_;
};

// Attacca Capturer: an insert, no ARA, usually the last on the DAW's output. It passes what it
// hears through untouched and keeps it for Curator by song time (link_capture.h).
class CaptureProcessor : public LinkEffect {
public:
    static const FUID classID () { return FUID (0x33C549EF, 0x2C9F4786, 0x82D20196, 0xA52ABC73); }
    static const FUID controllerID () { return FUID (0x6E77B57C, 0xA80D4D82, 0xA2AAA1AB, 0x1C69B2E6); }

    CaptureProcessor ()
    {
        setControllerClass (controllerID ());
        processContextRequirements.needTransportState ();
    }

    static FUnknown* create (void*) { return static_cast<Vst::IAudioProcessor*> (new CaptureProcessor); }
    static FUnknown* createController (void*) { return static_cast<Vst::IEditController*> (new CaptureController); }

    tresult PLUGIN_API setActive (TBool state) override
    {
        if (state)
        {
            auto* bus = FCast<Vst::AudioBus> (audioInputs.at (0).get ());
            capturer_.prepare (processSetup.sampleRate, bus ? Vst::SpeakerArr::getChannelCount (bus->getArrangement ()) : 2);
        }
        return AudioEffect::setActive (state);
    }

    // Its ID kept in the DAW's project, so the Attacca it was linked to finds it again.
    tresult PLUGIN_API getState (IBStream* stream) override { return writeState (stream, capturer_.id ()); }
    tresult PLUGIN_API setState (IBStream* stream) override
    {
        std::string id;
        if (readState (stream, id))
        {
            capturer_.setId (id);
            tellId ();
        }
        return kResultOk;
    }

    // Connected to its editing side: told its ID (for its window).
    tresult PLUGIN_API connect (Vst::IConnectionPoint* other) override
    {
        const tresult result = AudioEffect::connect (other);
        tellId ();
        return result;
    }

    // The DAW's channel it is on, from its editing side: its name in Attacca's Capturer menu.
    tresult PLUGIN_API notify (Vst::IMessage* message) override
    {
        std::string name;
        if (isMessage (message, channelMessage) && getText (message, "name", name))
        {
            capturer_.setName (name);
            return kResultOk;
        }
        return AudioEffect::notify (message);
    }

    tresult PLUGIN_API process (Vst::ProcessData& data) override
    {
        if (!data.inputs || data.numInputs == 0 || data.inputs[0].numChannels == 0)
            return kResultTrue;
        auto& in = data.inputs[0];
        if (const auto* context = data.processContext)
            capturer_.process (in.channelBuffers32, in.numChannels, data.numSamples, (context->state & Vst::ProcessContext::kPlaying) != 0,
                               context->projectTimeSamples);
        passThrough (data);
        return kResultTrue;
    }

private:
    void tellId ()
    {
        if (IPtr<Vst::IMessage> message = owned (allocateMessage ()))
        {
            message->setMessageID (capturerIdMessage);
            putText (message, "id", capturer_.id ());
            sendMessage (message);
        }
    }

    Capturer capturer_;
};

// The ARA factory on its own, for hosts that read it before making an instance.
class LinkMainFactory : public ARA::IMainFactory {
public:
    LinkMainFactory () { FUNKNOWN_CTOR }
    virtual ~LinkMainFactory () { FUNKNOWN_DTOR }
    static const FUID classID () { return FUID (0xCCE65654, 0xB4244C60, 0x933A6DA8, 0x6F147299); }
    static FUnknown* create (void*) { return static_cast<ARA::IMainFactory*> (new LinkMainFactory ()); }
    DECLARE_FUNKNOWN_METHODS
    const ARA::ARAFactory* PLUGIN_API getFactory () override { return LinkDocumentController::getARAFactory (); }
};

IMPLEMENT_FUNKNOWN_METHODS (LinkMainFactory, ARA::IMainFactory, ARA::IMainFactory::iid)

ARA_DISABLE_VST3_WARNINGS_END

}  // namespace attacca

ARA_DISABLE_VST3_WARNINGS_BEGIN

bool InitModule () { return true; }
bool DeinitModule () { return true; }

DEF_CLASS_IID (ARA::IMainFactory)
DEF_CLASS_IID (ARA::IPlugInEntryPoint)
DEF_CLASS_IID (ARA::IPlugInEntryPoint2)

#define LINK_FULL_VERSION LINK_VERSION "." LINK_QUOTE (LINK_BUILD)

// Each in a bundle of its own (LINK_VST3_CAPTURER): Attacca, ARA only (OnlyARA: not offered as
// an insert); Attacca Capturer, an insert only (a DAW pairs every effect of a bundle that has an
// ARA factory with it, and would offer the Capturer as an ARA extension).
BEGIN_FACTORY_DEF (LINK_VENDOR, LINK_URL, LINK_EMAIL)

#if LINK_VST3_CAPTURER
    DEF_CLASS2 (INLINE_UID_FROM_FUID (attacca::CaptureProcessor::classID ()), PClassInfo::kManyInstances, kVstAudioEffectClass, LINK_CAPTURER_NAME,
                Vst::kDistributable, "Fx|Analyzer", LINK_FULL_VERSION, kVstVersionString, attacca::CaptureProcessor::create)

    DEF_CLASS2 (INLINE_UID_FROM_FUID (attacca::CaptureProcessor::controllerID ()), PClassInfo::kManyInstances, kVstComponentControllerClass, LINK_CAPTURER_NAME,
                0, "", LINK_FULL_VERSION, kVstVersionString, attacca::CaptureProcessor::createController)
#else
    DEF_CLASS2 (INLINE_UID_FROM_FUID (attacca::LinkProcessor::classID ()), PClassInfo::kManyInstances, kVstAudioEffectClass, LINK_NAME,
                Vst::kDistributable, "Fx|OnlyARA", LINK_FULL_VERSION, kVstVersionString, attacca::LinkProcessor::create)

    DEF_CLASS2 (INLINE_UID_FROM_FUID (attacca::LinkProcessor::controllerID ()), PClassInfo::kManyInstances, kVstComponentControllerClass, LINK_NAME,
                0, "", LINK_FULL_VERSION, kVstVersionString, attacca::LinkProcessor::createController)

    DEF_CLASS2 (INLINE_UID_FROM_FUID (attacca::LinkMainFactory::classID ()), PClassInfo::kManyInstances, kARAMainFactoryClass, LINK_NAME,
                0, "", LINK_FULL_VERSION, kVstVersionString, attacca::LinkMainFactory::create)
#endif

END_FACTORY

ARA_DISABLE_VST3_WARNINGS_END
