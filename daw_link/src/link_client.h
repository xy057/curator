// Curator Link's line to Curator: one per process, shared by every document and instance in it.
#pragma once

#include <atomic>
#include <condition_variable>
#include <cstdint>
#include <deque>
#include <functional>
#include <map>
#include <mutex>
#include <string>
#include <thread>

namespace curator_link {

// What Curator says, a message's top-level fields (see readFlatObject).
using Message = std::map<std::string, std::string>;

// The connection to Curator, kept up on a thread of its own: Curator listens on the loopback
// address at the port its discovery file names (daw-link.json in its data folder, with a token
// the plug-in says back), and the plug-in connects to it, again every second while it isn't
// there. Messages are JSON objects, one a line.
//
// Documents publish their state by a key: the latest is kept and sent again whenever Curator
// connects, so Curator always holds every document there is. Transport (where the DAW is
// playing) is set from the audio thread without a lock and sent at most 30 times a second.
class LinkClient {
public:
    // Held by each document controller and plug-in instance; the thread runs while one holds it
    // and is stopped and joined when the last lets go (before the bundle can be unloaded).
    static LinkClient& retain ();
    static void release ();

    // [message] is the state of [key]: sent now, and again on each new connection.
    void publish (const std::string& key, std::string message);
    // [key] has gone: [message] says so, and nothing is sent for it again.
    void retract (const std::string& key, std::string message);
    // Sent now if Curator is there, else dropped.
    void send (std::string message);

    // Where the DAW is: from the audio thread, lock-free.
    void setTransport (bool playing, double seconds, double quarters, double tempo) noexcept;

    // Calls [handler] with each message Curator sends, on the connection's thread. After
    // unlisten returns, the handler isn't running and won't be called again.
    int listen (std::function<void (const Message&)> handler);
    void unlisten (int id);

    // Whether Curator is connected now.
    bool connected () const noexcept { return fd_.load () >= 0; }

private:
    LinkClient ();
    ~LinkClient ();
    void run ();
    bool tryConnect ();
    void disconnect ();
    bool sendLine (const std::string& line);
    void receive ();
    std::string transportMessage ();

    std::thread thread_;
    std::mutex mutex_;
    std::condition_variable wake_;
    bool stop_ { false };

    std::atomic<int> fd_ { -1 };
    std::string token_;
    bool sendAll_ { false };
    std::map<std::string, std::string> states_;
    std::deque<std::string> outbox_;
    std::string inbox_;

    std::mutex handlersMutex_;
    std::map<int, std::function<void (const Message&)>> handlers_;
    int nextHandler_ { 1 };

    std::atomic<bool> playing_ { false };
    std::atomic<double> seconds_ { 0 };
    std::atomic<double> quarters_ { 0 };
    std::atomic<double> tempo_ { 0 };
    std::atomic<uint32_t> transportStamp_ { 0 };
    uint32_t sentStamp_ { 0 };
};

// Curator's data folder (AppFolders.data) and cache folder (AppFolders.cache) on this system.
std::string curatorDataFolder ();
std::string curatorCacheFolder ();

}  // namespace curator_link
