#include "MacHookRuntime.h"
#include "SteamClientProbe.h"
#include "RuntimeManifestVerifier.h"
#include "BSTManifestTrust.h"
#include "OSTPlatform/include/Detour.h"
#include "OSTPlatform/Apple/DetourDiagnostics.h"
#include <dlfcn.h>
#include <filesystem>
#include <fstream>
#include <mutex>
#include <regex>
#include <set>
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
std::mutex g_configMutex;
std::set<uint32_t> g_configuredApps;
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

bool validAppID(const std::string& text, uint32_t& output) {
    if (text.empty() || text.size() > 10 || !std::all_of(text.begin(), text.end(), [](unsigned char c) { return c >= '0' && c <= '9'; })) return false;
    try {
        const auto value = std::stoull(text);
        if (!value || value > UINT32_MAX) return false;
        output = static_cast<uint32_t>(value); return true;
    } catch (...) { return false; }
}

void reloadLuaAppIDs() {
    const char* home = getenv("HOME");
    if (!home) return;
    const auto directory = std::filesystem::path(home) / "Library/Application Support/Steam/config/stplug-in";
    std::set<uint32_t> next;
    std::error_code error;
    if (std::filesystem::exists(directory, error)) {
        static const std::regex addApp(R"(\baddappid\s*\(\s*([0-9]+))", std::regex::ECMAScript | std::regex::icase);
        for (const auto& entry : std::filesystem::directory_iterator(directory, error)) {
            if (error || entry.is_symlink(error) || !entry.is_regular_file(error) || entry.path().extension() != ".lua") continue;
            const auto size = entry.file_size(error);
            if (error || size > 16 * 1024 * 1024) continue;
            std::ifstream file(entry.path());
            if (!file) continue;
            const std::string text((std::istreambuf_iterator<char>(file)), std::istreambuf_iterator<char>());
            for (std::sregex_iterator match(text.begin(), text.end(), addApp), end; match != end; ++match) {
                uint32_t app = 0; if (validAppID((*match)[1].str(), app)) next.insert(app);
            }
        }
    }
    std::lock_guard lock(g_configMutex);
    if (next != g_configuredApps) {
        g_configuredApps = std::move(next);
        log("Lua AppID registry reloaded: " + std::to_string(g_configuredApps.size()) + " app(s)");
    }
}

bool configured(uint32_t appID) {
    std::lock_guard lock(g_configMutex);
    return g_configuredApps.contains(appID);
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
    if (!ownership || !configured(appID) || result) return result;
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
        reloadLuaAppIDs();
        std::string diagnostic;
        const auto image = BST::Mac::probeSteamClient(diagnostic);
        if (image) {
            if (!approvedBuild(*image)) return;
            std::atomic_ref<void*>(g_original).store(reinterpret_cast<void*>(image->ownershipEntry), std::memory_order_release);
            if (!OSTPlatform::Detour::BeginTransaction()) { log(OSTPlatform::Apple::DetourLastError()); return; }
            const bool staged = OSTPlatform::Detour::Attach(&g_original, reinterpret_cast<void*>(&checkAppOwnershipHook));
            // Commit also clears a failed staging transaction.
            const bool committed = OSTPlatform::Detour::CommitTransaction();
            if (!staged || !committed) {
                log("CheckAppOwnership hook refused: " + OSTPlatform::Apple::DetourLastError());
                return;
            }
            log("CheckAppOwnership hook installed for Steam build " + std::string(BST::Mac::steamBuild));
            while (true) {
                reloadLuaAppIDs();
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
