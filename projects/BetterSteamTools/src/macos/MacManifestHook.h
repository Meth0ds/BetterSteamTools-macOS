#pragma once

#include "MacConfiguration.h"
#include <cstdint>
#include <span>

namespace BST::Mac {
struct ManifestEntry {
    uint32_t depotID;
    uint32_t appID;
    uint64_t manifestGID;
    uint64_t manifestSize;
    uint32_t dlcAppID;
    uint8_t lcsRequired;
    uint8_t notNewTarget;
    uint8_t sharedInstall;
    uint8_t padding;
};
static_assert(sizeof(ManifestEntry) == 32);
void ApplyManifestOverrides(const ConfigurationSnapshot& snapshot, std::span<ManifestEntry> entries);
void** BuildDepotDependencyOriginalSlot();
void* BuildDepotDependencyReplacement();
}
