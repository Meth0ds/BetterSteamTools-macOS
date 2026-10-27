#include "../MacPackageSync.h"
#include "../MacPackageHook.h"
#include <algorithm>
#include <cstdlib>
#include <filesystem>
#include <fstream>
#include <iostream>
#include <stdexcept>
#include <vector>
#include <unistd.h>

using namespace BST::Mac;
namespace {
NativePackageInfo package{};
int marks = 0, updates = 0, grows = 0;
bool failGrow = false;
NativePackageInfo* getPackage(void*, uint32_t id, uint64_t token) {
    if (id == 55 && token == 0) return &package;
    if (id != 0 || token != 10660652434190618804ull) throw std::runtime_error("wrong package arguments");
    return &package;
}
void* grow(NativeAppVector* vector, int extra) {
    ++grows;
    if (failGrow) return nullptr;
    const auto count = vector->capacity + static_cast<uint32_t>(extra);
    auto* result = static_cast<uint32_t*>(std::realloc(vector->memory, count * sizeof(uint32_t)));
    if (result) { vector->memory = result; vector->capacity = count; }
    return result;
}
void mark(void*, uint32_t id, bool flag) { if (id != 0 || !flag) throw std::runtime_error("invalid license notification"); ++marks; }
bool process(void*) { ++updates; return true; }
void check(bool value, const char* message) { if (!value) throw std::runtime_error(message); }
bool contains(uint32_t id) { return std::find(package.apps.memory, package.apps.memory + package.apps.size, id) != package.apps.memory + package.apps.size; }
}
int main() {
    try {
        const PackageFunctions functions{getPackage, grow, mark, process};
        MacPackageSync sync;
        int user = 0, cache = 0;
        check(grow(&package.apps, 1) != nullptr, "fixture allocation");
        package.apps.memory[0] = 10; package.apps.size = 1;
        ConfigurationSnapshot first; first.depots[10] = {}; first.depots[20] = {}; first.depots[30] = {};
        check(sync.reconcile(&cache, &user, &first, functions) == PackageSyncResult::Changed, "adds configured package apps");
        check(package.apps.size == 3 && contains(10) && contains(20) && contains(30), "keeps existing and inserts new ids");
        check(marks == 1 && updates == 1 && grows == 2, "grows once and notifies once");
        check(sync.reconcile(&cache, &user, &first, functions) == PackageSyncResult::Unchanged && marks == 1, "idempotent reload does not notify");
        ConfigurationSnapshot second; second.depots[40] = {};
        failGrow = true;
        check(sync.reconcile(&cache, &user, &second, functions) == PackageSyncResult::Invalid, "failed growth refuses update");
        check(package.apps.size == 3 && contains(10) && contains(20) && contains(30) && marks == 1, "failed growth preserves entries");
        failGrow = false;
        check(sync.reconcile(&cache, &user, &second, functions) == PackageSyncResult::Changed, "reconciles added and removed ids");
        check(package.apps.size == 2 && contains(10) && contains(40) && !contains(20) && !contains(30), "removes only managed ids");
        check(sync.reconcile(&cache, &user, nullptr, functions) == PackageSyncResult::Changed, "disabled configuration removes managed ids");
        check(package.apps.size == 1 && contains(10) && marks == 3 && updates == 3, "foreign entry preserved on disable");
        package.status = 3;
        check(sync.reconcile(&cache, &user, &first, functions) == PackageSyncResult::NotReady, "unavailable package is not modified");
        package.status = 0; package.apps.growSize = -1;
        check(sync.reconcile(&cache, &user, &first, functions) == PackageSyncResult::Invalid, "external or malformed memory refused");
        std::free(package.apps.memory);
        package = {}; marks = updates = 0;
        char pattern[] = "/tmp/bst-package-adapter-XXXXXX";
        const char* directory = mkdtemp(pattern); check(directory != nullptr, "temporary directory");
        const std::filesystem::path root(directory), scripts = root / "config/stplug-in";
        struct Cleanup { std::filesystem::path path; ~Cleanup() { std::error_code ignored; std::filesystem::remove_all(path, ignored); } } cleanup{root};
        std::filesystem::create_directories(scripts);
        { std::ofstream config(root / "opensteamtool.toml"); config << "[stats]\nenable_api = false\n"; }
        { std::ofstream lua(scripts / "42.lua"); lua << "addappid(42)\n"; }
        MacConfiguration configuration;
        check(configuration.reload(root).ready, "publish real Lua snapshot for hook adapter");
        *PackageGetOriginalSlot() = reinterpret_cast<void*>(&getPackage);
        ConfigurePackageFunctions(reinterpret_cast<uintptr_t>(&grow), reinterpret_cast<uintptr_t>(&mark), reinterpret_cast<uintptr_t>(&process));
        const auto replacement = reinterpret_cast<PackageFunctions::GetPackage>(PackageGetReplacement());
        check(replacement(&cache, 55, 0) == &package, "package replacement preserves original result and captures cache");
        ReconcilePackageForUser(&user);
        check(package.apps.size == 1 && contains(42) && marks == 1 && updates == 1, "adapter uses actual Lua snapshot and notifications");
        std::filesystem::remove(scripts / "42.lua");
        check(configuration.reload(root).ready, "publish empty configuration");
        ReconcilePackageForUser(&user);
        check(package.apps.size == 0 && marks == 2 && updates == 2, "adapter applies removed Lua configuration");
        std::free(package.apps.memory);
        std::cout << "PASS: package app vector reconciliation, ownership, growth and notifications\n";
        return 0;
    } catch (const std::exception& error) { std::cerr << "FAIL: " << error.what() << '\n'; return 1; }
}
