#include "include/Memory.h"
#include "LibraryImage.h"
#include <mach/mach.h>
#include <mach/mach_vm.h>
#include <mach-o/loader.h>
#include <libkern/OSCacheControl.h>
#include <algorithm>
#include <cstring>
#include <limits>

namespace OSTPlatform::Memory {
bool IsReadable(const void *address, size_t bytes) {
    if (!bytes) return true;
    if (!address) return false;
    const auto start = reinterpret_cast<uintptr_t>(address);
    if (bytes > std::numeric_limits<uintptr_t>::max() - start) return false;
    const auto end = start + bytes;
    auto cursor = start;
    while (cursor < end) {
        mach_vm_address_t region = cursor;
        mach_vm_size_t length = 0;
        vm_region_basic_info_data_64_t information{};
        mach_msg_type_number_t count = VM_REGION_BASIC_INFO_COUNT_64;
        mach_port_t object = MACH_PORT_NULL;
        auto result = mach_vm_region(mach_task_self(), &region, &length, VM_REGION_BASIC_INFO_64, reinterpret_cast<vm_region_info_t>(&information), &count, &object);
        if (object != MACH_PORT_NULL) mach_port_deallocate(mach_task_self(), object);
        if (result != KERN_SUCCESS || region > cursor || !length || !(information.protection & VM_PROT_READ)) return false;
        if (length > std::numeric_limits<uintptr_t>::max() - region) return false;
        cursor = region + length;
    }
    return true;
}
std::optional<ModuleImage> GetModuleImage(DynamicLibrary::ModuleHandle module) {
    intptr_t slide = 0;
    auto header = Apple::ImageHeader(module, slide);
    if (!header || !IsReadable(header, sizeof *header)) return std::nullopt;
    const auto commands = reinterpret_cast<const uint8_t*>(header + 1);
    if (!IsReadable(commands, header->sizeofcmds)) return std::nullopt;
    size_t offset = 0;
    for (uint32_t i = 0; i < header->ncmds; ++i) {
        if (offset > header->sizeofcmds || header->sizeofcmds - offset < sizeof(load_command)) return std::nullopt;
        const auto command = reinterpret_cast<const load_command*>(commands + offset);
        if (command->cmdsize < sizeof(load_command) || command->cmdsize > header->sizeofcmds - offset) return std::nullopt;
        if (command->cmd == LC_SEGMENT_64 && command->cmdsize >= sizeof(segment_command_64)) {
            const auto segment = reinterpret_cast<const segment_command_64*>(command);
            // Existing pattern scanning expects one fully readable span. Only the
            // code/constant __TEXT mapping meets that contract on Mach-O.
            if (strncmp(segment->segname, "__TEXT", sizeof segment->segname) == 0) {
                const auto base = static_cast<uintptr_t>(segment->vmaddr + slide);
                if (!IsReadable(reinterpret_cast<const void*>(base), segment->vmsize)) return std::nullopt;
                return ModuleImage{reinterpret_cast<uint8_t*>(base), static_cast<size_t>(segment->vmsize)};
            }
        }
        offset += command->cmdsize;
    }
    return std::nullopt;
}
bool WriteExecutableByte(void *address, uint8_t value) {
#if defined(__aarch64__)
    // AArch64 instructions are four bytes and require atomic instruction writes.
    // Never translate the Windows INT3 byte operation into corrupt ARM64 code.
    (void)address; (void)value;
    return false;
#else
    if (!IsReadable(address, 1)) return false;
    const auto page = reinterpret_cast<mach_vm_address_t>(address) & ~(static_cast<mach_vm_address_t>(vm_page_size) - 1);
    mach_vm_address_t region = page; mach_vm_size_t length = 0;
    vm_region_basic_info_data_64_t info{}; mach_msg_type_number_t count = VM_REGION_BASIC_INFO_COUNT_64;
    mach_port_t object = MACH_PORT_NULL;
    const auto queried = mach_vm_region(mach_task_self(), &region, &length, VM_REGION_BASIC_INFO_64, reinterpret_cast<vm_region_info_t>(&info), &count, &object);
    if (object != MACH_PORT_NULL) mach_port_deallocate(mach_task_self(), object);
    if (queried != KERN_SUCCESS) return false;
    if (mach_vm_protect(mach_task_self(), page, vm_page_size, false, VM_PROT_READ | VM_PROT_WRITE | VM_PROT_COPY) != KERN_SUCCESS) return false;
    *static_cast<volatile uint8_t*>(address) = value;
    const bool restored = mach_vm_protect(mach_task_self(), page, vm_page_size, false, info.protection) == KERN_SUCCESS;
    sys_icache_invalidate(address, 1);
    return restored;
#endif
}
}
