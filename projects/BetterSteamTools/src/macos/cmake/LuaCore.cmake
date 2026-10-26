include(FetchContent)
# Exact interpreter release used by the Windows base. HTTPS + official SHA-256
# from https://www.lua.org/ftp/ pin the native dependency reproducibly.
FetchContent_Declare(bst_lua
    URL https://www.lua.org/ftp/lua-5.5.0.tar.gz
    URL_HASH SHA256=57ccc32bbbd005cab75bcc52444052535af691789dba2b9016d5c50640d68b3d
    DOWNLOAD_EXTRACT_TIMESTAMP TRUE TLS_VERIFY TRUE)
FetchContent_MakeAvailable(bst_lua)
file(GLOB BST_LUA_SOURCES "${bst_lua_SOURCE_DIR}/src/*.c")
list(REMOVE_ITEM BST_LUA_SOURCES "${bst_lua_SOURCE_DIR}/src/lua.c" "${bst_lua_SOURCE_DIR}/src/luac.c")
add_library(BSTLua STATIC ${BST_LUA_SOURCES})
target_include_directories(BSTLua PUBLIC "${bst_lua_SOURCE_DIR}/src")
target_compile_definitions(BSTLua PRIVATE LUA_USE_MACOSX)
set_target_properties(BSTLua PROPERTIES POSITION_INDEPENDENT_CODE ON)
