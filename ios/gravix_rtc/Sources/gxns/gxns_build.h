/* Copyright (c) 2024-2026 Gravity Compile. MIT License; see LICENSE. */
/* Build defines for the gx_ns core on Apple (SPM target + podspec), the same
 * as native/gxns/CMakeLists.txt GXNS_DEFINES. Every forwarder includes this
 * first, so SwiftPM and CocoaPods need no per-target preprocessor settings. */
#ifndef GXNS_BUILD_H
#define GXNS_BUILD_H
#ifndef OUTSIDE_SPEEX
#define OUTSIDE_SPEEX 1
#endif
#ifndef FLOATING_POINT
#define FLOATING_POINT 1
#endif
#ifndef RANDOM_PREFIX
#define RANDOM_PREFIX gx
#endif
#ifndef EXPORT
#define EXPORT
#endif
#endif
