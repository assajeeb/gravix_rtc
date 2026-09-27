// Copyright 2024 Gravity Compile
//
// Licensed under the Apache License, Version 2.0 (the "License");
// you may not use this file except in compliance with the License.
// You may obtain a copy of the License at
//
//     http://www.apache.org/licenses/LICENSE-2.0
//
// Unless required by applicable law or agreed to in writing, software
// distributed under the License is distributed on an "AS IS" BASIS,
// WITHOUT WARRANTIES OR CONDITIONS OF ANY KIND, either express or implied.
// See the License for the specific language governing permissions and
// limitations under the License.

import 'endpoint.dart';

/// A token source that queries GravixRtc's development token server for development and testing.
///
/// This token source connects to GravixRtc Cloud's
/// [development token server](https://docs.gravix.io/frontends/build/authentication/sandbox-token-server/),
/// which is perfect for quick prototyping and getting started with GravixRtc development.
///
/// **Warning:** This token source is **insecure** and should **never** be used in production.
///
/// For production use, implement [EndpointTokenSource] with your own backend or use [CustomTokenSource].
class DevelopmentTokenSource extends EndpointTokenSource {
  /// Initialize with a development token server ID from GravixRtc Cloud.
  ///
  /// The [id] is obtained from your GravixRtc Cloud project's token server settings.
  DevelopmentTokenSource({required String id})
    : super(
        url: Uri.parse('https://cloud-api.gravix.io/api/v2/sandbox/connection-details'),
        headers: {'X-Sandbox-ID': _sanitizeId(id)},
      );
}

/// A token source that queries GravixRtc's sandbox token server for development and testing.
@Deprecated('Use DevelopmentTokenSource instead')
class SandboxTokenSource extends DevelopmentTokenSource {
  /// Initialize with a sandbox ID from GravixRtc Cloud.
  ///
  /// The [sandboxId] is obtained from your GravixRtc Cloud project's sandbox settings.
  SandboxTokenSource({required String sandboxId}) : super(id: sandboxId);
}

String _sanitizeId(String id) {
  var sanitized = id;
  sanitized = sanitized.replaceFirst(RegExp(r'^[^a-zA-Z0-9]+'), '');
  sanitized = sanitized.replaceFirst(RegExp(r'[^a-zA-Z0-9]+$'), '');
  return sanitized;
}
