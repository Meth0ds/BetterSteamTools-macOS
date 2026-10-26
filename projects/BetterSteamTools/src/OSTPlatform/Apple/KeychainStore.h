#pragma once
#include "include/SteamCredentialStore.h"
#include <Security/Security.h>
#include <memory>
#include <string>

namespace OSTPlatform::Apple {
// A dedicated service namespace avoids modifying Steam passwords or unrelated
// Keychain items. An explicit Keychain permits isolated integration fixtures.
class KeychainStore {
public:
    explicit KeychainStore(std::string service, SecKeychainRef keychain = nullptr);
    ~KeychainStore();
    KeychainStore(const KeychainStore&) = delete;
    KeychainStore& operator=(const KeychainStore&) = delete;
    SteamCredentialStore::Status read(uint32_t appID, const char* field, std::vector<uint8_t>& output) const;
    SteamCredentialStore::Status write(uint32_t appID, const char* field, const std::vector<uint8_t>& input) const;
    SteamCredentialStore::Status remove(uint32_t appID, const char* field) const;
private:
    bool unlocked() const;
    std::string service_;
    SecKeychainRef keychain_;
};
// Configure before executing Lua. The default is the current user's login
// Keychain with the com.bettersteamtools.credentials service namespace.
void SetCredentialStore(std::shared_ptr<KeychainStore> store);
}
