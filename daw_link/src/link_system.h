// What Attacca asks of the system it runs on (macOS, Windows), in one place: where Curator
// keeps its files, which process this is, and files by their UTF-8 names.
#pragma once

#include <filesystem>
#include <string>

namespace attacca {

// Curator's data folder (AppFolders.data) and cache folder (AppFolders.cache) on this system,
// found as Curator finds them (app/lib/app_folders.dart). UTF-8, as every path here is.
std::string curatorDataFolder ();
std::string curatorCacheFolder ();

// The DAW's name (its process's, without Windows' ".exe") and its process's number.
std::string processName ();
long processId ();

// Whether no process is numbered [process] any longer (false when it can't be told).
bool processGone (long process);

// [path] as the system names files: Windows in UTF-16.
inline std::filesystem::path fileOf (const std::string& path)
{
#if defined(_WIN32)
    return std::filesystem::path (std::u8string (path.begin (), path.end ()));
#else
    return std::filesystem::path (path);
#endif
}

// What the system calls [file], as UTF-8.
inline std::string pathOf (const std::filesystem::path& file)
{
    const std::u8string text = file.u8string ();
    return std::string (text.begin (), text.end ());
}

// [path], written with `/`, with the system's own separator (Windows: `\`): what Curator is
// told is a path as the system writes one.
inline std::string nativePath (std::string path)
{
#if defined(_WIN32)
    for (char& c : path)
    {
        if (c == '/')
            c = '\\';
    }
#endif
    return path;
}

}  // namespace attacca
