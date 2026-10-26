#include "CodePatch.h"
#include "include/Memory.h"
#include <mach/mach.h>
#include <mach/mach_vm.h>
#include <libkern/OSCacheControl.h>
#include <cstring>
#include <mutex>

namespace OSTPlatform::Apple {
namespace {
std::mutex patchMutex;
thread_local std::string lastError;
bool Fail(const char* operation, kern_return_t code) {
    lastError = std::string(operation) + ": " + mach_error_string(code);
    return false;
}
bool Protection(const void* address, vm_prot_t& protection, vm_prot_t* maximum = nullptr) {
    auto region = reinterpret_cast<mach_vm_address_t>(address);
    const auto wanted = region;
    mach_vm_size_t length = 0;
    vm_region_basic_info_data_64_t info{};
    mach_msg_type_number_t count = VM_REGION_BASIC_INFO_COUNT_64;
    mach_port_t object = MACH_PORT_NULL;
    const auto result = mach_vm_region(mach_task_self(), &region, &length, VM_REGION_BASIC_INFO_64, reinterpret_cast<vm_region_info_t>(&info), &count, &object);
    if (object != MACH_PORT_NULL) mach_port_deallocate(mach_task_self(), object);
    if (result != KERN_SUCCESS || region > wanted || wanted - region >= length) return false;
    protection = info.protection;
    if (maximum) *maximum = info.max_protection;
    return true;
}
}
bool IsExecutable(const void* address) {
    vm_prot_t protection = 0;
    return address && Protection(address, protection) && (protection & (VM_PROT_READ | VM_PROT_EXECUTE)) == (VM_PROT_READ | VM_PROT_EXECUTE);
}
bool IsWritable(const void* address) {
    vm_prot_t protection = 0;
    return address && Protection(address, protection) && (protection & (VM_PROT_READ | VM_PROT_WRITE)) == (VM_PROT_READ | VM_PROT_WRITE);
}
std::string CodePatchLastError() { return lastError; }
bool ReplaceCode(void* address, std::span<const uint8_t> expected, std::span<const uint8_t> replacement) {
    lastError.clear();
    if (!address || expected.empty() || expected.size() != replacement.size() || (reinterpret_cast<uintptr_t>(address) & 3) || (replacement.size() & 3)) return false;
    const auto page = reinterpret_cast<mach_vm_address_t>(address) & ~(mach_vm_address_t(vm_page_size) - 1);
    const auto offset = reinterpret_cast<uintptr_t>(address) - page;
    if (replacement.size() > vm_page_size - offset) return false;
    std::lock_guard lock(patchMutex);
    vm_prot_t original = 0, originalMaximum = 0;
    if (!Protection(address, original, &originalMaximum) || !(original & VM_PROT_EXECUTE) || !Memory::IsReadable(reinterpret_cast<void*>(page), vm_page_size) ||
        std::memcmp(address, expected.data(), expected.size()) != 0) return false;
    mach_vm_address_t copy = 0;
    auto result = mach_vm_allocate(mach_task_self(), &copy, vm_page_size, VM_FLAGS_ANYWHERE);
    if (result != KERN_SUCCESS) return Fail("allocate replacement page", result);
    struct Release { mach_vm_address_t address; ~Release() { mach_vm_deallocate(mach_task_self(), address, vm_page_size); } } release{copy};
    std::memcpy(reinterpret_cast<void*>(copy), reinterpret_cast<void*>(page), vm_page_size);
    std::memcpy(reinterpret_cast<void*>(copy + offset), replacement.data(), replacement.size());
    result = mach_vm_protect(mach_task_self(), copy, vm_page_size, false, original & ~VM_PROT_WRITE);
    if (result != KERN_SUCCESS) return Fail("protect replacement page RX", result);
    vm_prot_t copyCurrent = 0, copyMaximum = 0;
    if (!Protection(reinterpret_cast<void*>(copy), copyCurrent, &copyMaximum)) return Fail("query replacement page protection", KERN_FAILURE);
    // ARM64 executable-memory policy may already have reduced the new page's
    // maximum rights. Never try to increase them or grant rights the old page lacked.
    if (copyMaximum & ~originalMaximum) {
        result = mach_vm_protect(mach_task_self(), copy, vm_page_size, true, originalMaximum & copyMaximum);
        if (result != KERN_SUCCESS) return Fail("preserve maximum page protection", result);
    }
    sys_icache_invalidate(reinterpret_cast<void*>(copy), vm_page_size);
    // Another injector must not have replaced our expected entry while the page
    // was prepared. Never knowingly overwrite a foreign hook.
    if (std::memcmp(address, expected.data(), expected.size()) != 0) return false;
    mach_vm_address_t destination = page;
    vm_prot_t current = 0, maximum = 0;
    result = mach_vm_remap(mach_task_self(), &destination, vm_page_size, 0, VM_FLAGS_FIXED | VM_FLAGS_OVERWRITE,
                      mach_task_self(), copy, true, &current, &maximum, VM_INHERIT_COPY);
    if (result != KERN_SUCCESS) return Fail("remap executable page", result);
    sys_icache_invalidate(reinterpret_cast<void*>(page), vm_page_size);
    return std::memcmp(address, replacement.data(), replacement.size()) == 0;
}
}
