#include "MacPackageSync.h"
#include "OSTPlatform/include/Memory.h"
#include "OSTPlatform/Apple/CodePatch.h"
#include <mach/mach.h>
#include <algorithm>
#include <cstddef>
#include <limits>
#include <vector>

namespace BST::Mac {
static_assert(sizeof(NativeAppVector) == 24 && offsetof(NativeAppVector, size) == 16);
static_assert(offsetof(NativePackageInfo, status) == 0x18 && offsetof(NativePackageInfo, apps) == 0x40 && offsetof(NativePackageInfo, depots) == 0x58);
namespace {
constexpr uint64_t packageToken = 10660652434190618804ull;
constexpr size_t maxEntries = 1'000'000;
bool writable(const void* ptr, size_t bytes) {
    if (!bytes) return true;
    const auto begin = reinterpret_cast<uintptr_t>(ptr);
    if (!ptr || bytes - 1 > std::numeric_limits<uintptr_t>::max() - begin || !OSTPlatform::Memory::IsReadable(ptr, bytes)) return false;
    const auto end = begin + bytes - 1;
    for (auto address = begin;;) {
        if (!OSTPlatform::Apple::IsWritable(reinterpret_cast<const void*>(address))) return false;
        if (end - address < vm_page_size - (address % vm_page_size)) break;
        address += vm_page_size - (address % vm_page_size);
    }
    return true;
}
bool validVector(const NativeAppVector& vector) {
    if (vector.capacity > maxEntries || vector.size > vector.capacity || vector.growSize < 0) return false;
    if (!vector.capacity) return vector.memory == nullptr && vector.size == 0;
    return writable(vector.memory, static_cast<size_t>(vector.capacity) * sizeof(uint32_t));
}
}

PackageSyncResult MacPackageSync::reconcile(void* cache, void* user, const ConfigurationSnapshot* snapshot, const PackageFunctions& functions) {
    std::unique_lock lock(mutex_, std::try_to_lock);
    if (!lock.owns_lock()) return PackageSyncResult::Busy;
    if (!cache || !user || !functions.getPackage || !functions.grow || !functions.markChanged || !functions.process) return PackageSyncResult::NotReady;
    if ((!snapshot || snapshot->depots.empty()) && inserted_.empty()) return PackageSyncResult::Unchanged;
    auto* package = functions.getPackage(cache, 0, packageToken);
    if (!package || !writable(package, sizeof(NativePackageInfo))) return PackageSyncResult::Invalid;
    if (package->packageID != 0 || package->status != 0) return PackageSyncResult::NotReady;
    auto& apps = package->apps;
    if (!validVector(apps)) return PackageSyncResult::Invalid;
    if (package_ != package) { package_ = package; inserted_.clear(); }
    std::unordered_set<uint32_t> existing;
    for (uint32_t i = 0; i < apps.size; ++i) existing.insert(apps.memory[i]);
    std::unordered_set<uint32_t> nextManaged;
    std::vector<uint32_t> additions;
    if (snapshot) {
        for (const auto& [id, key] : snapshot->depots) {
            if (!id) continue;
            if (inserted_.contains(id) && existing.contains(id)) nextManaged.insert(id);
            if (!existing.contains(id)) { additions.push_back(id); nextManaged.insert(id); }
        }
    }
    std::vector<uint32_t> removals;
    for (const auto id : inserted_) if (!nextManaged.contains(id) && existing.contains(id)) removals.push_back(id);
    if (additions.empty() && removals.empty()) { inserted_ = std::move(nextManaged); return PackageSyncResult::Unchanged; }
    // Grow before removing anything. The reviewed Steam allocator grows the
    // capacity but leaves vector.size unchanged; update size ourselves.
    if (additions.size() > maxEntries - apps.size) return PackageSyncResult::Invalid;
    const auto required = static_cast<uint32_t>(apps.size + additions.size());
    if (required > apps.capacity) {
        const auto growth = required - apps.capacity;
        if (growth > static_cast<uint32_t>(std::numeric_limits<int>::max())) return PackageSyncResult::Invalid;
        functions.grow(&apps, static_cast<int>(growth));
        if (!validVector(apps) || apps.capacity < required) return PackageSyncResult::Invalid;
    }
    for (const auto id : removals) {
        auto* match = std::find(apps.memory, apps.memory + apps.size, id);
        if (match != apps.memory + apps.size) { *match = apps.memory[apps.size - 1]; --apps.size; }
    }
    std::sort(additions.begin(), additions.end());
    for (const auto id : additions) apps.memory[apps.size++] = id;
    inserted_ = std::move(nextManaged);
    functions.markChanged(user, 0, true);
    functions.process(user);
    return PackageSyncResult::Changed;
}
}
