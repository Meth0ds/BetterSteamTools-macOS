#include "../MacOwnership.h"
#include <iostream>
#include <stdexcept>
using namespace BST::Mac;
static void check(bool value, const char* message) { if (!value) throw std::runtime_error(message); }
int main() {
    try {
        ConfigurationSnapshot snapshot; snapshot.depots[42] = {};
        NativeAppOwnership ownership{}; ownership.packageID = 99; ownership.releaseState = 2; ownership.freeLicense = true;
        auto missing = ApplyOwnership(&snapshot, 41, false, &ownership);
        check(!missing.result && ownership.packageID == 99 && ownership.releaseState == 2, "unconfigured app is unchanged");
        auto added = ApplyOwnership(&snapshot, 42, false, &ownership);
        check(added.result && !added.genuinelyOwned && ownership.packageID == 0 && ownership.releaseState == 4 && ownership.ownsLicense && !ownership.freeLicense, "configured app uses package zero");
        ownership.packageID = 7; ownership.releaseState = 2; ownership.existInPackageNums = 2; ownership.ownsLicense = false;
        auto owned = ApplyOwnership(&snapshot, 42, true, &ownership);
        check(owned.result && owned.genuinelyOwned && ownership.packageID == 7 && ownership.releaseState == 4 && !ownership.ownsLicense, "genuine package remains intact");
        ownership.existInPackageNums = 1; ownership.packageID = 9; ownership.freeLicense = true;
        auto shared = ApplyOwnership(&snapshot, 42, true, &ownership);
        check(shared.result && !shared.genuinelyOwned && ownership.packageID == 0 && ownership.ownsLicense && !ownership.freeLicense, "single-package ownership follows Windows override");
        check(!ApplyOwnership(nullptr, 42, false, &ownership).result && !ApplyOwnership(&snapshot, 42, false, nullptr).result, "disabled config and null outputs fail safely");
        std::cout << "PASS: configured, genuine, shared and unmanaged ownership decisions\n"; return 0;
    } catch (const std::exception& error) { std::cerr << "FAIL: " << error.what() << '\n'; return 1; }
}
