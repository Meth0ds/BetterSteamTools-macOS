#include "include/Detour.h"
#include "include/Memory.h"
#include "Arm64Relocator.h"
#include "CodePatch.h"
#include "DetourDiagnostics.h"
#include <mach/mach.h>
#include <mach/mach_vm.h>
#include <libkern/OSCacheControl.h>
#include <array>
#include <algorithm>
#include <atomic>
#include <cstring>
#include <map>
#include <mutex>
#include <optional>
#include <thread>
#include <vector>

namespace {
thread_local std::string detourError;
bool Fail(std::string message) { detourError = std::move(message); return false; }
}
namespace OSTPlatform::Apple {
std::string DetourLastError() { return detourError; }
}

namespace OSTPlatform::Detour {
namespace {
using Apple::Arm64::Branch;
constexpr size_t slotBytes = 128;
constexpr size_t maxPages = 64;
struct Page { mach_vm_address_t address; size_t used; };
struct Hook {
    void** slot;
    void* address;
    void* replacement;
    void* trampoline;
    uint32_t original;
    uint32_t patched;
};
struct Operation { bool attach; void** slot; void* replacement; void* initial; };
struct Transaction { bool failed = false; std::vector<Operation> operations; };
std::mutex mutex;
std::vector<Page> pages;
std::map<void*, Hook> hooks;
thread_local std::optional<Transaction> transaction;

std::span<const uint8_t> Bytes(const uint32_t& value) { return {reinterpret_cast<const uint8_t*>(&value), sizeof value}; }
void Store(void** slot, void* pointer) { std::atomic_ref<void*>(*slot).store(pointer, std::memory_order_release); }
void* Load(void** slot) { return std::atomic_ref<void*>(*slot).load(std::memory_order_acquire); }
bool ReadInstruction(void* address, uint32_t& output) {
    if ((reinterpret_cast<uintptr_t>(address) & 3) || !Apple::IsExecutable(address) || !Memory::IsReadable(address, 4)) return false;
    std::memcpy(&output, address, 4);
    return true;
}

std::optional<uintptr_t> ReserveSlot(uintptr_t address) {
    for (auto& page : pages) {
        const auto next = page.address + page.used;
        if (page.used + slotBytes <= vm_page_size && Branch(address, next) && Branch(next + 96, address + 4)) {
            page.used += slotBytes;
            return next;
        }
    }
    if (pages.size() >= maxPages) return std::nullopt;
    const auto aligned = address & ~(uintptr_t(vm_page_size) - 1);
    // Fixed reservations never overwrite an existing mapping. Searching both
    // directions finds a free page within the ARM64 B instruction's ±128 MiB.
    const size_t limit = (uintptr_t{1} << 27) / vm_page_size;
    for (size_t distance = 1; distance < limit; ++distance) {
        for (bool above : {true, false}) {
            if (!above && aligned < distance * vm_page_size) continue;
            auto candidate = above ? aligned + distance * vm_page_size : aligned - distance * vm_page_size;
            if (!Branch(address, candidate) || !Branch(candidate + 96, address + 4)) continue;
            mach_vm_address_t region = candidate;
            if (mach_vm_allocate(mach_task_self(), &region, vm_page_size, VM_FLAGS_FIXED) != KERN_SUCCESS) continue;
            // An RX page of zeroes has no published entry points until its slot
            // is prepared. Later slots use the same atomic page replacement.
            if (mach_vm_protect(mach_task_self(), region, vm_page_size, false, VM_PROT_READ | VM_PROT_EXECUTE) != KERN_SUCCESS) {
                mach_vm_deallocate(mach_task_self(), region, vm_page_size); continue;
            }
            pages.push_back({region, slotBytes});
            return region;
        }
    }
    return std::nullopt;
}
std::optional<Hook> Prepare(const Operation& operation) {
    uint32_t original = 0;
    if (hooks.contains(operation.initial)) { Fail("Target already has an owned hook"); return std::nullopt; }
    if (!ReadInstruction(operation.initial, original) || !Apple::IsExecutable(operation.replacement)) {
        Fail("Target or replacement is not readable executable memory"); return std::nullopt;
    }
    const auto address = reinterpret_cast<uintptr_t>(operation.initial);
    // Check relocation before reserving executable memory as well as at its
    // final address. Unsupported/foreign branch entries never get patched.
    if (!Apple::Arm64::RelocateEntry(original, address, address + 64)) {
        Fail("Unsupported or already redirected ARM64 entry instruction: " + std::to_string(original)); return std::nullopt;
    }
    const auto slot = ReserveSlot(address);
    if (!slot) { Fail("No executable trampoline slot available within ARM64 branch range"); return std::nullopt; }
    const auto trampoline = *slot + 32;
    const auto relocated = Apple::Arm64::RelocateEntry(original, address, trampoline);
    const auto patched = Branch(address, *slot);
    if (!relocated || !patched || relocated->size() * 4 > slotBytes - 32) { Fail("Relocated entry is outside supported branch range"); return std::nullopt; }
    std::array<uint8_t, slotBytes> code{}, expected{};
    const uint32_t load = 0x58000051u; // LDR X17, PC+8
    const uint32_t jump = 0xD61F0220u; // BR X17 (ABI veneer scratch register)
    const auto replacement = reinterpret_cast<uint64_t>(operation.replacement);
    std::memcpy(code.data(), &load, 4); std::memcpy(code.data() + 4, &jump, 4);
    std::memcpy(code.data() + 8, &replacement, 8);
    std::memcpy(code.data() + 32, relocated->data(), relocated->size() * 4);
    if (!Apple::ReplaceCode(reinterpret_cast<void*>(*slot), expected, code)) {
        Fail("Cannot prepare trampoline: " + Apple::CodePatchLastError()); return std::nullopt;
    }
    return Hook{operation.slot, operation.initial, operation.replacement, reinterpret_cast<void*>(trampoline), original, *patched};
}
bool Apply(const Hook& hook, bool attach) {
    if (attach) {
        Store(hook.slot, hook.trampoline); // Publish original before the redirect can execute.
        if (Apple::ReplaceCode(hook.address, Bytes(hook.original), Bytes(hook.patched))) return true;
        Store(hook.slot, hook.address);
        return Fail("Cannot apply redirect: " + Apple::CodePatchLastError());
    } else {
        if (!Apple::ReplaceCode(hook.address, Bytes(hook.patched), Bytes(hook.original))) return Fail("Cannot restore owned entry: " + Apple::CodePatchLastError());
        Store(hook.slot, hook.address);
        return true;
    }
    return false;
}
bool Stage(bool attach, void** slot, void* replacement) {
    if (!transaction) return Fail("No active transaction on this thread");
    if (!slot || (reinterpret_cast<uintptr_t>(slot) % alignof(void*)) || !replacement || !Memory::IsReadable(slot, sizeof(void*)) || !Apple::IsWritable(slot)) {
        transaction->failed = true; return Fail("Invalid, unaligned or non-writable original-function slot");
    }
    for (const auto& operation : transaction->operations) {
        if (operation.slot == slot) { transaction->failed = true; return Fail("Original-function slot appears twice in one transaction"); }
    }
    auto initial = Load(slot);
    if (!initial || !Apple::IsExecutable(replacement)) { transaction->failed = true; return Fail("Null original or non-executable replacement"); }
    transaction->operations.push_back({attach, slot, replacement, initial});
    return true;
}
}

bool BeginTransaction() {
    if (transaction) return Fail("A transaction is already active on this thread");
    detourError.clear();
    transaction.emplace(); return true;
}
bool Attach(void** target, void* replacement) { return Stage(true, target, replacement); }
bool Detach(void** target, void* replacement) { return Stage(false, target, replacement); }
bool CommitTransaction() {
    if (!transaction) return Fail("No active transaction on this thread");
    auto staged = std::move(*transaction); transaction.reset();
    if (staged.failed) return false;
    std::lock_guard lock(mutex);
    std::vector<std::pair<Hook, bool>> prepared;
    std::map<void*, bool> addresses;
    // Validate/prepare the WHOLE batch before changing any target or caller slot.
    for (const auto& operation : staged.operations) {
        if (Load(operation.slot) != operation.initial) return Fail("Original-function slot changed after staging");
        if (operation.attach) {
            auto hook = Prepare(operation);
            if (!hook) return false;
            if (addresses.contains(hook->address)) return Fail("Target appears twice in one transaction");
            addresses[hook->address] = true; prepared.push_back({*hook, true});
        } else {
            auto existing = std::find_if(hooks.begin(), hooks.end(), [&](const auto& item) {
                return item.second.slot == operation.slot && item.second.replacement == operation.replacement && item.second.trampoline == operation.initial;
            });
            if (existing == hooks.end()) return Fail("No matching owned hook for this slot and replacement");
            if (addresses.contains(existing->first)) return Fail("Target appears twice in one transaction");
            uint32_t current = 0;
            if (!ReadInstruction(existing->first, current) || current != existing->second.patched) return Fail("Owned entry was modified externally; foreign code preserved");
            addresses[existing->first] = true; prepared.push_back({existing->second, false});
        }
    }
    size_t applied = 0;
    for (const auto& [hook, attach] : prepared) {
        if (!Apply(hook, attach)) {
            auto failure = detourError;
            // Keep ownership records aligned with any hook that could not be
            // rolled back (for example another injector changed that entry).
            while (applied) {
                const auto& prior = prepared[--applied];
                if (Apply(prior.first, !prior.second)) {
                    if (prior.second) hooks.erase(prior.first.address);
                    else hooks[prior.first.address] = prior.first;
                }
                else { failure += "; rollback incomplete: " + detourError; }
            }
            return Fail(std::move(failure));
        }
        if (attach) hooks[hook.address] = hook;
        else hooks.erase(hook.address);
        ++applied;
    }
    // Trampolines remain mapped for the lifetime of this process: an in-flight
    // original call must remain safe even after a hook has been detached.
    return true;
}
}
