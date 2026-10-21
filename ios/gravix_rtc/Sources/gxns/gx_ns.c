/* Copyright (c) 2024-2026 Gravity Compile. MIT License; see LICENSE. */
/* Forwarder: the gx_ns core lives once in native/gxns (shared with Android
 * CMake and the host tests). SwiftPM and CocoaPods only compile files inside
 * the iOS package, so each source is included here by relative path; the whole
 * plugin root is present in both build modes (pub cache / SourcePackages copy). */
#include "gxns_build.h"
#include "../../../../native/gxns/src/gx_ns.c"
