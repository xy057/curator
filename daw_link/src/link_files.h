// What Attacca's ARA side and its Capturer both need for the files they write Curator.
#pragma once

#include <sys/stat.h>

#include <cctype>
#include <cmath>
#include <cstdint>
#include <cstdio>
#include <functional>
#include <random>
#include <string>

namespace attacca {

// An ID no other has (a document's, a Capturer's): 16 hex digits.
inline std::string randomId ()
{
    std::random_device device;
    char buffer[24];
    std::snprintf (buffer, sizeof buffer, "%08x%08x", device (), device ());
    return buffer;
}

// A file name of [text]: letters, digits, spaces and a few marks; at most 60 bytes.
inline std::string safeName (const std::string& text)
{
    std::string out;
    for (unsigned char c : text)
    {
        if (std::isalnum (c) || c == ' ' || c == '-' || c == '_' || c == '.' || c >= 0x80)
            out += static_cast<char> (c);
        if (out.size () >= 60)
            break;
    }
    while (!out.empty () && (out.front () == '.' || out.front () == ' '))
        out.erase (out.begin ());
    return out.empty () ? std::string ("Recording") : out;
}

inline void makeFolders (const std::string& path)
{
    for (size_t i = 1; i <= path.size (); ++i)
    {
        if (i == path.size () || path[i] == '/')
            ::mkdir (path.substr (0, i).c_str (), 0755);
    }
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
