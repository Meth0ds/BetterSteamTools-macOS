#include "MacManifestHook.h"
#include "MacConfiguration.h"
#include "OSTPlatform/include/Memory.h"
#include "OSTPlatform/Apple/CodePatch.h"
#include <algorithm>
#include <atomic>
#include <cstddef>
#include <cstdint>
#include <limits>

namespace BST::Mac {
namespace {
// The native Steam arm64 build uses the same CUtlVector and 0x20-byte depot
// record shape as the Windows client. Keep this representation private and
// validate every pointer before touching Steam-owned memory.
struct NativeVector {
    void* memory;
    uint32_t allocationCount;
    uint32_t growSize;
    uint32_t size;
};
static_assert(offsetof(NativeVector, memory) == 0);
static_assert(offsetof(NativeVector, allocationCount) == 8);
static_assert(offsetof(NativeVector, size) == 16);
static_assert(sizeof(NativeVector) == 24);

using BuildDepotDependency = bool (*)(void*, uint32_t, void*, NativeVector*, NativeVector*, void*, uint32_t*, bool*);
void* original = nullptr;

bool safeVector(const NativeVector* vector) {
    if (!vector || !OSTPlatform::Memory::IsReadable(vector, sizeof(*vector))) return false;
    if (!vector->size || vector->size > vector->allocationCount || vector->size > 1'000'000) return false;
    if (!vector->memory) return false;
    const auto bytes = static_cast<size_t>(vector->size) * sizeof(ManifestEntry);
    const auto address = reinterpret_cast<uintptr_t>(vector->memory);
    if (address > std::numeric_limits<uintptr_t>::max() - (bytes - 1)) return false;
    auto* first = static_cast<const uint8_t*>(vector->memory);
    auto* last = first + bytes - 1;
    return OSTPlatform::Memory::IsReadable(first, bytes) &&
           OSTPlatform::Apple::IsWritable(first) &&
           OSTPlatform::Apple::IsWritable(const_cast<uint8_t*>(last));
}

bool hook(void* userAppManager, uint32_t appID, void* userConfig, NativeVector* depotInfo,
          NativeVector* sharedDepotInfo, void* steamApp, uint32_t* buildID, bool* betaFallback) {
    const auto next = reinterpret_cast<BuildDepotDependency>(
        std::atomic_ref<void*>(original).load(std::memory_order_acquire));
    const bool result = next ? next(userAppManager, appID, userConfig, depotInfo, sharedDepotInfo,
                                    steamApp, buildID, betaFallback) : false;
    if (!result) return result;

    const auto snapshot = GetConfigurationSnapshot();
    if (!snapshot) return result;

    // During a PICS refresh Steam can briefly return an empty native vector.
    // Keep the previous config rather than letting that transient erase it.
    if (appID && snapshot->depots.contains(appID)) {
        if (!depotInfo) return false;
        if (!OSTPlatform::Memory::IsReadable(depotInfo, sizeof(*depotInfo))) return result;
        if (!depotInfo->size) return false;
    }
    if (!depotInfo || snapshot->manifestOverrides.empty() || !safeVector(depotInfo)) return result;

    auto* entries = static_cast<ManifestEntry*>(depotInfo->memory);
    ApplyManifestOverrides(*snapshot, {entries, depotInfo->size});
    return result;
}
}

void ApplyManifestOverrides(const ConfigurationSnapshot& snapshot, std::span<ManifestEntry> entries) {
    for (auto& entry : entries) {
        const auto overrideIt = snapshot.manifestOverrides.find(entry.depotID);
        if (overrideIt == snapshot.manifestOverrides.end() || !overrideIt->second.gid) continue;
        entry.manifestGID = overrideIt->second.gid;
        if (overrideIt->second.size) entry.manifestSize = overrideIt->second.size;
    }
}

void** BuildDepotDependencyOriginalSlot() { return &original; }
void* BuildDepotDependencyReplacement() { return reinterpret_cast<void*>(&hook); }
}
