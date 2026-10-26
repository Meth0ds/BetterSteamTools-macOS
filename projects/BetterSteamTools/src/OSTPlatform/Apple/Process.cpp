#include "include/Process.h"
#include "include/Encoding.h"
#include <libproc.h>
#include <mach-o/dyld.h>
#include <mach-o/loader.h>
#include <sys/sysctl.h>
#include <sys/wait.h>
#include <spawn.h>
#include <fcntl.h>
#include <unistd.h>
#include <chrono>
#include <algorithm>
#include <cerrno>
#include <ctime>
#include <cstring>
#include <limits>
#include <thread>
#include <vector>
extern char **environ;

namespace OSTPlatform::Process {
namespace {
struct Arguments { std::vector<std::string> args, environment; };
std::optional<Arguments> arguments(uint32_t pid) {
    if (!pid || pid > static_cast<uint32_t>(std::numeric_limits<pid_t>::max())) return std::nullopt;
    int maxArgs = 0;
    size_t bytes = sizeof maxArgs;
    int maxQuery[] = {CTL_KERN, KERN_ARGMAX};
    if (sysctl(maxQuery, 2, &maxArgs, &bytes, nullptr, 0) != 0 || maxArgs < static_cast<int>(sizeof(int)) || maxArgs > 16 * 1024 * 1024) return std::nullopt;
    std::vector<char> data(maxArgs);
    bytes = data.size();
    int query[] = {CTL_KERN, KERN_PROCARGS2, static_cast<int>(pid)};
    if (sysctl(query, 3, data.data(), &bytes, nullptr, 0) != 0 || bytes < sizeof(int)) return std::nullopt;
    int argc = 0; memcpy(&argc, data.data(), sizeof argc);
    if (argc < 0 || static_cast<size_t>(argc) > bytes) return std::nullopt;
    size_t offset = sizeof argc;
    auto string = [&]() -> std::optional<std::string> {
        if (offset >= bytes) return std::nullopt;
        const char *end = static_cast<const char*>(memchr(data.data() + offset, '\0', bytes - offset));
        if (!end) return std::nullopt;
        std::string value(data.data() + offset, static_cast<size_t>(end - data.data()) - offset);
        offset = static_cast<size_t>(end - data.data()) + 1;
        return value;
    };
    if (!string()) return std::nullopt; // executable path precedes null padding and argv
    while (offset < bytes && data[offset] == '\0') ++offset;
    Arguments result;
    for (int index = 0; index < argc; ++index) { auto value = string(); if (!value) return std::nullopt; result.args.push_back(std::move(*value)); }
    while (offset < bytes && data[offset] != '\0') { auto value = string(); if (!value) return std::nullopt; result.environment.push_back(std::move(*value)); }
    return result;
}
}
std::optional<uint64_t> GetCreationTime(uint32_t pid) {
    proc_bsdinfo info{};
    if (pid > static_cast<uint32_t>(std::numeric_limits<pid_t>::max()) || proc_pidinfo(static_cast<int>(pid), PROC_PIDTBSDINFO, 0, &info, sizeof info) != sizeof info) return std::nullopt;
    // Keep the public API's FILETIME convention across platforms.
    constexpr uint64_t epoch = 11644473600ULL;
    if (info.pbi_start_tvsec > UINT64_MAX / 10000000ULL - epoch) return std::nullopt;
    return (info.pbi_start_tvsec + epoch) * 10000000ULL + info.pbi_start_tvusec * 10ULL;
}
std::string FormatCreationTime(uint64_t fileTime) {
    constexpr uint64_t epoch = 11644473600ULL;
    if (fileTime / 10000000ULL < epoch) return {};
    const time_t value = static_cast<time_t>(fileTime / 10000000ULL - epoch);
    tm local{};
    if (!localtime_r(&value, &local)) return {};
    char buffer[64];
    return strftime(buffer, sizeof buffer, "%Y-%m-%d %H:%M:%S", &local) ? buffer : "";
}
std::optional<std::string> GetImagePath(uint32_t pid) {
    if (!pid || pid > static_cast<uint32_t>(std::numeric_limits<pid_t>::max())) return std::nullopt;
    std::vector<char> buffer(PROC_PIDPATHINFO_MAXSIZE);
    int count = proc_pidpath(static_cast<int>(pid), buffer.data(), static_cast<uint32_t>(buffer.size()));
    if (count <= 0) return std::nullopt;
    return std::string(buffer.data());
}
std::optional<std::string> GetEnvironmentVariableValue(uint32_t pid, std::wstring_view name) {
    const auto key = Encoding::WideToUtf8(name);
    if (key.empty() || key.find('=') != std::string::npos) return std::nullopt;
    const auto values = arguments(pid);
    if (!values) return std::nullopt;
    const std::string prefix = key + "=";
    for (const auto& item : values->environment) { if (item.starts_with(prefix)) return item.substr(prefix.size()); }
    return std::nullopt;
}
std::optional<std::string> GetProcessCommandLine(uint32_t pid) {
    const auto values = arguments(pid);
    if (!values) return std::nullopt;
    std::string result;
    for (const auto& argument : values->args) {
        if (!result.empty()) result += ' ';
        result += '\'';
        for (char character : argument) { if (character == '\'') result += "'\\''"; else result += character; }
        result += '\'';
    }
    return result;
}
std::vector<ModuleInfo> EnumerateModules(uint32_t pid) {
    // Foreign tasks need an explicitly granted Mach task port. This API has no
    // such capability, so it never probes another process behind that boundary.
    if (pid != static_cast<uint32_t>(getpid())) return {};
    std::vector<ModuleInfo> result;
    for (uint32_t index = 0; index < _dyld_image_count(); ++index) {
        const char *name = _dyld_get_image_name(index);
        const auto *header = _dyld_get_image_header(index);
        if (!name || !header || header->magic != MH_MAGIC_64) continue;
        const auto *image = reinterpret_cast<const mach_header_64*>(header);
        const auto *commands = reinterpret_cast<const unsigned char*>(image + 1);
        uint64_t size = 0;
        size_t offset = 0;
        for (uint32_t commandIndex = 0; commandIndex < image->ncmds; ++commandIndex) {
            if (offset > image->sizeofcmds || image->sizeofcmds - offset < sizeof(load_command)) break;
            const auto *command = reinterpret_cast<const load_command*>(commands + offset);
            if (command->cmdsize < sizeof(load_command) || command->cmdsize > image->sizeofcmds - offset) break;
            if (command->cmd == LC_SEGMENT_64 && command->cmdsize >= sizeof(segment_command_64)) {
                const auto *segment = reinterpret_cast<const segment_command_64*>(command);
                if (segment->initprot) size += segment->vmsize;
            }
            offset += command->cmdsize;
        }
        result.push_back(ModuleInfo{name, std::filesystem::path(name), static_cast<uint32_t>(std::min<uint64_t>(size, UINT32_MAX)), image->filetype == MH_EXECUTE});
    }
    return result;
}
bool IsSystemModulePath(const std::string& path) {
    // Lexically normalize before the boundary check; prefixes like /Systematic
    // or /System/Library/../../Users are not OS-supplied modules.
    const auto canonical = std::filesystem::path(path).lexically_normal().string();
    return canonical.starts_with("/System/Library/") || canonical.starts_with("/usr/lib/");
}
bool LaunchDetachedHidden(const std::string& commandLine) {
    if (commandLine.empty() || commandLine.find('\0') != std::string::npos) return false;
    posix_spawnattr_t attributes;
    posix_spawn_file_actions_t files;
    if (posix_spawnattr_init(&attributes) != 0) return false;
    if (posix_spawn_file_actions_init(&files) != 0) { posix_spawnattr_destroy(&attributes); return false; }
    short flags = POSIX_SPAWN_SETPGROUP;
#ifdef POSIX_SPAWN_SETSID
    flags = POSIX_SPAWN_SETSID;
#endif
    bool valid = posix_spawnattr_setflags(&attributes, flags) == 0;
    if (flags == POSIX_SPAWN_SETPGROUP) valid = valid && posix_spawnattr_setpgroup(&attributes, 0) == 0;
    for (int fd = 0; fd <= 2; ++fd) valid = valid && posix_spawn_file_actions_addopen(&files, fd, "/dev/null", fd ? O_WRONLY : O_RDONLY, 0) == 0;
    char *args[] = {const_cast<char*>("sh"), const_cast<char*>("-c"), const_cast<char*>(commandLine.c_str()), nullptr};
    pid_t child = 0;
    const int spawned = valid ? posix_spawn(&child, "/bin/sh", &files, &attributes, args, environ) : -1;
    posix_spawn_file_actions_destroy(&files); posix_spawnattr_destroy(&attributes);
    if (spawned != 0) return false;
    try { std::thread([child] { while (waitpid(child, nullptr, 0) == -1 && errno == EINTR) {} }).detach(); }
    catch (...) { /* Child was created; a process-wide SIGCHLD handler may also reap it. */ }
    return true;
}
}
