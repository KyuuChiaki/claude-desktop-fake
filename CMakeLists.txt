cmake_minimum_required(VERSION 3.24)
project(ClaudeDesktopFake VERSION 0.6.0 LANGUAGES CXX ASM_MASM)

if(NOT WIN32 OR NOT MSVC OR NOT CMAKE_SIZEOF_VOID_P EQUAL 8)
    message(FATAL_ERROR "This project requires native Windows x64 and MSVC.")
endif()

set(CMAKE_CXX_STANDARD 17)
set(CMAKE_CXX_STANDARD_REQUIRED ON)
set(CMAKE_CXX_EXTENSIONS OFF)
string(REPLACE "/EHsc" "" CMAKE_CXX_FLAGS "${CMAKE_CXX_FLAGS}")
set(CMAKE_RUNTIME_OUTPUT_DIRECTORY "${CMAKE_BINARY_DIR}/bin")
set(CMAKE_LIBRARY_OUTPUT_DIRECTORY "${CMAKE_BINARY_DIR}/bin")
set(CMAKE_ARCHIVE_OUTPUT_DIRECTORY "${CMAKE_BINARY_DIR}/lib")

set(CDF_NATIVE_EXTRA "${CMAKE_BINARY_DIR}/lib/CdfNativeExtra.lib")
add_custom_command(OUTPUT "${CDF_NATIVE_EXTRA}"
    COMMAND "${CMAKE_COMMAND}" -E make_directory "${CMAKE_BINARY_DIR}/lib"
    COMMAND "${CMAKE_AR}" /nologo /machine:x64 "/def:${CMAKE_SOURCE_DIR}/src/ntdll_extra.def" "/out:${CDF_NATIVE_EXTRA}"
    DEPENDS src/ntdll_extra.def VERBATIM)
add_custom_target(cdf_native_extra_build DEPENDS "${CDF_NATIVE_EXTRA}")
add_library(CdfNativeExtra INTERFACE)
add_dependencies(CdfNativeExtra cdf_native_extra_build)
target_link_libraries(CdfNativeExtra INTERFACE "${CDF_NATIVE_EXTRA}")

# Some MSVC installations contain only 2052 resources. CMake can decode its UTF-8
# showIncludes probe using the Windows ANSI code page, producing a bad prefix.
if(CMAKE_CL_SHOWINCLUDES_PREFIX MATCHES "娉ㄦ剰")
    set(CMAKE_CL_SHOWINCLUDES_PREFIX "注意: 包含文件:")
endif()

add_library(CdfBootstrap64 SHARED src/bootstrap.cpp)
target_include_directories(CdfBootstrap64 PRIVATE include)
target_compile_definitions(CdfBootstrap64 PRIVATE WIN32_LEAN_AND_MEAN NOMINMAX)
target_compile_options(CdfBootstrap64 PRIVATE /W4 /WX /utf-8 /GS- /GR- /EHs-c- /Zl)
target_link_options(CdfBootstrap64 PRIVATE
    /ENTRY:CdfBootstrapEntry /NODEFAULTLIB /MANIFEST:NO /INCREMENTAL:NO
    "/MAP:${CMAKE_RUNTIME_OUTPUT_DIRECTORY}/CdfBootstrap64.map")

add_executable(CdfProbe64 src/probe.cpp)
target_compile_definitions(CdfProbe64 PRIVATE UNICODE _UNICODE WIN32_LEAN_AND_MEAN NOMINMAX)
target_compile_options(CdfProbe64 PRIVATE /W4 /WX /utf-8 /EHsc)
set_property(TARGET CdfProbe64 PROPERTY MSVC_RUNTIME_LIBRARY "MultiThreaded$<$<CONFIG:Debug>:Debug>")

find_package(Python3 3.10 COMPONENTS Interpreter REQUIRED)
set(CDF_CATALOG_DIRECTORY "${CMAKE_BINARY_DIR}/generated")
add_custom_command(OUTPUT "${CDF_CATALOG_DIRECTORY}/runtime_catalog.generated.inc"
    COMMAND "${Python3_EXECUTABLE}" "${CMAKE_SOURCE_DIR}/scripts/Compile-RuntimeCatalog.py"
        --catalog "${CMAKE_SOURCE_DIR}/profiles/runtime-adapters.json" --output "${CDF_CATALOG_DIRECTORY}/runtime_catalog.generated.inc"
    DEPENDS scripts/Compile-RuntimeCatalog.py profiles/runtime-adapters.json VERBATIM)
add_custom_target(cdf_runtime_catalog DEPENDS "${CDF_CATALOG_DIRECTORY}/runtime_catalog.generated.inc")
include_directories("${CDF_CATALOG_DIRECTORY}")
set(CDF_PROVIDER_SOURCES src/time_provider.cpp src/time_core.cpp src/time_runtime.cpp src/locale_core.cpp src/locale_provider.cpp
    src/runtime_compat.cpp
    src/runtime_provider.cpp src/runtime_winrt.cpp src/runtime_winrt_forward.asm src/runtime_adapter.cpp src/runtime_capture.cpp src/sha256.cpp)
add_library(CdfTimeZone64 SHARED ${CDF_PROVIDER_SOURCES})
add_dependencies(CdfTimeZone64 cdf_runtime_catalog)
target_include_directories(CdfTimeZone64 PRIVATE include third_party/jsmn)
target_compile_definitions(CdfTimeZone64 PRIVATE UNICODE _UNICODE WIN32_LEAN_AND_MEAN NOMINMAX _WIN32_WINNT=0x0A00 NTDDI_VERSION=0x0A000006)
target_compile_options(CdfTimeZone64 PRIVATE "$<$<COMPILE_LANGUAGE:CXX>:/W4;/WX;/utf-8;/GS-;/GR-;/EHs-c-;/Zl;/Gs4096>")
target_link_options(CdfTimeZone64 PRIVATE /ENTRY:CdfTimeZoneEntry /NODEFAULTLIB /MANIFEST:NO /INCREMENTAL:NO /CETCOMPAT "/MAP:${CMAKE_RUNTIME_OUTPUT_DIRECTORY}/CdfTimeZone64.map")
target_link_libraries(CdfTimeZone64 PRIVATE ntdll CdfNativeExtra)

set(CDF_TIME_PROVIDER_SOURCES ${CDF_PROVIDER_SOURCES} src/claude_identity.cpp)
foreach(_target IN ITEMS CdfClaudeTimeZone64 CdfClaudeTimeZoneTest64)
    add_library(${_target} SHARED ${CDF_TIME_PROVIDER_SOURCES})
    add_dependencies(${_target} cdf_runtime_catalog)
    target_include_directories(${_target} PRIVATE include third_party/jsmn)
    target_compile_definitions(${_target} PRIVATE UNICODE _UNICODE WIN32_LEAN_AND_MEAN NOMINMAX _WIN32_WINNT=0x0A00 NTDDI_VERSION=0x0A000006 CDF_CLAUDE_IDENTITY_REQUIRED=1)
    target_compile_options(${_target} PRIVATE "$<$<COMPILE_LANGUAGE:CXX>:/W4;/WX;/utf-8;/GS-;/GR-;/EHs-c-;/Zl;/Gs4096>")
    target_link_options(${_target} PRIVATE /ENTRY:CdfTimeZoneEntry /NODEFAULTLIB /MANIFEST:NO /INCREMENTAL:NO /CETCOMPAT "/MAP:${CMAKE_RUNTIME_OUTPUT_DIRECTORY}/${_target}.map")
    target_link_libraries(${_target} PRIVATE ntdll CdfNativeExtra)
endforeach()
target_compile_definitions(CdfClaudeTimeZoneTest64 PRIVATE CDF_CLAUDE_IDENTITY_MANIFEST_TEST=1)

function(cdf_time_test target)
    target_include_directories(${target} PRIVATE include third_party/jsmn)
    target_compile_definitions(${target} PRIVATE UNICODE _UNICODE WIN32_LEAN_AND_MEAN NOMINMAX _WIN32_WINNT=0x0A00 NTDDI_VERSION=0x0A000006)
    target_compile_options(${target} PRIVATE /W4 /WX /utf-8 /EHsc)
    set_property(TARGET ${target} PROPERTY MSVC_RUNTIME_LIBRARY "MultiThreaded$<$<CONFIG:Debug>:Debug>")
    target_link_libraries(${target} PRIVATE ntdll CdfNativeExtra)
endfunction()
add_executable(CdfRuntimeResolve64 src/runtime_resolve.cpp src/runtime_compat.cpp src/sha256.cpp src/time_core.cpp)
cdf_time_test(CdfRuntimeResolve64)
add_dependencies(CdfRuntimeResolve64 cdf_runtime_catalog)
set(CDF_VS_ROOT "" CACHE PATH "Optional Visual Studio installation root")
get_filename_component(_cdf_compiler_root "${CMAKE_CXX_COMPILER}" DIRECTORY)
foreach(_cdf_level RANGE 1 7)
    get_filename_component(_cdf_compiler_root "${_cdf_compiler_root}" DIRECTORY)
endforeach()
find_path(CDF_DIA_INCLUDE_DIR dia2.h HINTS
    "${CDF_VS_ROOT}/DIA SDK/include"
    "$ENV{VSINSTALLDIR}/DIA SDK/include"
    "${_cdf_compiler_root}/DIA SDK/include")
if(CDF_DIA_INCLUDE_DIR)
    target_include_directories(CdfRuntimeResolve64 PRIVATE "${CDF_DIA_INCLUDE_DIR}")
    target_compile_definitions(CdfRuntimeResolve64 PRIVATE CDF_HAS_DIA=1)
else()
    target_compile_definitions(CdfRuntimeResolve64 PRIVATE CDF_HAS_DIA=0)
    message(STATUS "DIA SDK not found: optional --symbols verification is unavailable")
endif()
target_link_libraries(CdfRuntimeResolve64 PRIVATE ole32 version)
add_executable(CdfRuntimeCompatibilityRules64 tests/runtime_compat_rules.cpp src/runtime_compat.cpp src/sha256.cpp src/time_core.cpp)
cdf_time_test(CdfRuntimeCompatibilityRules64)
add_dependencies(CdfRuntimeCompatibilityRules64 cdf_runtime_catalog)
add_executable(CdfTimeRules64 tests/time_rules.cpp src/time_core.cpp src/locale_core.cpp)
cdf_time_test(CdfTimeRules64)
add_library(CdfTimeEarly64 SHARED tests/time_consumer.cpp)
cdf_time_test(CdfTimeEarly64)
add_library(CdfTimeLate64 SHARED tests/time_consumer.cpp)
cdf_time_test(CdfTimeLate64)
target_compile_definitions(CdfTimeLate64 PRIVATE CDF_LATE_CONSUMER)
add_executable(CdfTimeProbe64 tests/time_probe.cpp src/time_core.cpp)
cdf_time_test(CdfTimeProbe64)
target_link_libraries(CdfTimeProbe64 PRIVATE CdfTimeEarly64 winmm)

add_executable(CdfLocaleRules64 tests/locale_rules.cpp src/time_core.cpp src/locale_core.cpp)
cdf_time_test(CdfLocaleRules64)
add_library(CdfLocaleEarly64 SHARED tests/locale_consumer.cpp)
cdf_time_test(CdfLocaleEarly64)
add_library(CdfLocaleLate64 SHARED tests/locale_consumer.cpp)
cdf_time_test(CdfLocaleLate64)
target_compile_definitions(CdfLocaleLate64 PRIVATE CDF_LATE_CONSUMER)
add_executable(CdfLocaleProbe64 tests/locale_probe.cpp)
cdf_time_test(CdfLocaleProbe64)
target_link_libraries(CdfLocaleProbe64 PRIVATE CdfLocaleEarly64)

add_executable(CdfClaudeGateProbe64 tests/claude_gate_probe.cpp)
cdf_time_test(CdfClaudeGateProbe64)

    add_executable(CdfRuntimeRules64 tests/runtime_rules.cpp src/time_core.cpp src/locale_core.cpp src/sha256.cpp)
    cdf_time_test(CdfRuntimeRules64)
    add_library(CdfRuntimeEarly64 SHARED tests/runtime_early.cpp)
    cdf_time_test(CdfRuntimeEarly64)
    add_executable(CdfRuntimeProbe64 tests/runtime_native.cpp)
    cdf_time_test(CdfRuntimeProbe64)
    target_link_libraries(CdfRuntimeProbe64 PRIVATE windowsapp CdfRuntimeEarly64)
    add_executable(CdfRuntimePolicyLaunch64 tests/runtime_policy_launch.cpp)
    cdf_time_test(CdfRuntimePolicyLaunch64)
    add_library(CdfRuntimeNative64 SHARED tests/runtime_native.cpp)
    cdf_time_test(CdfRuntimeNative64)
    target_compile_definitions(CdfRuntimeNative64 PRIVATE CDF_RUNTIME_ADDON)
    target_link_libraries(CdfRuntimeNative64 PRIVATE windowsapp)
    set_target_properties(CdfRuntimeNative64 PROPERTIES SUFFIX ".node")

include(CTest)
if(BUILD_TESTING)
    find_program(CDF_POWERSHELL NAMES pwsh powershell REQUIRED)
    add_test(NAME runtime_rules COMMAND CdfRuntimeRules64)
    add_test(NAME runtime_compatibility_rules COMMAND CdfRuntimeCompatibilityRules64
        "${CMAKE_SOURCE_DIR}/out/runtime-fixtures/electron-44.9.3/CdfElectronProbe64.exe")
    add_test(NAME runtime_cross_version COMMAND "${CDF_POWERSHELL}" -NoProfile -ExecutionPolicy Bypass
        -File "${CMAKE_SOURCE_DIR}/scripts/Test-CrossVersionRuntime.ps1" -BuildDirectory "${CMAKE_BINARY_DIR}" -Iterations 10)
    add_test(NAME runtime_build_inspection COMMAND "${CDF_POWERSHELL}" -NoProfile -ExecutionPolicy Bypass
        -File "${CMAKE_SOURCE_DIR}/scripts/Inspect-RuntimeBuild.ps1" -BuildDirectory "${CMAKE_BINARY_DIR}")
    add_test(NAME runtime_safety COMMAND "${CDF_POWERSHELL}" -NoProfile -ExecutionPolicy Bypass
        -File "${CMAKE_SOURCE_DIR}/scripts/Test-RuntimeSafety.ps1" -BuildDirectory "${CMAKE_BINARY_DIR}")
    add_test(NAME runtime_integration COMMAND "${CDF_POWERSHELL}" -NoProfile -ExecutionPolicy Bypass
        -File "${CMAKE_SOURCE_DIR}/scripts/Test-Runtime.ps1" -BuildDirectory "${CMAKE_BINARY_DIR}" -Iterations 10 -Capture)
    add_test(NAME time_rules COMMAND CdfTimeRules64)
    add_test(NAME locale_rules COMMAND CdfLocaleRules64)
    add_test(NAME locale_build_inspection COMMAND "${CDF_POWERSHELL}" -NoProfile -ExecutionPolicy Bypass
        -File "${CMAKE_SOURCE_DIR}/scripts/Inspect-LocaleBuild.ps1" -BuildDirectory "${CMAKE_BINARY_DIR}")
    add_test(NAME locale_integration COMMAND "${CDF_POWERSHELL}" -NoProfile -ExecutionPolicy Bypass
        -File "${CMAKE_SOURCE_DIR}/scripts/Test-Locale.ps1" -BuildDirectory "${CMAKE_BINARY_DIR}" -Iterations 10)
    add_test(NAME build_inspection COMMAND "${CDF_POWERSHELL}" -NoProfile -ExecutionPolicy Bypass
        -File "${CMAKE_SOURCE_DIR}/scripts/Inspect-Build.ps1" -BuildDirectory "${CMAKE_BINARY_DIR}")
    add_test(NAME verifier_load_integration COMMAND "${CDF_POWERSHELL}" -NoProfile -ExecutionPolicy Bypass
        -File "${CMAKE_SOURCE_DIR}/scripts/Test-Load.ps1" -BuildDirectory "${CMAKE_BINARY_DIR}")
    add_test(NAME configuration_safety COMMAND "${CDF_POWERSHELL}" -NoProfile -ExecutionPolicy Bypass
        -File "${CMAKE_SOURCE_DIR}/scripts/Test-ConfigurationSafety.ps1" -BuildDirectory "${CMAKE_BINARY_DIR}")
    add_test(NAME timezone_build_inspection COMMAND "${CDF_POWERSHELL}" -NoProfile -ExecutionPolicy Bypass
        -File "${CMAKE_SOURCE_DIR}/scripts/Inspect-TimeZoneBuild.ps1" -BuildDirectory "${CMAKE_BINARY_DIR}")
    add_test(NAME timezone_configuration_safety COMMAND "${CDF_POWERSHELL}" -NoProfile -ExecutionPolicy Bypass
        -File "${CMAKE_SOURCE_DIR}/scripts/Test-TimeZoneSafety.ps1" -BuildDirectory "${CMAKE_BINARY_DIR}")
    add_test(NAME timezone_integration COMMAND "${CDF_POWERSHELL}" -NoProfile -ExecutionPolicy Bypass
        -File "${CMAKE_SOURCE_DIR}/scripts/Test-TimeZone.ps1" -BuildDirectory "${CMAKE_BINARY_DIR}" -Iterations 10)
    add_test(NAME claude_gate_build_inspection COMMAND "${CDF_POWERSHELL}" -NoProfile -ExecutionPolicy Bypass
        -File "${CMAKE_SOURCE_DIR}/scripts/Inspect-ClaudeBuild.ps1" -BuildDirectory "${CMAKE_BINARY_DIR}")
    add_test(NAME claude_gate_integration COMMAND "${CDF_POWERSHELL}" -NoProfile -ExecutionPolicy Bypass
        -File "${CMAKE_SOURCE_DIR}/scripts/Test-ClaudeGate.ps1" -BuildDirectory "${CMAKE_BINARY_DIR}")
    set_tests_properties(verifier_load_integration PROPERTIES RUN_SERIAL TRUE TIMEOUT 180)
    set_tests_properties(configuration_safety PROPERTIES RUN_SERIAL TRUE TIMEOUT 60)
    set_tests_properties(timezone_configuration_safety PROPERTIES RUN_SERIAL TRUE TIMEOUT 180)
    set_tests_properties(timezone_integration PROPERTIES RUN_SERIAL TRUE TIMEOUT 300)
    set_tests_properties(locale_integration PROPERTIES RUN_SERIAL TRUE TIMEOUT 300)
    set_tests_properties(claude_gate_integration PROPERTIES RUN_SERIAL TRUE TIMEOUT 240)
    set_tests_properties(runtime_safety PROPERTIES RUN_SERIAL TRUE TIMEOUT 1800)
    set_tests_properties(runtime_integration PROPERTIES RUN_SERIAL TRUE TIMEOUT 2400)
    set_tests_properties(runtime_cross_version PROPERTIES RUN_SERIAL TRUE TIMEOUT 5400)
endif()
