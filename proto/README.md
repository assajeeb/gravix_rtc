# proto

Sources used to regenerate the Dart protobuf output at
`lib/src/rtc_core/src/proto/gravixcloud_*.pb*.dart`.

## Why the package rename

The upstream wire protos declare `package livekit;`. Dart's protobuf runtime
embeds the package name as a string (`PackageName(..)`) that **survives AOT
compilation** — that would leak the upstream brand into the release binary.
Therefore the package is renamed to **`gravixcloud`** before every
regeneration. Never regenerate with the original package name.

## Regenerating

Requires:

- `protoc` (Homebrew: `brew install protobuf`) — also provides the
  `google/protobuf` well-known includes.
- `protoc-gen-dart` (`dart pub global activate protoc_plugin`; add
  `$HOME/.pub-cache/bin` to PATH).

From the package root:

```sh
PROTOC_INCLUDE="$(brew --prefix protobuf)/include"   # for google/protobuf/*
protoc \
  --dart_out=lib/src/rtc_core/src/proto \
  -I proto -I "$PROTOC_INCLUDE" \
  proto/gravixcloud_rtc.proto \
  proto/gravixcloud_models.proto \
  proto/gravixcloud_metrics.proto
```

The generated folder also picks up `logger/options.proto` (imported by the
RTX protos for field-option extensions).

## Updating the wire definitions

New protocol versions come from the upstream `protocol` repository
(v1.50.4 was used here). Copy the three `.proto` files, then apply:

- `package <upstream>;  →  package gravixcloud;`
- `import "<upstream>_models.proto";  →  import "gravixcloud_models.proto";`
  (same for `_metrics`)
- strip the old brand from comments/`go_package`/namespaces

then regenerate and re-run the package test suite.