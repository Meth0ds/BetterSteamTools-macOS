#include "../MacConfigStore.h"
#include <array>
#include <algorithm>
#include <iostream>
#include <stdexcept>

void check(bool value, const char* message) { if (!value) throw std::runtime_error(message); }
int main() {
    try {
        using namespace BST::Mac;
        check(DepotIDFromConfigKey("Software\\Valve\\Steam\\Depots\\42\\DecryptionKey") == 42, "Windows-style config key retained on macOS");
        check(DepotIDFromConfigKey("Software/Valve/Steam/Depots/42/DecryptionKey") == 42, "POSIX separators supported");
        check(DepotIDFromConfigKey("Software\\Valve\\Steam\\Depots\\4294967295\\DecryptionKey") == UINT32_MAX, "full UInt32 depot ID");
        for (const auto* name : {"Software\\Valve\\Steam\\Depots\\4294967296\\DecryptionKey", "Software\\Valve\\Steam\\Depots\\0\\DecryptionKey", "Software\\Valve\\Steam\\Depots\\-1\\DecryptionKey", "Software\\Valve\\Steam\\Depots\\\\DecryptionKey", "Software\\Valve\\Steam\\Depots\\42x\\DecryptionKey", "Software\\Valve\\Steam\\Depots\\42\\DecryptionKeyBackup", "Other\\42\\DecryptionKey", "apptickets\\42"})
            check(!DepotIDFromConfigKey(name), "malformed/unrelated config read rejected");
        ConfigurationSnapshot snapshot;
        snapshot.depots[42] = std::vector<uint8_t>(32, 0xab);
        snapshot.depots[43] = {};
        std::array<uint8_t, 64> output; output.fill(0x55);
        check(CopyConfiguredDepotKey(snapshot, "Software\\Valve\\Steam\\Depots\\42\\DecryptionKey", output) == 32, "configured key copied");
        check(std::all_of(output.begin(), output.begin() + 32, [](auto byte) { return byte == 0xab; }) && output[32] == 0x55, "key bytes and trailing canary");
        output.fill(0x55);
        check(!CopyConfiguredDepotKey(snapshot, "Software\\Valve\\Steam\\Depots\\42\\DecryptionKey", {output.data(), 31}) && output[0] == 0x55, "short buffer untouched");
        check(!CopyConfiguredDepotKey(snapshot, "Software\\Valve\\Steam\\Depots\\43\\DecryptionKey", output) && output[0] == 0x55, "AppID without a key falls through");
        check(!CopyConfiguredDepotKey(snapshot, "Software\\Valve\\Steam\\Depots\\44\\DecryptionKey", output) && output[0] == 0x55, "undeclared depot falls through");
        std::cout << "PASS: ConfigStore depot path parsing, exact key bytes and original-call fallthrough conditions\n";
        return 0;
    } catch (const std::exception& error) { std::cerr << "FAIL: " << error.what() << '\n'; return 1; }
}
