#include "link_system.h"

#if defined(_WIN32)
#include <windows.h>
#else
#include <unistd.h>

#include <cerrno>
#include <csignal>
#include <cstdlib>
#if !defined(__APPLE__)
#include <fstream>
#endif
#endif

namespace attacca {

#if defined(_WIN32)

namespace {

std::string utf8 (const std::wstring& text)
{
    const int n = ::WideCharToMultiByte (CP_UTF8, 0, text.data (), static_cast<int> (text.size ()), nullptr, 0, nullptr, nullptr);
    std::string out (static_cast<size_t> (n > 0 ? n : 0), '\0');
    if (n > 0)
        ::WideCharToMultiByte (CP_UTF8, 0, text.data (), static_cast<int> (text.size ()), out.data (), n, nullptr, nullptr);
    return out;
}

// The process's variable [name] as it is now (never the C runtime's copy, taken when the DAW
// loaded it); empty when it has none.
std::wstring variable (const wchar_t* name)
{
    std::wstring value (512, L'\0');
    DWORD n = ::GetEnvironmentVariableW (name, value.data (), static_cast<DWORD> (value.size ()));
    if (n >= value.size ())
    {
        value.resize (n);
        n = ::GetEnvironmentVariableW (name, value.data (), static_cast<DWORD> (value.size ()));
    }
    value.resize (n < value.size () ? n : 0);
    return value;
}

// Whether [path] says where it is whole: `C:\…` or `\\…`.
bool absolute (const std::wstring& path)
{
    const bool drive = path.size () >= 3 && ((path[0] >= L'A' && path[0] <= L'Z') || (path[0] >= L'a' && path[0] <= L'z')) && path[1] == L':' && path[2] == L'\\';
    return drive || (path.size () >= 2 && path[0] == L'\\' && path[1] == L'\\');
}

std::wstring joined (std::wstring base, const wchar_t* rest)
{
    if (base.empty () || base.back () != L'\\')
        base += L'\\';
    return base + rest;
}

// %LocalAppData%, else the profile's AppData\Local, else the temporary folder: as Curator's
// AppFolders._windowsLocal has it.
std::wstring localFolder ()
{
    if (const std::wstring local = variable (L"LOCALAPPDATA"); absolute (local))
        return local;
    if (const std::wstring profile = variable (L"USERPROFILE"); absolute (profile))
        return joined (profile, L"AppData\\Local");
    std::wstring temp (MAX_PATH + 1, L'\0');
    temp.resize (::GetTempPathW (static_cast<DWORD> (temp.size ()), temp.data ()));
    while (temp.size () > 3 && temp.back () == L'\\')
        temp.pop_back ();
    return temp;
}

}  // namespace

std::string curatorDataFolder () { return utf8 (joined (localFolder (), L"Curator")); }

std::string curatorCacheFolder () { return utf8 (joined (localFolder (), L"Curator\\Cache")); }

std::string processName ()
{
    std::wstring path (MAX_PATH, L'\0');
    DWORD n = ::GetModuleFileNameW (nullptr, path.data (), static_cast<DWORD> (path.size ()));
    while (n >= path.size () && path.size () < 32768)
    {
        path.resize (path.size () * 2);
        n = ::GetModuleFileNameW (nullptr, path.data (), static_cast<DWORD> (path.size ()));
    }
    path.resize (n);
    if (const size_t slash = path.find_last_of (L"\\/"); slash != std::wstring::npos)
        path.erase (0, slash + 1);
    if (path.size () > 4 && ::_wcsicmp (path.c_str () + path.size () - 4, L".exe") == 0)
        path.resize (path.size () - 4);
    return utf8 (path);
}

long processId () { return static_cast<long> (::GetCurrentProcessId ()); }

bool processGone (long process)
{
    // (One that may not be asked after is there.)
    const HANDLE handle = ::OpenProcess (SYNCHRONIZE, FALSE, static_cast<DWORD> (process));
    if (!handle)
        return ::GetLastError () == ERROR_INVALID_PARAMETER;
    const bool ended = ::WaitForSingleObject (handle, 0) == WAIT_OBJECT_0;
    ::CloseHandle (handle);
    return ended;
}

#else

namespace {

std::string home ()
{
    const char* h = std::getenv ("HOME");
    return (h && *h == '/') ? std::string (h) : std::string ("/tmp");
}

#if !defined(__APPLE__)
std::string xdg (const char* name, const char* fallback)
{
    const char* v = std::getenv (name);
    return (v && *v == '/') ? std::string (v) : home () + fallback;
}
#endif

}  // namespace

std::string curatorDataFolder ()
{
#if defined(__APPLE__)
    return home () + "/Library/Application Support/Curator";
#else
    return xdg ("XDG_DATA_HOME", "/.local/share") + "/curator";
#endif
}

std::string curatorCacheFolder ()
{
#if defined(__APPLE__)
    return home () + "/Library/Caches/Curator";
#else
    return xdg ("XDG_CACHE_HOME", "/.cache") + "/curator";
#endif
}

std::string processName ()
{
#if defined(__APPLE__)
    return getprogname ();
#else
    std::ifstream comm ("/proc/self/comm");
    std::string name;
    std::getline (comm, name);
    return name;
#endif
}

long processId () { return static_cast<long> (::getpid ()); }

bool processGone (long process) { return ::kill (static_cast<pid_t> (process), 0) != 0 && errno == ESRCH; }

#endif

}  // namespace attacca
