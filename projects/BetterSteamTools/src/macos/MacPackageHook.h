#pragma once
#include <cstdint>
namespace BST::Mac {
void** PackageGetOriginalSlot();
void* PackageGetReplacement();
void ConfigurePackageFunctions(uintptr_t grow, uintptr_t markChanged, uintptr_t process);
void ReconcilePackageForUser(void* user) noexcept;
}
