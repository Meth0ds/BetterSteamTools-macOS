#include "include/DirectoryWatch.h"
#include <CoreServices/CoreServices.h>
#include <dispatch/dispatch.h>
#include <sys/stat.h>
#include <poll.h>
#include <fcntl.h>
#include <unistd.h>
#include <cerrno>
#include <chrono>
#include <filesystem>
#include <map>
#include <mutex>
#include <utility>

namespace OSTPlatform::DirectoryWatch {
namespace {
struct Stamp {
    uint64_t inode, size;
    timespec modified, changed;
    bool operator==(const Stamp& b) const {
        return inode == b.inode && size == b.size && modified.tv_sec == b.modified.tv_sec && modified.tv_nsec == b.modified.tv_nsec && changed.tv_sec == b.changed.tv_sec && changed.tv_nsec == b.changed.tv_nsec;
    }
};
using Snapshot = std::map<std::string, Stamp>;
Snapshot scan(const std::string& directory) {
    Snapshot result;
    std::error_code error;
    for (std::filesystem::directory_iterator cursor(directory, error), end; !error && cursor != end; cursor.increment(error)) {
        struct stat info{};
        if (lstat(cursor->path().c_str(), &info) != 0 || !S_ISREG(info.st_mode)) continue;
        result.emplace(cursor->path().filename().string(), Stamp{info.st_ino, static_cast<uint64_t>(info.st_size), info.st_mtimespec, info.st_ctimespec});
    }
    return result;
}
}
struct Watch::Impl {
    std::string directory;
    FSEventStreamRef stream = nullptr;
    dispatch_queue_t queue = nullptr;
    int signal[2] = {-1, -1};
    std::mutex mutex;
    Snapshot snapshot;
    std::map<std::string, ChangeAction> pending;
    bool armed = false;
    ~Impl() { Close(); }
    void Rescan() {
        std::lock_guard guard(mutex);
        auto next = scan(directory);
        for (const auto& [name, stamp] : snapshot) {
            const auto found = next.find(name);
            if (found == next.end()) pending[name] = ChangeAction::Removed;
            else if (!(stamp == found->second)) pending[name] = ChangeAction::Modified;
        }
        for (const auto& [name, stamp] : next) { if (!snapshot.contains(name)) pending[name] = ChangeAction::Added; }
        snapshot = std::move(next);
        if (!pending.empty() && armed && signal[1] >= 0) {
            const unsigned char event = 1;
            // A full nonblocking pipe already represents a pending notification.
            ssize_t ignored = write(signal[1], &event, 1); (void)ignored;
        }
    }
    static void Callback(ConstFSEventStreamRef, void *context, size_t, void*, const FSEventStreamEventFlags[], const FSEventStreamEventId[]) {
        static_cast<Impl*>(context)->Rescan();
    }
    void Close() {
        if (stream) {
            FSEventStreamStop(stream);
            FSEventStreamInvalidate(stream);
            FSEventStreamRelease(stream);
            stream = nullptr;
        }
        if (queue) { dispatch_sync(queue, ^{}); queue = nullptr; }
        std::lock_guard guard(mutex);
        for (auto& fd : signal) { if (fd >= 0) close(fd); fd = -1; }
        directory.clear(); snapshot.clear(); pending.clear(); armed = false;
    }
};
Watch::Watch() : impl_(std::make_unique<Impl>()) {}
Watch::~Watch() = default;
Watch::Watch(Watch&&) noexcept = default;
Watch& Watch::operator=(Watch&&) noexcept = default;
bool Watch::Open(const std::string& directory, uint32_t bufferSize) {
    (void)bufferSize; // Events are coalesced by filename instead of using a fixed byte buffer.
    if (!impl_) impl_ = std::make_unique<Impl>();
    impl_->Close();
    std::error_code error;
    auto path = std::filesystem::canonical(directory, error);
    if (error || !std::filesystem::is_directory(path, error)) return false;
    impl_->directory = path.string();
    if (pipe(impl_->signal) != 0) { impl_->Close(); return false; }
    for (int fd : impl_->signal) {
        if (fcntl(fd, F_SETFL, O_NONBLOCK) == -1 || fcntl(fd, F_SETFD, FD_CLOEXEC) == -1) { impl_->Close(); return false; }
    }
    impl_->snapshot = scan(impl_->directory);
    CFStringRef string = CFStringCreateWithFileSystemRepresentation(kCFAllocatorDefault, impl_->directory.c_str());
    if (!string) { impl_->Close(); return false; }
    const void *item = string;
    CFArrayRef paths = CFArrayCreate(kCFAllocatorDefault, &item, 1, &kCFTypeArrayCallBacks);
    CFRelease(string);
    if (!paths) { impl_->Close(); return false; }
    FSEventStreamContext context{0, impl_.get(), nullptr, nullptr, nullptr};
    impl_->stream = FSEventStreamCreate(kCFAllocatorDefault, Impl::Callback, &context, paths, kFSEventStreamEventIdSinceNow, 0.05,
        kFSEventStreamCreateFlagFileEvents | kFSEventStreamCreateFlagNoDefer | kFSEventStreamCreateFlagWatchRoot);
    CFRelease(paths);
    if (!impl_->stream) { impl_->Close(); return false; }
    impl_->queue = dispatch_queue_create("com.bettersteamtools.directory-watch", DISPATCH_QUEUE_SERIAL);
    FSEventStreamSetDispatchQueue(impl_->stream, impl_->queue);
    if (!FSEventStreamStart(impl_->stream)) { impl_->Close(); return false; }
    return true;
}
bool Watch::IssueRead() {
    if (!IsOpen()) return false;
    { std::lock_guard guard(impl_->mutex); impl_->armed = true; }
    impl_->Rescan();
    return true;
}
std::vector<Change> Watch::Drain() {
    if (!IsOpen()) return {};
    std::lock_guard guard(impl_->mutex);
    unsigned char bytes[256];
    while (read(impl_->signal[0], bytes, sizeof bytes) > 0) {}
    std::vector<Change> changes;
    for (auto& [path, action] : impl_->pending) changes.push_back({path, action});
    impl_->pending.clear();
    return changes;
}
void Watch::Cancel() { if (impl_) impl_->Close(); }
bool Watch::IsOpen() const { return impl_ && impl_->stream && impl_->signal[0] >= 0; }
const std::string& Watch::Directory() const { static const std::string empty; return impl_ ? impl_->directory : empty; }
WaitResult WaitAny(std::span<Watch*> watches, uint32_t timeoutMs) {
    std::vector<pollfd> fds;
    std::vector<size_t> indexes;
    for (size_t i = 0; i < watches.size(); ++i) {
        if (!watches[i] || !watches[i]->IsOpen()) continue;
        fds.push_back(pollfd{watches[i]->impl_->signal[0], POLLIN, 0}); indexes.push_back(i);
    }
    if (fds.empty()) return {WaitStatus::Failed, 0};
    const auto deadline = std::chrono::steady_clock::now() + std::chrono::milliseconds(timeoutMs);
    while (true) {
        auto remaining = std::chrono::duration_cast<std::chrono::milliseconds>(deadline - std::chrono::steady_clock::now()).count();
        int result = poll(fds.data(), static_cast<nfds_t>(fds.size()), static_cast<int>(std::min<int64_t>(std::max<int64_t>(0, remaining), INT_MAX)));
        if (result == 0) return {WaitStatus::Timeout, 0};
        if (result < 0) { if (errno == EINTR) continue; return {WaitStatus::Failed, 0}; }
        for (size_t i = 0; i < fds.size(); ++i) {
            if (fds[i].revents & POLLIN) return {WaitStatus::Signaled, indexes[i]};
            if (fds[i].revents & (POLLHUP | POLLERR | POLLNVAL)) return {WaitStatus::Failed, indexes[i]};
        }
    }
}
}
