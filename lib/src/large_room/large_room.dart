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

/// Large-room client helpers. Every one of these is opt-in: importing them
/// changes nothing, and [GravixRoomService] applies none of them for you.
library;

export 'gravix_audio_only_fallback.dart';
export 'gravix_participant_attributes.dart';
export 'gravix_publish_presets.dart';
export 'gravix_room_view.dart';
