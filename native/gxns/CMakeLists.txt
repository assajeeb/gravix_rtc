# gx_ns: on-device noise suppression core (RNNoise + speexdsp resampler + gx_ns).
# Host build + tests:
#   cmake -S native/gxns -B <build> -DGXNS_BUILD_TESTS=ON && cmake --build <build> && ctest --test-dir <build>
# Android (externalNativeBuild) / iOS (SPM C target) / WASM (emcmake) reuse
# GXNS_SOURCES + GXNS_DEFINES below; this file only defines a static library.
cmake_minimum_required(VERSION 3.18)
project(gxns C)

set(CMAKE_C_STANDARD 11)
set(CMAKE_C_STANDARD_REQUIRED ON)
set(CMAKE_C_EXTENSIONS ON) # gnu11: speexdsp resample_neon.h uses `asm`

option(GXNS_BUILD_TESTS "Build host unit tests" OFF)

set(GXNS_DIR ${CMAKE_CURRENT_LIST_DIR})
set(GXNS_SOURCES
  ${GXNS_DIR}/src/gx_ns.c
  ${GXNS_DIR}/src/gx_ns_timer.c
  ${GXNS_DIR}/third_party/rnnoise/src/denoise.c
  ${GXNS_DIR}/third_party/rnnoise/src/rnn.c
  ${GXNS_DIR}/third_party/rnnoise/src/rnn_data.c
  ${GXNS_DIR}/third_party/rnnoise/src/pitch.c
  ${GXNS_DIR}/third_party/rnnoise/src/kiss_fft.c
  ${GXNS_DIR}/third_party/rnnoise/src/celt_lpc.c
  ${GXNS_DIR}/third_party/speexdsp/resample.c)
set(GXNS_INCLUDES
  ${GXNS_DIR}/include
  ${GXNS_DIR}/src
  ${GXNS_DIR}/third_party/rnnoise/include
  ${GXNS_DIR}/third_party/rnnoise/src
  ${GXNS_DIR}/third_party/speexdsp)
set(GXNS_DEFINES OUTSIDE_SPEEX FLOATING_POINT RANDOM_PREFIX=gx EXPORT=)

function(gxns_add_library name)
  add_library(${name} STATIC ${GXNS_SOURCES})
  target_include_directories(${name} PUBLIC ${GXNS_INCLUDES})
  target_compile_definitions(${name} PRIVATE ${GXNS_DEFINES} ${ARGN})
  target_compile_definitions(${name} PUBLIC OUTSIDE_SPEEX RANDOM_PREFIX=gx)
  if(NOT MSVC)
    target_compile_options(${name} PRIVATE -O2 -fvisibility=hidden -ffunction-sections -fdata-sections)
    target_link_libraries(${name} PUBLIC m)
  endif()
endfunction()

gxns_add_library(gxns)

if(GXNS_BUILD_TESTS)
  enable_testing()
  # Variant with malloc/calloc/realloc/free redirected to a counting trap, for
  # the "no allocation on the hot path" test.
  gxns_add_library(gxns_alloctrap)
  target_compile_options(gxns_alloctrap PRIVATE -include ${GXNS_DIR}/tests/alloc_trap.h)

  set(GXNS_FIXTURES ${GXNS_DIR}/tests/fixtures)
  foreach(t timer golden rates crossfade agc external pregain dtx_quiet dtx_street room_replay wind)
    add_executable(test_${t} ${GXNS_DIR}/tests/test_${t}.c ${GXNS_DIR}/tests/test_util.c)
    target_link_libraries(test_${t} gxns)
    target_compile_definitions(test_${t} PRIVATE GXNS_FIXTURES="${GXNS_FIXTURES}"
      GXNS_SHARED_FIXTURE="${GXNS_DIR}/../../test/fixtures/ns_policy_cases.json")
    add_test(NAME ${t} COMMAND test_${t})
  endforeach()
  add_executable(gxns_replay ${GXNS_DIR}/tools/gxns_replay.c)
  target_link_libraries(gxns_replay gxns)
  add_executable(test_noalloc ${GXNS_DIR}/tests/test_noalloc.c ${GXNS_DIR}/tests/test_util.c ${GXNS_DIR}/tests/alloc_trap.c)
  target_link_libraries(test_noalloc gxns_alloctrap)
  add_test(NAME noalloc COMMAND test_noalloc)
endif()
