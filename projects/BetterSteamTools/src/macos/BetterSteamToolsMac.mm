// Minimal, fail-closed macOS bootstrap for BetterSteamTools.
// Steam-specific hooks are gated by signed build manifests and are added in
// signature-specific modules. This bootstrap never modifies unknown builds.
#import <Foundation/Foundation.h>
#include <mach-o/dyld.h>
#include <unistd.h>
#include "MacHookRuntime.h"

static bool isSteamProcess() {
    char path[PATH_MAX] = {0};
    uint32_t size = sizeof(path);
    if (_NSGetExecutablePath(path, &size) != 0) return false;
    NSString *name = [[[NSString stringWithUTF8String:path] lastPathComponent] lowercaseString];
    return [name isEqualToString:@"steam_osx"] || [name isEqualToString:@"steam"];
}

static void bstLog(NSString *message) {
    NSString *dir = [NSHomeDirectory() stringByAppendingPathComponent:@"Library/Application Support/BetterSteamTools/logs"];
    [[NSFileManager defaultManager] createDirectoryAtPath:dir withIntermediateDirectories:YES attributes:nil error:nil];
    NSString *file = [dir stringByAppendingPathComponent:@"macos-bootstrap.log"];
    NSString *line = [NSString stringWithFormat:@"%@ %@\n", [NSDate date], message];
    NSFileHandle *handle = [NSFileHandle fileHandleForWritingAtPath:file];
    if (!handle) { [line writeToFile:file atomically:YES encoding:NSUTF8StringEncoding error:nil]; return; }
    [handle seekToEndOfFile];
    [handle writeData:[line dataUsingEncoding:NSUTF8StringEncoding]];
    [handle closeFile];
}

__attribute__((constructor)) static void BetterSteamToolsMacBootstrap(void) {
    @autoreleasepool {
        if (!isSteamProcess()) return;
        bstLog(@"Bootstrap cargado; verificando el manifiesto firmado y los binarios de Steam antes de activar hooks.");
        BSTMacStartHooks();
    }
}

extern "C" const char *BSTMacBootstrapVersion(void) { return "0.1.0-bootstrap"; }
