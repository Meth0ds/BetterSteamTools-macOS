#include "include/Detour.h"
#include "Apple/Arm64Relocator.h"
#include "Apple/CodePatch.h"
#include "Apple/DetourDiagnostics.h"
#include <array>
#include <atomic>
#include <cstring>
#include <dlfcn.h>
#include <iostream>
#include <stdexcept>
#include <thread>
#include <vector>
#include <mach/mach.h>
#include <mach/mach_vm.h>

extern "C" {
uint64_t bst_fixture_add(uint64_t);
uint64_t bst_fixture_prologue(uint64_t);
uint64_t bst_fixture_pac(uint64_t);
uint64_t bst_fixture_adr(uint64_t);
uint64_t bst_fixture_adrp(uint64_t);
uint64_t bst_fixture_literal(uint64_t);
uint64_t bst_fixture_literal32(uint64_t);
uint64_t bst_fixture_literalsigned(uint64_t);
uint64_t bst_fixture_cbz(uint64_t);
uint64_t bst_fixture_cbnz(uint64_t);
uint64_t bst_fixture_tbz(uint64_t);
uint64_t bst_fixture_tbnz(uint64_t);
uint64_t bst_fixture_cond(uint64_t);
uint64_t bst_fixture_cond_caller(uint64_t);
uint64_t bst_fixture_always(uint64_t);
uint64_t bst_fixture_branch(uint64_t);
uint64_t bst_fixture_call_with_flags(uint64_t, uint64_t(*)(uint64_t));
}
using Function = uint64_t(*)(uint64_t);
namespace Detour = OSTPlatform::Detour;
namespace Apple = OSTPlatform::Apple;
static void* original = nullptr;
static uint64_t replacement(uint64_t value) {
    auto function = reinterpret_cast<Function>(std::atomic_ref<void*>(original).load(std::memory_order_acquire));
    return function(value) + 100;
}
static uint64_t conditionalReplacement(uint64_t value) {
    auto function = reinterpret_cast<Function>(std::atomic_ref<void*>(original).load(std::memory_order_acquire));
    // NZCV is caller-clobbered by the C ABI. This fixture deliberately supplies
    // flags immediately before entering the trampoline to test its preservation.
    return bst_fixture_call_with_flags(value, function) + 100;
}
static void check(bool value, const char* message) { if (!value) throw std::runtime_error(message); }
static void roundtrip(Function entry, Function caller = nullptr) {
    if (!caller) caller = entry;
    const auto zero = caller(0), nonzero = caller(9);
    std::array<uint8_t, 32> before{};
    std::memcpy(before.data(), reinterpret_cast<void*>(entry), before.size());
    original = reinterpret_cast<void*>(entry);
    void* redirect = reinterpret_cast<void*>(entry == bst_fixture_cond ? conditionalReplacement : replacement);
    check(Detour::BeginTransaction(), "begin attach");
    check(Detour::Attach(&original, redirect), "stage attach");
    if (!Detour::CommitTransaction()) throw std::runtime_error("commit native redirect: " + Apple::DetourLastError());
    check(original != reinterpret_cast<void*>(entry), "original slot becomes trampoline");
    const auto actualZero = caller(0), actualNonzero = caller(9);
    if (actualZero != zero + 100 || actualNonzero != nonzero + 100) {
        Dl_info info{}; dladdr(reinterpret_cast<void*>(entry), &info);
        throw std::runtime_error(std::string(info.dli_sname ? info.dli_sname : "entry") + " relocation: expected=" +
            std::to_string(zero + 100) + "," + std::to_string(nonzero + 100) + " actual=" + std::to_string(actualZero) + "," + std::to_string(actualNonzero));
    }
    auto retired = reinterpret_cast<Function>(original);
    check(Detour::BeginTransaction(), "begin detach");
    check(Detour::Detach(&original, redirect), "stage detach");
    check(Detour::CommitTransaction(), "commit detach");
    check(original == reinterpret_cast<void*>(entry), "original slot restored");
    check(caller(0) == zero && caller(9) == nonzero, "original behavior restored");
    check(std::memcmp(before.data(), reinterpret_cast<void*>(entry), before.size()) == 0, "exact original code restored");
    if (entry != bst_fixture_cond) check(retired(9) == nonzero, "in-flight trampoline remains executable after detach");
}
static void testPreflight() {
    void* good = reinterpret_cast<void*>(bst_fixture_add);
    void* branch = reinterpret_cast<void*>(bst_fixture_branch);
    check(Detour::BeginTransaction(), "begin preflight");
    check(!Detour::BeginTransaction(), "nested transaction rejected");
    check(Detour::Attach(&good, reinterpret_cast<void*>(replacement)), "stage valid candidate");
    check(Detour::Attach(&branch, reinterpret_cast<void*>(replacement)), "stage branch candidate");
    check(!Detour::CommitTransaction(), "unknown/foreign branch entry rejected before target mutations");
    check(good == reinterpret_cast<void*>(bst_fixture_add) && bst_fixture_add(3) == 4, "failed batch leaves valid candidate unchanged");
    check(Detour::BeginTransaction(), "begin invalid argument batch");
    check(!Detour::Attach(nullptr, reinterpret_cast<void*>(replacement)), "null slot rejected");
    check(!Detour::CommitTransaction(), "invalid staged operation fails whole batch");
    check(!Detour::CommitTransaction(), "commit without begin rejected");
    check(Detour::BeginTransaction(), "begin pointer precondition");
    check(Detour::Attach(&good, reinterpret_cast<void*>(replacement)), "stage pointer precondition");
    good = reinterpret_cast<void*>(bst_fixture_cbz);
    check(!Detour::CommitTransaction() && good == reinterpret_cast<void*>(bst_fixture_cbz), "changed caller slot is not overwritten");
}
static void testForeignModification() {
    original = reinterpret_cast<void*>(bst_fixture_add);
    check(Detour::BeginTransaction() && Detour::Attach(&original, reinterpret_cast<void*>(replacement)) && Detour::CommitTransaction(), "prepare owned hook");
    uint32_t owned = 0; std::memcpy(&owned, reinterpret_cast<void*>(bst_fixture_add), 4);
    const uint32_t foreign = 0xD503201Fu; // NOP represents a later external patch.
    auto bytes = [](const uint32_t& value) { return std::span<const uint8_t>(reinterpret_cast<const uint8_t*>(&value), 4); };
    check(Apple::ReplaceCode(reinterpret_cast<void*>(bst_fixture_add), bytes(owned), bytes(foreign)), "simulate foreign modification");
    check(Detour::BeginTransaction() && Detour::Detach(&original, reinterpret_cast<void*>(replacement)), "stage modified owned hook");
    check(!Detour::CommitTransaction(), "do not overwrite a later foreign patch");
    uint32_t current = 0; std::memcpy(&current, reinterpret_cast<void*>(bst_fixture_add), 4);
    check(current == foreign, "foreign instruction preserved");
    check(Apple::ReplaceCode(reinterpret_cast<void*>(bst_fixture_add), bytes(foreign), bytes(owned)), "restore fixture hook ownership");
    check(Detour::BeginTransaction() && Detour::Detach(&original, reinterpret_cast<void*>(replacement)) && Detour::CommitTransaction(), "owned hook can then detach");
}
static void testConcurrentCalls() {
    original = reinterpret_cast<void*>(bst_fixture_add);
    std::atomic<bool> stop{false}, failed{false};
    std::atomic<uint64_t> calls{0};
    std::vector<std::thread> workers;
    for (unsigned i = 0; i < 4; ++i) workers.emplace_back([&] {
        while (!stop.load(std::memory_order_relaxed)) {
            const auto result = bst_fixture_add(3);
            if (result != 4 && result != 104) failed = true;
            calls.fetch_add(1, std::memory_order_relaxed);
        }
    });
    bool commits = true;
    for (unsigned i = 0; i < 100 && commits; ++i) {
        commits = Detour::BeginTransaction() && Detour::Attach(&original, reinterpret_cast<void*>(replacement)) && Detour::CommitTransaction();
        if (commits) commits = Detour::BeginTransaction() && Detour::Detach(&original, reinterpret_cast<void*>(replacement)) && Detour::CommitTransaction();
    }
    stop = true; for (auto& worker : workers) worker.join();
    check(commits && !failed && calls > 0, "concurrent calls see valid original or hooked code without transient non-executable pages");
}
static void testReadExecuteOnly() {
    mach_vm_address_t page = 0;
    check(mach_vm_allocate(mach_task_self(), &page, vm_page_size, VM_FLAGS_ANYWHERE) == KERN_SUCCESS, "allocate RX-only fixture");
    const std::array<uint32_t, 2> code{0x91000400u, 0xD65F03C0u}; // ADD X0,X0,#1; RET
    std::memcpy(reinterpret_cast<void*>(page), code.data(), sizeof code);
    check(mach_vm_protect(mach_task_self(), page, vm_page_size, false, VM_PROT_READ | VM_PROT_EXECUTE) == KERN_SUCCESS, "set RX protection");
    check(mach_vm_protect(mach_task_self(), page, vm_page_size, true, VM_PROT_READ | VM_PROT_EXECUTE) == KERN_SUCCESS, "restrict maximum to RX");
    roundtrip(reinterpret_cast<Function>(page));
    mach_vm_address_t region = page; mach_vm_size_t length = 0;
    vm_region_basic_info_data_64_t info{}; mach_msg_type_number_t count = VM_REGION_BASIC_INFO_COUNT_64; mach_port_t object = MACH_PORT_NULL;
    const auto result = mach_vm_region(mach_task_self(), &region, &length, VM_REGION_BASIC_INFO_64, reinterpret_cast<vm_region_info_t>(&info), &count, &object);
    if (object != MACH_PORT_NULL) mach_port_deallocate(mach_task_self(), object);
    check(result == KERN_SUCCESS && info.protection == (VM_PROT_READ | VM_PROT_EXECUTE) && info.max_protection == (VM_PROT_READ | VM_PROT_EXECUTE), "replacement does not relax current or maximum page permissions");
    mach_vm_deallocate(mach_task_self(), page, vm_page_size);
}
int main() {
    try {
        using namespace Apple::Arm64;
        check(Branch(0x1000, 0x1004) == 0x14000001, "positive ARM64 B encoding");
        check(Branch(0x1004, 0x1000) == 0x17ffffff, "negative ARM64 B encoding");
        check(!Branch(0x1000, 0x1001) && !Branch(0x1000, 0x8001000), "unaligned/out-of-range branch rejected");
        check(!RelocateEntry(0x14000001, 0x1000, 0x2000), "pre-existing branch rejected");
        check(!RelocateEntry(0xD4200000, 0x1000, 0x2000), "breakpoint rejected");
        for (const auto entry : {bst_fixture_add, bst_fixture_prologue, bst_fixture_pac, bst_fixture_adr, bst_fixture_adrp, bst_fixture_literal, bst_fixture_literal32,
                                 bst_fixture_literalsigned, bst_fixture_cbz, bst_fixture_cbnz, bst_fixture_tbz, bst_fixture_tbnz, bst_fixture_always}) roundtrip(entry);
        roundtrip(bst_fixture_cond, bst_fixture_cond_caller);
        testPreflight(); testForeignModification(); testConcurrentCalls(); testReadExecuteOnly();
        std::cout << "PASS: live ARM64 redirects, ADR/ADRP/literal and conditional relocation, exact restoration, failed batches, foreign patches and concurrent calls\n";
    } catch (const std::exception& error) { std::cerr << "FAIL: " << error.what() << '\n'; return 1; }
}
