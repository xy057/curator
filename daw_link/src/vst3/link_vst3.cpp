// Curator Link as a VST3 plug-in with ARA (Cubase, Nuendo, Studio One, REAPER, …).
#include "../link_client.h"
#include "../link_config.h"
#include "../link_document.h"

#include "ARA_API/ARAVST3.h"

ARA_DISABLE_VST3_WARNINGS_BEGIN
#include "pluginterfaces/vst/ivstprocesscontext.h"
#include "public.sdk/source/main/pluginfactory.h"
#include "public.sdk/source/vst/vstaudioeffect.h"
#include "public.sdk/source/vst/vsteditcontroller.h"
ARA_DISABLE_VST3_WARNINGS_END

#include <cstring>

using namespace Steinberg;

namespace curator_link {

ARA_DISABLE_VST3_WARNINGS_BEGIN

// The audio side: plays the regions it is given (as an ARA playback renderer), else passes
// what comes in; tells Curator where the DAW is playing.
class LinkProcessor : public Vst::AudioEffect, public ARA::IPlugInEntryPoint, public ARA::IPlugInEntryPoint2 {
public:
    static const FUID classID () { return FUID (0x0F041F96, 0xA2654B5A, 0xB41C67D5, 0x36C58ED9); }
    static const FUID controllerID () { return FUID (0x1245D387, 0xA75E4A1C, 0x88D4A3DD, 0x99FD9C89); }

    LinkProcessor () : client_ (LinkClient::retain ())
    {
        setControllerClass (controllerID ());
        processContextRequirements.needTransportState ().needProjectTimeMusic ().needTempo ();
    }
    ~LinkProcessor () override { LinkClient::release (); }

    static FUnknown* create (void*) { return static_cast<Vst::IAudioProcessor*> (new LinkProcessor); }
    static FUnknown* createController (void*) { return static_cast<Vst::IEditController*> (new Vst::EditController); }

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
        return extension_.bindToARA (controller, known, assigned);
    }

    OBJ_METHODS (LinkProcessor, AudioEffect)
    DEFINE_INTERFACES
        DEF_INTERFACE (IPlugInEntryPoint)
        DEF_INTERFACE (IPlugInEntryPoint2)
    END_DEFINE_INTERFACES (AudioEffect)
    REFCOUNT_METHODS (AudioEffect)

private:
    int outputChannels () const
    {
        auto* bus = FCast<Vst::AudioBus> (audioOutputs.at (0).get ());
        return bus ? Vst::SpeakerArr::getChannelCount (bus->getArrangement ()) : 2;
    }

    LinkClient& client_;
    ARA::PlugIn::PlugInExtension extension_;
};

// The ARA factory on its own, for hosts that read it before making an instance.
class LinkMainFactory : public ARA::IMainFactory {
public:
    LinkMainFactory () { FUNKNOWN_CTOR }
    virtual ~LinkMainFactory () { FUNKNOWN_DTOR }
    static const FUID classID () { return FUID (0x7F016CB2, 0xBF5A4C89, 0xB5BCE924, 0x2F895E3C); }
    static FUnknown* create (void*) { return static_cast<ARA::IMainFactory*> (new LinkMainFactory ()); }
    DECLARE_FUNKNOWN_METHODS
    const ARA::ARAFactory* PLUGIN_API getFactory () override { return LinkDocumentController::getARAFactory (); }
};

IMPLEMENT_FUNKNOWN_METHODS (LinkMainFactory, ARA::IMainFactory, ARA::IMainFactory::iid)

ARA_DISABLE_VST3_WARNINGS_END

}  // namespace curator_link

ARA_DISABLE_VST3_WARNINGS_BEGIN

bool InitModule () { return true; }
bool DeinitModule () { return true; }

DEF_CLASS_IID (ARA::IMainFactory)
DEF_CLASS_IID (ARA::IPlugInEntryPoint)
DEF_CLASS_IID (ARA::IPlugInEntryPoint2)

#define LINK_FULL_VERSION LINK_VERSION "." LINK_QUOTE (LINK_BUILD)

BEGIN_FACTORY_DEF (LINK_VENDOR, LINK_URL, LINK_EMAIL)

    DEF_CLASS2 (INLINE_UID_FROM_FUID (curator_link::LinkProcessor::classID ()), PClassInfo::kManyInstances, kVstAudioEffectClass, LINK_NAME,
                Vst::kDistributable, "Fx|Analyzer", LINK_FULL_VERSION, kVstVersionString, curator_link::LinkProcessor::create)

    DEF_CLASS2 (INLINE_UID_FROM_FUID (curator_link::LinkProcessor::controllerID ()), PClassInfo::kManyInstances, kVstComponentControllerClass, LINK_NAME,
                0, "", LINK_FULL_VERSION, kVstVersionString, curator_link::LinkProcessor::createController)

    DEF_CLASS2 (INLINE_UID_FROM_FUID (curator_link::LinkMainFactory::classID ()), PClassInfo::kManyInstances, kARAMainFactoryClass, LINK_NAME,
                0, "", LINK_FULL_VERSION, kVstVersionString, curator_link::LinkMainFactory::create)

END_FACTORY

ARA_DISABLE_VST3_WARNINGS_END
