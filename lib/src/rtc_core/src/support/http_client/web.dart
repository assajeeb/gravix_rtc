// Copyright 2026 LiveKit, Inc.
// Modifications Copyright 2024-2026 Gravity Compile
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

import 'package:http/http.dart' as http;

import '../../options.dart';

http.Client createSdkHttpClient(NetworkOptions networkOptions) {
  if (networkOptions.certificatePinning?.isEnabled ?? false) {
    throw UnsupportedError('Certificate pinning is not supported on Flutter web');
  }
  return http.Client();
}

/// Web: the browser's own keep-alive pool serves repeated requests; there is no
/// socket hook, so [onConnect] is never called and [idleTimeout] is ignored.
http.Client createSdkProbeHttpClient(
  NetworkOptions networkOptions, {
  void Function()? onConnect,
  Duration? idleTimeout,
}) => createSdkHttpClient(networkOptions);
