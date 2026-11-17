# Attacca: the ARA plug-in (VST3 and Audio Unit) that hands a DAW's tempo map, bars, keys,
# tracks, recordings and transport to Curator (docs/daw-link.md). `make daw-link` fetches the
# SDKs it is built on into third_party/ (pinned in the Makefile) and builds it here.
#
# The SDKs' sources are compiled as listed below; none of their own build scripts are run.
cmake_minimum_required(VERSION 3.21)
project(Attacca LANGUAGES C CXX OBJCXX)

if(NOT APPLE)
    message(FATAL_ERROR "Attacca is built for macOS.")
endif()

set(CMAKE_CXX_STANDARD 23)
set(CMAKE_CXX_STANDARD_REQUIRED ON)
set(CMAKE_OSX_DEPLOYMENT_TARGET 11.0 CACHE STRING "")
if(NOT CMAKE_BUILD_TYPE)
    set(CMAKE_BUILD_TYPE Release)
endif()
set(CMAKE_C_VISIBILITY_PRESET hidden)
set(CMAKE_CXX_VISIBILITY_PRESET hidden)
set(CMAKE_VISIBILITY_INLINES_HIDDEN ON)

set(LINK_VERSION "0.0.0" CACHE STRING "Curator's version (app/pubspec.yaml)")
set(LINK_BUILD "0" CACHE STRING "Curator's build number (app/pubspec.yaml)")
set(LINK_RELEASE_PATCH "0" CACHE STRING "The patch of Curator's release (app/lib/updater.dart's appReleasePatch)")
# An Audio Unit's version as Logic compares it: 0xMMMMmmbb. Its patch byte is the release's (its
# leading digits, at most 255): LINK_VERSION's patch is the build, too big for a byte.
string(REPLACE "." ";" version_parts "${LINK_VERSION}")
list(GET version_parts 0 version_major)
list(GET version_parts 1 version_minor)
string(REGEX MATCH "^[0-9]*" version_patch "${LINK_RELEASE_PATCH}")
if(version_patch STREQUAL "")
    set(version_patch 0)
elseif(version_patch GREATER 255)
    set(version_patch 255)
endif()
math(EXPR LINK_AU_VERSION "(${version_major} << 16) | (${version_minor} << 8) | ${version_patch}")

set(SDKS "${CMAKE_CURRENT_SOURCE_DIR}/third_party")
set(ARA_SDK "${SDKS}/ARA_SDK")
set(VST3_SDK "${SDKS}/vst3sdk")
set(AU_SDK "${SDKS}/AudioUnitSDK")
foreach(dir "${ARA_SDK}/ARA_Library" "${VST3_SDK}/public.sdk" "${AU_SDK}/src")
    if(NOT EXISTS "${dir}")
        message(FATAL_ERROR "${dir} is missing: run `make daw-link` from the repository's root.")
    endif()
endforeach()

# Warnings the SDKs' code gives in numbers that would hide ours.
set(sdk_quiet -w)

# ARA: the plug-in side of the ARA Library (Apache 2.0).
add_library(ara_plugin STATIC
    "${ARA_SDK}/ARA_Library/Debug/ARADebug.c"
    "${ARA_SDK}/ARA_Library/Dispatch/ARAPlugInDispatch.cpp"
    "${ARA_SDK}/ARA_Library/PlugIn/ARAPlug.cpp"
    "${ARA_SDK}/ARA_Library/Utilities/ARAChannelFormat.cpp"
    "${ARA_SDK}/ARA_Library/Utilities/ARAPitchInterpretation.cpp"
)
target_include_directories(ara_plugin PUBLIC "${ARA_SDK}")
target_compile_definitions(ara_plugin PUBLIC NDEBUG=1 ARA_SUPPORT_VERSION_1=0)
target_compile_options(ara_plugin PRIVATE ${sdk_quiet})

# What both formats share: the line to Curator and the ARA document.
add_library(link_core STATIC
    src/json.h
    src/link_config.h
    src/link_client.h
    src/link_client.cpp
    src/link_document.h
    src/link_document.cpp
    src/link_files.h
    src/link_capture.h
    src/link_capture.cpp
)
target_link_libraries(link_core PUBLIC ara_plugin)
target_compile_definitions(link_core PUBLIC LINK_VERSION="${LINK_VERSION}" LINK_BUILD=${LINK_BUILD})
target_compile_options(link_core PRIVATE -Wall -Wextra -Wno-unused-parameter)

# The plug-in's window (src/mac/link_view.mm) in [target], its classes named for it ([suffix]):
# the VST3 and the Audio Unit can be loaded in one process.
function(link_view target suffix)
    target_sources(${target} PRIVATE src/mac/link_view.mm)
    target_compile_options(${target} PRIVATE "$<$<COMPILE_LANGUAGE:OBJCXX>:-fobjc-arc>")
    target_compile_definitions(${target} PRIVATE LINK_VIEW_SUFFIX=${suffix})
    target_link_libraries(${target} PRIVATE "-framework Cocoa" "-framework AudioToolbox")
endfunction()

# A bundle of [target]: its Info.plist, the licences of the SDKs in it (the app's asset, one
# copy), and an ad-hoc signature sealing it (Apple silicon runs nothing unsigned).
set(LINK_LICENSES "${CMAKE_CURRENT_SOURCE_DIR}/../app/assets/daw_link/LICENSES.txt")
function(link_bundle target extension plist)
    configure_file("${plist}" "${CMAKE_CURRENT_BINARY_DIR}/${target}-Info.plist" @ONLY)
    target_sources(${target} PRIVATE "${LINK_LICENSES}")
    set_source_files_properties("${LINK_LICENSES}" PROPERTIES MACOSX_PACKAGE_LOCATION Resources)
    set_target_properties(${target} PROPERTIES
        BUNDLE ON
        BUNDLE_EXTENSION ${extension}
        OUTPUT_NAME "Attacca"
        MACOSX_BUNDLE_INFO_PLIST "${CMAKE_CURRENT_BINARY_DIR}/${target}-Info.plist"
        LIBRARY_OUTPUT_DIRECTORY "${CMAKE_CURRENT_BINARY_DIR}/out"
    )
    add_custom_command(TARGET ${target} POST_BUILD
        COMMAND codesign --force --sign - --timestamp=none "$<TARGET_BUNDLE_DIR:${target}>"
        VERBATIM
    )
endfunction()

# VST3 (MIT): the SDK's base, interfaces and the effect classes the plug-in is made of.
add_library(vst3_sdk STATIC
    "${VST3_SDK}/base/source/baseiids.cpp"
    "${VST3_SDK}/base/source/fbuffer.cpp"
    "${VST3_SDK}/base/source/fdebug.cpp"
    "${VST3_SDK}/base/source/fdynlib.cpp"
    "${VST3_SDK}/base/source/fobject.cpp"
    "${VST3_SDK}/base/source/fstreamer.cpp"
    "${VST3_SDK}/base/source/fstring.cpp"
    "${VST3_SDK}/base/source/timer.cpp"
    "${VST3_SDK}/base/source/updatehandler.cpp"
    "${VST3_SDK}/base/thread/source/fcondition.cpp"
    "${VST3_SDK}/base/thread/source/flock.cpp"
    "${VST3_SDK}/pluginterfaces/base/conststringtable.cpp"
    "${VST3_SDK}/pluginterfaces/base/coreiids.cpp"
    "${VST3_SDK}/pluginterfaces/base/funknown.cpp"
    "${VST3_SDK}/pluginterfaces/base/ustring.cpp"
    "${VST3_SDK}/public.sdk/source/common/commoniids.cpp"
    "${VST3_SDK}/public.sdk/source/common/pluginview.cpp"
    "${VST3_SDK}/public.sdk/source/main/pluginfactory.cpp"
    "${VST3_SDK}/public.sdk/source/vst/vstaudioeffect.cpp"
    "${VST3_SDK}/public.sdk/source/vst/vstbus.cpp"
    "${VST3_SDK}/public.sdk/source/vst/vstcomponent.cpp"
    "${VST3_SDK}/public.sdk/source/vst/vstcomponentbase.cpp"
    "${VST3_SDK}/public.sdk/source/vst/vsteditcontroller.cpp"
    "${VST3_SDK}/public.sdk/source/vst/vstinitiids.cpp"
    "${VST3_SDK}/public.sdk/source/vst/vstparameters.cpp"
)
target_include_directories(vst3_sdk PUBLIC "${VST3_SDK}")
target_compile_definitions(vst3_sdk PUBLIC RELEASE=1)
target_compile_options(vst3_sdk PRIVATE ${sdk_quiet})
target_link_libraries(vst3_sdk PUBLIC "-framework CoreFoundation")

add_library(AttaccaVST3 MODULE
    src/vst3/link_vst3.cpp
    "${VST3_SDK}/public.sdk/source/main/macmain.cpp"
)
target_link_libraries(AttaccaVST3 PRIVATE link_core vst3_sdk)
link_view(AttaccaVST3 VST3)
target_link_options(AttaccaVST3 PRIVATE "-Wl,-exported_symbols_list,${VST3_SDK}/public.sdk/source/main/macexport.exp")
link_bundle(AttaccaVST3 vst3 "${CMAKE_CURRENT_SOURCE_DIR}/mac/Info-VST3.plist.in")

# Audio Unit (Apple's AudioUnitSDK, Apache 2.0): the effect base class.
add_library(audiounit_sdk STATIC
    "${AU_SDK}/src/AudioUnitSDK/AUBase.cpp"
    "${AU_SDK}/src/AudioUnitSDK/AUBuffer.cpp"
    "${AU_SDK}/src/AudioUnitSDK/AUBufferAllocator.cpp"
    "${AU_SDK}/src/AudioUnitSDK/AUEffectBase.cpp"
    "${AU_SDK}/src/AudioUnitSDK/AUInputElement.cpp"
    "${AU_SDK}/src/AudioUnitSDK/AUOutputElement.cpp"
    "${AU_SDK}/src/AudioUnitSDK/AUPlugInDispatch.cpp"
    "${AU_SDK}/src/AudioUnitSDK/AUScopeElement.cpp"
    "${AU_SDK}/src/AudioUnitSDK/ComponentBase.cpp"
)
target_include_directories(audiounit_sdk PUBLIC "${AU_SDK}/include")
target_compile_options(audiounit_sdk PRIVATE ${sdk_quiet})
target_link_libraries(audiounit_sdk PUBLIC
    "-framework CoreFoundation" "-framework CoreAudio" "-framework AudioToolbox" "-framework AudioUnit")

add_library(AttaccaAU MODULE src/au/link_au.cpp)
target_link_libraries(AttaccaAU PRIVATE link_core audiounit_sdk)
link_view(AttaccaAU AU)
target_link_options(AttaccaAU PRIVATE "-Wl,-exported_symbol,_AttaccaFactory" "-Wl,-exported_symbol,_AttaccaCapturerFactory")
link_bundle(AttaccaAU component "${CMAKE_CURRENT_SOURCE_DIR}/mac/Info-AU.plist.in")

# A DAW in miniature that loads the VST3 and the Audio Unit and checks what Curator is told (`make daw-link` runs it
# before zipping the bundles): test/link_host.cpp, on the ARA examples' VST3 loader.
add_executable(link_host
    test/link_host.cpp
    "${ARA_SDK}/ARA_Examples/ExamplesCommon/PlugInHosting/VST3Loader.cpp"
)
target_include_directories(link_host PRIVATE "${ARA_SDK}/ARA_Examples")
target_link_libraries(link_host PRIVATE ara_plugin vst3_sdk "-framework AudioToolbox" "-framework AudioUnit" "-framework AppKit")
add_dependencies(link_host AttaccaVST3 AttaccaAU)
