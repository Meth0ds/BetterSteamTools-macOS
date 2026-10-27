#include "MacHookRuntime.h"
#include "MacConfiguration.h"
#include "MacConfigStore.h"
#include "MacManifestHook.h"
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
constexpr uint32_t kReleased = 4;
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

// Matches the native CheckAppOwnership output layout observed in Steam 1792618285.
// The static assertions prevent accidental use of a Windows packing convention.
struct NativeAppOwnership {
    uint32_t packageID;
    uint32_t releaseState;
    uint32_t steamID32;
    uint32_t masterSubscriptionAppID;
    uint32_t trialSeconds;
    uint32_t existInPackageNums;
    char purchaseCountryCode[4];
    uint32_t timeStamp;
    uint32_t timeExpire;
    bool ownsLicense;
    bool licenseExpired;
    bool permanent;
    bool lowViolence;
    bool freeLicense;
    bool regionRestricted;
    bool freeWeekend;
    bool licenseLocked;
    bool licensePending;
    bool retailLicense;
    bool autoGrant;
    bool licensePermanent;
    bool guestPass;
    bool borrowed;
    bool anySiteLicense;
    bool allSiteLicenses;
    bool allActivationRequired;
    bool familyShared;
};
static_assert(offsetof(NativeAppOwnership, ownsLicense) == 36);
static_assert(offsetof(NativeAppOwnership, freeLicense) == 40);
static_assert(offsetof(NativeAppOwnership, familyShared) == 53);

using CheckAppOwnership = bool (*)(void*, uint32_t, NativeAppOwnership*);
void* g_original = nullptr;

bool checkAppOwnershipHook(void* object, uint32_t appID, NativeAppOwnership* ownership) {
    const auto original = reinterpret_cast<CheckAppOwnership>(std::atomic_ref<void*>(g_original).load(std::memory_order_acquire));
    const bool result = original ? original(object, appID, ownership) : false;
    if (!ownership || !BST::Mac::HasConfiguredDepot(appID) || result) return result;
    ownership->packageID = 0;
    ownership->releaseState = kReleased;
    ownership->ownsLicense = true;
    // Steam hides a free license from the library; LuaTools entries must remain visible.
    ownership->freeLicense = false;
    return true;
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
                    if (!OSTPlatform::Detour::BeginTransaction()) { log(OSTPlatform::Apple::DetourLastError()); return; }
                    const bool staged = OSTPlatform::Detour::Attach(&g_original, reinterpret_cast<void*>(&checkAppOwnershipHook));
                    const bool depotStaged = OSTPlatform::Detour::Attach(BST::Mac::ConfigStoreOriginalSlot(), BST::Mac::ConfigStoreReplacement());
                    const bool manifestStaged = OSTPlatform::Detour::Attach(BST::Mac::BuildDepotDependencyOriginalSlot(), BST::Mac::BuildDepotDependencyReplacement());
                    const bool committed = OSTPlatform::Detour::CommitTransaction();
                    if (!staged || !depotStaged || !manifestStaged || !committed) {
                        BST::Mac::DisableConfiguration();
                        log("Ownership/depot hook batch refused: " + OSTPlatform::Apple::DetourLastError()); return;
                    }
                    attached = true;
                    log("CheckAppOwnership, ConfigStore GetBinary and BuildDepotDependency hooks installed for Steam build " + std::string(BST::Mac::steamBuild));
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
