// Copyright 2025 LiveKit, Inc.
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

import 'dart:async';

/// Serializes async operations so concurrent calls execute sequentially.
///
/// When [run] is called while a previous operation is still in progress,
/// the new call waits for the previous one to complete before executing.
/// This prevents race conditions from concurrent calls to the same
/// async operation.
///
/// Equivalent to the Swift SDK's `SerialRunnerActor`.
class SerialRunner<T> {
  Future<void>? _tail;

  /// Whether an operation is currently in progress or queued.
  bool get isRunning => _tail != null;

  /// Runs [block] after every earlier call has completed, in call order.
  ///
  /// If no operation is pending, [block] executes immediately.
  /// Errors from [block] propagate to the caller only, not to
  /// subsequent waiters.
  Future<T> run(Future<T> Function() block) async {
    final previous = _tail;
    final done = Completer<void>();
    final mine = done.future;
    _tail = mine;
    if (previous != null) await previous;
    try {
      return await block();
    } finally {
      done.complete();
      if (identical(_tail, mine)) _tail = null;
    }
  }
}
