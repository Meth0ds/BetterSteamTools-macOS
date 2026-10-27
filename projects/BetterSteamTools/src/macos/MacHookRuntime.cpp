#include "MacHookRuntime.h"
#include "MacConfiguration.h"
#include "MacConfigStore.h"
#include "MacManifestHook.h"
#include "MacPackageHook.h"
#include "MacOwnership.h"
#include "SteamClientProbe.h"
#include "RuntimeManifestVerifier.h"
#include "BSTManifestTrust.h"
#include "OSTPlatform/include/Detour.h"
#include "OSTPlatform/Apple/DetourDiagnostics.h"
#include <dlfcn.h>
#include <filesystem>
#include <fstream>
#include <mutex>
#include <string>
#include <thread>
#include <chrono>
#include <algorithm>
#include <cstddef>
#include <cstdint>
#include <cstdlib>
#include <optional>
#include <atomic>
#include <array>

namespace {
std::once_flag g_start;
std::ofstream g_log;

void log(const std::string& message) {
    static std::mutex mutex;
    std::lock_guard lock(mutex);
    if (!g_log.is_open()) {
        const char* home = getenv("HOME");
        if (!home) return;
        const std::filesystem::path directory = std::filesystem::path(home) / "Library/Application Support/BetterSteamTools/logs";
        std::error_code error;
        std::filesystem::create_directories(directory, error);
        g_log.open(directory / "macos-hooks.log", std::ios::app);
    }
    if (g_log) g_log << message << '\n' << std::flush;
}

BST::Mac::MacConfiguration g_configuration;
bool reloadLuaConfiguration() {
    const char* home = getenv("HOME");
    if (!home) { log("HOME is unavailable; Lua configuration disabled"); return false; }
    const auto report = g_configuration.reload(std::filesystem::path(home) / "Library/Application Support/Steam");
    for (const auto& diagnostic : report.diagnostics) log("Lua configuration: " + diagnostic.file + ": " + diagnostic.message);
    if (report.reloaded && report.ready) log("Lua configuration executed: " + std::to_string(report.depotCount) + " app/depot(s)");
    return report.ready;
}

using CheckAppOwnership = bool (*)(void*, uint32_t, BST::Mac::NativeAppOwnership*);
void* g_original = nullptr;

bool checkAppOwnershipHook(void* object, uint32_t appID, BST::Mac::NativeAppOwnership* ownership) {
    const auto original = reinterpret_cast<CheckAppOwnership>(std::atomic_ref<void*>(g_original).load(std::memory_order_acquire));
    const bool result = original ? original(object, appID, ownership) : false;
#if BST_EXPERIMENTAL_PACKAGE_HOOK
    BST::Mac::ReconcilePackageForUser(object);
#endif
    const auto snapshot = BST::Mac::GetConfigurationSnapshot();
    const auto decision = BST::Mac::ApplyOwnership(snapshot.get(), appID, result, ownership);
    if (decision.genuinelyOwned) {
        // Do not make a Steam thread wait for a Lua script performing network I/O.
        std::unique_lock lock(BST::Mac::ConfigurationMutex(), std::try_to_lock);
        if (lock.owns_lock()) { try { LuaConfig::MarkOwned(appID); } catch (...) { log("Failed to record genuinely owned app"); } }
    }
    return decision.result;
}

bool approvedBuild(const BST::Mac::SteamClientProbe& image) {
    Dl_info ownImage{};
    if (!dladdr(reinterpret_cast<void*>(&BSTMacStartHooks), &ownImage) || !ownImage.dli_fname) {
        log("Cannot locate BetterSteamTools payload; hooks disabled"); return false;
    }
    const auto payload = std::filesystem::absolute(ownImage.dli_fname);
    const auto manifest = payload.parent_path().parent_path() / "Resources/BetterSteamTools.build.json";
    std::array<char, 1024> diagnostic{};
    const bool accepted = BSTVerifyBuildManifest(manifest.c_str(), image.path.parent_path().c_str(), payload.c_str(),
        bstManifestKeyID, bstManifestPublicKeyHex, BST::Mac::steamBuild, diagnostic.data(), diagnostic.size()) == 1;
    log(std::string(accepted ? "Signed build accepted: " : "Signed build rejected; hooks disabled: ") + diagnostic.data());
    return accepted;
}

void coordinator() {
    for (unsigned attempt = 0; attempt < 240; ++attempt) {
        std::string diagnostic;
        const auto image = BST::Mac::probeSteamClient(diagnostic);
        if (image) {
            if (!approvedBuild(*image)) return;
            bool attached = false;
            while (true) {
                const bool configured = reloadLuaConfiguration();
                if (configured && !attached) {
                    std::atomic_ref<void*>(g_original).store(reinterpret_cast<void*>(image->ownershipEntry), std::memory_order_release);
                    std::atomic_ref<void*>(*BST::Mac::ConfigStoreOriginalSlot()).store(reinterpret_cast<void*>(image->configStoreGetBinaryEntry), std::memory_order_release);
                    std::atomic_ref<void*>(*BST::Mac::BuildDepotDependencyOriginalSlot()).store(reinterpret_cast<void*>(image->buildDepotDependencyEntry), std::memory_order_release);
#if BST_EXPERIMENTAL_PACKAGE_HOOK
                    std::atomic_ref<void*>(*BST::Mac::PackageGetOriginalSlot()).store(reinterpret_cast<void*>(image->getPackageInfoEntry), std::memory_order_release);
                    BST::Mac::ConfigurePackageFunctions(image->vectorGrowEntry, image->markLicenseChangedEntry, image->processLicenseUpdatesEntry);
#endif
                    if (!OSTPlatform::Detour::BeginTransaction()) { log(OSTPlatform::Apple::DetourLastError()); return; }
                    const bool staged = OSTPlatform::Detour::Attach(&g_original, reinterpret_cast<void*>(&checkAppOwnershipHook));
                    const bool depotStaged = OSTPlatform::Detour::Attach(BST::Mac::ConfigStoreOriginalSlot(), BST::Mac::ConfigStoreReplacement());
                    const bool manifestStaged = OSTPlatform::Detour::Attach(BST::Mac::BuildDepotDependencyOriginalSlot(), BST::Mac::BuildDepotDependencyReplacement());
#if BST_EXPERIMENTAL_PACKAGE_HOOK
                    const bool packageStaged = OSTPlatform::Detour::Attach(BST::Mac::PackageGetOriginalSlot(), BST::Mac::PackageGetReplacement());
#else
                    constexpr bool packageStaged = true;
#endif
                    const bool committed = OSTPlatform::Detour::CommitTransaction();
                    if (!staged || !depotStaged || !manifestStaged || !packageStaged || !committed) {
                        BST::Mac::DisableConfiguration();
                        log("Ownership/depot hook batch refused: " + OSTPlatform::Apple::DetourLastError()); return;
                    }
                    attached = true;
                    log("Ownership, ConfigStore and depot manifest hooks installed for Steam build " + std::string(BST::Mac::steamBuild));
#if BST_EXPERIMENTAL_PACKAGE_HOOK
                    log("Experimental package hook enabled; live Steam ABI remains unverified");
#endif
                }
                std::this_thread::sleep_for(std::chrono::seconds(2));
            }
        } else if (diagnostic != "steamclient.dylib is not loaded") { log(diagnostic + "; hooks disabled"); return; }
        std::this_thread::sleep_for(std::chrono::milliseconds(250));
    }
    log("steamclient.dylib did not appear before hook coordinator deadline");
}
}

void BSTMacStartHooks() {
    std::call_once(g_start, [] {
        std::thread([] {
            // Keep this dylib mapped while its worker and replacement can run.
            Dl_info ownImage{};
            if (!dladdr(reinterpret_cast<void*>(&BSTMacStartHooks), &ownImage) || !ownImage.dli_fname ||
                !dlopen(ownImage.dli_fname, RTLD_NOW | RTLD_LOCAL | RTLD_NODELETE)) {
                log("Cannot pin BetterSteamTools runtime; hooks disabled"); return;
            }
            try { coordinator(); } catch (const std::exception& error) { log(std::string("Hook coordinator failed: ") + error.what()); }
        }).detach();
    });
}
