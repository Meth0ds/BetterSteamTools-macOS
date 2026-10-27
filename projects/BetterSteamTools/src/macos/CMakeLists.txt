cmake_minimum_required(VERSION 3.20)
enable_language(OBJCXX)
enable_language(Swift)
add_subdirectory("${CMAKE_CURRENT_SOURCE_DIR}/../OSTPlatform/Apple" "${CMAKE_CURRENT_BINARY_DIR}/platform")
list(APPEND CMAKE_MODULE_PATH "${CMAKE_CURRENT_SOURCE_DIR}/../cmake")
include(Tomlplusplus)
include("${CMAKE_CURRENT_SOURCE_DIR}/cmake/LuaCore.cmake")
add_library(BSTConfiguration STATIC
    MacLuaSupport.cpp MacConfiguration.cpp MacConfigStore.cpp
    ../Utils/Config/LuaConfig.cpp ../Utils/Config/Config.cpp
    ../Utils/SteamMetadata/StatsClient.cpp ../Utils/SteamMetadata/ManifestClient.cpp
    ../Utils/Tickets/AppTicketStorage.cpp)
target_include_directories(BSTConfiguration PUBLIC "${CMAKE_CURRENT_SOURCE_DIR}/.." "${CMAKE_CURRENT_BINARY_DIR}/../generated")
target_link_libraries(BSTConfiguration PUBLIC OSTPlatformMac BSTLua tomlplusplus::tomlplusplus)

set(BST_MANIFEST_KEY_ID "" CACHE STRING "Trusted Ed25519 build-manifest key identifier")
set(BST_MANIFEST_PUBLIC_KEY_HEX "" CACHE STRING "Trusted Ed25519 public key, 64 lowercase hexadecimal characters")
if(BST_MANIFEST_KEY_ID OR BST_MANIFEST_PUBLIC_KEY_HEX)
    string(LENGTH "${BST_MANIFEST_PUBLIC_KEY_HEX}" BST_MANIFEST_KEY_LENGTH)
    if(NOT BST_MANIFEST_KEY_ID MATCHES "^[A-Za-z0-9._-]+$" OR NOT BST_MANIFEST_PUBLIC_KEY_HEX MATCHES "^[0-9a-f]+$" OR NOT BST_MANIFEST_KEY_LENGTH EQUAL 64)
        message(FATAL_ERROR "Build-manifest trust requires a safe key ID and a 32-byte Ed25519 public key")
    endif()
endif()
configure_file(BSTManifestTrust.h.in "${CMAKE_CURRENT_BINARY_DIR}/generated/BSTManifestTrust.h" @ONLY)
set(BST_APPROVAL_SOURCES
    "${CMAKE_CURRENT_SOURCE_DIR}/../../macos/Sources/BSTBuildApproval/BuildApproval.swift"
    "${CMAKE_CURRENT_SOURCE_DIR}/../../macos/Sources/BSTBuildApproval/RuntimeVerifier.swift")
add_library(BSTBuildApproval STATIC ${BST_APPROVAL_SOURCES})
set_target_properties(BSTBuildApproval PROPERTIES Swift_LANGUAGE_VERSION 6 Swift_MODULE_NAME BSTBuildApproval)
add_library(BSTSteamClientProbe STATIC MachOImageLayout.cpp SteamClientProbe.cpp)
target_include_directories(BSTSteamClientProbe PRIVATE "${CMAKE_CURRENT_SOURCE_DIR}/..")
target_link_libraries(BSTSteamClientProbe PUBLIC OSTPlatformMac)

option(BST_EXPERIMENTAL_PACKAGE_HOOK "Enable package hooks not yet validated in live Steam" OFF)
add_library(BetterSteamToolsMac SHARED BetterSteamToolsMac.mm MacHookRuntime.cpp MacManifestHook.cpp MacPackageSync.cpp MacPackageHook.cpp MacOwnership.cpp)
set_target_properties(BetterSteamToolsMac PROPERTIES
    OUTPUT_NAME "BetterSteamTools"
    PREFIX ""
    OBJCXX_STANDARD 20
    OBJCXX_STANDARD_REQUIRED YES
    OSX_ARCHITECTURES "arm64"
    OSX_DEPLOYMENT_TARGET "15.0"
    MACOSX_RPATH ON
    INSTALL_NAME_DIR "@rpath"
)
target_compile_features(BetterSteamToolsMac PRIVATE cxx_std_20)
target_include_directories(BetterSteamToolsMac PRIVATE "${CMAKE_CURRENT_SOURCE_DIR}/.." "${CMAKE_CURRENT_BINARY_DIR}/generated")
target_compile_definitions(BetterSteamToolsMac PRIVATE "$<$<COMPILE_LANGUAGE:CXX,OBJCXX>:BST_MACOS_BUILD=1>")
if(BST_EXPERIMENTAL_PACKAGE_HOOK)
    target_compile_definitions(BetterSteamToolsMac PRIVATE "$<$<COMPILE_LANGUAGE:CXX,OBJCXX>:BST_EXPERIMENTAL_PACKAGE_HOOK=1>")
endif()
target_link_libraries(BetterSteamToolsMac PRIVATE BSTSteamClientProbe BSTBuildApproval BSTConfiguration "-framework Foundation" "-framework Security")
install(TARGETS BetterSteamToolsMac LIBRARY DESTINATION .)

include(CTest)
if(BUILD_TESTING)
    enable_language(ASM)
    add_executable(bst-lua-configuration-selftest tests/LuaConfigurationSelfTest.mm)
    set_target_properties(bst-lua-configuration-selftest PROPERTIES OBJCXX_STANDARD 20 OBJCXX_STANDARD_REQUIRED YES)
    target_link_libraries(bst-lua-configuration-selftest PRIVATE BSTConfiguration)
    add_test(NAME bst-lua-configuration-selftest COMMAND bst-lua-configuration-selftest)
    set_tests_properties(bst-lua-configuration-selftest PROPERTIES TIMEOUT 30)
    add_executable(bst-configstore-selftest tests/ConfigStoreSelfTest.cpp)
    target_link_libraries(bst-configstore-selftest PRIVATE BSTConfiguration)
    add_test(NAME bst-configstore-selftest COMMAND bst-configstore-selftest)
    add_executable(bst-manifest-hook-selftest tests/ManifestHookSelfTest.cpp MacManifestHook.cpp)
    target_include_directories(bst-manifest-hook-selftest PRIVATE "${CMAKE_CURRENT_SOURCE_DIR}/..")
    target_link_libraries(bst-manifest-hook-selftest PRIVATE BSTConfiguration)
    add_test(NAME bst-manifest-hook-selftest COMMAND bst-manifest-hook-selftest)
    add_executable(bst-package-sync-selftest tests/PackageSyncSelfTest.cpp MacPackageSync.cpp MacPackageHook.cpp)
    target_include_directories(bst-package-sync-selftest PRIVATE "${CMAKE_CURRENT_SOURCE_DIR}/..")
    target_link_libraries(bst-package-sync-selftest PRIVATE BSTConfiguration)
    add_test(NAME bst-package-sync-selftest COMMAND bst-package-sync-selftest)
    add_executable(bst-ownership-selftest tests/OwnershipSelfTest.cpp MacOwnership.cpp)
    target_include_directories(bst-ownership-selftest PRIVATE "${CMAKE_CURRENT_SOURCE_DIR}/..")
    target_link_libraries(bst-ownership-selftest PRIVATE BSTConfiguration)
    add_test(NAME bst-ownership-selftest COMMAND bst-ownership-selftest)
    add_executable(bst-platform-selftest tests/PlatformSelfTest.mm)
    set_target_properties(bst-platform-selftest PROPERTIES OBJCXX_STANDARD 20 OBJCXX_STANDARD_REQUIRED YES)
    target_link_libraries(bst-platform-selftest PRIVATE OSTPlatformMac)
    add_test(NAME bst-platform-selftest COMMAND bst-platform-selftest)
    add_executable(bst-detour-selftest tests/DetourSelfTest.cpp tests/EntryFixtures.S)
    target_link_libraries(bst-detour-selftest PRIVATE OSTPlatformMac)
    add_test(NAME bst-detour-selftest COMMAND bst-detour-selftest)
    add_executable(bst-macho-layout-selftest tests/MachOImageLayoutTest.cpp MachOImageLayout.cpp)
    target_compile_features(bst-macho-layout-selftest PRIVATE cxx_std_20)
    add_test(NAME bst-macho-layout-selftest COMMAND bst-macho-layout-selftest)
    add_executable(bst-real-hook-smoke tests/RealHookSmoke.cpp)
    target_include_directories(bst-real-hook-smoke PRIVATE "${CMAKE_CURRENT_SOURCE_DIR}/..")
    target_link_libraries(bst-real-hook-smoke PRIVATE BSTSteamClientProbe)
    add_executable(bst-steam-rtti-probe tests/SteamRTTIProbe.cpp)
    target_include_directories(bst-steam-rtti-probe PRIVATE "${CMAKE_CURRENT_SOURCE_DIR}/..")
    target_link_libraries(bst-steam-rtti-probe PRIVATE BSTSteamClientProbe)
endif()
