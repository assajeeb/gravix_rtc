# libgxns.so for Android: the gx_ns core (RNNoise + speexdsp resampler + gx_ns)
# from ../native/gxns plus the JNI bridge used by GxNoiseProcessor.kt.
cmake_minimum_required(VERSION 3.18)
project(gxns_android C)

set(GXNS_ROOT ${CMAKE_CURRENT_LIST_DIR}/../../../../native/gxns)
# Reuse the core's source list / defines (it only defines static targets).
add_subdirectory(${GXNS_ROOT} ${CMAKE_CURRENT_BINARY_DIR}/gxns_core EXCLUDE_FROM_ALL)
set_target_properties(gxns PROPERTIES POSITION_INDEPENDENT_CODE ON)

add_library(gxns_jni SHARED gx_ns_jni.c)
set_target_properties(gxns_jni PROPERTIES OUTPUT_NAME gxns)
target_link_libraries(gxns_jni PRIVATE gxns log m)
target_compile_options(gxns_jni PRIVATE -O2 -fvisibility=hidden -ffunction-sections -fdata-sections)
# 16 KB page alignment (Android 15+ devices) regardless of the NDK default;
# drop unused sections; export only the JNI entry points.
target_link_options(gxns_jni PRIVATE
  -Wl,-z,max-page-size=16384
  -Wl,--gc-sections
  -Wl,--exclude-libs,ALL
  -Wl,--build-id=sha1)

# Studio engine (DeepFilterNet3 on the bundled minimal ONNX Runtime): arm64-v8a
# only. A separate library so libgxns never depends on ORT.
option(GXNS_STUDIO "Build the DFN3 studio engine (arm64-v8a)" ON)
if(GXNS_STUDIO AND ANDROID_ABI STREQUAL "arm64-v8a")
  # libgxort.so = the release ORT 1.31.0 minimal with its soname renamed
  # (tool/ns_android/rename_ort.py): never collides with an app's libonnxruntime.so
  add_library(gx_onnxruntime SHARED IMPORTED)
  set_target_properties(gx_onnxruntime PROPERTIES
    IMPORTED_LOCATION ${CMAKE_CURRENT_LIST_DIR}/../../studio/jniLibs/arm64-v8a/libgxort.so)
  add_library(gxns_dfn SHARED gx_dfn_engine.c)
  target_include_directories(gxns_dfn PRIVATE ${GXNS_ROOT}/include ${CMAKE_CURRENT_LIST_DIR}/third_party/onnxruntime/include)
  target_link_libraries(gxns_dfn PRIVATE gx_onnxruntime log m)
  target_compile_options(gxns_dfn PRIVATE -O2 -fvisibility=hidden -ffunction-sections -fdata-sections)
  target_link_options(gxns_dfn PRIVATE -Wl,-z,max-page-size=16384 -Wl,--gc-sections -Wl,--build-id=sha1)
endif()
