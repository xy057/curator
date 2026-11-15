// Curator Link: what the plug-in is called and who it says it is, in one place.
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

#define LINK_NAME "Curator Link"
#define LINK_VENDOR "Curator"
#define LINK_URL "https://github.com/xy057/curator"
#define LINK_EMAIL "mailto:"
#define LINK_FACTORY_ID "com.curatedscore.link.arafactory"
#define LINK_ARCHIVE_ID "com.curatedscore.link.archive.1"

// What Curator and the plug-in say to each other (docs/daw-link.md); raised only when one
// side could no longer read the other.
#define LINK_PROTOCOL 1
