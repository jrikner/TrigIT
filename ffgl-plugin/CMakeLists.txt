# SPDX-License-Identifier: GPL-3.0-or-later
# TrigIT as an FFGL plugin for Resolume. See README.md.
#   cmake -B build -DCMAKE_BUILD_TYPE=Release && cmake --build build --config Release
#   ctest --test-dir build -C Release --output-on-failure
cmake_minimum_required(VERSION 3.20)
project(TrigITFFGL VERSION 0.1.0 LANGUAGES C CXX)

set(CMAKE_CXX_STANDARD 17)
set(CMAKE_CXX_STANDARD_REQUIRED ON)
set(CMAKE_POSITION_INDEPENDENT_CODE ON)
set(CMAKE_OSX_DEPLOYMENT_TARGET 10.15 CACHE STRING "")
set(CMAKE_MSVC_RUNTIME_LIBRARY "MultiThreaded$<$<CONFIG:Debug>:Debug>") # no VC++ runtime to install

include(FetchContent)

# Lua runs the Show Engine: the same engine.lua the grandMA3 plugin runs.
FetchContent_Declare(lua
    GIT_REPOSITORY https://github.com/lua/lua.git
    GIT_TAG        6e22fedb74cf0c9b6656e9fce8b7331db847c605 # v5.4.8
)
FetchContent_MakeAvailable(lua)
add_library(lua STATIC ${lua_SOURCE_DIR}/onelua.c)
target_compile_definitions(lua PRIVATE MAKE_LIB)
target_include_directories(lua PUBLIC ${lua_SOURCE_DIR})

set(MA3_SRC ${CMAKE_CURRENT_SOURCE_DIR}/../ma3-plugin/src)
set(LUA_MODULES
    json=${MA3_SRC}/json.lua
    timecode=${MA3_SRC}/timecode.lua
    engine=${MA3_SRC}/engine.lua
    host=${CMAKE_CURRENT_SOURCE_DIR}/src/host.lua
)
set(EMBEDDED ${CMAKE_CURRENT_BINARY_DIR}/generated/EmbeddedLua.h)
add_custom_command(
    OUTPUT  ${EMBEDDED}
    COMMAND ${CMAKE_COMMAND} "-DMODULES=${LUA_MODULES}" -DOUT=${EMBEDDED} -P ${CMAKE_CURRENT_SOURCE_DIR}/cmake/embed.cmake
    DEPENDS ${MA3_SRC}/json.lua ${MA3_SRC}/timecode.lua ${MA3_SRC}/engine.lua src/host.lua cmake/embed.cmake
    VERBATIM
)

add_library(trigit-core STATIC core/TrigITCore.cpp core/TrigITCore.h ${EMBEDDED})
target_include_directories(trigit-core PUBLIC core PRIVATE ${CMAKE_CURRENT_BINARY_DIR}/generated)
target_link_libraries(trigit-core PRIVATE lua)
find_package(Threads REQUIRED)
target_link_libraries(trigit-core PUBLIC Threads::Threads)
if (WIN32)
    target_link_libraries(trigit-core PUBLIC ws2_32)
endif()

enable_testing()
add_executable(core-test test/core_test.cpp)
target_link_libraries(core-test PRIVATE trigit-core)
add_test(NAME core COMMAND core-test)

# The plugin itself needs OpenGL and the FFGL SDK, which has no Linux host.
if (APPLE OR WIN32)
    FetchContent_Declare(ffgl
        GIT_REPOSITORY https://github.com/resolume/ffgl.git
        GIT_TAG        5b6e07840277df9ec35a228b9eb067636316350f
    )
    FetchContent_Populate(ffgl)

    add_library(TrigIT MODULE plugin/TrigITFFGL.cpp ${ffgl_SOURCE_DIR}/source/lib/FFGLSDK.cpp)
    target_include_directories(TrigIT PRIVATE ${ffgl_SOURCE_DIR}/source/lib)
    target_link_libraries(TrigIT PRIVATE trigit-core)
    if (APPLE)
        target_compile_definitions(TrigIT PRIVATE GL_SILENCE_DEPRECATION)
        target_link_libraries(TrigIT PRIVATE "-framework OpenGL")
        set_target_properties(TrigIT PROPERTIES
            BUNDLE TRUE
            BUNDLE_EXTENSION bundle
            MACOSX_BUNDLE_GUI_IDENTIFIER com.trigit.ffgl
            MACOSX_BUNDLE_BUNDLE_NAME TrigIT
            MACOSX_BUNDLE_BUNDLE_VERSION ${PROJECT_VERSION}
            MACOSX_BUNDLE_SHORT_VERSION_STRING ${PROJECT_VERSION}
        )
    else()
        set(GLEW ${ffgl_SOURCE_DIR}/deps/glew-2.1.0)
        target_compile_definitions(TrigIT PRIVATE GLEW_STATIC NOMINMAX WIN32_LEAN_AND_MEAN)
        target_include_directories(TrigIT PRIVATE ${GLEW}/include)
        target_link_libraries(TrigIT PRIVATE ${GLEW}/lib/Release/x64/glew32s.lib opengl32)
    endif()
endif()
