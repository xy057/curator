// What Attacca's ARA side and its Capturer both need for the files they write Curator.
#pragma once

#include "link_system.h"

#include <cctype>
#include <cmath>
#include <cstdint>
#include <cstdio>
#include <functional>
#include <random>
#include <string>
#include <system_error>

namespace attacca {

// An ID no other has (a document's, a Capturer's): 16 hex digits.
inline std::string randomId ()
{
    std::random_device device;
    char buffer[24];
    std::snprintf (buffer, sizeof buffer, "%08x%08x", device (), device ());
    return buffer;
}

// A file name of [text]: letters, digits, spaces and a few marks; at most 60 bytes, of whole
// characters (a name cut inside one isn't UTF-8, and macOS makes no file by such a name), a
// byte that is no character's left out. Never one of the names Windows keeps for its devices
// ("CON", "COM1": a file so named, whatever follows its dot, is the device there).
inline std::string safeName (const std::string& text)
{
    std::string out;
    for (size_t i = 0; i < text.size ();)
    {
        const unsigned char c = static_cast<unsigned char> (text[i]);
        // The character here: one byte, or a UTF-8 lead byte and those that follow it.
        const size_t n = c < 0x80 ? 1 : c < 0xc2 ? 0 : c < 0xe0 ? 2 : c < 0xf0 ? 3 : c < 0xf5 ? 4 : 0;
        bool whole = n > 0 && i + n <= text.size ();
        for (size_t k = 1; whole && k < n; ++k)
            whole = (static_cast<unsigned char> (text[i + k]) & 0xc0) == 0x80;
        if (!whole)
        {
            ++i;
            continue;
        }
        if (out.size () + n > 60)
            break;
        if (n > 1 || std::isalnum (c) || c == ' ' || c == '-' || c == '_' || c == '.')
            out.append (text, i, n);
        i += n;
    }
    while (!out.empty () && (out.front () == '.' || out.front () == ' '))
        out.erase (out.begin ());
#if defined(_WIN32)
    std::string stem = out.substr (0, out.find ('.'));
    while (!stem.empty () && stem.back () == ' ')
        stem.pop_back ();
    for (char& c : stem)
        c = static_cast<char> (std::toupper (static_cast<unsigned char> (c)));
    const bool numbered = stem.size () == 4 && (stem.compare (0, 3, "COM") == 0 || stem.compare (0, 3, "LPT") == 0) && std::isdigit (static_cast<unsigned char> (stem[3]));
    if (stem == "CON" || stem == "PRN" || stem == "AUX" || stem == "NUL" || numbered)
        out.insert (out.begin (), '_');
#endif
    return out.empty () ? std::string ("Recording") : out;
}

// [path] and every folder above it made, where they aren't there.
inline void makeFolders (const std::string& path)
{
    std::error_code error;
    std::filesystem::create_directories (fileOf (path), error);
}

// The file [from] put in place as [to], instead of any there: where it is now, or empty when it
// can't be put. Windows lets no file take the place of one a program has open (Curator plays a
// recording from the file the plug-in wrote, and may ask for it again): it then goes by the same
// name into a folder beside [to]'s ("<folder> 2", "<folder> 3", …), the first that takes it.
inline std::string putInPlace (const std::string& from, const std::string& to)
{
    const std::filesystem::path file = fileOf (from), wanted = fileOf (to);
    std::error_code error;
    std::filesystem::rename (file, wanted, error);
    if (!error)
        return to;
    for (int i = 2; i <= 50 && std::filesystem::exists (wanted, error); ++i)
    {
        std::filesystem::path folder = wanted.parent_path ();
        folder += " " + std::to_string (i);
        const std::filesystem::path beside = folder / wanted.filename ();
        std::filesystem::create_directories (folder, error);
        std::filesystem::rename (file, beside, error);
        if (!error)
            return pathOf (beside);
    }
    return {};
}

inline void removeFile (const std::string& path)
{
    std::error_code error;
    std::filesystem::remove (fileOf (path), error);
}

// 16 hex digits naming [text] in a folder's name.
inline std::string hashOf (const std::string& text)
{
    char hash[24];
    std::snprintf (hash, sizeof hash, "%016llx", static_cast<unsigned long long> (std::hash<std::string> {} (text)));
    return hash;
}

// A 32-bit float WAV's header (RIFF, fmt, fact, data: 56 bytes) for [frames] frames of
// [channels] at [rate]; its samples follow it.
constexpr int64_t wavHeaderBytes = 56;
inline std::string wavHeader (int channels, double rate, int64_t frames)
{
    std::string h;
    auto put16 = [&h] (uint32_t v) { h += static_cast<char> (v & 0xff); h += static_cast<char> ((v >> 8) & 0xff); };
    auto put32 = [&] (uint32_t v) { put16 (v & 0xffff); put16 (v >> 16); };
    const uint32_t dataBytes = static_cast<uint32_t> (frames * channels * 4);
    h += "RIFF";
    put32 (4 + (8 + 16) + (8 + 4) + 8 + dataBytes);
    h += "WAVE";
    h += "fmt ";
    put32 (16);
    put16 (3);  // IEEE float
    put16 (static_cast<uint32_t> (channels));
    put32 (static_cast<uint32_t> (std::lround (rate)));
    put32 (static_cast<uint32_t> (std::lround (rate)) * static_cast<uint32_t> (channels) * 4);
    put16 (static_cast<uint32_t> (channels * 4));
    put16 (32);
    h += "fact";
    put32 (4);
    put32 (static_cast<uint32_t> (frames));
    h += "data";
    put32 (dataBytes);
    return h;
}

// A plug-in instance's saved state, kept in the DAW's project: a short text (Attacca: the
// Capturer linked; a Capturer: its ID) as "Atca", its length (4 bytes, little-endian), its bytes.
inline std::string stateOf (const std::string& text)
{
    std::string out = "Atca";
    const uint32_t n = static_cast<uint32_t> (text.size ());
    for (int i = 0; i < 4; ++i)
        out += static_cast<char> ((n >> (8 * i)) & 0xff);
    return out + text;
}

// The text in [state] ([stateOf]); false when it isn't one.
inline bool textOfState (const std::string& state, std::string& text)
{
    if (state.size () < 8 || state.compare (0, 4, "Atca") != 0)
        return false;
    uint32_t n = 0;
    for (int i = 0; i < 4; ++i)
        n |= static_cast<uint32_t> (static_cast<unsigned char> (state[4 + static_cast<size_t> (i)])) << (8 * i);
    if (state.size () < 8 + static_cast<size_t> (n) || n > 4096)
        return false;
    text = state.substr (8, n);
    return true;
}

}  // namespace attacca
