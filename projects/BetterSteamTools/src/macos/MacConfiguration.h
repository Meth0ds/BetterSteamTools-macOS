#pragma once
#include "MacLuaSupport.h"
#include <cstdint>
#include <filesystem>
#include <map>
#include <mutex>
#include <string>

namespace BST::Mac {
struct ConfigurationReport {
    bool reloaded = false;
    bool ready = false;
    size_t depotCount = 0;
    std::vector<LuaSupport::Diagnostic> diagnostics;
};
// The shared Lua interpreter is serialized with every native hook query.
// Future native manifest/ticket hooks must use this same mutex and ready gate.
std::recursive_mutex& ConfigurationMutex();
bool HasConfiguredDepot(uint32_t appID);
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
