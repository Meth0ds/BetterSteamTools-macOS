#include "../SteamClientProbe.h"
#include "OSTPlatform/include/Detour.h"
#include "OSTPlatform/Apple/DetourDiagnostics.h"
#include <dlfcn.h>
#include <atomic>
#include <array>
#include <cstring>
#include <iostream>

static void* original = nullptr;
// Pass-through only. Never fabricate a Steam user object or license output.
static bool passthrough(void* object, uint32_t app, void* output) {
    using Function = bool (*)(void*, uint32_t, void*);
    const auto function = reinterpret_cast<Function>(std::atomic_ref<void*>(original).load(std::memory_order_acquire));
    return function(object, app, output);
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
    namespace Detour = OSTPlatform::Detour;
    if (!Detour::BeginTransaction()) { std::cerr << "begin attach failed\n"; return 1; }
    const bool attached = Detour::Attach(&original, reinterpret_cast<void*>(passthrough));
    const bool committed = Detour::CommitTransaction();
    if (!attached || !committed || original == entry || !std::memcmp(before.data(), entry, 4)) {
        std::cerr << "Real-image detour failed: " << OSTPlatform::Apple::DetourLastError() << '\n'; return 1;
    }
    if (!Detour::BeginTransaction()) { std::cerr << "begin detach failed\n"; return 1; }
    const bool detached = Detour::Detach(&original, reinterpret_cast<void*>(passthrough));
    const bool restored = Detour::CommitTransaction();
    if (!detached || !restored || original != entry || std::memcmp(before.data(), entry, before.size())) {
        std::cerr << "Real-image restoration failed: " << OSTPlatform::Apple::DetourLastError() << '\n'; return 1;
    }
    // Retain the loaded client until process exit; its initializers may have
    // created workers. No Steam process/bundle is changed by this helper.
    std::cout << "PASS: real ARM64 image hash/RVA/entry verified; detour attached and 32 original bytes restored\n"
                 "Scope: isolated code patching; Steam user ABI, library UI and game launch are not exercised.\n";
    return 0;
}
