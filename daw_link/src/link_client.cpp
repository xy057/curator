#include "link_client.h"

#include "json.h"
#include "link_config.h"

#include <arpa/inet.h>
#include <netinet/in.h>
#include <netinet/tcp.h>
#include <poll.h>
#include <sys/socket.h>
#include <unistd.h>

#include <cerrno>
#include <csignal>
#include <chrono>
#include <cstdlib>
#include <fstream>
#include <sstream>

namespace attacca {

namespace {

std::mutex sharedMutex;
int sharedCount = 0;
LinkClient* shared = nullptr;

// The most a line from Curator may be: its messages are a few hundred bytes.
constexpr size_t maxInbox = 1 << 20;

using Clock = std::chrono::steady_clock;

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

LinkClient& LinkClient::retain ()
{
    std::lock_guard<std::mutex> lock (sharedMutex);
    if (sharedCount++ == 0)
        shared = new LinkClient ();
    return *shared;
}

void LinkClient::release ()
{
    LinkClient* gone = nullptr;
    {
        std::lock_guard<std::mutex> lock (sharedMutex);
        if (--sharedCount == 0)
        {
            gone = shared;
            shared = nullptr;
        }
    }
    delete gone;
}

LinkClient::LinkClient ()
{
    thread_ = std::thread ([this] { run (); });
}

LinkClient::~LinkClient ()
{
    {
        std::lock_guard<std::mutex> lock (mutex_);
        stop_ = true;
    }
    wake_.notify_all ();
    if (thread_.joinable ())
        thread_.join ();
}

void LinkClient::publish (const std::string& key, std::string message)
{
    {
        std::lock_guard<std::mutex> lock (mutex_);
        auto& kept = states_[key];
        if (kept == message)
            return;
        kept = message;
        if (fd_.load () >= 0 && !sendAll_)
            outbox_.push_back (std::move (message));
    }
    wake_.notify_all ();
}

void LinkClient::retract (const std::string& key, std::string message)
{
    {
        std::lock_guard<std::mutex> lock (mutex_);
        states_.erase (key);
        if (fd_.load () >= 0 && !sendAll_)
            outbox_.push_back (std::move (message));
    }
    wake_.notify_all ();
}

void LinkClient::answer (const char* type, const std::string& document, const char* kind, const std::string& id, const char* key,
                         const std::string& value)
{
    JsonWriter w;
    w.object ().field ("t", type).field ("document", document).field (kind, id).field (key, value).endObject ();
    send (w.text ());
}

void LinkClient::progress (const std::string& document, const char* kind, const std::string& id, double done)
{
    JsonWriter w;
    w.object ().field ("t", "progress").field ("document", document).field (kind, id).field ("done", done).endObject ();
    send (w.text ());
}

void LinkClient::send (std::string message)
{
    {
        std::lock_guard<std::mutex> lock (mutex_);
        if (fd_.load () < 0)
            return;
        outbox_.push_back (std::move (message));
    }
    wake_.notify_all ();
}

void LinkClient::setTransport (bool playing, double seconds, double quarters, double tempo) noexcept
{
    if (playing_.load (std::memory_order_relaxed) == playing && seconds_.load (std::memory_order_relaxed) == seconds &&
        quarters_.load (std::memory_order_relaxed) == quarters && tempo_.load (std::memory_order_relaxed) == tempo)
        return;
    playing_.store (playing, std::memory_order_relaxed);
    seconds_.store (seconds, std::memory_order_relaxed);
    quarters_.store (quarters, std::memory_order_relaxed);
    tempo_.store (tempo, std::memory_order_relaxed);
    transportStamp_.fetch_add (1, std::memory_order_release);
}

namespace {

std::vector<std::string> linesOf (const std::string& text)
{
    std::vector<std::string> lines;
    size_t at = 0;
    while (!text.empty () && at <= text.size ())
    {
        const size_t end = text.find ('\n', at);
        lines.push_back (text.substr (at, end == std::string::npos ? std::string::npos : end - at));
        if (end == std::string::npos)
            break;
        at = end + 1;
    }
    return lines;
}

}  // namespace

std::string LinkClient::linkedCapturer ()
{
    std::lock_guard<std::mutex> lock (mutex_);
    return linkedCapturer_;
}

void LinkClient::setLinkedCapturer (const std::string& id)
{
    {
        std::lock_guard<std::mutex> lock (mutex_);
        linkedCapturer_ = id;
    }
    JsonWriter w;
    w.object ().field ("t", "link").field ("capturer", id).endObject ();
    publish ("link", w.text ());
}

std::string LinkClient::toldOf (const char* type, const char* key) const
{
    const auto said = told_.find (type);
    const std::string* field = said == told_.end () ? nullptr : fieldOf (said->second, key);
    return field ? *field : std::string ();
}

std::vector<std::pair<std::string, std::string>> LinkClient::inserts ()
{
    std::lock_guard<std::mutex> lock (mutex_);
    const auto ids = linesOf (toldOf ("inserts", "ids")), names = linesOf (toldOf ("inserts", "names"));
    std::vector<std::pair<std::string, std::string>> out;
    for (size_t i = 0; i < ids.size (); ++i)
        out.emplace_back (ids[i], i < names.size () ? names[i] : ids[i]);
    return out;
}

int LinkClient::linked (const std::string& id)
{
    std::lock_guard<std::mutex> lock (mutex_);
    if (!told_.count ("linked") || fd_.load () < 0)
        return -1;
    for (const auto& linked : linesOf (toldOf ("linked", "ids")))
    {
        if (linked == id)
            return 1;
    }
    return 0;
}

std::string LinkClient::followers ()
{
    std::lock_guard<std::mutex> lock (mutex_);
    return toldOf ("followers", "names");
}

int LinkClient::listen (std::function<void (const Message&)> handler)
{
    std::lock_guard<std::mutex> lock (handlersMutex_);
    const int id = nextHandler_++;
    handlers_[id] = std::move (handler);
    return id;
}

void LinkClient::unlisten (int id)
{
    std::lock_guard<std::mutex> lock (handlersMutex_);
    handlers_.erase (id);
}

std::string LinkClient::transportMessage ()
{
    JsonWriter w;
    w.object ()
        .field ("t", "transport")
        .field ("playing", playing_.load (std::memory_order_relaxed))
        .field ("seconds", seconds_.load (std::memory_order_relaxed))
        .field ("quarters", quarters_.load (std::memory_order_relaxed))
        .field ("tempo", tempo_.load (std::memory_order_relaxed))
        .endObject ();
    return w.text ();
}

bool LinkClient::tryConnect ()
{
    // Curator writes where it listens when it starts, and removes the file when it quits.
    std::ifstream file (curatorDataFolder () + "/daw-link.json");
    if (!file)
        return false;
    std::stringstream text;
    text << file.rdbuf ();
    Message found;
    if (!readFlatObject (text.str (), found))
        return false;
    const long port = std::strtol (found["port"].c_str (), nullptr, 10);
    if (port <= 0 || port > 65535 || found["token"].empty ())
        return false;
    // A Curator that went without removing its file (it crashed): its port may be another
    // program's by now, which would be told the token and held as Curator for good.
    const long curator = std::strtol (found["pid"].c_str (), nullptr, 10);
    if (curator > 0 && ::kill (static_cast<pid_t> (curator), 0) != 0 && errno == ESRCH)
        return false;

    const int fd = ::socket (AF_INET, SOCK_STREAM, 0);
    if (fd < 0)
        return false;
#if defined(SO_NOSIGPIPE)
    int on = 1;
    ::setsockopt (fd, SOL_SOCKET, SO_NOSIGPIPE, &on, sizeof on);
#endif
    int noDelay = 1;
    ::setsockopt (fd, IPPROTO_TCP, TCP_NODELAY, &noDelay, sizeof noDelay);
    // A Curator that stops reading (paused in a debugger) mustn't hold this thread for long.
    timeval timeout { 2, 0 };
    ::setsockopt (fd, SOL_SOCKET, SO_SNDTIMEO, &timeout, sizeof timeout);

    sockaddr_in address {};
    address.sin_family = AF_INET;
    address.sin_port = htons (static_cast<uint16_t> (port));
    address.sin_addr.s_addr = htonl (INADDR_LOOPBACK);
    if (::connect (fd, reinterpret_cast<sockaddr*> (&address), sizeof address) != 0)
    {
        ::close (fd);
        return false;
    }

    curatorBuild_.store (static_cast<int> (std::strtol (found["build"].c_str (), nullptr, 10)));
    std::lock_guard<std::mutex> lock (mutex_);
    token_ = found["token"];
    inbox_.clear ();
    outbox_.clear ();
    sendAll_ = true;
    sentStamp_ = transportStamp_.load () - 1;  // where the DAW is, said at once
    fd_.store (fd);
    return true;
}

void LinkClient::disconnect ()
{
    const int fd = fd_.exchange (-1);
    if (fd >= 0)
        ::close (fd);
    std::lock_guard<std::mutex> lock (mutex_);
    told_.clear ();
    outbox_.clear ();
}

bool LinkClient::sendLine (const std::string& line)
{
    const int fd = fd_.load ();
    if (fd < 0)
        return false;
    std::string data = line;
    data += '\n';
    size_t sent = 0;
    while (sent < data.size ())
    {
#if defined(MSG_NOSIGNAL)
        const ssize_t n = ::send (fd, data.data () + sent, data.size () - sent, MSG_NOSIGNAL);
#else
        const ssize_t n = ::send (fd, data.data () + sent, data.size () - sent, 0);
#endif
        if (n < 0 && errno == EINTR)
            continue;
        if (n <= 0)
            return false;
        sent += static_cast<size_t> (n);
    }
    return true;
}

void LinkClient::receive ()
{
    const int fd = fd_.load ();
    char buffer[4096];
    const ssize_t n = ::recv (fd, buffer, sizeof buffer, 0);
    if (n < 0 && errno == EINTR)
        return;
    if (n <= 0)
    {
        disconnect ();
        return;
    }
    inbox_.append (buffer, static_cast<size_t> (n));
    size_t end;
    while ((end = inbox_.find ('\n')) != std::string::npos)
    {
        const std::string line = inbox_.substr (0, end);
        inbox_.erase (0, end + 1);
        Message message;
        if (!readFlatObject (line, message))
            continue;
        // A state told: kept, for what asks after it.
        if (const std::string* t = fieldOf (message, "t"); t && (*t == "followers" || *t == "linked" || *t == "inserts"))
        {
            std::lock_guard<std::mutex> lock (mutex_);
            told_[*t] = std::move (message);
            continue;
        }
        std::lock_guard<std::mutex> lock (handlersMutex_);
        for (auto& handler : handlers_)
            handler.second (message);
    }
    if (inbox_.size () > maxInbox)
        disconnect ();
}

void LinkClient::run ()
{
    Clock::time_point nextTry {};
    Clock::time_point lastTransport {};
    const std::string host = processName ();
    while (true)
    {
        // Told to stop, what is waiting is still sent (a document's "closed" as it goes).
        bool stopping;
        {
            std::lock_guard<std::mutex> lock (mutex_);
            stopping = stop_;
        }

        if (fd_.load () < 0)
        {
            if (stopping)
                break;
            if (Clock::now () >= nextTry)
            {
                nextTry = Clock::now () + std::chrono::seconds (1);
                tryConnect ();
            }
            if (fd_.load () < 0)
            {
                std::unique_lock<std::mutex> lock (mutex_);
                wake_.wait_for (lock, std::chrono::milliseconds (200), [this] { return stop_; });
                continue;
            }
        }

        std::deque<std::string> lines;
        {
            std::lock_guard<std::mutex> lock (mutex_);
            if (sendAll_)
            {
                JsonWriter hello;
                hello.object ()
                    .field ("t", "hello")
                    .field ("protocol", static_cast<double> (LINK_PROTOCOL))
                    .field ("token", token_)
                    .field ("plugin", LINK_VERSION)
                    .field ("build", static_cast<double> (LINK_BUILD))
                    .field ("host", host)
                    .field ("pid", static_cast<double> (::getpid ()))
                    .endObject ();
                lines.push_back (hello.text ());
                for (auto& state : states_)
                    lines.push_back (state.second);
                outbox_.clear ();
                sendAll_ = false;
            }
            else
            {
                lines.swap (outbox_);
            }
        }
        bool ok = true;
        for (auto& line : lines)
        {
            if (!(ok = sendLine (line)))
                break;
        }
        if (stopping)
            break;

        const uint32_t stamp = transportStamp_.load (std::memory_order_acquire);
        if (ok && stamp != sentStamp_ && Clock::now () - lastTransport >= std::chrono::milliseconds (33))
        {
            ok = sendLine (transportMessage ());
            sentStamp_ = stamp;
            lastTransport = Clock::now ();
        }
        if (!ok)
        {
            disconnect ();
            continue;
        }

        pollfd p { fd_.load (), POLLIN, 0 };
        if (p.fd >= 0 && ::poll (&p, 1, 15) > 0)
        {
            if (p.revents & (POLLIN | POLLHUP | POLLERR))
                receive ();
        }
    }
    disconnect ();
}

}  // namespace attacca
