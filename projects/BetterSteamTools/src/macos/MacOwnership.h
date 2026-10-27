#pragma once
#include "MacConfiguration.h"
#include <cstdint>
namespace BST::Mac {
struct NativeAppOwnership {
    uint32_t packageID, releaseState, steamID32, masterSubscriptionAppID, trialSeconds, existInPackageNums;
    char purchaseCountryCode[4]; uint32_t timeStamp, timeExpire;
    bool ownsLicense, licenseExpired, permanent, lowViolence, freeLicense, regionRestricted, freeWeekend, licenseLocked;
    bool licensePending, retailLicense, autoGrant, licensePermanent, guestPass, borrowed, anySiteLicense, allSiteLicenses, allActivationRequired, familyShared;
};
struct OwnershipDecision { bool result; bool genuinelyOwned; };
OwnershipDecision ApplyOwnership(const ConfigurationSnapshot* snapshot, uint32_t appID, bool originalResult, NativeAppOwnership* ownership);
}
