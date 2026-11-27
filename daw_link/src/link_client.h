// Attacca's line to Curator: one per process, shared by every document and instance in it.
#pragma once

#include <atomic>
#include <condition_variable>
#include <cstdint>
#include <cstdlib>
#include <deque>
#include <functional>
#include <map>
#include <memory>
#include <mutex>
#include <string>
#include <thread>
#include <utility>
#include <vector>

namespace attacca {

// What Curator says, a message's top-level fields (see readFlatObject).
using Message = std::map<std::string, std::string>;

// [message]'s field [key]; null when it hasn't one.
inline const std::string* fieldOf (const Message& message, const char* key)
{
    const auto found = message.find (key);
    return found == message.end () ? nullptr : &found->second;
}

// [message]'s field [key] as a number; [otherwise] when it hasn't one.
inline double numberOf (const Message& message, const char* key, double otherwise)
{
    const std::string* field = fieldOf (message, key);
    return field ? std::strtod (field->c_str (), nullptr) : otherwise;
}

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

    // To Curator about what it asked of [document], the [kind] [id] ("source", "track",
    // "capturer"): what came of it, {t: [type], [key]: [value]} ("path", or "error" and why),
    // and how far it has got, {t: "progress", done: 0–1}.
    void answer (const char* type, const std::string& document, const char* kind, const std::string& id, const char* key, const std::string& value);
    void progress (const std::string& document, const char* kind, const std::string& id, double done);

    // Where the DAW is: from the audio thread, lock-free.
    void setTransport (bool playing, double seconds, double quarters, double tempo) noexcept;

    // Calls [handler] with each message Curator sends, on the connection's thread, and with
    // {t: "disconnected"} when the connection ends (what Curator asked is no longer awaited).
    // No lock is held while it runs: it may listen, send, or let go of itself or another. After
    // unlisten returns the handler isn't called again; on any other thread it waits for a call
    // under way to end (so its owner may go), on the connection's own (from inside a handler) it
    // doesn't, the call going on. So a handler asks nothing of the DAW, which may wait on its
    // main thread while that thread lets go of the handler: it only notes what to do there.
    int listen (std::function<void (const Message&)> handler);
    void unlisten (int id);

    // Whether Curator is connected now.
    bool connected () const noexcept { return fd_.load () >= 0; }

    // The Curator projects following this DAW, as Curator last said (`followers`: one name a
    // line); empty while none is or Curator isn't connected.
    std::string followers ();

    // The version of the Attacca Curator bundles, as its discovery file says (`build`; 0: one
    // that doesn't say). A plug-in older than it (LINK_VERSION) is outdated. (A Curator from
    // before Attacca had a version of its own says its own build: lower than any such version.)
    int bundledVersion () const noexcept { return bundledVersion_.load (); }

    // Attacca's side: the Attacca Capturer linked to this DAW's Attacca (its ID; empty: none),
    // chosen in Attacca's window and kept in its instances' state. Published as `link`, and so
    // told Curator again on each connection.
    std::string linkedCapturer ();
    void setLinkedCapturer (const std::string& id);

    // Attacca's side: the Attacca Capturers in this DAW, as Curator last said (`inserts`: their
    // IDs and names), for its window's Capturer menu; empty while Curator isn't connected.
    std::vector<std::pair<std::string, std::string>> inserts ();

    // A Capturer's side: whether the Capturer [id] is linked to an Attacca in this DAW with a
    // document, as Curator last said (`linked`): 1 or 0; -1 while it hasn't said or isn't
    // connected. (The two may be in bundles of their own: Curator matches them.)
    int linked (const std::string& id);

private:
    LinkClient ();
    ~LinkClient ();
    void run ();
    bool tryConnect ();
    void disconnect ();
    bool sendLine (const std::string& line);
    void receive ();
    // [message] to every handler there is as it comes, with no lock held (see listen); one let
    // go of meanwhile is passed over. On the connection's thread alone.
    void deliver (const Message& message);
    std::string transportMessage ();

    std::thread thread_;
    std::mutex mutex_;
    std::condition_variable wake_;
    bool stop_ { false };

    std::atomic<std::intptr_t> fd_ { -1 };  // the socket (net::Socket); -1: none
    std::atomic<int> bundledVersion_ { 0 };
    std::string linkedCapturer_;
    // What Curator last told of a state, by the message's type (`followers`, `linked`,
    // `inserts`: told); none while it hasn't, or isn't connected.
    std::map<std::string, Message> told_;
    // A field of what was told of [type]; empty when it wasn't. Under [mutex_].
    std::string toldOf (const char* type, const char* key) const;
    std::string token_;
    bool sendAll_ { false };
    std::map<std::string, std::string> states_;
    std::deque<std::string> outbox_;
    std::string inbox_;

    // The handlers by ID (never one again), each kept alive by the delivery calling it, should it
    // be let go of meanwhile; and the one being called now (0: none), which unlisten waits for.
    using Handler = std::function<void (const Message&)>;
    std::mutex handlersMutex_;
    std::condition_variable handlerDone_;
    std::map<int, std::shared_ptr<const Handler>> handlers_;
    int nextHandler_ { 1 };
    int calling_ { 0 };

    std::atomic<bool> playing_ { false };
    std::atomic<double> seconds_ { 0 };
    std::atomic<double> quarters_ { 0 };
    std::atomic<double> tempo_ { 0 };
    std::atomic<uint32_t> transportStamp_ { 0 };
    uint32_t sentStamp_ { 0 };
};

}  // namespace attacca
