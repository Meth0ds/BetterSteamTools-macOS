#include "include/DynamicLibrary.h"
#include "include/Encoding.h"
#include "include/Hash.h"
#include "include/Http.h"
#include "include/DirectoryWatch.h"
#include "include/Memory.h"
#include "include/Process.h"
#include <sys/mman.h>
#include <filesystem>
#include <fstream>
#include <chrono>
#include <array>
#include <sys/socket.h>
#include <netinet/in.h>
#include <unistd.h>
#include <iostream>
#include <thread>
#include <stdexcept>

static void check(bool value, const char *message) { if (!value) throw std::runtime_error(message); }
static OSTPlatform::Http::Result request(const std::string& response, uint32_t cap) {
    const int server = socket(AF_INET, SOCK_STREAM, 0);
    check(server >= 0, "socket");
    sockaddr_in address{}; address.sin_family = AF_INET; address.sin_addr.s_addr = htonl(INADDR_LOOPBACK);
    check(bind(server, reinterpret_cast<sockaddr*>(&address), sizeof address) == 0, "bind");
    socklen_t length = sizeof address;
    check(getsockname(server, reinterpret_cast<sockaddr*>(&address), &length) == 0, "getsockname");
    check(listen(server, 1) == 0, "listen");
    std::thread service([=] {
        int client = accept(server, nullptr, nullptr);
        if (client >= 0) {
            char buffer[4096]; recv(client, buffer, sizeof buffer, 0);
            // MSG_NOSIGNAL is unavailable on Darwin: SO_NOSIGPIPE avoids process termination
            // if the client cancels an over-limit response.
            int one = 1; setsockopt(client, SOL_SOCKET, SO_NOSIGPIPE, &one, sizeof one);
            send(client, response.data(), response.size(), 0); close(client);
        }
        close(server);
    });
    std::string url = "http://127.0.0.1:" + std::to_string(ntohs(address.sin_port)) + "/";
    auto result = OSTPlatform::Http::Execute(L"GET", url.c_str(), nullptr, 0, nullptr, 500, 500, 500, 500, cap);
    service.join(); return result;
}
static void testDirectoryWatch() {
    namespace DW = OSTPlatform::DirectoryWatch;
    char templatePath[] = "/tmp/bst-watch-test-XXXXXX";
    const char *created = mkdtemp(templatePath);
    check(created != nullptr, "temporary watch directory");
    const std::filesystem::path root(created);
    struct Cleanup { std::filesystem::path path; ~Cleanup() { std::error_code error; std::filesystem::remove_all(path, error); } } cleanup{root};
    DW::Watch watch;
    check(watch.Open(root.string(), 4096) && watch.IssueRead(), "open FSEvents stream");
    std::array<DW::Watch*, 2> watches{nullptr, &watch};
    auto wait = [&](const std::string& name, DW::ChangeAction action) {
        const auto deadline = std::chrono::steady_clock::now() + std::chrono::seconds(5);
        while (std::chrono::steady_clock::now() < deadline) {
            const auto result = DW::WaitAny(watches, 100);
            if (result.status == DW::WaitStatus::Signaled) {
                check(result.index == 1, "WaitAny preserves original watch index");
                for (const auto& change : watch.Drain()) { if (change.relativePath == name && change.action == action) return; }
                check(watch.IssueRead(), "rearm watcher");
            }
        }
        throw std::runtime_error("FSEvents did not report " + name);
    };
    { std::ofstream(root / "42.lua") << "first"; }
    wait("42.lua", DW::ChangeAction::Added);
    { std::ofstream(root / "42.lua", std::ios::app) << "changed"; }
    wait("42.lua", DW::ChangeAction::Modified);
    std::filesystem::remove(root / "42.lua");
    wait("42.lua", DW::ChangeAction::Removed);
    check(DW::WaitAny(watches, 20).status == DW::WaitStatus::Timeout, "idle watcher times out");
    DW::Watch moved = std::move(watch);
    check(moved.IsOpen() && !watch.IsOpen(), "moving watcher preserves stream ownership");
    moved.Cancel(); check(!moved.IsOpen(), "cancel closes stream");
}
int main() {
    try {
        check(OSTPlatform::Hash::Sha256OfBuffer("abc", 3) == "ba7816bf8f01cfea414140de5dae2223b00361a396177a9cb410ff61f20015ad", "SHA-256 known vector");
        std::string text = "Español 🎮 日本語";
        check(OSTPlatform::Encoding::WideToUtf8(OSTPlatform::Encoding::Utf8ToWide(text)) == text, "Unicode UTF-8/UTF-32 roundtrip");
        check(OSTPlatform::Encoding::Utf8ToWide(std::string("\xff", 1)).empty(), "malformed UTF-8");
        auto module = OSTPlatform::DynamicLibrary::GetLoaded("libSystem.B.dylib");
        check(module != nullptr, "loaded system library");
        check(OSTPlatform::DynamicLibrary::GetSymbol(module, "getpid") != nullptr, "dlsym exported function");
        check(!OSTPlatform::DynamicLibrary::GetMainExecutablePath().empty(), "main executable path");
        auto image = OSTPlatform::Memory::GetModuleImage(module);
        check(image && image->base && image->size > 0, "Mach-O text image from dlopen handle");
        check(OSTPlatform::Memory::IsReadable(image->base, 32), "readable module text");
        void *memory = mmap(nullptr, 2 * getpagesize(), PROT_READ | PROT_WRITE, MAP_PRIVATE | MAP_ANON, -1, 0);
        check(memory != MAP_FAILED, "memory fixture");
        check(OSTPlatform::Memory::IsReadable(memory, 2 * getpagesize()), "readable cross-region range");
        mprotect(static_cast<char*>(memory) + getpagesize(), getpagesize(), PROT_NONE);
        check(!OSTPlatform::Memory::IsReadable(memory, 2 * getpagesize()), "unreadable neighbour rejected");
        munmap(memory, 2 * getpagesize());
        check(!OSTPlatform::Memory::IsReadable(reinterpret_cast<void*>(UINTPTR_MAX - 1), 8), "overflow range rejected");
        auto response = request("HTTP/1.1 200 OK\r\nContent-Length: 5\r\nConnection: close\r\n\r\nhello", 32);
        check(response.ok && response.status == 200 && response.body == "hello", "NSURLSession success");
        response = request("HTTP/1.1 404 Not Found\r\nContent-Length: 0\r\nConnection: close\r\n\r\n", 32);
        check(response.ok && response.status == 404, "HTTP errors preserve transport success and status");
        response = request("HTTP/1.1 200 OK\r\nContent-Length: 1000\r\nConnection: close\r\n\r\nhello", 4);
        check(!response.ok, "response body bound");
        const auto creation = OSTPlatform::Process::GetCreationTime(getpid());
        check(creation && !OSTPlatform::Process::FormatCreationTime(*creation).empty(), "process creation time");
        check(OSTPlatform::Process::GetImagePath(getpid()).has_value(), "native process image path");
        check(OSTPlatform::Process::GetProcessCommandLine(getpid()).has_value(), "native process arguments");
        check(!OSTPlatform::Process::EnumerateModules(getpid()).empty(), "native dyld module enumeration");
        check(OSTPlatform::Process::IsSystemModulePath("/usr/lib/libSystem.B.dylib"), "system module prefix");
        check(!OSTPlatform::Process::IsSystemModulePath("/System/Library/../../Users/game.dylib"), "normalized system path boundary");
        testDirectoryWatch();
        std::cout << "PASS: native hashes, encoding, dyld and bounded NSURLSession HTTP\n";
    } catch (const std::exception& error) { std::cerr << "FAIL: " << error.what() << '\n'; return 1; }
}
