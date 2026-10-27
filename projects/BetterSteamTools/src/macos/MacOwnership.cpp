#include "MacOwnership.h"
#include "OSTPlatform/include/Memory.h"
#include "OSTPlatform/Apple/CodePatch.h"
#include <cstddef>
#include <limits>

namespace BST::Mac {
static_assert(offsetof(NativeAppOwnership, ownsLicense) == 36 && offsetof(NativeAppOwnership, freeLicense) == 40 && offsetof(NativeAppOwnership, familyShared) == 53);
OwnershipDecision ApplyOwnership(const ConfigurationSnapshot* snapshot, uint32_t appID, bool result, NativeAppOwnership* ownership) {
    if (!snapshot || !snapshot->depots.contains(appID) || !ownership) return {result, false};
    const auto address = reinterpret_cast<uintptr_t>(ownership);
    if (address > std::numeric_limits<uintptr_t>::max() - sizeof(*ownership) ||
        !OSTPlatform::Memory::IsReadable(ownership, sizeof(*ownership)) ||
        !OSTPlatform::Apple::IsWritable(ownership) || !OSTPlatform::Apple::IsWritable(reinterpret_cast<const uint8_t*>(ownership) + sizeof(*ownership) - 1)) return {result, false};
    if (result && ownership->existInPackageNums > 1) {
        ownership->releaseState = 4;
        return {true, true};
    }
    ownership->packageID = 0;
    ownership->releaseState = 4;
    ownership->ownsLicense = true;
    ownership->freeLicense = false;
    return {true, false};
}
}
