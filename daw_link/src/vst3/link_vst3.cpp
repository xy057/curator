// Attacca as a VST3 plug-in with ARA (Cubase, Nuendo, Studio One, REAPER, …).
#include "../link_capture.h"
#include "../link_client.h"
#include "../link_config.h"
#include "../link_document.h"
#include "../mac/link_view.h"

#include "ARA_API/ARAVST3.h"

ARA_DISABLE_VST3_WARNINGS_BEGIN
#include "pluginterfaces/vst/ivstprocesscontext.h"
#include "public.sdk/source/common/pluginview.h"
#include "public.sdk/source/main/pluginfactory.h"
#include "public.sdk/source/vst/vstaudioeffect.h"
#include "public.sdk/source/vst/vsteditcontroller.h"
ARA_DISABLE_VST3_WARNINGS_END

#include <atomic>
#include <cstring>
#include <memory>

using namespace Steinberg;

namespace attacca {

ARA_DISABLE_VST3_WARNINGS_BEGIN

// The window the DAW opens for the plug-in: its name, and whether Curator is connected.
class LinkView : public CPluginView {
public:
    LinkView (bool capturer, std::shared_ptr<std::atomic<int>> bound) : CPluginView (nullptr), capturer_ (capturer), bound_ (std::move (bound))
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
        handle_ = attachStatusView (parent, capturer_, bound ? std::function<int ()> ([bound] { return bound->load (); }) : std::function<int ()> ());
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
};

// What Attacca's audio side tells its editing side: whether it is bound to ARA ("bound": 1 or 0).
constexpr const char* boundMessage = "attacca.bound";

// The editing side: no parameters, only the window (Attacca's, or [capturer] its Capturer's).
class LinkController : public Vst::EditController {
public:
    explicit LinkController (bool capturer = false) : capturer_ (capturer) {}
    IPlugView* PLUGIN_API createView (FIDString name) override
    {
        return name && std::strcmp (name, Vst::ViewType::kEditor) == 0 ? new LinkView (capturer_, capturer_ ? nullptr : bound_) : nullptr;
    }

    // Attacca's audio side says whether it is bound to ARA: an instance never bound is on an
    // insert only, and its window says so.
    tresult PLUGIN_API notify (Vst::IMessage* message) override
    {
        int64 bound = 0;
        if (message && message->getMessageID () && std::strcmp (message->getMessageID (), boundMessage) == 0 && message->getAttributes () &&
            message->getAttributes ()->getInt ("bound", bound) == kResultOk)
        {
            bound_->store (bound != 0 ? 1 : 0);
            return kResultOk;
        }
        return EditController::notify (message);
    }

private:
    bool capturer_;
    std::shared_ptr<std::atomic<int>> bound_ = std::make_shared<std::atomic<int>> (-1);
};

// The audio side: plays the regions it is given (as an ARA playback renderer), else passes
// what comes in; tells Curator where the DAW is playing.
class LinkProcessor : public Vst::AudioEffect, public ARA::IPlugInEntryPoint, public ARA::IPlugInEntryPoint2 {
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

    tresult PLUGIN_API setActive (TBool state) override
    {
        if (auto* renderer = extension_.getPlaybackRenderer<LinkPlaybackRenderer> ())
        {
            if (state)
                renderer->enable (processSetup.sampleRate, outputChannels ());
        }
        return AudioEffect::setActive (state);
    }

    tresult PLUGIN_API canProcessSampleSize (int32 size) override { return size == Vst::kSample32 ? kResultTrue : kResultFalse; }

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
            renderer->render (out.channelBuffers32, at, data.numSamples, playing);
        }
        else if (data.inputs && data.numInputs > 0)
        {
            for (int32 c = 0; c < out.numChannels && c < data.inputs[0].numChannels; ++c)
            {
                if (out.channelBuffers32[c] != data.inputs[0].channelBuffers32[c])
                    std::memcpy (out.channelBuffers32[c], data.inputs[0].channelBuffers32[c], sizeof (float) * static_cast<size_t> (data.numSamples));
            }
        }
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

    int outputChannels () const
    {
        auto* bus = FCast<Vst::AudioBus> (audioOutputs.at (0).get ());
        return bus ? Vst::SpeakerArr::getChannelCount (bus->getArrangement ()) : 2;
    }

    LinkClient& client_;
    ARA::PlugIn::PlugInExtension extension_;
};

// Attacca Capturer: an insert, no ARA, usually the last on the DAW's output. It passes what it
// hears through untouched and keeps it for Curator by song time (link_capture.h).
class CaptureProcessor : public Vst::AudioEffect {
public:
    static const FUID classID () { return FUID (0x33C549EF, 0x2C9F4786, 0x82D20196, 0xA52ABC73); }
    static const FUID controllerID () { return FUID (0x6E77B57C, 0xA80D4D82, 0xA2AAA1AB, 0x1C69B2E6); }

    CaptureProcessor ()
    {
        setControllerClass (controllerID ());
        processContextRequirements.needTransportState ();
    }

    static FUnknown* create (void*) { return static_cast<Vst::IAudioProcessor*> (new CaptureProcessor); }
    static FUnknown* createController (void*) { return static_cast<Vst::IEditController*> (new LinkController (true)); }

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
        if (numIns == 1 && numOuts == 1 && inputs[0] == outputs[0] && Vst::SpeakerArr::getChannelCount (outputs[0]) != 0)
            return AudioEffect::setBusArrangements (inputs, numIns, outputs, numOuts);
        return kResultFalse;
    }

    tresult PLUGIN_API setActive (TBool state) override
    {
        if (state)
        {
            auto* bus = FCast<Vst::AudioBus> (audioInputs.at (0).get ());
            capturer_.prepare (processSetup.sampleRate, bus ? Vst::SpeakerArr::getChannelCount (bus->getArrangement ()) : 2);
        }
        return AudioEffect::setActive (state);
    }

    tresult PLUGIN_API canProcessSampleSize (int32 size) override { return size == Vst::kSample32 ? kResultTrue : kResultFalse; }

    tresult PLUGIN_API process (Vst::ProcessData& data) override
    {
        if (!data.inputs || data.numInputs == 0 || data.inputs[0].numChannels == 0)
            return kResultTrue;
        auto& in = data.inputs[0];
        if (const auto* context = data.processContext)
            capturer_.process (in.channelBuffers32, in.numChannels, data.numSamples, (context->state & Vst::ProcessContext::kPlaying) != 0,
                               context->projectTimeSamples);
        if (data.outputs && data.numOutputs > 0)
        {
            auto& out = data.outputs[0];
            for (int32 c = 0; c < out.numChannels && c < in.numChannels; ++c)
            {
                if (out.channelBuffers32[c] != in.channelBuffers32[c])
                    std::memcpy (out.channelBuffers32[c], in.channelBuffers32[c], sizeof (float) * static_cast<size_t> (data.numSamples));
            }
        }
        return kResultTrue;
    }

private:
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

BEGIN_FACTORY_DEF (LINK_VENDOR, LINK_URL, LINK_EMAIL)

    DEF_CLASS2 (INLINE_UID_FROM_FUID (attacca::LinkProcessor::classID ()), PClassInfo::kManyInstances, kVstAudioEffectClass, LINK_NAME,
                Vst::kDistributable, "Fx|Analyzer", LINK_FULL_VERSION, kVstVersionString, attacca::LinkProcessor::create)

    DEF_CLASS2 (INLINE_UID_FROM_FUID (attacca::LinkProcessor::controllerID ()), PClassInfo::kManyInstances, kVstComponentControllerClass, LINK_NAME,
                0, "", LINK_FULL_VERSION, kVstVersionString, attacca::LinkProcessor::createController)

    DEF_CLASS2 (INLINE_UID_FROM_FUID (attacca::LinkMainFactory::classID ()), PClassInfo::kManyInstances, kARAMainFactoryClass, LINK_NAME,
                0, "", LINK_FULL_VERSION, kVstVersionString, attacca::LinkMainFactory::create)

    DEF_CLASS2 (INLINE_UID_FROM_FUID (attacca::CaptureProcessor::classID ()), PClassInfo::kManyInstances, kVstAudioEffectClass, LINK_CAPTURER_NAME,
                Vst::kDistributable, "Fx|Analyzer", LINK_FULL_VERSION, kVstVersionString, attacca::CaptureProcessor::create)

    DEF_CLASS2 (INLINE_UID_FROM_FUID (attacca::CaptureProcessor::controllerID ()), PClassInfo::kManyInstances, kVstComponentControllerClass, LINK_CAPTURER_NAME,
                0, "", LINK_FULL_VERSION, kVstVersionString, attacca::CaptureProcessor::createController)

END_FACTORY

ARA_DISABLE_VST3_WARNINGS_END
