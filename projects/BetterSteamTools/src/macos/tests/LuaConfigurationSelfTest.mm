#include "Utils/Config/LuaConfig.h"
#include "Utils/Config/Config.h"
#include "Utils/SteamMetadata/ManifestClient.h"
#include "OSTPlatform/Apple/KeychainStore.h"
#include "OSTPlatform/Apple/SteamSession.h"
#include "OSTPlatform/include/SteamCredentialStore.h"
#include "macos/MacLuaSupport.h"
#include "macos/MacConfiguration.h"
#include <Security/Security.h>
#include <algorithm>
#include <filesystem>
#include <fstream>
#include <future>
#include <iostream>
#include <set>
#include <stdexcept>
#include <thread>
#include <unistd.h>

namespace fs = std::filesystem;
using Status = OSTPlatform::SteamCredentialStore::Status;
namespace Store = OSTPlatform::SteamCredentialStore;
void check(bool value, const char* message) { if (!value) throw std::runtime_error(message); }
void write(const fs::path& path, const std::string& text) {
    std::ofstream output(path, std::ios::binary); output << text; output.close();
    check(output.good(), "write Lua fixture");
}
struct Vault {
    fs::path root;
    SecKeychainRef keychain = nullptr;
    std::shared_ptr<OSTPlatform::Apple::KeychainStore> store;
    std::string password;
    Vault() {
        char pattern[] = "/tmp/bst-lua-keychain-XXXXXX";
        const auto* directory = mkdtemp(pattern); check(directory, "private fixture directory"); root = directory;
        password = "fixture-" + root.filename().string();
        const auto code = SecKeychainCreate((root / "Fixture.keychain-db").c_str(), static_cast<uint32_t>(password.size()), password.data(), false, nullptr, &keychain);
        if (code != errSecSuccess) throw std::runtime_error("create isolated real Keychain: " + std::to_string(code));
        store = std::make_shared<OSTPlatform::Apple::KeychainStore>("org.bst.fixture." + root.filename().string(), keychain);
        OSTPlatform::Apple::SetCredentialStore(store);
    }
    ~Vault() {
        OSTPlatform::Apple::SetCredentialStore(nullptr); store.reset();
        if (keychain) { SecKeychainDelete(keychain); CFRelease(keychain); }
        std::error_code ignored; fs::remove_all(root, ignored);
    }
};
void testKeychain(Vault& vault) {
    std::vector<uint8_t> output{9, 8}, binary{0, 1, 0xff, 0, 0x80};
    check(Store::GetAppTicket(42, output) == Status::NotFound && output == std::vector<uint8_t>({9, 8}), "missing ticket preserves output");
    check(Store::WriteAppTicket(42, binary) == Status::Ok, "write binary ticket to real Keychain");
    check(Store::GetAppTicket(42, output) == Status::Ok && output == binary, "binary ticket roundtrip includes NUL/high bytes");
    check(Store::WriteAppTicket(42, {3, 4}) == Status::Ok, "update existing credential without delete gap");
    check(Store::GetAppTicket(42, output) == Status::Ok && output == std::vector<uint8_t>({3, 4}), "read updated credential");
    check(Store::WriteETicket(42, {}) == Status::Ok, "empty encrypted ticket stored");
    check(Store::GetETicket(42, output) == Status::Ok && output.empty(), "empty encrypted ticket roundtrip");
    check(Store::WriteSteamId(42, UINT64_MAX) == Status::Ok, "write full uint64 SteamID value");
    uint64_t steamID = 123;
    check(Store::GetSteamId(42, steamID) == Status::Ok && steamID == UINT64_MAX, "SteamID precision is not reduced to double");
    check(vault.store->write(43, "SteamID", {'b', 'a', 'd'}) == Status::Ok, "store malformed SteamID fixture");
    check(Store::GetSteamId(43, steamID) == Status::NotFound && steamID == UINT64_MAX, "invalid SteamID preserves output");
    check(vault.store->remove(42, "AppTicket") == Status::Ok, "delete owned fixture credential");
    check(Store::GetAppTicket(42, output) == Status::NotFound, "deleted credential is absent");
    check(SecKeychainLock(vault.keychain) == errSecSuccess, "lock isolated Keychain");
    output = {7};
    check(Store::GetSteamId(42, steamID) == Status::Failed && steamID == UINT64_MAX, "locked Keychain fails without replacing output");
    check(SecKeychainUnlock(vault.keychain, static_cast<uint32_t>(vault.password.size()), vault.password.data(), true) == errSecSuccess, "unlock isolated Keychain explicitly");
}
void testSessionParser() {
    using OSTPlatform::Apple::ParseSteamHelperSession;
    const std::vector<std::string> args{"steamwebhelper", "-steampid=1234", "-steamid=76561197960265770", "-steamuniverse=Public"};
    const auto session = ParseSteamHelperSession(args, 1234);
    check(session && session->accountID == 42 && session->universe == L"Public", "native helper session fields");
    check(!ParseSteamHelperSession(args, 5678), "another Steam instance is not the active user");
    auto duplicate = args; duplicate.push_back("-steamid=76561197960265771");
    check(!ParseSteamHelperSession(duplicate, 1234), "ambiguous SteamID flags refused");
    auto loggedOut = args; loggedOut[2] = "-steamid=0";
    check(!ParseSteamHelperSession(loggedOut, 1234), "logged-out helper is not an authenticated session");
    auto mismatch = args; mismatch[3] = "-steamuniverse=Beta";
    check(!ParseSteamHelperSession(mismatch, 1234), "SteamID universe must match helper universe");
    uint32_t account = 999; std::wstring universe = L"kept";
    check(Store::GetActiveUser(account, universe) == Status::NotFound && account == 999 && universe == L"kept", "auxiliary test process is not a Steam session");
}
void testLua(Vault& vault) {
    const auto directory = vault.root / "scripts"; fs::create_directory(directory);
    const auto script = directory / "71.lua";
    const auto config = vault.root / "opensteamtool.toml";
    write(config, "[stats]\nenable_api = false\n[manifest]\nurl = \"opensteamtool\"\n[lua]\npaths = [\"config/stplug-in\"]\n");
    Config::Load(config.string()); check(!Config::GetStatsEnableApi(), "original TOML config is compiled and applied on macOS");
    write(script, R"lua(
local base = 70
-- addappid(9999)
local literal = "addappid(9998)"
for i = 1, 3 do
    ADDAPPID(base + i, 1, string.rep("ab", 32))
end
AddToken(71, "18446744073709551615")
setManifestid(72, "18446744073709551614")
setLegacyCDKey(73, "USER-PROVIDED-KEY")
addProcess(73, "Game.exe")
forceDenuvo(73)
setETicketURL("https://example.invalid/fixture")
setStat(73, "76561197960265770")
setAppTicket(73, "000102ff")
setETicket(73, "abcdef")
function fetch_manifest_code(gid)
    return "18446744073709551613"
end
function fetch_manifest_code_ex(app, depot, gid)
    if app == 71 and depot == 72 then return "18446744073709551612" end
    return nil
end
)lua");
    LuaConfig::ReloadDirectories({directory.string()}, true);
    const auto diagnostics = BST::Mac::LuaSupport::TakeDiagnostics();
    if (!diagnostics.empty()) throw std::runtime_error("real Lua fixture: " + diagnostics.front().message);
    check(LuaConfig::HasDepot(71, false) && LuaConfig::HasDepot(72, false) && LuaConfig::HasDepot(73, false), "real Lua locals, loops and case-insensitive registered functions");
    check(!LuaConfig::HasDepot(9999, false) && !LuaConfig::HasDepot(9998, false), "comments and string literals do not register fake AppIDs");
    check(LuaConfig::GetDecryptionKey(72) == std::vector<uint8_t>(32, 0xab), "all depot decryption key bytes retained");
    check(LuaConfig::GetAccessToken(71) == UINT64_MAX, "access token full precision");
    check(LuaConfig::GetManifestOverrides().at(72).gid == UINT64_MAX - 1, "pinned manifest GID full precision");
    check(LuaConfig::GetLegacyCDKey(73) == "USER-PROVIDED-KEY", "explicit legacy key stored");
    check(LuaConfig::GetAppIdForProcess("GAME.EXE") == 73 && LuaConfig::IsForcedDenuvo(73), "process mapping and flags are registered");
    check(LuaConfig::GetEticketUrl() == "https://example.invalid/fixture" && LuaConfig::GetStatSteamId(73) == 76561197960265770ULL, "ticket URL and explicit stat SteamID");
    std::vector<uint8_t> ticket;
    check(Store::GetAppTicket(73, ticket) == Status::Ok && ticket == std::vector<uint8_t>({0, 1, 2, 255}), "Lua setAppTicket writes actual Keychain bytes");
    check(Store::GetETicket(73, ticket) == Status::Ok && ticket == std::vector<uint8_t>({0xab, 0xcd, 0xef}), "Lua setETicket writes actual Keychain bytes");
    uint64_t code = 0;
    check(LuaConfig::CallManifestFetchCode(UINT64_MAX - 1, &code) && code == UINT64_MAX - 2, "manifest callback executes real Lua with exact decimal return");
    check(ManifestClient::FetchManifestRequestCode(UINT64_MAX - 1, &code, 71, 72) && code == UINT64_MAX - 3, "shared ManifestClient invokes depot-aware Lua callback before HTTP");
    write(script, "addappid(74)\n");
    LuaConfig::ReloadDirectories({directory.string()}, false);
    check(!LuaConfig::HasDepot(71, false) && LuaConfig::HasDepot(74, false), "full native reload replaces prior file contributions");
    check(LuaConfig::GetAccessToken(71) == 0 && !LuaConfig::GetLegacyCDKey(73) && LuaConfig::GetManifestOverrides().empty(), "removed token/key/manifest configuration does not remain stale");
    check(LuaConfig::GetAppIdForProcess("game.exe") == 0 && !LuaConfig::IsForcedDenuvo(73) && LuaConfig::GetEticketUrl().empty(), "removed process/flag/URL configuration cleared");
    check(!LuaConfig::HasManifestCodeFunc() && !LuaConfig::HasManifestCodeFuncEx(), "removed Lua callback globals cleared");
    auto removed = LuaConfig::TakePendingRemovals(), added = LuaConfig::TakePendingAdditions();
    check(std::set<uint32_t>(removed.begin(), removed.end()) == std::set<uint32_t>({71, 72, 73}) && added == std::vector<uint32_t>({74}), "reload reports actual depot differences");
    write(script, "while true do end\n");
    LuaConfig::ReloadDirectories({directory.string()}, false);
    const auto errors = BST::Mac::LuaSupport::TakeDiagnostics();
    check(errors.size() == 1 && errors.front().message.find("limit") != std::string::npos, "non-terminating config reports an execution limit");
    write(script, "local incomplete =\n");
    LuaConfig::ReloadDirectories({directory.string()}, false);
    check(!BST::Mac::LuaSupport::TakeDiagnostics().empty(), "syntax errors have explicit diagnostics");
    fs::remove(script);
    LuaConfig::ReloadDirectories({directory.string()}, false);
    check(LuaConfig::GetAllDepotIds().empty(), "removed Lua files are absent from native registry");
}
void testNativeReload(Vault& vault) {
    const auto steam = vault.root / "SteamData";
    const auto scripts = steam / "config/stplug-in";
    fs::create_directories(scripts);
    const auto script = scripts / "configured.lua";
    write(steam / "opensteamtool.toml", "[stats]\nenable_api = false\n");
    write(script, "local value = 100\naddappid(value + 1)\n");
    BST::Mac::MacConfiguration configuration;
    auto report = configuration.reload(steam);
    check(report.ready && report.reloaded && report.depotCount == 1 && BST::Mac::HasConfiguredDepot(101), "native hook registry uses the real shared Lua interpreter");
    report = configuration.reload(steam);
    check(report.ready && !report.reloaded, "unchanged scripts do not execute side effects on every polling tick");
    write(script, "local value = 200\naddappid(value + 1)\n");
    report = configuration.reload(steam);
    check(report.ready && report.reloaded && !BST::Mac::HasConfiguredDepot(101) && BST::Mac::HasConfiguredDepot(201), "content hash detects same-size Lua changes");
    write(script, "addappid(201)\nerror('fixture invalid configuration')\n");
    report = configuration.reload(steam);
    check(!report.ready && !report.diagnostics.empty() && !BST::Mac::HasConfiguredDepot(201), "partial/error configuration cannot affect ownership hooks");
    write(script, "addappid(301)\n");
    report = configuration.reload(steam);
    check(report.ready && BST::Mac::HasConfiguredDepot(301), "corrected configuration resumes without restarting the registry");
    std::promise<void> entered, leave;
    const auto leaveSignal = leave.get_future().share();
    std::thread worker([&] { std::lock_guard lock(BST::Mac::ConfigurationMutex()); entered.set_value(); leaveSignal.wait(); });
    entered.get_future().wait();
    auto query = std::async(std::launch::async, [] { return BST::Mac::HasConfiguredDepot(301); });
    const bool responsive = query.wait_for(std::chrono::seconds(1)) == std::future_status::ready;
    leave.set_value(); worker.join();
    check(responsive && query.get(), "ownership snapshot remains usable while the Lua interpreter lock is held");
    fs::remove(script);
    report = configuration.reload(steam);
    check(report.ready && report.depotCount == 0 && !BST::Mac::HasConfiguredDepot(301), "removed scripts leave no configured hook entries");
}
int main() {
    @autoreleasepool {
        // Headless test policy only; never change the Steam host's process-
        // wide Keychain interaction setting in the production backend.
        SecKeychainSetUserInteractionAllowed(false);
        try { Vault vault; testKeychain(vault); testSessionParser(); testLua(vault); testNativeReload(vault);
            std::cout << "PASS: real isolated Keychain, native session parsing, shared Windows Lua/config/manifest code and native reload\n";
            return 0;
        } catch (const std::exception& error) { std::cerr << "FAIL: " << error.what() << '\n'; return 1; }
    }
}
