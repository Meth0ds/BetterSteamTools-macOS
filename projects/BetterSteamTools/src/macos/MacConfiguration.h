#pragma once
#include "MacLuaSupport.h"
#include "Utils/Config/LuaConfig.h"
#include <cstdint>
#include <filesystem>
#include <map>
#include <memory>
#include <mutex>
#include <string>
#include <unordered_map>

namespace BST::Mac {
struct ConfigurationSnapshot {
    // Every declared AppID/depot remains in the map, including entries without
    // a key. Published data is immutable while Steam threads read it.
    std::unordered_map<uint32_t, std::vector<uint8_t>> depots;
    // Manifest overrides are copied into the same immutable publication so
    // Steam threads never read LuaConfig's mutable maps while a reload runs.
    std::unordered_map<uint64_t, LuaConfig::ManifestOverride> manifestOverrides;
};
struct ConfigurationReport {
    bool reloaded = false;
    bool ready = false;
    size_t depotCount = 0;
    std::vector<LuaSupport::Diagnostic> diagnostics;
};
// Reloads serialize access to the shared interpreter. Hook threads read the
// immutable snapshot; future hooks must use the same ready gate and publication.
std::recursive_mutex& ConfigurationMutex();
bool HasConfiguredDepot(uint32_t appID);
void DisableConfiguration();
std::shared_ptr<const ConfigurationSnapshot> GetConfigurationSnapshot();
class MacConfiguration {
public:
    ConfigurationReport reload(const std::filesystem::path& steamData);
private:
    bool initialized_ = false;
    std::filesystem::path root_;
    std::string configHash_;
    std::map<std::filesystem::path, std::string> files_;
};
}
