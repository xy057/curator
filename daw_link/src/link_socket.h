// The sockets Attacca and Curator talk through (TCP on the loopback address), the same calls
// on macOS and Windows: Windows names and types them its own way (Winsock).
#pragma once

#if defined(_WIN32)
#include <winsock2.h>
#include <ws2tcpip.h>
#else
#include <arpa/inet.h>
#include <netinet/in.h>
#include <netinet/tcp.h>
#include <poll.h>
#include <sys/socket.h>
#include <unistd.h>

#include <cerrno>
#endif

#include <cstddef>
#include <cstdint>

namespace attacca::net {

// A socket; [none] when there isn't one (so `>= 0` asks whether there is).
using Socket = std::intptr_t;
constexpr Socket none = -1;

// Before the first socket and after the last, once each per user (Windows: Winsock is counted).
inline void begin ()
{
#if defined(_WIN32)
    WSADATA data;
    ::WSAStartup (MAKEWORD (2, 2), &data);
#endif
}

inline void end ()
{
#if defined(_WIN32)
    ::WSACleanup ();
#endif
}

inline void close (Socket socket)
{
#if defined(_WIN32)
    ::closesocket (static_cast<SOCKET> (socket));
#else
    ::close (static_cast<int> (socket));
#endif
}

// A TCP socket that sends at once (no waiting to fill a packet) and never for longer than
// [sendSeconds] (0: as long as it takes); writing to one closed is an error, not a signal.
inline Socket open (int sendSeconds = 0)
{
#if defined(_WIN32)
    const SOCKET made = ::socket (AF_INET, SOCK_STREAM, 0);
    if (made == INVALID_SOCKET)
        return none;
    const Socket socket = static_cast<Socket> (made);
    const BOOL noDelay = TRUE;
    ::setsockopt (made, IPPROTO_TCP, TCP_NODELAY, reinterpret_cast<const char*> (&noDelay), sizeof noDelay);
    const DWORD timeout = static_cast<DWORD> (sendSeconds) * 1000;
    if (sendSeconds > 0)
        ::setsockopt (made, SOL_SOCKET, SO_SNDTIMEO, reinterpret_cast<const char*> (&timeout), sizeof timeout);
#else
    const Socket socket = ::socket (AF_INET, SOCK_STREAM, 0);
    if (socket < 0)
        return none;
#if defined(SO_NOSIGPIPE)
    int on = 1;
    ::setsockopt (static_cast<int> (socket), SOL_SOCKET, SO_NOSIGPIPE, &on, sizeof on);
#endif
    int noDelay = 1;
    ::setsockopt (static_cast<int> (socket), IPPROTO_TCP, TCP_NODELAY, &noDelay, sizeof noDelay);
    timeval timeout { sendSeconds, 0 };
    if (sendSeconds > 0)
        ::setsockopt (static_cast<int> (socket), SOL_SOCKET, SO_SNDTIMEO, &timeout, sizeof timeout);
#endif
    return socket;
}

inline sockaddr_in loopback (uint16_t port)
{
    sockaddr_in address {};
    address.sin_family = AF_INET;
    address.sin_port = htons (port);
    address.sin_addr.s_addr = htonl (INADDR_LOOPBACK);
    return address;
}

// [socket] connected to [port] of this machine.
inline bool connect (Socket socket, uint16_t port)
{
    const sockaddr_in address = loopback (port);
#if defined(_WIN32)
    return ::connect (static_cast<SOCKET> (socket), reinterpret_cast<const sockaddr*> (&address), sizeof address) == 0;
#else
    return ::connect (static_cast<int> (socket), reinterpret_cast<const sockaddr*> (&address), sizeof address) == 0;
#endif
}

// [socket] listening on this machine at a port the system picks: the port, or 0 when it can't.
inline uint16_t listen (Socket socket)
{
    sockaddr_in address = loopback (0);
#if defined(_WIN32)
    const SOCKET s = static_cast<SOCKET> (socket);
    int length = sizeof address;
#else
    const int s = static_cast<int> (socket);
    socklen_t length = sizeof address;
#endif
    if (::bind (s, reinterpret_cast<const sockaddr*> (&address), sizeof address) != 0 || ::listen (s, 4) != 0 ||
        ::getsockname (s, reinterpret_cast<sockaddr*> (&address), &length) != 0)
        return 0;
    return ntohs (address.sin_port);
}

// The connection waiting at [listener]; [none] when it can't be taken.
inline Socket accept (Socket listener)
{
#if defined(_WIN32)
    const SOCKET made = ::accept (static_cast<SOCKET> (listener), nullptr, nullptr);
    return made == INVALID_SOCKET ? none : static_cast<Socket> (made);
#else
    const int made = ::accept (static_cast<int> (listener), nullptr, nullptr);
    return made < 0 ? none : made;
#endif
}

// Whether [socket] has something to read (or has closed, or failed: reading tells) within
// [milliseconds].
inline bool readable (Socket socket, int milliseconds)
{
#if defined(_WIN32)
    WSAPOLLFD p { static_cast<SOCKET> (socket), POLLRDNORM, 0 };
    return ::WSAPoll (&p, 1, milliseconds) > 0 && (p.revents & (POLLRDNORM | POLLHUP | POLLERR)) != 0;
#else
    pollfd p { static_cast<int> (socket), POLLIN, 0 };
    return ::poll (&p, 1, milliseconds) > 0 && (p.revents & (POLLIN | POLLHUP | POLLERR)) != 0;
#endif
}

// Sends some of [size] bytes at [data]: how many, or -1 when it can't.
inline long long send (Socket socket, const char* data, size_t size)
{
#if defined(_WIN32)
    const int n = ::send (static_cast<SOCKET> (socket), data, static_cast<int> (size < 0x40000000 ? size : 0x40000000), 0);
    return n > 0 ? n : -1;
#else
    while (true)
    {
#if defined(MSG_NOSIGNAL)
        const ssize_t n = ::send (static_cast<int> (socket), data, size, MSG_NOSIGNAL);
#else
        const ssize_t n = ::send (static_cast<int> (socket), data, size, 0);
#endif
        if (n < 0 && errno == EINTR)
            continue;
        return n > 0 ? static_cast<long long> (n) : -1;
    }
#endif
}

// Reads up to [size] bytes into [data]: how many; 0 when the other side closed; -1 when it
// can't.
inline long long receive (Socket socket, char* data, size_t size)
{
#if defined(_WIN32)
    const int n = ::recv (static_cast<SOCKET> (socket), data, static_cast<int> (size < 0x40000000 ? size : 0x40000000), 0);
    return n >= 0 ? n : -1;
#else
    while (true)
    {
        const ssize_t n = ::recv (static_cast<int> (socket), data, size, 0);
        if (n < 0 && errno == EINTR)
            continue;
        return n >= 0 ? static_cast<long long> (n) : -1;
    }
#endif
}

}  // namespace attacca::net
