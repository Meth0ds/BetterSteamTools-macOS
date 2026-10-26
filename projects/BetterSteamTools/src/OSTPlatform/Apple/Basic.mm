#import <Foundation/Foundation.h>
#include "include/DynamicLibrary.h"
#include "include/Encoding.h"
#include "include/Hash.h"
#include "include/Thread.h"
#include <CommonCrypto/CommonDigest.h>
#include <mach-o/dyld.h>
#include <dlfcn.h>
#include <cerrno>
#include <climits>
#include <cstdio>
#include <map>
#include <mutex>
#include <thread>
#include <vector>

namespace OSTPlatform::Encoding {
std::string WideToUtf8(std::wstring_view value) {
    if (value.empty()) return {};
    @autoreleasepool {
        // Darwin wchar_t is UTF-32; reject malformed scalar values instead of replacing them.
        NSString *text = [[NSString alloc] initWithBytes:value.data() length:value.size() * sizeof(wchar_t) encoding:NSUTF32LittleEndianStringEncoding];
        NSData *data = [text dataUsingEncoding:NSUTF8StringEncoding allowLossyConversion:NO];
        return data ? std::string(static_cast<const char*>(data.bytes), data.length) : std::string{};
    }
}
std::wstring Utf8ToWide(std::string_view value) {
    if (value.empty()) return {};
    @autoreleasepool {
        NSString *text = [[NSString alloc] initWithBytes:value.data() length:value.size() encoding:NSUTF8StringEncoding];
        NSData *data = [text dataUsingEncoding:NSUTF32LittleEndianStringEncoding allowLossyConversion:NO];
        if (!data || data.length % sizeof(wchar_t)) return {};
        std::wstring out(data.length / sizeof(wchar_t), L'\0');
        memcpy(out.data(), data.bytes, data.length);
        return out;
    }
}
}
namespace OSTPlatform::Hash {
static std::string hex(const unsigned char *bytes) {
    constexpr char digits[] = "0123456789abcdef";
    std::string result(CC_SHA256_DIGEST_LENGTH * 2, '0');
    for (size_t i = 0; i < CC_SHA256_DIGEST_LENGTH; ++i) {
        result[2*i] = digits[bytes[i] >> 4]; result[2*i+1] = digits[bytes[i] & 15];
    }
    return result;
}
std::string Sha256OfBuffer(const void *data, size_t count) {
    if (!data && count) return {};
    CC_SHA256_CTX state; CC_SHA256_Init(&state);
    const auto *cursor = static_cast<const unsigned char*>(data);
    while (count) {
        auto chunk = static_cast<CC_LONG>(std::min<size_t>(count, UINT32_MAX));
        CC_SHA256_Update(&state, cursor, chunk); cursor += chunk; count -= chunk;
    }
    unsigned char digest[CC_SHA256_DIGEST_LENGTH]; CC_SHA256_Final(digest, &state);
    return hex(digest);
}
std::string Sha256OfFile(const std::filesystem::path& path) {
    FILE *file = fopen(path.c_str(), "rb");
    if (!file) return {};
    CC_SHA256_CTX state; CC_SHA256_Init(&state);
    unsigned char block[65536]; size_t count;
    while ((count = fread(block, 1, sizeof block, file)) != 0) { CC_SHA256_Update(&state, block, static_cast<CC_LONG>(count)); }
    const bool failed = ferror(file); fclose(file);
    if (failed) return {};
    unsigned char digest[CC_SHA256_DIGEST_LENGTH]; CC_SHA256_Final(digest, &state);
    return hex(digest);
}
}
namespace OSTPlatform::DynamicLibrary {
namespace {
std::mutex mutex;
std::map<void*, std::filesystem::path> paths;
thread_local uint32_t errorCode = 0;
ModuleHandle open(const std::filesystem::path& path, int mode) {
    dlerror();
    auto handle = dlopen(path.c_str(), mode);
    errorCode = handle ? 0 : ENOENT;
    if (handle) { std::lock_guard lock(mutex); paths[handle] = path; }
    return handle;
}
}
ModuleHandle Load(const std::filesystem::path& path) { return open(path, RTLD_LOCAL | RTLD_NOW); }
ModuleHandle GetLoaded(std::string_view name) {
    for (uint32_t i = 0; i < _dyld_image_count(); ++i) {
        const char *raw = _dyld_get_image_name(i);
        if (!raw) continue;
        const std::filesystem::path path(raw);
        if (name == path.string() || name == path.filename().string()) return open(path, RTLD_NOLOAD | RTLD_LAZY);
    }
    errorCode = ENOENT; return nullptr;
}
void *GetSymbol(ModuleHandle module, const char *name) {
    if (!module || !name) { errorCode = EINVAL; return nullptr; }
    dlerror();
    void *address = dlsym(module, name);
    errorCode = dlerror() ? ENOENT : 0;
    return errorCode ? nullptr : address;
}
void *GetSymbol(ModuleHandle, uint16_t) { errorCode = ENOTSUP; return nullptr; }
uint32_t GetLastErrorCode() { return errorCode; }
std::string GetCurrentDirectoryPath() { std::error_code ec; auto path = std::filesystem::current_path(ec); return ec ? "" : path.string(); }
std::string GetSystemDirectoryPath() { return "/System/Library"; }
std::filesystem::path GetModuleDirectory(ModuleHandle module) {
    std::lock_guard lock(mutex);
    const auto item = paths.find(module);
    return item == paths.end() ? std::filesystem::path{} : item->second.parent_path();
}
std::filesystem::path GetMainExecutablePath() {
    uint32_t size = 0; _NSGetExecutablePath(nullptr, &size);
    std::vector<char> buffer(size);
    if (_NSGetExecutablePath(buffer.data(), &size) != 0) return {};
    std::error_code ec; auto canonical = std::filesystem::canonical(buffer.data(), ec);
    return ec ? std::filesystem::path(buffer.data()) : canonical;
}
}
namespace OSTPlatform::Thread {
NativeThreadHandle CurrentNativeThreadHandle() { return reinterpret_cast<void*>(pthread_self()); }
bool StartDetached(std::function<uint32_t()> entry) {
    if (!entry) return false;
    try { std::thread([entry = std::move(entry)] { try { entry(); } catch (...) {} }).detach(); return true; }
    catch (...) { return false; }
}
}

namespace OSTPlatform::Apple {
const mach_header_64* ImageHeader(DynamicLibrary::ModuleHandle module, intptr_t& slide) {
    const auto directory = DynamicLibrary::GetModuleDirectory(module);
    if (directory.empty()) return nullptr;
    // The loader has retained a dlopen reference. Its mapped image cannot disappear
    // while this library owns the handle.
    for (uint32_t i = 0; i < _dyld_image_count(); ++i) {
        const char *name = _dyld_get_image_name(i);
        if (!name || std::filesystem::path(name).parent_path() != directory) continue;
        // A directory alone is not an identity: verify dlsym's module handle too.
        void *probe = dlopen(name, RTLD_NOLOAD | RTLD_LAZY);
        if (!probe) continue;
        const bool same = probe == module;
        dlclose(probe);
        if (!same) continue;
        auto header = _dyld_get_image_header(i);
        if (!header || header->magic != MH_MAGIC_64) return nullptr;
        slide = _dyld_get_image_vmaddr_slide(i);
        return reinterpret_cast<const mach_header_64*>(header);
    }
    return nullptr;
}
}
