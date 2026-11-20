// Copyright (c) 2026 Gravity Compile. MIT License; see LICENSE.

// Entry point of the headless second engine the iOS example starts on request
// (channel `gravix_example/second_engine`, integration_test/ios_events_test.dart).
// It stands in for an app's background / push engine: the SDK's plugins
// register on it too, and native events must still reach the UI engine.

/// Runs in the second engine; nothing to do, the plugins registered natively.
@pragma('vm:entry-point')
void secondEngineMain() {}
