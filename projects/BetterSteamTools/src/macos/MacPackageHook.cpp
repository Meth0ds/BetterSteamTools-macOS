#include "MacPackageHook.h"
#include "MacPackageSync.h"
#include <atomic>

namespace BST::Mac {
namespace {
void* original = nullptr;
std::atomic<void*> cache{nullptr};
std::atomic<uintptr_t> grow{0}, mark{0}, process{0};
MacPackageSync synchronizer;
NativePackageInfo* getPackage(void* object, uint32_t packageID, uint64_t token) {
    const auto next = reinterpret_cast<PackageFunctions::GetPackage>(std::atomic_ref<void*>(original).load(std::memory_order_acquire));
    if (!next) return nullptr;
    auto* result = next(object, packageID, token);
    if (object && result) cache.store(object, std::memory_order_release);
    return result;
}
}
void** PackageGetOriginalSlot() { return &original; }
void* PackageGetReplacement() { return reinterpret_cast<void*>(&getPackage); }
void ConfigurePackageFunctions(uintptr_t growth, uintptr_t changed, uintptr_t pending) {
    grow.store(growth, std::memory_order_release); mark.store(changed, std::memory_order_release); process.store(pending, std::memory_order_release);
}
void ReconcilePackageForUser(void* user) noexcept {
    try {
        const auto snapshot = GetConfigurationSnapshot();
        const PackageFunctions functions{
            reinterpret_cast<PackageFunctions::GetPackage>(std::atomic_ref<void*>(original).load(std::memory_order_acquire)),
            reinterpret_cast<PackageFunctions::Grow>(grow.load(std::memory_order_acquire)),
            reinterpret_cast<PackageFunctions::MarkChanged>(mark.load(std::memory_order_acquire)),
            reinterpret_cast<PackageFunctions::Process>(process.load(std::memory_order_acquire))
        };
        synchronizer.reconcile(cache.load(std::memory_order_acquire), user, snapshot.get(), functions);
    } catch (...) { /* Never unwind through Steam's native ABI. */ }
}
}
