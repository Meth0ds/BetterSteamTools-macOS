#include "../SteamClientProbe.h"
#include "OSTPlatform/include/Detour.h"
#include "OSTPlatform/Apple/DetourDiagnostics.h"
#include <dlfcn.h>
#include <atomic>
#include <array>
#include <cstring>
#include <iostream>

static void* original = nullptr;
static void* binaryOriginal = nullptr;
static void* manifestOriginal = nullptr;
// Pass-through only. Never fabricate a Steam user object or license output.
static bool passthrough(void* object, uint32_t app, void* output) {
    using Function = bool (*)(void*, uint32_t, void*);
    const auto function = reinterpret_cast<Function>(std::atomic_ref<void*>(original).load(std::memory_order_acquire));
    return function(object, app, output);
}
static int32_t binaryPassthrough(void* object, uint32_t store, const char* name, void* output, uint32_t capacity) {
    using Function = int32_t (*)(void*, uint32_t, const char*, void*, uint32_t);
    const auto function = reinterpret_cast<Function>(std::atomic_ref<void*>(binaryOriginal).load(std::memory_order_acquire));
    return function(object, store, name, output, capacity);
}
static bool manifestPassthrough(void* userAppManager, uint32_t appID, void* userConfig, void* depotInfo,
                                void* sharedDepotInfo, void* steamApp, uint32_t* buildID, bool* betaFallback) {
    using Function = bool (*)(void*, uint32_t, void*, void*, void*, void*, uint32_t*, bool*);
    const auto function = reinterpret_cast<Function>(std::atomic_ref<void*>(manifestOriginal).load(std::memory_order_acquire));
    return function(userAppManager, appID, userConfig, depotInfo, sharedDepotInfo, steamApp, buildID, betaFallback);
}
int main(int argc, char** argv) {
    if (argc != 2) { std::cerr << "usage: bst-real-hook-smoke <steamclient.dylib>\n"; return 2; }
    void* handle = dlopen(argv[1], RTLD_NOW | RTLD_LOCAL);
    if (!handle) { std::cerr << "dlopen failed: " << (dlerror() ?: "unknown") << '\n'; return 1; }
    std::string diagnostic;
    const auto image = BST::Mac::probeSteamClient(diagnostic);
    if (!image) { std::cerr << diagnostic << '\n'; return 1; }
    std::array<uint8_t, 32> before{}; auto* entry = reinterpret_cast<void*>(image->ownershipEntry);
    std::memcpy(before.data(), entry, before.size()); original = entry;
    std::array<uint8_t, 32> binaryBefore{};
    auto* binaryEntry = reinterpret_cast<void*>(image->configStoreGetBinaryEntry);
    std::memcpy(binaryBefore.data(), binaryEntry, binaryBefore.size()); binaryOriginal = binaryEntry;
    std::array<uint8_t, 32> manifestBefore{};
    auto* manifestEntry = reinterpret_cast<void*>(image->buildDepotDependencyEntry);
    std::memcpy(manifestBefore.data(), manifestEntry, manifestBefore.size()); manifestOriginal = manifestEntry;
    namespace Detour = OSTPlatform::Detour;
    if (!Detour::BeginTransaction()) { std::cerr << "begin attach failed\n"; return 1; }
    const bool attached = Detour::Attach(&original, reinterpret_cast<void*>(passthrough));
    const bool binaryAttached = Detour::Attach(&binaryOriginal, reinterpret_cast<void*>(binaryPassthrough));
    const bool manifestAttached = Detour::Attach(&manifestOriginal, reinterpret_cast<void*>(manifestPassthrough));
    const bool committed = Detour::CommitTransaction();
    if (!attached || !binaryAttached || !manifestAttached || !committed || original == entry || binaryOriginal == binaryEntry || manifestOriginal == manifestEntry ||
        !std::memcmp(before.data(), entry, 4) || !std::memcmp(binaryBefore.data(), binaryEntry, 4) || !std::memcmp(manifestBefore.data(), manifestEntry, 4)) {
        std::cerr << "Real-image detour failed: " << OSTPlatform::Apple::DetourLastError() << '\n'; return 1;
    }
    if (!Detour::BeginTransaction()) { std::cerr << "begin detach failed\n"; return 1; }
    const bool detached = Detour::Detach(&original, reinterpret_cast<void*>(passthrough));
    const bool binaryDetached = Detour::Detach(&binaryOriginal, reinterpret_cast<void*>(binaryPassthrough));
    const bool manifestDetached = Detour::Detach(&manifestOriginal, reinterpret_cast<void*>(manifestPassthrough));
    const bool restored = Detour::CommitTransaction();
    if (!detached || !binaryDetached || !manifestDetached || !restored || original != entry || binaryOriginal != binaryEntry || manifestOriginal != manifestEntry ||
        std::memcmp(before.data(), entry, before.size()) || std::memcmp(binaryBefore.data(), binaryEntry, binaryBefore.size()) || std::memcmp(manifestBefore.data(), manifestEntry, manifestBefore.size())) {
        std::cerr << "Real-image restoration failed: " << OSTPlatform::Apple::DetourLastError() << '\n'; return 1;
    }
    // Retain the loaded client until process exit; its initializers may have
    // created workers. No Steam process/bundle is changed by this helper.
    std::cout << "PASS: real ARM64 ownership/ConfigStore/manifest entries verified; three detours attached and all 96 original bytes restored\n"
                 "Scope: isolated code patching; Steam user ABI, library UI and game launch are not exercised.\n";
    return 0;
}
