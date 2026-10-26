#include "MacConfiguration.h"
#include "Utils/Config/Config.h"
#include "Utils/Config/LuaConfig.h"
#include "OSTPlatform/include/Hash.h"
#include <algorithm>
#include <atomic>
#include <memory>
#include <unordered_set>

namespace BST::Mac {
namespace {
std::recursive_mutex mutex;
bool ready = false;
using DepotSnapshot = std::shared_ptr<const std::unordered_set<uint32_t>>;
DepotSnapshot configured;
void publish(DepotSnapshot value) { std::atomic_store_explicit(&configured, std::move(value), std::memory_order_release); }
std::string hashFile(const std::filesystem::path& path, std::error_code& error) {
    const auto state = std::filesystem::symlink_status(path, error);
    if (error == std::errc::no_such_file_or_directory) { error.clear(); return "missing"; }
    if (error) return {};
    if (!std::filesystem::is_regular_file(state)) { error = std::make_error_code(std::errc::invalid_argument); return {}; }
    const auto size = std::filesystem::file_size(path, error);
    if (error || size > 16 * 1024 * 1024) { error = std::make_error_code(std::errc::file_too_large); return {}; }
    const auto hash = OSTPlatform::Hash::Sha256OfFile(path);
    if (hash.size() != 64) error = std::make_error_code(std::errc::io_error);
    return hash;
}
}
std::recursive_mutex& ConfigurationMutex() { return mutex; }
bool HasConfiguredDepot(uint32_t appID) {
    // Steam's ownership hook must not wait for a script's synchronous HTTP
    // callback or Keychain operation on the reload worker.
    const auto snapshot = std::atomic_load_explicit(&configured, std::memory_order_acquire);
    return snapshot && snapshot->contains(appID);
}
ConfigurationReport MacConfiguration::reload(const std::filesystem::path& steamData) {
    std::lock_guard lock(mutex);
    ConfigurationReport report;
    report.diagnostics = LuaSupport::TakeDiagnostics();
    const auto reject = [&](const std::filesystem::path& file, const std::string& message) {
        ready = false; publish(nullptr);
        report.ready = false; report.diagnostics.push_back({file.string(), message}); return report;
    };
    std::error_code error;
    const auto root = std::filesystem::weakly_canonical(steamData, error);
    if (error) return reject(steamData, error.message());
    const auto config = root / "opensteamtool.toml";
    const auto configHash = hashFile(config, error);
    if (error) return reject(config, error.message());
    const bool configChanged = !initialized_ || root != root_ || configHash != configHash_;
    if (configChanged && !Config::Load(config.string()).applied) return reject(config, "Configuration could not be parsed; native Lua hooks disabled until corrected");
    std::vector<std::filesystem::path> directories;
    for (const auto& raw : Config::GetLuaPaths()) {
        const std::filesystem::path candidate(raw);
        directories.push_back(candidate.is_absolute() ? candidate : root / candidate);
    }
    directories.push_back(root / "config/stplug-in");
    std::vector<std::string> unique;
    std::map<std::filesystem::path, std::string> files;
    for (const auto& raw : directories) {
        const auto directory = std::filesystem::weakly_canonical(raw, error);
        if (error) return reject(raw, error.message());
        bool duplicate = false;
        for (const auto& previous : unique) {
            if (directory == previous || std::filesystem::equivalent(directory, previous, error)) { duplicate = true; break; }
            error.clear();
        }
        if (duplicate) continue;
        unique.push_back(directory.string());
        if (!std::filesystem::exists(directory, error)) {
            error.clear(); std::filesystem::create_directories(directory, error);
            if (error) return reject(directory, error.message());
        }
        if (!std::filesystem::is_directory(directory, error) || error) return reject(directory, "Lua watch path is not an accessible directory");
        for (std::filesystem::directory_iterator it(directory, error), end; it != end && !error; it.increment(error)) {
            const auto file = it->path();
            if (file.extension() != ".lua") continue;
            const auto hash = hashFile(file, error);
            if (error || hash == "missing") return reject(file, error ? error.message() : "Lua file disappeared during reload");
            files[file] = hash;
            if (files.size() > 4096) return reject(directory, "Lua configuration exceeds 4096 files");
        }
        if (error) return reject(directory, error.message());
    }
    if (configChanged || files != files_ || !ready) {
        LuaConfig::ReloadDirectories(unique, !initialized_);
        auto errors = LuaSupport::TakeDiagnostics();
        report.reloaded = true;
        if (!errors.empty()) {
            ready = false; publish(nullptr);
            report.diagnostics.insert(report.diagnostics.end(), errors.begin(), errors.end()); return report;
        }
        const auto depots = LuaConfig::GetAllDepotIds();
        publish(std::make_shared<const std::unordered_set<uint32_t>>(depots.begin(), depots.end()));
        initialized_ = true; root_ = root; configHash_ = configHash; files_ = std::move(files); ready = true;
    }
    report.ready = ready; report.depotCount = LuaConfig::GetAllDepotIds().size();
    return report;
}
}
