#!/bin/sh
# macOS host check of the iOS DFN3 studio path. Usage: run.sh <dfn3-release-dir> <out-dir> [python-with-coremltools]
# Compares the Swift Core ML runner with a coremltools reference loop (parity SNR) and prints timings.
set -eu
REL="$1"; OUT="$2"; PY="${3:-}"
HERE="$(cd "$(dirname "$0")" && pwd)"; SRC="$HERE/../../ios/gravix_rtc/Sources"
mkdir -p "$OUT"
xcrun swiftc -O -I "$SRC/gxns/include" -o "$OUT/hosttest" "$HERE/main.swift" \
  "$SRC/gravix_rtc/noise/GxNsDfn3CoreML.swift" "$SRC/gravix_rtc/noise/GxNsStudioPack.swift" "$SRC/gravix_rtc/noise/GxNsStudioEngine.swift"
"$OUT/hosttest" "$REL/bundled/common/bench_2s_48k_mono.wav" "$SRC/gravix_rtc/Resources/ns/gxns_dfn3.mlmodelc" \
  "$REL/bundled/ios/dfn3_std_int8.mlpackage.zip" "$REL/download/ll/dfn3_ll_int8.mlpackage.zip" "$OUT"
if [ -n "$PY" ]; then
  mkdir -p "$OUT/pk"; (cd "$OUT/pk" && unzip -o -q "$REL/bundled/ios/dfn3_std_int8.mlpackage.zip")
  "$PY" -I "$HERE/coreml_ref.py" "$OUT/pk/"*.mlpackage "$REL/bundled/common/bench_2s_48k_mono.wav" "$OUT/std_ref.f32"
  "$PY" -I -c "import numpy as np,sys; a=np.fromfile(sys.argv[1],np.float32); b=np.fromfile(sys.argv[2],np.float32); print('std parity SNR %.1f dB' % (10*np.log10(np.sum(b**2)/np.sum((a-b)**2))))" "$OUT/std_swift.f32" "$OUT/std_ref.f32"
fi
