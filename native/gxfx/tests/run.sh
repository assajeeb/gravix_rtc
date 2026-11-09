#!/bin/bash
# Host tests: release build, then a ThreadSanitizer run of the swap stress.
set -e
cd "$(dirname "$0")/.."
O=${TMPDIR:-/tmp}/gxfx-test; mkdir -p "$O"
F="-std=c++17 -O2 -w -Iinclude"
clang++ $F tests/test_gx_fx.cpp src/gx_fx.cpp -o "$O/t"
"$O/t"
clang++ $F -fsanitize=thread tests/test_gx_fx.cpp src/gx_fx.cpp -o "$O/ts"
"$O/ts" stress
