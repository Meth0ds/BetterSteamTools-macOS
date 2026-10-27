#pragma once
#include "MacConfiguration.h"
#include <cstdint>
#include <mutex>
#include <unordered_set>

namespace BST::Mac {
// Layout established from Steam arm64 1792618285 constructor and readers.
struct NativeAppVector { uint32_t* memory; uint32_t capacity; int32_t growSize; uint32_t size; };
struct NativePackageInfo {
    uint32_t packageID; int32_t changeNumber; uint64_t accessToken;
    uint32_t billingType, licenseType, status; uint8_t sha1[20];
    void* node; void* extendedNode; NativeAppVector apps; NativeAppVector depots;
};
struct PackageFunctions {
    using GetPackage = NativePackageInfo* (*)(void*, uint32_t, uint64_t);
    using Grow = void* (*)(NativeAppVector*, int);
    using MarkChanged = void (*)(void*, uint32_t, bool);
    using Process = bool (*)(void*);
    GetPackage getPackage; Grow grow; MarkChanged markChanged; Process process;
};
enum class PackageSyncResult { Busy, NotReady, Unchanged, Changed, Invalid };

/// Called on a Steam ownership thread. It tracks only IDs it inserted, so
/// removal never removes an entry that was already in Steam's package.
class MacPackageSync {
public:
    PackageSyncResult reconcile(void* cache, void* user, const ConfigurationSnapshot* snapshot, const PackageFunctions& functions);
private:
    std::mutex mutex_;
    NativePackageInfo* package_ = nullptr;
    std::unordered_set<uint32_t> inserted_;
};
}
