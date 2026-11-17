// Attacca as an Audio Unit with ARA (Logic Pro).
#include "../link_capture.h"
#include "../link_client.h"
#include "../link_document.h"
#include "../mac/link_view.h"

_Pragma ("GCC diagnostic push")
_Pragma ("GCC diagnostic ignored \"-Wimport-preprocessor-directive-pedantic\"")
#include <AudioUnitSDK/AUEffectBase.h>
_Pragma ("GCC diagnostic pop")

#include "ARA_API/ARAAudioUnit.h"

#include <AudioToolbox/AudioUnitProperties.h>

#include <cstring>
#include <vector>

namespace attacca {

// The audio side: plays the regions it is given (as an ARA playback renderer), else passes
// what comes in; tells Curator where the DAW is playing.
class LinkAudioUnit : public ausdk::AUEffectBase {
public:
    explicit LinkAudioUnit (AudioComponentInstance component) : AUEffectBase (component), client_ (LinkClient::retain ()) { CreateElements (); }
    ~LinkAudioUnit () override { LinkClient::release (); }

    OSStatus Initialize () override
    {
        const OSStatus result = AUEffectBase::Initialize ();
        if (auto* renderer = extension_.getPlaybackRenderer<LinkPlaybackRenderer> ())
            renderer->enable (GetSampleRate (), static_cast<int> (GetNumberOfChannels ()));
        return result;
    }

    UInt32 SupportedNumChannels (const AUChannelInfo** info) override
    {
        static const AUChannelInfo any { -1, -1 };
        if (info)
            *info = &any;
        return 1;
    }

    OSStatus GetPropertyInfo (AudioUnitPropertyID id, AudioUnitScope scope, AudioUnitElement element, UInt32& size, bool& writable) override
    {
        if (scope == kAudioUnitScope_Global)
        {
            switch (id)
            {
                case ARA::kAudioUnitProperty_ARAFactory:
                    writable = false;
                    size = sizeof (ARA::ARAAudioUnitFactory);
                    return noErr;
                case ARA::kAudioUnitProperty_ARAPlugInExtensionBindingWithRoles:
                    writable = false;
                    size = sizeof (ARA::ARAAudioUnitPlugInExtensionBinding);
                    return noErr;
                case kAudioUnitProperty_CocoaUI:
                    writable = false;
                    size = sizeof (AudioUnitCocoaViewInfo);
                    return noErr;
                default:
                    break;
            }
        }
        return AUEffectBase::GetPropertyInfo (id, scope, element, size, writable);
    }

    OSStatus GetProperty (AudioUnitPropertyID id, AudioUnitScope scope, AudioUnitElement element, void* data) override
    {
        if (scope == kAudioUnitScope_Global)
        {
            switch (id)
            {
                case ARA::kAudioUnitProperty_ARAFactory:
                {
                    auto* factory = static_cast<ARA::ARAAudioUnitFactory*> (data);
                    // The magic number tells this from another use of the same property ID.
                    if (factory->inOutMagicNumber != ARA::kARAAudioUnitMagic)
                        return kAudioUnitErr_InvalidProperty;
                    factory->outFactory = LinkDocumentController::getARAFactory ();
                    return noErr;
                }
                case ARA::kAudioUnitProperty_ARAPlugInExtensionBindingWithRoles:
                {
                    auto* binding = static_cast<ARA::ARAAudioUnitPlugInExtensionBinding*> (data);
                    if (binding->inOutMagicNumber != ARA::kARAAudioUnitMagic)
                        return kAudioUnitErr_InvalidProperty;
                    binding->outPlugInExtension = extension_.bindToARA (binding->inDocumentControllerRef, binding->knownRoles, binding->assignedRoles);
                    if (!binding->outPlugInExtension)
                        return kAudioUnitErr_CannotDoInCurrentContext;
                    return noErr;
                }
                case kAudioUnitProperty_CocoaUI:
                {
                    // The window: a class in this bundle that makes it (the host releases both).
                    CFBundleRef bundle = CFBundleGetBundleWithIdentifier (CFSTR ("com.curatedscore.attacca.component"));
                    if (!bundle)
                        return kAudioUnitErr_InvalidProperty;
                    auto* info = static_cast<AudioUnitCocoaViewInfo*> (data);
                    info->mCocoaAUViewBundleLocation = CFBundleCopyBundleURL (bundle);
                    info->mCocoaAUViewClass[0] = CFStringCreateWithCString (kCFAllocatorDefault, statusViewFactoryClass (), kCFStringEncodingUTF8);
                    return noErr;
                }
                default:
                    break;
            }
        }
        return AUEffectBase::GetProperty (id, scope, element, data);
    }

    OSStatus ProcessBufferLists (AudioUnitRenderActionFlags&, const AudioBufferList& in, AudioBufferList& out, UInt32 frames) override
    {
        // The host's transport: by its newer callback where it gives one (the SDK asks only the older).
        Boolean playing = false;
        Float64 sample = 0;
        const HostCallbackInfo& host = GetHostCallbackInfo ();
        if (host.transportStateProc2)
            host.transportStateProc2 (host.hostUserData, &playing, nullptr, nullptr, &sample, nullptr, nullptr, nullptr);
        else
            CallHostTransportState (&playing, nullptr, &sample, nullptr, nullptr, nullptr);
        Float64 beat = -1, tempo = 0;
        if (CallHostBeatAndTempo (&beat, &tempo) != noErr)
            beat = -1, tempo = 0;
        const double rate = GetSampleRate ();
        client_.setTransport (playing, rate > 0 ? sample / rate : 0, beat, tempo);

        const UInt32 channels = out.mNumberBuffers;
        float* outputs[64];
        const UInt32 n = std::min<UInt32> (channels, 64);
        for (UInt32 c = 0; c < n; ++c)
            outputs[c] = static_cast<float*> (out.mBuffers[c].mData);
        if (auto* renderer = extension_.getPlaybackRenderer<LinkPlaybackRenderer> ())
        {
            renderer->render (outputs, static_cast<int64_t> (sample), frames, playing);
        }
        else
        {
            for (UInt32 c = 0; c < n && c < in.mNumberBuffers; ++c)
            {
                if (outputs[c] != in.mBuffers[c].mData)
                    std::memcpy (outputs[c], in.mBuffers[c].mData, sizeof (float) * frames);
            }
        }
        return noErr;
    }

    OSStatus Render (AudioUnitRenderActionFlags& flags, const AudioTimeStamp& time, UInt32 frames) override
    {
        // A playback renderer has no input to pull: the regions are its sound.
        if (!HasInput (0) && extension_.getPlaybackRenderer<LinkPlaybackRenderer> ())
        {
            AudioBufferList none {};
            none.mNumberBuffers = 0;
            return ProcessBufferLists (flags, none, Output (0).GetBufferList (), frames);
        }
        return AUEffectBase::Render (flags, time, frames);
    }

    bool SupportsTail () override { return true; }

private:
    LinkClient& client_;
    ARA::PlugIn::PlugInExtension extension_;
};

// Attacca Capturer: an insert, no ARA, usually the last on the DAW's output. It passes what it
// hears through untouched and keeps it for Curator by song time (link_capture.h).
class CaptureAudioUnit : public ausdk::AUEffectBase {
public:
    explicit CaptureAudioUnit (AudioComponentInstance component) : AUEffectBase (component) { CreateElements (); }

    OSStatus Initialize () override
    {
        const OSStatus result = AUEffectBase::Initialize ();
        capturer_.prepare (GetSampleRate (), static_cast<int> (GetNumberOfChannels ()));
        return result;
    }

    UInt32 SupportedNumChannels (const AUChannelInfo** info) override
    {
        static const AUChannelInfo any { -1, -1 };
        if (info)
            *info = &any;
        return 1;
    }

    OSStatus GetPropertyInfo (AudioUnitPropertyID id, AudioUnitScope scope, AudioUnitElement element, UInt32& size, bool& writable) override
    {
        if (scope == kAudioUnitScope_Global && id == kAudioUnitProperty_CocoaUI)
        {
            writable = false;
            size = sizeof (AudioUnitCocoaViewInfo);
            return noErr;
        }
        return AUEffectBase::GetPropertyInfo (id, scope, element, size, writable);
    }

    OSStatus GetProperty (AudioUnitPropertyID id, AudioUnitScope scope, AudioUnitElement element, void* data) override
    {
        if (scope == kAudioUnitScope_Global && id == kAudioUnitProperty_CocoaUI)
        {
            // The same window as Attacca's, made for a Capturer (the factory tells by the name).
            CFBundleRef bundle = CFBundleGetBundleWithIdentifier (CFSTR ("com.curatedscore.attacca.component"));
            if (!bundle)
                return kAudioUnitErr_InvalidProperty;
            auto* info = static_cast<AudioUnitCocoaViewInfo*> (data);
            info->mCocoaAUViewBundleLocation = CFBundleCopyBundleURL (bundle);
            info->mCocoaAUViewClass[0] = CFStringCreateWithCString (kCFAllocatorDefault, statusViewFactoryClass (), kCFStringEncodingUTF8);
            return noErr;
        }
        return AUEffectBase::GetProperty (id, scope, element, data);
    }

    OSStatus ProcessBufferLists (AudioUnitRenderActionFlags&, const AudioBufferList& in, AudioBufferList& out, UInt32 frames) override
    {
        Boolean playing = false;
        Float64 sample = 0;
        const HostCallbackInfo& host = GetHostCallbackInfo ();
        if (host.transportStateProc2)
            host.transportStateProc2 (host.hostUserData, &playing, nullptr, nullptr, &sample, nullptr, nullptr, nullptr);
        else
            CallHostTransportState (&playing, nullptr, &sample, nullptr, nullptr, nullptr);
        const float* inputs[64];
        const UInt32 n = std::min<UInt32> (in.mNumberBuffers, 64);
        for (UInt32 c = 0; c < n; ++c)
            inputs[c] = static_cast<const float*> (in.mBuffers[c].mData);
        capturer_.process (inputs, static_cast<int> (n), frames, playing, static_cast<int64_t> (sample));
        for (UInt32 c = 0; c < out.mNumberBuffers && c < in.mNumberBuffers; ++c)
        {
            if (out.mBuffers[c].mData != in.mBuffers[c].mData)
                std::memcpy (out.mBuffers[c].mData, in.mBuffers[c].mData, sizeof (float) * frames);
        }
        return noErr;
    }

    bool SupportsTail () override { return true; }

private:
    Capturer capturer_;
};

}  // namespace attacca

// The factory functions Info.plist names: AttaccaFactory, AttaccaCapturerFactory.
using Attacca = attacca::LinkAudioUnit;
AUSDK_COMPONENT_ENTRY (ausdk::AUBaseFactory, Attacca)
using AttaccaCapturer = attacca::CaptureAudioUnit;
AUSDK_COMPONENT_ENTRY (ausdk::AUBaseFactory, AttaccaCapturer)
