#import <Foundation/Foundation.h>
#import <LocalAuthentication/LocalAuthentication.h>
#include "KeychainStore.h"
#include "include/Numbers.h"
#include <mutex>
#include <utility>

namespace {
using Status = OSTPlatform::SteamCredentialStore::Status;
constexpr size_t maxCredentialBytes = 16 * 1024 * 1024;
Status status(OSStatus code) {
    if (code == errSecSuccess) return Status::Ok;
    if (code == errSecItemNotFound) return Status::NotFound;
    return Status::Failed;
}
NSMutableDictionary* query(const std::string& service, SecKeychainRef keychain, uint32_t appID, const char* field, bool adding) {
    if (service.empty() || service.size() > 255 || !field || !*field) return nil;
    NSString* serviceName = [NSString stringWithUTF8String:service.c_str()];
    NSString* fieldName = [NSString stringWithUTF8String:field];
    if (!serviceName || !fieldName) return nil;
    NSMutableDictionary* value = [@{(__bridge id)kSecClass: (__bridge id)kSecClassGenericPassword,
        (__bridge id)kSecAttrService: serviceName,
        (__bridge id)kSecAttrAccount: [NSString stringWithFormat:@"%u/%@", appID, fieldName],
        (__bridge id)kSecAttrSynchronizable: @NO} mutableCopy];
    if (keychain) {
        if (adding) value[(__bridge id)kSecUseKeychain] = (__bridge id)keychain;
        else value[(__bridge id)kSecMatchSearchList] = @[(__bridge id)keychain];
    }
    LAContext* context = [LAContext new]; context.interactionNotAllowed = YES;
    value[(__bridge id)kSecUseAuthenticationContext] = context;
    return value;
}
std::mutex storeMutex;
std::shared_ptr<OSTPlatform::Apple::KeychainStore> configuredStore;
std::shared_ptr<OSTPlatform::Apple::KeychainStore> currentStore() {
    std::lock_guard lock(storeMutex);
    if (!configuredStore) configuredStore = std::make_shared<OSTPlatform::Apple::KeychainStore>("com.bettersteamtools.credentials");
    return configuredStore;
}
}
namespace OSTPlatform::Apple {
KeychainStore::KeychainStore(std::string service, SecKeychainRef keychain): service_(std::move(service)), keychain_(keychain) {
    if (keychain_) CFRetain(keychain_);
    else if (SecKeychainCopyDefault(&keychain_) != errSecSuccess) keychain_ = nullptr;
}
KeychainStore::~KeychainStore() { if (keychain_) CFRelease(keychain_); }
bool KeychainStore::unlocked() const {
    if (!keychain_) return false;
    SecKeychainStatus flags = 0;
    return SecKeychainGetStatus(keychain_, &flags) == errSecSuccess && (flags & kSecUnlockStateStatus);
}
SteamCredentialStore::Status KeychainStore::read(uint32_t appID, const char* field, std::vector<uint8_t>& output) const {
    @autoreleasepool {
        // Legacy file-based Keychains may attempt an automatic unlock before
        // honoring LAContext. Detect their locked state without requesting UI.
        if (!unlocked()) return Status::Failed;
        auto value = query(service_, keychain_, appID, field, false);
        if (!value) return Status::Failed;
        value[(__bridge id)kSecReturnData] = @YES;
        value[(__bridge id)kSecMatchLimit] = (__bridge id)kSecMatchLimitOne;
        CFTypeRef raw = nullptr;
        const auto code = SecItemCopyMatching((__bridge CFDictionaryRef)value, &raw);
        if (code != errSecSuccess) { if (raw) CFRelease(raw); return status(code); }
        if (!raw || CFGetTypeID(raw) != CFDataGetTypeID()) { if (raw) CFRelease(raw); return Status::Failed; }
        const auto data = static_cast<CFDataRef>(raw);
        const auto count = CFDataGetLength(data);
        if (count < 0 || static_cast<size_t>(count) > maxCredentialBytes) { CFRelease(raw); return Status::Failed; }
        std::vector<uint8_t> bytes(static_cast<size_t>(count));
        if (count) CFDataGetBytes(data, CFRangeMake(0, count), bytes.data());
        CFRelease(raw); output = std::move(bytes); return Status::Ok;
    }
}
SteamCredentialStore::Status KeychainStore::write(uint32_t appID, const char* field, const std::vector<uint8_t>& input) const {
    @autoreleasepool {
        if (!unlocked()) return Status::Failed;
        if (input.size() > maxCredentialBytes) return Status::Failed;
        auto existing = query(service_, keychain_, appID, field, false);
        if (!existing) return Status::Failed;
        NSData* bytes = [NSData dataWithBytes:input.data() length:input.size()];
        const auto updated = SecItemUpdate((__bridge CFDictionaryRef)existing,
            (__bridge CFDictionaryRef)@{(__bridge id)kSecValueData: bytes});
        if (updated != errSecItemNotFound) return status(updated);
        auto adding = query(service_, keychain_, appID, field, true);
        adding[(__bridge id)kSecValueData] = bytes;
        const auto added = SecItemAdd((__bridge CFDictionaryRef)adding, nullptr);
        if (added == errSecDuplicateItem) {
            return status(SecItemUpdate((__bridge CFDictionaryRef)existing,
                (__bridge CFDictionaryRef)@{(__bridge id)kSecValueData: bytes}));
        }
        return status(added);
    }
}
SteamCredentialStore::Status KeychainStore::remove(uint32_t appID, const char* field) const {
    @autoreleasepool {
        if (!unlocked()) return Status::Failed;
        auto value = query(service_, keychain_, appID, field, false);
        return value ? status(SecItemDelete((__bridge CFDictionaryRef)value)) : Status::Failed;
    }
}
void SetCredentialStore(std::shared_ptr<KeychainStore> store) { std::lock_guard lock(storeMutex); configuredStore = std::move(store); }
}
namespace OSTPlatform::SteamCredentialStore {
const char* ToString(Status value) {
    switch (value) { case Status::Ok: return "Ok"; case Status::NotFound: return "NotFound"; case Status::Unsupported: return "Unsupported"; case Status::Failed: return "Failed"; }
    return "Unknown";
}
Status GetAppTicket(uint32_t id, std::vector<uint8_t>& out) { return currentStore()->read(id, "AppTicket", out); }
Status WriteAppTicket(uint32_t id, const std::vector<uint8_t>& bytes) { return currentStore()->write(id, "AppTicket", bytes); }
Status GetETicket(uint32_t id, std::vector<uint8_t>& out) { return currentStore()->read(id, "ETicket", out); }
Status WriteETicket(uint32_t id, const std::vector<uint8_t>& bytes) { return currentStore()->write(id, "ETicket", bytes); }
Status GetSteamId(uint32_t id, uint64_t& output) {
    std::vector<uint8_t> bytes;
    const auto result = currentStore()->read(id, "SteamID", bytes);
    if (result != Status::Ok) return result;
    const auto value = Numbers::ParseUInt64(std::string(bytes.begin(), bytes.end()));
    if (!value || !*value) return Status::NotFound;
    output = *value; return Status::Ok;
}
Status WriteSteamId(uint32_t id, uint64_t value) {
    const auto text = std::to_string(value);
    return currentStore()->write(id, "SteamID", {text.begin(), text.end()});
}
}
