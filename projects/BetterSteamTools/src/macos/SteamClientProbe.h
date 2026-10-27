#pragma once
#include <cstdint>
#include <filesystem>
#include <memory>
#include <optional>
#include <string>

namespace BST::Mac {
inline constexpr const char* steamBuild = "1792618285";
struct SteamClientProbe {
    std::filesystem::path path;
    uintptr_t ownershipEntry = 0;
    uintptr_t configStoreGetBinaryEntry = 0;
    uintptr_t buildDepotDependencyEntry = 0;
    uintptr_t getPackageInfoEntry = 0;
    uintptr_t vectorGrowEntry = 0;
    uintptr_t markLicenseChangedEntry = 0;
    uintptr_t processLicenseUpdatesEntry = 0;
    std::shared_ptr<void> module;
};
// Pins the loaded image for the returned probe's lifetime. Validates on-disk
// SHA-256, ARM64 load commands, code-section bounds and 32 original entry bytes.
std::optional<SteamClientProbe> probeSteamClient(std::string& diagnostic);
}
