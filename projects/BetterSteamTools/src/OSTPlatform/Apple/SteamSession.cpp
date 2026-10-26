#include "SteamSession.h"
#include "ProcessArguments.h"
#include "include/SteamCredentialStore.h"
#include "include/Process.h"
#include "include/DynamicLibrary.h"
#include "include/Numbers.h"
#include <libproc.h>
#include <unistd.h>
#include <filesystem>
#include <map>

namespace OSTPlatform::Apple {
std::optional<SteamSession> ParseSteamHelperSession(const std::vector<std::string>& arguments, uint32_t steamPID) {
    std::map<std::string, std::string> flags;
    for (const auto& argument : arguments) {
        const auto equals = argument.find('=');
        if (equals == std::string::npos) continue;
        const auto key = argument.substr(0, equals);
        if (key != "-steampid" && key != "-steamid" && key != "-steamuniverse") continue;
        if (!flags.emplace(key, argument.substr(equals + 1)).second) return std::nullopt;
    }
    const auto pid = Numbers::ParseUInt64(flags["-steampid"]);
    const auto id = Numbers::ParseUInt64(flags["-steamid"]);
    if (!pid || *pid != steamPID || !id || !*id) return std::nullopt;
    const auto account = static_cast<uint32_t>(*id);
    const auto type = (*id >> 52) & 15, universe = *id >> 56;
    const std::map<std::string, uint64_t> universes{{"Public", 1}, {"Beta", 2}, {"Internal", 3}, {"Dev", 4}, {"RC", 5}};
    const auto found = universes.find(flags["-steamuniverse"]);
    if (!account || type != 1 || found == universes.end() || found->second != universe) return std::nullopt;
    return SteamSession{account, std::wstring(found->first.begin(), found->first.end())};
}
}
namespace OSTPlatform::SteamCredentialStore {
Status GetActiveUser(uint32_t& accountID, std::wstring& universe) {
    const auto executable = DynamicLibrary::GetMainExecutablePath();
    if (executable.filename() != "steam_osx" && executable.filename() != "steam") return Status::NotFound;
    std::error_code error;
    const auto mainBundle = std::filesystem::weakly_canonical(executable.parent_path().parent_path().parent_path(), error);
    if (error) return Status::Failed;
    std::vector<int> pids(65536);
    const auto count = proc_listallpids(pids.data(), static_cast<int>(pids.size() * sizeof(int)));
    if (count <= 0 || count >= pids.size()) return Status::Failed;
    std::optional<Apple::SteamSession> active;
    for (int index = 0; index < count; ++index) {
        const auto path = Process::GetImagePath(pids[index]);
        if (!path) continue;
        const auto name = std::filesystem::path(*path).filename();
        if (name != "steamwebhelper" && name != "Steam Helper") continue;
        const auto canonical = std::filesystem::weakly_canonical(*path, error);
        if (error || !canonical.string().starts_with(mainBundle.string() + "/Contents/")) continue;
        const auto args = Apple::GetProcessArguments(pids[index]);
        const auto session = args ? Apple::ParseSteamHelperSession(*args, static_cast<uint32_t>(getpid())) : std::nullopt;
        if (!session) continue;
        if (active && (active->accountID != session->accountID || active->universe != session->universe)) return Status::Failed;
        active = session;
    }
    if (!active) return Status::NotFound;
    accountID = active->accountID; universe = active->universe; return Status::Ok;
}
}
