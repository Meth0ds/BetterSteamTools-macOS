#include "MacLuaSupport.h"
#include <sys/stat.h>
#include <fcntl.h>
#include <unistd.h>
#include <cerrno>
#include <chrono>
#include <cstring>
#include <mutex>

namespace BST::Mac::LuaSupport {
namespace {
struct Budget { uint64_t remaining = 50'000'000; std::chrono::steady_clock::time_point deadline = std::chrono::steady_clock::now() + std::chrono::seconds(10); Budget* previous = nullptr; };
thread_local Budget* active = nullptr;
std::mutex diagnosticMutex;
std::vector<Diagnostic> diagnostics;
void countInstructions(lua_State* state, lua_Debug*) {
    if (!active) return;
    if (active->remaining < 10'000 || std::chrono::steady_clock::now() > active->deadline) {
        luaL_error(state, "Lua execution limit exceeded"); return;
    }
    active->remaining -= 10'000;
}
}
ExecutionBudget::ExecutionBudget(lua_State* state): state_(state), previous_(lua_gethook(state)), previousMask_(lua_gethookmask(state)), previousCount_(lua_gethookcount(state)) {
    auto* budget = new Budget; budget->previous = active; active = budget; budget_ = budget;
    lua_sethook(state, countInstructions, LUA_MASKCOUNT, 10'000);
}
ExecutionBudget::~ExecutionBudget() {
    lua_sethook(state_, previous_, previousMask_, previousCount_);
    auto* budget = static_cast<Budget*>(budget_); active = budget->previous; delete budget;
}
void Report(const std::string& file, const char* message) {
    std::lock_guard lock(diagnosticMutex);
    if (diagnostics.size() >= 64) return;
    diagnostics.push_back({file, message ? std::string(message).substr(0, 4096) : "Unknown Lua error"});
}
std::vector<Diagnostic> TakeDiagnostics() {
    std::lock_guard lock(diagnosticMutex);
    auto result = std::move(diagnostics); diagnostics.clear(); return result;
}
bool ExecuteFile(lua_State* state, const std::filesystem::path& path) {
    const int descriptor = open(path.c_str(), O_RDONLY | O_CLOEXEC | O_NOFOLLOW);
    if (descriptor < 0) { Report(path.string(), std::strerror(errno)); return false; }
    struct Close { int descriptor; ~Close() { close(descriptor); } } closeFile{descriptor};
    struct stat info{};
    if (fstat(descriptor, &info) || !S_ISREG(info.st_mode) || info.st_size < 0 || info.st_size > 16 * 1024 * 1024) {
        Report(path.string(), "Lua configuration must be a regular file no larger than 16 MiB"); return false;
    }
    std::string text(static_cast<size_t>(info.st_size), '\0');
    size_t offset = 0;
    while (offset < text.size()) {
        const auto count = read(descriptor, text.data() + offset, text.size() - offset);
        if (count < 0 && errno == EINTR) continue;
        if (count <= 0) { Report(path.string(), "Lua file changed or could not be read"); return false; }
        offset += static_cast<size_t>(count);
    }
    lua_settop(state, 0);
    ExecutionBudget budget(state);
    if (luaL_loadbufferx(state, text.data(), text.size(), path.c_str(), "t") != LUA_OK || lua_pcall(state, 0, 0, 0) != LUA_OK) {
        Report(path.string(), lua_tostring(state, -1)); lua_settop(state, 0); return false;
    }
    return true;
}
}
