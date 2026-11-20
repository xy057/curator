# Attacca: the ARA plug-in (VST3, and on macOS an Audio Unit) that hands a DAW's tempo map,
# bars, keys, tracks, recordings and transport to Curator (docs/daw-link.md). `make daw-link`
# fetches the SDKs it is built on into third_party/ (pinned in the Makefile) and builds it here
# for macOS; `make daw-link-windows` (daw_link/windows.sh) builds it for Windows, on a Mac too,
# with llvm-mingw.
#
# The SDKs' sources are compiled as listed below; none of their own build scripts are run.
cmake_minimum_required(VERSION 3.21)
project(Attacca LANGUAGES C CXX)

if(APPLE)
    enable_language(OBJCXX)
elseif(NOT WIN32)
    message(FATAL_ERROR "Attacca is built for macOS and Windows.")
endif()

set(CMAKE_CXX_STANDARD 23)
set(CMAKE_CXX_STANDARD_REQUIRED ON)
set(CMAKE_OSX_DEPLOYMENT_TARGET 11.0 CACHE STRING "")
if(NOT CMAKE_BUILD_TYPE)
    set(CMAKE_BUILD_TYPE Release)
endif()
if(WIN32)
    # Windows 10's calls, in UTF-16, without the old macros (min, max) and headers.
    add_compile_definitions(UNICODE _UNICODE WIN32_LEAN_AND_MEAN NOMINMAX _WIN32_WINNT=0x0A00)
    # Nothing but Windows' own libraries is needed where a DAW loads it: the C++ library is in it.
    if(MSVC)
        set(CMAKE_MSVC_RUNTIME_LIBRARY "MultiThreaded$<$<CONFIG:Debug>:Debug>")
    else()
        add_link_options(-static)
    endif()
    # The folder of a VST3 bundle its program is in, named for the processor it is built for.
    string(TOLOWER "${CMAKE_SYSTEM_PROCESSOR}" processor)
    if(processor MATCHES "^(arm64|aarch64)$")
        set(LINK_WINDOWS_ARCH "arm64-win")
    elseif(processor MATCHES "^(x86_64|amd64)$")
        set(LINK_WINDOWS_ARCH "x86_64-win")
    else()
        message(FATAL_ERROR "Attacca is built for x86_64 and arm64 Windows, not ${CMAKE_SYSTEM_PROCESSOR}.")
    endif()
endif()
set(CMAKE_C_VISIBILITY_PRESET hidden)
set(CMAKE_CXX_VISIBILITY_PRESET hidden)
set(CMAKE_VISIBILITY_INLINES_HIDDEN ON)

set(LINK_VERSION "0" CACHE STRING "Attacca's own version, a whole number (app/lib/attacca_version.dart)")
# An Audio Unit's version as Logic compares it, 0xMMMMmmbb: 1, then Attacca's version over the
# two bytes after it (630 is 1.2.118), so it rises with it and is above every one from before
# Attacca had a version of its own (0.10.0 at most).
math(EXPR LINK_AU_VERSION "(1 << 16) | ${LINK_VERSION}")

set(SDKS "${CMAKE_CURRENT_SOURCE_DIR}/third_party")
set(ARA_SDK "${SDKS}/ARA_SDK")
set(VST3_SDK "${SDKS}/vst3sdk")
set(AU_SDK "${SDKS}/AudioUnitSDK")
set(sdk_dirs "${ARA_SDK}/ARA_Library" "${VST3_SDK}/public.sdk")
if(APPLE)
    list(APPEND sdk_dirs "${AU_SDK}/src")
endif()
foreach(dir ${sdk_dirs})
    if(NOT EXISTS "${dir}")
        message(FATAL_ERROR "${dir} is missing: run `make daw-link` (Windows: `make daw-link-windows`) from the repository's root.")
    endif()
endforeach()

# Warnings the SDKs' code gives in numbers that would hide ours.
if(MSVC)
    set(sdk_quiet /w)
    set(link_warnings /W3)
else()
    set(sdk_quiet -w)
    set(link_warnings -Wall -Wextra -Wno-unused-parameter)
endif()

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
    src/link_socket.h
    src/link_system.h
    src/link_system.cpp
    src/link_view.h
)
target_link_libraries(link_core PUBLIC ara_plugin)
target_compile_definitions(link_core PUBLIC LINK_VERSION=${LINK_VERSION})
target_compile_options(link_core PRIVATE ${link_warnings})
if(WIN32)
    target_link_libraries(link_core PUBLIC ws2_32)
endif()

# The plug-in's window in [target]. macOS (src/mac/link_view.mm): its classes named for it
# ([suffix]), since the VST3 and the Audio Unit can be loaded in one process. Windows
# (src/win/link_view.cpp): its window class is its DLL's own.
function(link_view target suffix)
    if(APPLE)
        target_sources(${target} PRIVATE src/mac/link_view.mm)
        target_compile_options(${target} PRIVATE "$<$<COMPILE_LANGUAGE:OBJCXX>:-fobjc-arc>")
        target_compile_definitions(${target} PRIVATE LINK_VIEW_SUFFIX=${suffix})
        target_link_libraries(${target} PRIVATE "-framework Cocoa" "-framework AudioToolbox")
    else()
        target_sources(${target} PRIVATE src/win/link_view.cpp)
        target_compile_options(${target} PRIVATE ${link_warnings})
        target_link_libraries(${target} PRIVATE user32 gdi32)
    endif()
endfunction()

set(LINK_LICENSES "${CMAKE_CURRENT_SOURCE_DIR}/../app/assets/daw_link/LICENSES.txt")

# Windows: a VST3 bundle of [target], named [name]: a folder <name>.vst3 holding its program
# (Contents/<processor>-win/<name>.vst3, a DLL) and, in Contents/Resources, the licences of the
# SDKs in it and Attacca's version (version.txt, "630": what Settings reads as the version
# installed; macOS has it in the bundle's Info.plist).
function(link_windows_bundle target name)
    set(bundle "${CMAKE_CURRENT_BINARY_DIR}/out/${name}.vst3")
    set_target_properties(${target} PROPERTIES
        PREFIX ""
        SUFFIX ".vst3"
        OUTPUT_NAME "${name}"
        LIBRARY_OUTPUT_DIRECTORY "${bundle}/Contents/${LINK_WINDOWS_ARCH}"
    )
    foreach(config Debug Release RelWithDebInfo MinSizeRel)
        string(TOUPPER ${config} upper)
        set_target_properties(${target} PROPERTIES LIBRARY_OUTPUT_DIRECTORY_${upper} "${bundle}/Contents/${LINK_WINDOWS_ARCH}")
    endforeach()
    file(WRITE "${CMAKE_CURRENT_BINARY_DIR}/version.txt" "${LINK_VERSION}\n")
    add_custom_command(TARGET ${target} POST_BUILD
        COMMAND ${CMAKE_COMMAND} -E make_directory "${bundle}/Contents/Resources"
        COMMAND ${CMAKE_COMMAND} -E copy_if_different "${LINK_LICENSES}" "${CMAKE_CURRENT_BINARY_DIR}/version.txt" "${bundle}/Contents/Resources"
        VERBATIM
    )
endfunction()

# macOS: a bundle of [target]: its Info.plist, the licences of the SDKs in it (the app's asset,
# one copy), and an ad-hoc signature sealing it (Apple silicon runs nothing unsigned). Its
# program is named Attacca, or the name given after [plist].
function(link_bundle target extension plist)
    set(name "Attacca")
    if(ARGC GREATER 3)
        set(name "${ARGV3}")
    endif()
    configure_file("${plist}" "${CMAKE_CURRENT_BINARY_DIR}/${target}-Info.plist" @ONLY)
    target_sources(${target} PRIVATE "${LINK_LICENSES}")
    set_source_files_properties("${LINK_LICENSES}" PROPERTIES MACOSX_PACKAGE_LOCATION Resources)
    set_target_properties(${target} PROPERTIES
        BUNDLE ON
        BUNDLE_EXTENSION ${extension}
        OUTPUT_NAME "${name}"
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
if(APPLE)
    target_link_libraries(vst3_sdk PUBLIC "-framework CoreFoundation")
else()
    target_link_libraries(vst3_sdk PUBLIC ole32 user32)
endif()

# A VST3 of src/vst3/link_vst3.cpp: [target], the bundle [name].vst3. macOS: its window's
# classes named [suffix], its Info.plist made of mac/[plist]. Its entry points are the SDK's
# (macOS: bundleEntry, bundleExit; Windows: InitDll, ExitDll; both GetPluginFactory).
function(link_vst3 target name suffix plist)
    if(APPLE)
        add_library(${target} MODULE src/vst3/link_vst3.cpp "${VST3_SDK}/public.sdk/source/main/macmain.cpp")
        target_link_options(${target} PRIVATE "-Wl,-exported_symbols_list,${VST3_SDK}/public.sdk/source/main/macexport.exp")
        link_bundle(${target} vst3 "${CMAKE_CURRENT_SOURCE_DIR}/mac/${plist}" "${name}")
    else()
        add_library(${target} MODULE src/vst3/link_vst3.cpp "${VST3_SDK}/public.sdk/source/main/dllmain.cpp")
        set_source_files_properties("${VST3_SDK}/public.sdk/source/main/dllmain.cpp" PROPERTIES COMPILE_OPTIONS "${sdk_quiet}")
        link_windows_bundle(${target} "${name}")
    endif()
    target_link_libraries(${target} PRIVATE link_core vst3_sdk)
    link_view(${target} ${suffix})
endfunction()

link_vst3(AttaccaVST3 "Attacca" VST3 Info-VST3.plist.in)

# Attacca Capturer as a VST3 of its own: in Attacca's bundle a DAW would offer it as an ARA
# extension too (it pairs a bundle's effects with its ARA factory).
link_vst3(AttaccaCapturerVST3 "Attacca Capturer" CapturerVST3 Info-CapturerVST3.plist.in)
target_compile_definitions(AttaccaCapturerVST3 PRIVATE LINK_VST3_CAPTURER=1)

# A DAW in miniature that loads the plug-ins and checks what Curator is told (`make daw-link`
# and daw_link/windows.sh run it before zipping the bundles): test/link_host.cpp, on the ARA
# examples' VST3 loader. On macOS it checks the Audio Unit too.
add_executable(link_host
    test/link_host.cpp
    "${ARA_SDK}/ARA_Examples/ExamplesCommon/PlugInHosting/VST3Loader.cpp"
    "${VST3_SDK}/public.sdk/source/common/memorystream.cpp"
)
target_include_directories(link_host PRIVATE "${ARA_SDK}/ARA_Examples")
target_link_libraries(link_host PRIVATE ara_plugin vst3_sdk)
target_compile_definitions(link_host PRIVATE LINK_VERSION=${LINK_VERSION})
add_dependencies(link_host AttaccaVST3 AttaccaCapturerVST3)
if(WIN32)
    target_link_libraries(link_host PRIVATE ws2_32 user32)
endif()

# macOS alone has Audio Units.
if(APPLE)
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

    target_link_libraries(link_host PRIVATE "-framework AudioToolbox" "-framework AudioUnit" "-framework AppKit")
    add_dependencies(link_host AttaccaAU)
endif()
