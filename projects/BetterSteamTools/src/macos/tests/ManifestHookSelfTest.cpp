#include "../MacManifestHook.h"
#include <array>
#include <filesystem>
#include <fstream>
#include <iostream>
#include <stdexcept>
#include <unistd.h>

namespace {
bool check(bool value, const char* message) {
    if (!value) { std::cerr << "FAIL: " << message << '\n'; return false; }
    return true;
}
struct FixtureVector {
    BST::Mac::ManifestEntry* memory;
    uint32_t allocationCount;
    uint32_t growSize;
    uint32_t size;
};
static_assert(offsetof(FixtureVector, size) == 16);
static bool originalResult = true;
static int originalCalls = 0;
bool original(void*, uint32_t, void*, FixtureVector*, FixtureVector*, void*, uint32_t*, bool*) {
    ++originalCalls;
    return originalResult;
}
void testHook() {
    char pattern[] = "/tmp/bst-manifest-hook-XXXXXX";
    const auto* directory = mkdtemp(pattern);
    if (!directory) throw std::runtime_error("create fixture directory");
    const std::filesystem::path root(directory);
    struct Cleanup { std::filesystem::path root; ~Cleanup() { std::error_code ec; std::filesystem::remove_all(root, ec); } } cleanup{root};
    const auto scripts = root / "config/stplug-in";
    std::filesystem::create_directories(scripts);
    { std::ofstream f(root / "opensteamtool.toml"); f << "[stats]\nenable_api = false\n"; if (!f) throw std::runtime_error("write TOML"); }
    { std::ofstream f(scripts / "71.lua"); f << "addappid(71)\nsetManifestid(301, '123456789')\n"; if (!f) throw std::runtime_error("write Lua"); }
    BST::Mac::MacConfiguration configuration;
    if (!configuration.reload(root).ready) throw std::runtime_error("execute real Lua configuration");

    using Function = bool (*)(void*, uint32_t, void*, FixtureVector*, FixtureVector*, void*, uint32_t*, bool*);
    auto** slot = BST::Mac::BuildDepotDependencyOriginalSlot();
    const auto saved = *slot;
    *slot = reinterpret_cast<void*>(&original);
    struct Restore { void** slot; void* saved; ~Restore() { *slot = saved; BST::Mac::DisableConfiguration(); } } restore{slot, saved};
    const auto hook = reinterpret_cast<Function>(BST::Mac::BuildDepotDependencyReplacement());
    std::array<BST::Mac::ManifestEntry, 2> entries{{{301, 71, 7, 70, 0, 0, 0, 0, 0}, {302, 71, 8, 80, 0, 0, 0, 0, 0}}};
    FixtureVector vector{entries.data(), 2, 0, 2};
    if (!check(hook(nullptr, 71, nullptr, &vector, nullptr, nullptr, nullptr, nullptr) && originalCalls == 1 &&
               entries[0].manifestGID == 123456789 && entries[0].manifestSize == 70 && entries[1].manifestGID == 8,
               "hook calls original and applies the actual Lua-published override")) throw std::runtime_error("hook override");
    FixtureVector empty{nullptr, 0, 0, 0};
    if (!check(!hook(nullptr, 71, nullptr, &empty, nullptr, nullptr, nullptr, nullptr), "empty configured depot list is refused") ||
        !check(hook(nullptr, 72, nullptr, &empty, nullptr, nullptr, nullptr, nullptr), "empty unrelated depot list remains unchanged")) throw std::runtime_error("empty vectors");
    FixtureVector invalid{reinterpret_cast<BST::Mac::ManifestEntry*>(1), 1, 0, 1};
    if (!check(hook(nullptr, 71, nullptr, &invalid, nullptr, nullptr, nullptr, nullptr), "unreadable vector memory is not modified") ||
        !check(hook(nullptr, 71, nullptr, reinterpret_cast<FixtureVector*>(1), nullptr, nullptr, nullptr, nullptr), "unreadable vector descriptor is not dereferenced")) throw std::runtime_error("invalid vectors");
    originalResult = false; entries[0].manifestGID = 7;
    if (!check(!hook(nullptr, 71, nullptr, &vector, nullptr, nullptr, nullptr, nullptr) && entries[0].manifestGID == 7,
               "failed original call does not mutate output")) throw std::runtime_error("original failure");
    originalResult = true;
}
}

int main() {
    BST::Mac::ConfigurationSnapshot snapshot;
    snapshot.manifestOverrides.emplace(301, LuaConfig::ManifestOverride{0x1122334455667788ULL, 0});
    snapshot.manifestOverrides.emplace(302, LuaConfig::ManifestOverride{0x8877665544332211ULL, 999});
    std::array<BST::Mac::ManifestEntry, 3> entries{{
        {301, 71, 7, 70, 0, 0, 0, 0, 0},
        {302, 71, 8, 80, 0, 0, 0, 0, 0},
        {303, 71, 9, 90, 0, 0, 0, 0, 0},
    }};
    BST::Mac::ApplyManifestOverrides(snapshot, entries);
    if (!check(entries[0].manifestGID == 0x1122334455667788ULL && entries[0].manifestSize == 70,
               "zero override size preserves Steam's manifest size")) return 1;
    if (!check(entries[1].manifestGID == 0x8877665544332211ULL && entries[1].manifestSize == 999,
               "configured manifest gid and size are replaced")) return 1;
    if (!check(entries[2].manifestGID == 9 && entries[2].manifestSize == 90,
               "unmanaged depots remain untouched")) return 1;
    try { testHook(); } catch (const std::exception& error) { std::cerr << "FAIL: " << error.what() << '\n'; return 1; }
    std::cout << "PASS: native manifest hook, original-call behavior, Lua snapshot and vector validation\n";
    return 0;
}
