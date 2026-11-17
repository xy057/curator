// Attacca: what the plug-in is called and who it says it is, in one place.
#pragma once

#define LINK_QUOTE_(x) #x
#define LINK_QUOTE(x) LINK_QUOTE_(x)

// Set by CMakeLists.txt from app/pubspec.yaml: the plug-in has Curator's version.
#ifndef LINK_VERSION
#define LINK_VERSION "0.0.0"
#endif
#ifndef LINK_BUILD
#define LINK_BUILD 0
#endif

#define LINK_NAME "Attacca"
#define LINK_VENDOR "Curator"
#define LINK_URL "https://github.com/xy057/curator"
#define LINK_EMAIL "mailto:"
// Attacca's own IDs, none of Curator Link's: a DAW keeps what it learnt of a plug-in by its
// IDs (Cubase its name and buses by the VST3 class ID), so Curator Link's would have kept it
// "Curator Link" with no audio buses.
#define LINK_FACTORY_ID "com.curatedscore.attacca.arafactory"
// Curator's own bundle (app/macos/Runner/Configs/AppInfo.xcconfig): whether it is open.
#define LINK_CURATOR_BUNDLE_ID "com.curatedscore.curatedScore"
#define LINK_ARCHIVE_ID "com.curatedscore.attacca.archive.1"

// What Curator and the plug-in say to each other (docs/daw-link.md); raised only when one
// side could no longer read the other.
#define LINK_PROTOCOL 1
