// This is a generated file - do not edit.
//
// Generated from gravixcloud_rtc.proto.

// @dart = 3.3

// ignore_for_file: annotate_overrides, camel_case_types, comment_references
// ignore_for_file: constant_identifier_names
// ignore_for_file: curly_braces_in_flow_control_structures
// ignore_for_file: deprecated_member_use_from_same_package, library_prefixes
// ignore_for_file: non_constant_identifier_names, prefer_relative_imports
// ignore_for_file: unused_import

import 'dart:convert' as $convert;
import 'dart:core' as $core;
import 'dart:typed_data' as $typed_data;

@$core.Deprecated('Use signalTargetDescriptor instead')
const SignalTarget$json = {
  '1': 'SignalTarget',
  '2': [
    {'1': 'PUBLISHER', '2': 0},
    {'1': 'SUBSCRIBER', '2': 1},
  ],
};

/// Descriptor for `SignalTarget`. Decode as a `google.protobuf.EnumDescriptorProto`.
final $typed_data.Uint8List signalTargetDescriptor =
    $convert.base64Decode('CgxTaWduYWxUYXJnZXQSDQoJUFVCTElTSEVSEAASDgoKU1VCU0NSSUJFUhAB');

@$core.Deprecated('Use streamStateDescriptor instead')
const StreamState$json = {
  '1': 'StreamState',
  '2': [
    {'1': 'ACTIVE', '2': 0},
    {'1': 'PAUSED', '2': 1},
  ],
};

/// Descriptor for `StreamState`. Decode as a `google.protobuf.EnumDescriptorProto`.
final $typed_data.Uint8List streamStateDescriptor =
    $convert.base64Decode('CgtTdHJlYW1TdGF0ZRIKCgZBQ1RJVkUQABIKCgZQQVVTRUQQAQ==');

@$core.Deprecated('Use candidateProtocolDescriptor instead')
const CandidateProtocol$json = {
  '1': 'CandidateProtocol',
  '2': [
    {'1': 'UDP', '2': 0},
    {'1': 'TCP', '2': 1},
    {'1': 'TLS', '2': 2},
  ],
};

/// Descriptor for `CandidateProtocol`. Decode as a `google.protobuf.EnumDescriptorProto`.
final $typed_data.Uint8List candidateProtocolDescriptor =
    $convert.base64Decode('ChFDYW5kaWRhdGVQcm90b2NvbBIHCgNVRFAQABIHCgNUQ1AQARIHCgNUTFMQAg==');

@$core.Deprecated('Use signalRequestDescriptor instead')
const SignalRequest$json = {
  '1': 'SignalRequest',
  '2': [
    {'1': 'offer', '3': 1, '4': 1, '5': 11, '6': '.gravixcloud.SessionDescription', '9': 0, '10': 'offer'},
    {'1': 'answer', '3': 2, '4': 1, '5': 11, '6': '.gravixcloud.SessionDescription', '9': 0, '10': 'answer'},
    {'1': 'trickle', '3': 3, '4': 1, '5': 11, '6': '.gravixcloud.TrickleRequest', '9': 0, '10': 'trickle'},
    {'1': 'add_track', '3': 4, '4': 1, '5': 11, '6': '.gravixcloud.AddTrackRequest', '9': 0, '10': 'addTrack'},
    {'1': 'mute', '3': 5, '4': 1, '5': 11, '6': '.gravixcloud.MuteTrackRequest', '9': 0, '10': 'mute'},
    {
      '1': 'subscription',
      '3': 6,
      '4': 1,
      '5': 11,
      '6': '.gravixcloud.UpdateSubscription',
      '9': 0,
      '10': 'subscription'
    },
    {
      '1': 'track_setting',
      '3': 7,
      '4': 1,
      '5': 11,
      '6': '.gravixcloud.UpdateTrackSettings',
      '9': 0,
      '10': 'trackSetting'
    },
    {'1': 'leave', '3': 8, '4': 1, '5': 11, '6': '.gravixcloud.LeaveRequest', '9': 0, '10': 'leave'},
    {
      '1': 'update_layers',
      '3': 10,
      '4': 1,
      '5': 11,
      '6': '.gravixcloud.UpdateVideoLayers',
      '8': {'3': true},
      '9': 0,
      '10': 'updateLayers',
    },
    {
      '1': 'subscription_permission',
      '3': 11,
      '4': 1,
      '5': 11,
      '6': '.gravixcloud.SubscriptionPermission',
      '9': 0,
      '10': 'subscriptionPermission'
    },
    {'1': 'sync_state', '3': 12, '4': 1, '5': 11, '6': '.gravixcloud.SyncState', '9': 0, '10': 'syncState'},
    {'1': 'simulate', '3': 13, '4': 1, '5': 11, '6': '.gravixcloud.SimulateScenario', '9': 0, '10': 'simulate'},
    {'1': 'ping', '3': 14, '4': 1, '5': 3, '9': 0, '10': 'ping'},
    {
      '1': 'update_metadata',
      '3': 15,
      '4': 1,
      '5': 11,
      '6': '.gravixcloud.UpdateParticipantMetadata',
      '9': 0,
      '10': 'updateMetadata'
    },
    {'1': 'ping_req', '3': 16, '4': 1, '5': 11, '6': '.gravixcloud.Ping', '9': 0, '10': 'pingReq'},
    {
      '1': 'update_audio_track',
      '3': 17,
      '4': 1,
      '5': 11,
      '6': '.gravixcloud.UpdateLocalAudioTrack',
      '9': 0,
      '10': 'updateAudioTrack'
    },
    {
      '1': 'update_video_track',
      '3': 18,
      '4': 1,
      '5': 11,
      '6': '.gravixcloud.UpdateLocalVideoTrack',
      '9': 0,
      '10': 'updateVideoTrack'
    },
    {
      '1': 'publish_data_track_request',
      '3': 19,
      '4': 1,
      '5': 11,
      '6': '.gravixcloud.PublishDataTrackRequest',
      '9': 0,
      '10': 'publishDataTrackRequest'
    },
    {
      '1': 'unpublish_data_track_request',
      '3': 20,
      '4': 1,
      '5': 11,
      '6': '.gravixcloud.UnpublishDataTrackRequest',
      '9': 0,
      '10': 'unpublishDataTrackRequest'
    },
    {
      '1': 'update_data_subscription',
      '3': 21,
      '4': 1,
      '5': 11,
      '6': '.gravixcloud.UpdateDataSubscription',
      '9': 0,
      '10': 'updateDataSubscription'
    },
    {
      '1': 'store_data_blob_request',
      '3': 22,
      '4': 1,
      '5': 11,
      '6': '.gravixcloud.StoreDataBlobRequest',
      '9': 0,
      '10': 'storeDataBlobRequest'
    },
    {
      '1': 'get_data_blob_request',
      '3': 23,
      '4': 1,
      '5': 11,
      '6': '.gravixcloud.GetDataBlobRequest',
      '9': 0,
      '10': 'getDataBlobRequest'
    },
  ],
  '8': [
    {'1': 'message'},
  ],
};

/// Descriptor for `SignalRequest`. Decode as a `google.protobuf.DescriptorProto`.
final $typed_data.Uint8List signalRequestDescriptor =
    $convert.base64Decode('Cg1TaWduYWxSZXF1ZXN0EjcKBW9mZmVyGAEgASgLMh8uZ3Jhdml4Y2xvdWQuU2Vzc2lvbkRlc2'
        'NyaXB0aW9uSABSBW9mZmVyEjkKBmFuc3dlchgCIAEoCzIfLmdyYXZpeGNsb3VkLlNlc3Npb25E'
        'ZXNjcmlwdGlvbkgAUgZhbnN3ZXISNwoHdHJpY2tsZRgDIAEoCzIbLmdyYXZpeGNsb3VkLlRyaW'
        'NrbGVSZXF1ZXN0SABSB3RyaWNrbGUSOwoJYWRkX3RyYWNrGAQgASgLMhwuZ3Jhdml4Y2xvdWQu'
        'QWRkVHJhY2tSZXF1ZXN0SABSCGFkZFRyYWNrEjMKBG11dGUYBSABKAsyHS5ncmF2aXhjbG91ZC'
        '5NdXRlVHJhY2tSZXF1ZXN0SABSBG11dGUSRQoMc3Vic2NyaXB0aW9uGAYgASgLMh8uZ3Jhdml4'
        'Y2xvdWQuVXBkYXRlU3Vic2NyaXB0aW9uSABSDHN1YnNjcmlwdGlvbhJHCg10cmFja19zZXR0aW'
        '5nGAcgASgLMiAuZ3Jhdml4Y2xvdWQuVXBkYXRlVHJhY2tTZXR0aW5nc0gAUgx0cmFja1NldHRp'
        'bmcSMQoFbGVhdmUYCCABKAsyGS5ncmF2aXhjbG91ZC5MZWF2ZVJlcXVlc3RIAFIFbGVhdmUSSQ'
        'oNdXBkYXRlX2xheWVycxgKIAEoCzIeLmdyYXZpeGNsb3VkLlVwZGF0ZVZpZGVvTGF5ZXJzQgIY'
        'AUgAUgx1cGRhdGVMYXllcnMSXgoXc3Vic2NyaXB0aW9uX3Blcm1pc3Npb24YCyABKAsyIy5ncm'
        'F2aXhjbG91ZC5TdWJzY3JpcHRpb25QZXJtaXNzaW9uSABSFnN1YnNjcmlwdGlvblBlcm1pc3Np'
        'b24SNwoKc3luY19zdGF0ZRgMIAEoCzIWLmdyYXZpeGNsb3VkLlN5bmNTdGF0ZUgAUglzeW5jU3'
        'RhdGUSOwoIc2ltdWxhdGUYDSABKAsyHS5ncmF2aXhjbG91ZC5TaW11bGF0ZVNjZW5hcmlvSABS'
        'CHNpbXVsYXRlEhQKBHBpbmcYDiABKANIAFIEcGluZxJRCg91cGRhdGVfbWV0YWRhdGEYDyABKA'
        'syJi5ncmF2aXhjbG91ZC5VcGRhdGVQYXJ0aWNpcGFudE1ldGFkYXRhSABSDnVwZGF0ZU1ldGFk'
        'YXRhEi4KCHBpbmdfcmVxGBAgASgLMhEuZ3Jhdml4Y2xvdWQuUGluZ0gAUgdwaW5nUmVxElIKEn'
        'VwZGF0ZV9hdWRpb190cmFjaxgRIAEoCzIiLmdyYXZpeGNsb3VkLlVwZGF0ZUxvY2FsQXVkaW9U'
        'cmFja0gAUhB1cGRhdGVBdWRpb1RyYWNrElIKEnVwZGF0ZV92aWRlb190cmFjaxgSIAEoCzIiLm'
        'dyYXZpeGNsb3VkLlVwZGF0ZUxvY2FsVmlkZW9UcmFja0gAUhB1cGRhdGVWaWRlb1RyYWNrEmMK'
        'GnB1Ymxpc2hfZGF0YV90cmFja19yZXF1ZXN0GBMgASgLMiQuZ3Jhdml4Y2xvdWQuUHVibGlzaE'
        'RhdGFUcmFja1JlcXVlc3RIAFIXcHVibGlzaERhdGFUcmFja1JlcXVlc3QSaQocdW5wdWJsaXNo'
        'X2RhdGFfdHJhY2tfcmVxdWVzdBgUIAEoCzImLmdyYXZpeGNsb3VkLlVucHVibGlzaERhdGFUcm'
        'Fja1JlcXVlc3RIAFIZdW5wdWJsaXNoRGF0YVRyYWNrUmVxdWVzdBJfChh1cGRhdGVfZGF0YV9z'
        'dWJzY3JpcHRpb24YFSABKAsyIy5ncmF2aXhjbG91ZC5VcGRhdGVEYXRhU3Vic2NyaXB0aW9uSA'
        'BSFnVwZGF0ZURhdGFTdWJzY3JpcHRpb24SWgoXc3RvcmVfZGF0YV9ibG9iX3JlcXVlc3QYFiAB'
        'KAsyIS5ncmF2aXhjbG91ZC5TdG9yZURhdGFCbG9iUmVxdWVzdEgAUhRzdG9yZURhdGFCbG9iUm'
        'VxdWVzdBJUChVnZXRfZGF0YV9ibG9iX3JlcXVlc3QYFyABKAsyHy5ncmF2aXhjbG91ZC5HZXRE'
        'YXRhQmxvYlJlcXVlc3RIAFISZ2V0RGF0YUJsb2JSZXF1ZXN0QgkKB21lc3NhZ2U=');

@$core.Deprecated('Use signalResponseDescriptor instead')
const SignalResponse$json = {
  '1': 'SignalResponse',
  '2': [
    {'1': 'join', '3': 1, '4': 1, '5': 11, '6': '.gravixcloud.JoinResponse', '9': 0, '10': 'join'},
    {'1': 'answer', '3': 2, '4': 1, '5': 11, '6': '.gravixcloud.SessionDescription', '9': 0, '10': 'answer'},
    {'1': 'offer', '3': 3, '4': 1, '5': 11, '6': '.gravixcloud.SessionDescription', '9': 0, '10': 'offer'},
    {'1': 'trickle', '3': 4, '4': 1, '5': 11, '6': '.gravixcloud.TrickleRequest', '9': 0, '10': 'trickle'},
    {'1': 'update', '3': 5, '4': 1, '5': 11, '6': '.gravixcloud.ParticipantUpdate', '9': 0, '10': 'update'},
    {
      '1': 'track_published',
      '3': 6,
      '4': 1,
      '5': 11,
      '6': '.gravixcloud.TrackPublishedResponse',
      '9': 0,
      '10': 'trackPublished'
    },
    {'1': 'leave', '3': 8, '4': 1, '5': 11, '6': '.gravixcloud.LeaveRequest', '9': 0, '10': 'leave'},
    {'1': 'mute', '3': 9, '4': 1, '5': 11, '6': '.gravixcloud.MuteTrackRequest', '9': 0, '10': 'mute'},
    {
      '1': 'speakers_changed',
      '3': 10,
      '4': 1,
      '5': 11,
      '6': '.gravixcloud.SpeakersChanged',
      '9': 0,
      '10': 'speakersChanged'
    },
    {'1': 'room_update', '3': 11, '4': 1, '5': 11, '6': '.gravixcloud.RoomUpdate', '9': 0, '10': 'roomUpdate'},
    {
      '1': 'connection_quality',
      '3': 12,
      '4': 1,
      '5': 11,
      '6': '.gravixcloud.ConnectionQualityUpdate',
      '9': 0,
      '10': 'connectionQuality'
    },
    {
      '1': 'stream_state_update',
      '3': 13,
      '4': 1,
      '5': 11,
      '6': '.gravixcloud.StreamStateUpdate',
      '9': 0,
      '10': 'streamStateUpdate'
    },
    {
      '1': 'subscribed_quality_update',
      '3': 14,
      '4': 1,
      '5': 11,
      '6': '.gravixcloud.SubscribedQualityUpdate',
      '9': 0,
      '10': 'subscribedQualityUpdate'
    },
    {
      '1': 'subscription_permission_update',
      '3': 15,
      '4': 1,
      '5': 11,
      '6': '.gravixcloud.SubscriptionPermissionUpdate',
      '9': 0,
      '10': 'subscriptionPermissionUpdate'
    },
    {'1': 'refresh_token', '3': 16, '4': 1, '5': 9, '9': 0, '10': 'refreshToken'},
    {
      '1': 'track_unpublished',
      '3': 17,
      '4': 1,
      '5': 11,
      '6': '.gravixcloud.TrackUnpublishedResponse',
      '9': 0,
      '10': 'trackUnpublished'
    },
    {'1': 'pong', '3': 18, '4': 1, '5': 3, '9': 0, '10': 'pong'},
    {'1': 'reconnect', '3': 19, '4': 1, '5': 11, '6': '.gravixcloud.ReconnectResponse', '9': 0, '10': 'reconnect'},
    {'1': 'pong_resp', '3': 20, '4': 1, '5': 11, '6': '.gravixcloud.Pong', '9': 0, '10': 'pongResp'},
    {
      '1': 'subscription_response',
      '3': 21,
      '4': 1,
      '5': 11,
      '6': '.gravixcloud.SubscriptionResponse',
      '9': 0,
      '10': 'subscriptionResponse'
    },
    {
      '1': 'request_response',
      '3': 22,
      '4': 1,
      '5': 11,
      '6': '.gravixcloud.RequestResponse',
      '9': 0,
      '10': 'requestResponse'
    },
    {
      '1': 'track_subscribed',
      '3': 23,
      '4': 1,
      '5': 11,
      '6': '.gravixcloud.TrackSubscribed',
      '9': 0,
      '10': 'trackSubscribed'
    },
    {'1': 'room_moved', '3': 24, '4': 1, '5': 11, '6': '.gravixcloud.RoomMovedResponse', '9': 0, '10': 'roomMoved'},
    {
      '1': 'media_sections_requirement',
      '3': 25,
      '4': 1,
      '5': 11,
      '6': '.gravixcloud.MediaSectionsRequirement',
      '9': 0,
      '10': 'mediaSectionsRequirement'
    },
    {
      '1': 'subscribed_audio_codec_update',
      '3': 26,
      '4': 1,
      '5': 11,
      '6': '.gravixcloud.SubscribedAudioCodecUpdate',
      '9': 0,
      '10': 'subscribedAudioCodecUpdate'
    },
    {
      '1': 'publish_data_track_response',
      '3': 27,
      '4': 1,
      '5': 11,
      '6': '.gravixcloud.PublishDataTrackResponse',
      '9': 0,
      '10': 'publishDataTrackResponse'
    },
    {
      '1': 'unpublish_data_track_response',
      '3': 28,
      '4': 1,
      '5': 11,
      '6': '.gravixcloud.UnpublishDataTrackResponse',
      '9': 0,
      '10': 'unpublishDataTrackResponse'
    },
    {
      '1': 'data_track_subscriber_handles',
      '3': 29,
      '4': 1,
      '5': 11,
      '6': '.gravixcloud.DataTrackSubscriberHandles',
      '9': 0,
      '10': 'dataTrackSubscriberHandles'
    },
    {
      '1': 'store_data_blob_response',
      '3': 30,
      '4': 1,
      '5': 11,
      '6': '.gravixcloud.StoreDataBlobResponse',
      '9': 0,
      '10': 'storeDataBlobResponse'
    },
    {
      '1': 'get_data_blob_response',
      '3': 31,
      '4': 1,
      '5': 11,
      '6': '.gravixcloud.GetDataBlobResponse',
      '9': 0,
      '10': 'getDataBlobResponse'
    },
  ],
  '8': [
    {'1': 'message'},
  ],
};

/// Descriptor for `SignalResponse`. Decode as a `google.protobuf.DescriptorProto`.
final $typed_data.Uint8List signalResponseDescriptor =
    $convert.base64Decode('Cg5TaWduYWxSZXNwb25zZRIvCgRqb2luGAEgASgLMhkuZ3Jhdml4Y2xvdWQuSm9pblJlc3Bvbn'
        'NlSABSBGpvaW4SOQoGYW5zd2VyGAIgASgLMh8uZ3Jhdml4Y2xvdWQuU2Vzc2lvbkRlc2NyaXB0'
        'aW9uSABSBmFuc3dlchI3CgVvZmZlchgDIAEoCzIfLmdyYXZpeGNsb3VkLlNlc3Npb25EZXNjcm'
        'lwdGlvbkgAUgVvZmZlchI3Cgd0cmlja2xlGAQgASgLMhsuZ3Jhdml4Y2xvdWQuVHJpY2tsZVJl'
        'cXVlc3RIAFIHdHJpY2tsZRI4CgZ1cGRhdGUYBSABKAsyHi5ncmF2aXhjbG91ZC5QYXJ0aWNpcG'
        'FudFVwZGF0ZUgAUgZ1cGRhdGUSTgoPdHJhY2tfcHVibGlzaGVkGAYgASgLMiMuZ3Jhdml4Y2xv'
        'dWQuVHJhY2tQdWJsaXNoZWRSZXNwb25zZUgAUg50cmFja1B1Ymxpc2hlZBIxCgVsZWF2ZRgIIA'
        'EoCzIZLmdyYXZpeGNsb3VkLkxlYXZlUmVxdWVzdEgAUgVsZWF2ZRIzCgRtdXRlGAkgASgLMh0u'
        'Z3Jhdml4Y2xvdWQuTXV0ZVRyYWNrUmVxdWVzdEgAUgRtdXRlEkkKEHNwZWFrZXJzX2NoYW5nZW'
        'QYCiABKAsyHC5ncmF2aXhjbG91ZC5TcGVha2Vyc0NoYW5nZWRIAFIPc3BlYWtlcnNDaGFuZ2Vk'
        'EjoKC3Jvb21fdXBkYXRlGAsgASgLMhcuZ3Jhdml4Y2xvdWQuUm9vbVVwZGF0ZUgAUgpyb29tVX'
        'BkYXRlElUKEmNvbm5lY3Rpb25fcXVhbGl0eRgMIAEoCzIkLmdyYXZpeGNsb3VkLkNvbm5lY3Rp'
        'b25RdWFsaXR5VXBkYXRlSABSEWNvbm5lY3Rpb25RdWFsaXR5ElAKE3N0cmVhbV9zdGF0ZV91cG'
        'RhdGUYDSABKAsyHi5ncmF2aXhjbG91ZC5TdHJlYW1TdGF0ZVVwZGF0ZUgAUhFzdHJlYW1TdGF0'
        'ZVVwZGF0ZRJiChlzdWJzY3JpYmVkX3F1YWxpdHlfdXBkYXRlGA4gASgLMiQuZ3Jhdml4Y2xvdW'
        'QuU3Vic2NyaWJlZFF1YWxpdHlVcGRhdGVIAFIXc3Vic2NyaWJlZFF1YWxpdHlVcGRhdGUScQoe'
        'c3Vic2NyaXB0aW9uX3Blcm1pc3Npb25fdXBkYXRlGA8gASgLMikuZ3Jhdml4Y2xvdWQuU3Vic2'
        'NyaXB0aW9uUGVybWlzc2lvblVwZGF0ZUgAUhxzdWJzY3JpcHRpb25QZXJtaXNzaW9uVXBkYXRl'
        'EiUKDXJlZnJlc2hfdG9rZW4YECABKAlIAFIMcmVmcmVzaFRva2VuElQKEXRyYWNrX3VucHVibG'
        'lzaGVkGBEgASgLMiUuZ3Jhdml4Y2xvdWQuVHJhY2tVbnB1Ymxpc2hlZFJlc3BvbnNlSABSEHRy'
        'YWNrVW5wdWJsaXNoZWQSFAoEcG9uZxgSIAEoA0gAUgRwb25nEj4KCXJlY29ubmVjdBgTIAEoCz'
        'IeLmdyYXZpeGNsb3VkLlJlY29ubmVjdFJlc3BvbnNlSABSCXJlY29ubmVjdBIwCglwb25nX3Jl'
        'c3AYFCABKAsyES5ncmF2aXhjbG91ZC5Qb25nSABSCHBvbmdSZXNwElgKFXN1YnNjcmlwdGlvbl'
        '9yZXNwb25zZRgVIAEoCzIhLmdyYXZpeGNsb3VkLlN1YnNjcmlwdGlvblJlc3BvbnNlSABSFHN1'
        'YnNjcmlwdGlvblJlc3BvbnNlEkkKEHJlcXVlc3RfcmVzcG9uc2UYFiABKAsyHC5ncmF2aXhjbG'
        '91ZC5SZXF1ZXN0UmVzcG9uc2VIAFIPcmVxdWVzdFJlc3BvbnNlEkkKEHRyYWNrX3N1YnNjcmli'
        'ZWQYFyABKAsyHC5ncmF2aXhjbG91ZC5UcmFja1N1YnNjcmliZWRIAFIPdHJhY2tTdWJzY3JpYm'
        'VkEj8KCnJvb21fbW92ZWQYGCABKAsyHi5ncmF2aXhjbG91ZC5Sb29tTW92ZWRSZXNwb25zZUgA'
        'Uglyb29tTW92ZWQSZQoabWVkaWFfc2VjdGlvbnNfcmVxdWlyZW1lbnQYGSABKAsyJS5ncmF2aX'
        'hjbG91ZC5NZWRpYVNlY3Rpb25zUmVxdWlyZW1lbnRIAFIYbWVkaWFTZWN0aW9uc1JlcXVpcmVt'
        'ZW50EmwKHXN1YnNjcmliZWRfYXVkaW9fY29kZWNfdXBkYXRlGBogASgLMicuZ3Jhdml4Y2xvdW'
        'QuU3Vic2NyaWJlZEF1ZGlvQ29kZWNVcGRhdGVIAFIac3Vic2NyaWJlZEF1ZGlvQ29kZWNVcGRh'
        'dGUSZgobcHVibGlzaF9kYXRhX3RyYWNrX3Jlc3BvbnNlGBsgASgLMiUuZ3Jhdml4Y2xvdWQuUH'
        'VibGlzaERhdGFUcmFja1Jlc3BvbnNlSABSGHB1Ymxpc2hEYXRhVHJhY2tSZXNwb25zZRJsCh11'
        'bnB1Ymxpc2hfZGF0YV90cmFja19yZXNwb25zZRgcIAEoCzInLmdyYXZpeGNsb3VkLlVucHVibG'
        'lzaERhdGFUcmFja1Jlc3BvbnNlSABSGnVucHVibGlzaERhdGFUcmFja1Jlc3BvbnNlEmwKHWRh'
        'dGFfdHJhY2tfc3Vic2NyaWJlcl9oYW5kbGVzGB0gASgLMicuZ3Jhdml4Y2xvdWQuRGF0YVRyYW'
        'NrU3Vic2NyaWJlckhhbmRsZXNIAFIaZGF0YVRyYWNrU3Vic2NyaWJlckhhbmRsZXMSXQoYc3Rv'
        'cmVfZGF0YV9ibG9iX3Jlc3BvbnNlGB4gASgLMiIuZ3Jhdml4Y2xvdWQuU3RvcmVEYXRhQmxvYl'
        'Jlc3BvbnNlSABSFXN0b3JlRGF0YUJsb2JSZXNwb25zZRJXChZnZXRfZGF0YV9ibG9iX3Jlc3Bv'
        'bnNlGB8gASgLMiAuZ3Jhdml4Y2xvdWQuR2V0RGF0YUJsb2JSZXNwb25zZUgAUhNnZXREYXRhQm'
        'xvYlJlc3BvbnNlQgkKB21lc3NhZ2U=');

@$core.Deprecated('Use simulcastCodecDescriptor instead')
const SimulcastCodec$json = {
  '1': 'SimulcastCodec',
  '2': [
    {'1': 'codec', '3': 1, '4': 1, '5': 9, '10': 'codec'},
    {'1': 'cid', '3': 2, '4': 1, '5': 9, '10': 'cid'},
    {'1': 'layers', '3': 4, '4': 3, '5': 11, '6': '.gravixcloud.VideoLayer', '10': 'layers'},
    {'1': 'video_layer_mode', '3': 5, '4': 1, '5': 14, '6': '.gravixcloud.VideoLayer.Mode', '10': 'videoLayerMode'},
  ],
};

/// Descriptor for `SimulcastCodec`. Decode as a `google.protobuf.DescriptorProto`.
final $typed_data.Uint8List simulcastCodecDescriptor =
    $convert.base64Decode('Cg5TaW11bGNhc3RDb2RlYxIUCgVjb2RlYxgBIAEoCVIFY29kZWMSEAoDY2lkGAIgASgJUgNjaW'
        'QSLwoGbGF5ZXJzGAQgAygLMhcuZ3Jhdml4Y2xvdWQuVmlkZW9MYXllclIGbGF5ZXJzEkYKEHZp'
        'ZGVvX2xheWVyX21vZGUYBSABKA4yHC5ncmF2aXhjbG91ZC5WaWRlb0xheWVyLk1vZGVSDnZpZG'
        'VvTGF5ZXJNb2Rl');

@$core.Deprecated('Use addTrackRequestDescriptor instead')
const AddTrackRequest$json = {
  '1': 'AddTrackRequest',
  '2': [
    {'1': 'cid', '3': 1, '4': 1, '5': 9, '10': 'cid'},
    {'1': 'name', '3': 2, '4': 1, '5': 9, '10': 'name'},
    {'1': 'type', '3': 3, '4': 1, '5': 14, '6': '.gravixcloud.TrackType', '10': 'type'},
    {'1': 'width', '3': 4, '4': 1, '5': 13, '10': 'width'},
    {'1': 'height', '3': 5, '4': 1, '5': 13, '10': 'height'},
    {'1': 'muted', '3': 6, '4': 1, '5': 8, '10': 'muted'},
    {
      '1': 'disable_dtx',
      '3': 7,
      '4': 1,
      '5': 8,
      '8': {'3': true},
      '10': 'disableDtx',
    },
    {'1': 'source', '3': 8, '4': 1, '5': 14, '6': '.gravixcloud.TrackSource', '10': 'source'},
    {'1': 'layers', '3': 9, '4': 3, '5': 11, '6': '.gravixcloud.VideoLayer', '10': 'layers'},
    {'1': 'simulcast_codecs', '3': 10, '4': 3, '5': 11, '6': '.gravixcloud.SimulcastCodec', '10': 'simulcastCodecs'},
    {'1': 'sid', '3': 11, '4': 1, '5': 9, '10': 'sid'},
    {
      '1': 'stereo',
      '3': 12,
      '4': 1,
      '5': 8,
      '8': {'3': true},
      '10': 'stereo',
    },
    {'1': 'disable_red', '3': 13, '4': 1, '5': 8, '10': 'disableRed'},
    {'1': 'encryption', '3': 14, '4': 1, '5': 14, '6': '.gravixcloud.Encryption.Type', '10': 'encryption'},
    {'1': 'stream', '3': 15, '4': 1, '5': 9, '10': 'stream'},
    {
      '1': 'backup_codec_policy',
      '3': 16,
      '4': 1,
      '5': 14,
      '6': '.gravixcloud.BackupCodecPolicy',
      '10': 'backupCodecPolicy'
    },
    {'1': 'audio_features', '3': 17, '4': 3, '5': 14, '6': '.gravixcloud.AudioTrackFeature', '10': 'audioFeatures'},
    {
      '1': 'packet_trailer_features',
      '3': 18,
      '4': 3,
      '5': 14,
      '6': '.gravixcloud.PacketTrailerFeature',
      '10': 'packetTrailerFeatures'
    },
  ],
};

/// Descriptor for `AddTrackRequest`. Decode as a `google.protobuf.DescriptorProto`.
final $typed_data.Uint8List addTrackRequestDescriptor =
    $convert.base64Decode('Cg9BZGRUcmFja1JlcXVlc3QSEAoDY2lkGAEgASgJUgNjaWQSEgoEbmFtZRgCIAEoCVIEbmFtZR'
        'IqCgR0eXBlGAMgASgOMhYuZ3Jhdml4Y2xvdWQuVHJhY2tUeXBlUgR0eXBlEhQKBXdpZHRoGAQg'
        'ASgNUgV3aWR0aBIWCgZoZWlnaHQYBSABKA1SBmhlaWdodBIUCgVtdXRlZBgGIAEoCFIFbXV0ZW'
        'QSIwoLZGlzYWJsZV9kdHgYByABKAhCAhgBUgpkaXNhYmxlRHR4EjAKBnNvdXJjZRgIIAEoDjIY'
        'LmdyYXZpeGNsb3VkLlRyYWNrU291cmNlUgZzb3VyY2USLwoGbGF5ZXJzGAkgAygLMhcuZ3Jhdm'
        'l4Y2xvdWQuVmlkZW9MYXllclIGbGF5ZXJzEkYKEHNpbXVsY2FzdF9jb2RlY3MYCiADKAsyGy5n'
        'cmF2aXhjbG91ZC5TaW11bGNhc3RDb2RlY1IPc2ltdWxjYXN0Q29kZWNzEhAKA3NpZBgLIAEoCV'
        'IDc2lkEhoKBnN0ZXJlbxgMIAEoCEICGAFSBnN0ZXJlbxIfCgtkaXNhYmxlX3JlZBgNIAEoCFIK'
        'ZGlzYWJsZVJlZBI8CgplbmNyeXB0aW9uGA4gASgOMhwuZ3Jhdml4Y2xvdWQuRW5jcnlwdGlvbi'
        '5UeXBlUgplbmNyeXB0aW9uEhYKBnN0cmVhbRgPIAEoCVIGc3RyZWFtEk4KE2JhY2t1cF9jb2Rl'
        'Y19wb2xpY3kYECABKA4yHi5ncmF2aXhjbG91ZC5CYWNrdXBDb2RlY1BvbGljeVIRYmFja3VwQ2'
        '9kZWNQb2xpY3kSRQoOYXVkaW9fZmVhdHVyZXMYESADKA4yHi5ncmF2aXhjbG91ZC5BdWRpb1Ry'
        'YWNrRmVhdHVyZVINYXVkaW9GZWF0dXJlcxJZChdwYWNrZXRfdHJhaWxlcl9mZWF0dXJlcxgSIA'
        'MoDjIhLmdyYXZpeGNsb3VkLlBhY2tldFRyYWlsZXJGZWF0dXJlUhVwYWNrZXRUcmFpbGVyRmVh'
        'dHVyZXM=');

@$core.Deprecated('Use publishDataTrackRequestDescriptor instead')
const PublishDataTrackRequest$json = {
  '1': 'PublishDataTrackRequest',
  '2': [
    {'1': 'pub_handle', '3': 1, '4': 1, '5': 13, '10': 'pubHandle'},
    {'1': 'name', '3': 2, '4': 1, '5': 9, '10': 'name'},
    {'1': 'encryption', '3': 3, '4': 1, '5': 14, '6': '.gravixcloud.Encryption.Type', '10': 'encryption'},
    {
      '1': 'frame_encoding',
      '3': 4,
      '4': 1,
      '5': 11,
      '6': '.gravixcloud.DataTrackFrameEncoding',
      '9': 0,
      '10': 'frameEncoding',
      '17': true
    },
    {'1': 'schema', '3': 5, '4': 1, '5': 11, '6': '.gravixcloud.DataTrackSchemaId', '9': 1, '10': 'schema', '17': true},
  ],
  '8': [
    {'1': '_frame_encoding'},
    {'1': '_schema'},
  ],
};

/// Descriptor for `PublishDataTrackRequest`. Decode as a `google.protobuf.DescriptorProto`.
final $typed_data.Uint8List publishDataTrackRequestDescriptor =
    $convert.base64Decode('ChdQdWJsaXNoRGF0YVRyYWNrUmVxdWVzdBIdCgpwdWJfaGFuZGxlGAEgASgNUglwdWJIYW5kbG'
        'USEgoEbmFtZRgCIAEoCVIEbmFtZRI8CgplbmNyeXB0aW9uGAMgASgOMhwuZ3Jhdml4Y2xvdWQu'
        'RW5jcnlwdGlvbi5UeXBlUgplbmNyeXB0aW9uEk8KDmZyYW1lX2VuY29kaW5nGAQgASgLMiMuZ3'
        'Jhdml4Y2xvdWQuRGF0YVRyYWNrRnJhbWVFbmNvZGluZ0gAUg1mcmFtZUVuY29kaW5niAEBEjsK'
        'BnNjaGVtYRgFIAEoCzIeLmdyYXZpeGNsb3VkLkRhdGFUcmFja1NjaGVtYUlkSAFSBnNjaGVtYY'
        'gBAUIRCg9fZnJhbWVfZW5jb2RpbmdCCQoHX3NjaGVtYQ==');

@$core.Deprecated('Use publishDataTrackResponseDescriptor instead')
const PublishDataTrackResponse$json = {
  '1': 'PublishDataTrackResponse',
  '2': [
    {'1': 'info', '3': 1, '4': 1, '5': 11, '6': '.gravixcloud.DataTrackInfo', '10': 'info'},
  ],
};

/// Descriptor for `PublishDataTrackResponse`. Decode as a `google.protobuf.DescriptorProto`.
final $typed_data.Uint8List publishDataTrackResponseDescriptor =
    $convert.base64Decode('ChhQdWJsaXNoRGF0YVRyYWNrUmVzcG9uc2USLgoEaW5mbxgBIAEoCzIaLmdyYXZpeGNsb3VkLk'
        'RhdGFUcmFja0luZm9SBGluZm8=');

@$core.Deprecated('Use unpublishDataTrackRequestDescriptor instead')
const UnpublishDataTrackRequest$json = {
  '1': 'UnpublishDataTrackRequest',
  '2': [
    {'1': 'pub_handle', '3': 1, '4': 1, '5': 13, '10': 'pubHandle'},
  ],
};

/// Descriptor for `UnpublishDataTrackRequest`. Decode as a `google.protobuf.DescriptorProto`.
final $typed_data.Uint8List unpublishDataTrackRequestDescriptor =
    $convert.base64Decode('ChlVbnB1Ymxpc2hEYXRhVHJhY2tSZXF1ZXN0Eh0KCnB1Yl9oYW5kbGUYASABKA1SCXB1Ykhhbm'
        'RsZQ==');

@$core.Deprecated('Use unpublishDataTrackResponseDescriptor instead')
const UnpublishDataTrackResponse$json = {
  '1': 'UnpublishDataTrackResponse',
  '2': [
    {'1': 'info', '3': 1, '4': 1, '5': 11, '6': '.gravixcloud.DataTrackInfo', '10': 'info'},
  ],
};

/// Descriptor for `UnpublishDataTrackResponse`. Decode as a `google.protobuf.DescriptorProto`.
final $typed_data.Uint8List unpublishDataTrackResponseDescriptor =
    $convert.base64Decode('ChpVbnB1Ymxpc2hEYXRhVHJhY2tSZXNwb25zZRIuCgRpbmZvGAEgASgLMhouZ3Jhdml4Y2xvdW'
        'QuRGF0YVRyYWNrSW5mb1IEaW5mbw==');

@$core.Deprecated('Use dataTrackSubscriberHandlesDescriptor instead')
const DataTrackSubscriberHandles$json = {
  '1': 'DataTrackSubscriberHandles',
  '2': [
    {
      '1': 'sub_handles',
      '3': 1,
      '4': 3,
      '5': 11,
      '6': '.gravixcloud.DataTrackSubscriberHandles.SubHandlesEntry',
      '10': 'subHandles'
    },
  ],
  '3': [DataTrackSubscriberHandles_PublishedDataTrack$json, DataTrackSubscriberHandles_SubHandlesEntry$json],
};

@$core.Deprecated('Use dataTrackSubscriberHandlesDescriptor instead')
const DataTrackSubscriberHandles_PublishedDataTrack$json = {
  '1': 'PublishedDataTrack',
  '2': [
    {'1': 'publisher_identity', '3': 1, '4': 1, '5': 9, '10': 'publisherIdentity'},
    {'1': 'publisher_sid', '3': 2, '4': 1, '5': 9, '10': 'publisherSid'},
    {'1': 'track_sid', '3': 3, '4': 1, '5': 9, '10': 'trackSid'},
  ],
};

@$core.Deprecated('Use dataTrackSubscriberHandlesDescriptor instead')
const DataTrackSubscriberHandles_SubHandlesEntry$json = {
  '1': 'SubHandlesEntry',
  '2': [
    {'1': 'key', '3': 1, '4': 1, '5': 13, '10': 'key'},
    {
      '1': 'value',
      '3': 2,
      '4': 1,
      '5': 11,
      '6': '.gravixcloud.DataTrackSubscriberHandles.PublishedDataTrack',
      '10': 'value'
    },
  ],
  '7': {'7': true},
};

/// Descriptor for `DataTrackSubscriberHandles`. Decode as a `google.protobuf.DescriptorProto`.
final $typed_data.Uint8List dataTrackSubscriberHandlesDescriptor =
    $convert.base64Decode('ChpEYXRhVHJhY2tTdWJzY3JpYmVySGFuZGxlcxJYCgtzdWJfaGFuZGxlcxgBIAMoCzI3LmdyYX'
        'ZpeGNsb3VkLkRhdGFUcmFja1N1YnNjcmliZXJIYW5kbGVzLlN1YkhhbmRsZXNFbnRyeVIKc3Vi'
        'SGFuZGxlcxqFAQoSUHVibGlzaGVkRGF0YVRyYWNrEi0KEnB1Ymxpc2hlcl9pZGVudGl0eRgBIA'
        'EoCVIRcHVibGlzaGVySWRlbnRpdHkSIwoNcHVibGlzaGVyX3NpZBgCIAEoCVIMcHVibGlzaGVy'
        'U2lkEhsKCXRyYWNrX3NpZBgDIAEoCVIIdHJhY2tTaWQaeQoPU3ViSGFuZGxlc0VudHJ5EhAKA2'
        'tleRgBIAEoDVIDa2V5ElAKBXZhbHVlGAIgASgLMjouZ3Jhdml4Y2xvdWQuRGF0YVRyYWNrU3Vi'
        'c2NyaWJlckhhbmRsZXMuUHVibGlzaGVkRGF0YVRyYWNrUgV2YWx1ZToCOAE=');

@$core.Deprecated('Use trickleRequestDescriptor instead')
const TrickleRequest$json = {
  '1': 'TrickleRequest',
  '2': [
    {'1': 'candidateInit', '3': 1, '4': 1, '5': 9, '10': 'candidateInit'},
    {'1': 'target', '3': 2, '4': 1, '5': 14, '6': '.gravixcloud.SignalTarget', '10': 'target'},
    {'1': 'final', '3': 3, '4': 1, '5': 8, '10': 'final'},
  ],
};

/// Descriptor for `TrickleRequest`. Decode as a `google.protobuf.DescriptorProto`.
final $typed_data.Uint8List trickleRequestDescriptor =
    $convert.base64Decode('Cg5Ucmlja2xlUmVxdWVzdBIkCg1jYW5kaWRhdGVJbml0GAEgASgJUg1jYW5kaWRhdGVJbml0Ej'
        'EKBnRhcmdldBgCIAEoDjIZLmdyYXZpeGNsb3VkLlNpZ25hbFRhcmdldFIGdGFyZ2V0EhQKBWZp'
        'bmFsGAMgASgIUgVmaW5hbA==');

@$core.Deprecated('Use muteTrackRequestDescriptor instead')
const MuteTrackRequest$json = {
  '1': 'MuteTrackRequest',
  '2': [
    {'1': 'sid', '3': 1, '4': 1, '5': 9, '10': 'sid'},
    {'1': 'muted', '3': 2, '4': 1, '5': 8, '10': 'muted'},
  ],
};

/// Descriptor for `MuteTrackRequest`. Decode as a `google.protobuf.DescriptorProto`.
final $typed_data.Uint8List muteTrackRequestDescriptor =
    $convert.base64Decode('ChBNdXRlVHJhY2tSZXF1ZXN0EhAKA3NpZBgBIAEoCVIDc2lkEhQKBW11dGVkGAIgASgIUgVtdX'
        'RlZA==');

@$core.Deprecated('Use joinResponseDescriptor instead')
const JoinResponse$json = {
  '1': 'JoinResponse',
  '2': [
    {'1': 'room', '3': 1, '4': 1, '5': 11, '6': '.gravixcloud.Room', '10': 'room'},
    {'1': 'participant', '3': 2, '4': 1, '5': 11, '6': '.gravixcloud.ParticipantInfo', '10': 'participant'},
    {
      '1': 'other_participants',
      '3': 3,
      '4': 3,
      '5': 11,
      '6': '.gravixcloud.ParticipantInfo',
      '10': 'otherParticipants'
    },
    {'1': 'server_version', '3': 4, '4': 1, '5': 9, '10': 'serverVersion'},
    {'1': 'ice_servers', '3': 5, '4': 3, '5': 11, '6': '.gravixcloud.ICEServer', '10': 'iceServers'},
    {'1': 'subscriber_primary', '3': 6, '4': 1, '5': 8, '10': 'subscriberPrimary'},
    {'1': 'alternative_url', '3': 7, '4': 1, '5': 9, '10': 'alternativeUrl'},
    {
      '1': 'client_configuration',
      '3': 8,
      '4': 1,
      '5': 11,
      '6': '.gravixcloud.ClientConfiguration',
      '10': 'clientConfiguration'
    },
    {'1': 'server_region', '3': 9, '4': 1, '5': 9, '10': 'serverRegion'},
    {'1': 'ping_timeout', '3': 10, '4': 1, '5': 5, '10': 'pingTimeout'},
    {'1': 'ping_interval', '3': 11, '4': 1, '5': 5, '10': 'pingInterval'},
    {'1': 'server_info', '3': 12, '4': 1, '5': 11, '6': '.gravixcloud.ServerInfo', '10': 'serverInfo'},
    {'1': 'sif_trailer', '3': 13, '4': 1, '5': 12, '10': 'sifTrailer'},
    {'1': 'enabled_publish_codecs', '3': 14, '4': 3, '5': 11, '6': '.gravixcloud.Codec', '10': 'enabledPublishCodecs'},
    {'1': 'fast_publish', '3': 15, '4': 1, '5': 8, '10': 'fastPublish'},
  ],
};

/// Descriptor for `JoinResponse`. Decode as a `google.protobuf.DescriptorProto`.
final $typed_data.Uint8List joinResponseDescriptor =
    $convert.base64Decode('CgxKb2luUmVzcG9uc2USJQoEcm9vbRgBIAEoCzIRLmdyYXZpeGNsb3VkLlJvb21SBHJvb20SPg'
        'oLcGFydGljaXBhbnQYAiABKAsyHC5ncmF2aXhjbG91ZC5QYXJ0aWNpcGFudEluZm9SC3BhcnRp'
        'Y2lwYW50EksKEm90aGVyX3BhcnRpY2lwYW50cxgDIAMoCzIcLmdyYXZpeGNsb3VkLlBhcnRpY2'
        'lwYW50SW5mb1IRb3RoZXJQYXJ0aWNpcGFudHMSJQoOc2VydmVyX3ZlcnNpb24YBCABKAlSDXNl'
        'cnZlclZlcnNpb24SNwoLaWNlX3NlcnZlcnMYBSADKAsyFi5ncmF2aXhjbG91ZC5JQ0VTZXJ2ZX'
        'JSCmljZVNlcnZlcnMSLQoSc3Vic2NyaWJlcl9wcmltYXJ5GAYgASgIUhFzdWJzY3JpYmVyUHJp'
        'bWFyeRInCg9hbHRlcm5hdGl2ZV91cmwYByABKAlSDmFsdGVybmF0aXZlVXJsElMKFGNsaWVudF'
        '9jb25maWd1cmF0aW9uGAggASgLMiAuZ3Jhdml4Y2xvdWQuQ2xpZW50Q29uZmlndXJhdGlvblIT'
        'Y2xpZW50Q29uZmlndXJhdGlvbhIjCg1zZXJ2ZXJfcmVnaW9uGAkgASgJUgxzZXJ2ZXJSZWdpb2'
        '4SIQoMcGluZ190aW1lb3V0GAogASgFUgtwaW5nVGltZW91dBIjCg1waW5nX2ludGVydmFsGAsg'
        'ASgFUgxwaW5nSW50ZXJ2YWwSOAoLc2VydmVyX2luZm8YDCABKAsyFy5ncmF2aXhjbG91ZC5TZX'
        'J2ZXJJbmZvUgpzZXJ2ZXJJbmZvEh8KC3NpZl90cmFpbGVyGA0gASgMUgpzaWZUcmFpbGVyEkgK'
        'FmVuYWJsZWRfcHVibGlzaF9jb2RlY3MYDiADKAsyEi5ncmF2aXhjbG91ZC5Db2RlY1IUZW5hYm'
        'xlZFB1Ymxpc2hDb2RlY3MSIQoMZmFzdF9wdWJsaXNoGA8gASgIUgtmYXN0UHVibGlzaA==');

@$core.Deprecated('Use reconnectResponseDescriptor instead')
const ReconnectResponse$json = {
  '1': 'ReconnectResponse',
  '2': [
    {'1': 'ice_servers', '3': 1, '4': 3, '5': 11, '6': '.gravixcloud.ICEServer', '10': 'iceServers'},
    {
      '1': 'client_configuration',
      '3': 2,
      '4': 1,
      '5': 11,
      '6': '.gravixcloud.ClientConfiguration',
      '10': 'clientConfiguration'
    },
    {'1': 'server_info', '3': 3, '4': 1, '5': 11, '6': '.gravixcloud.ServerInfo', '10': 'serverInfo'},
    {'1': 'last_message_seq', '3': 4, '4': 1, '5': 13, '10': 'lastMessageSeq'},
  ],
};

/// Descriptor for `ReconnectResponse`. Decode as a `google.protobuf.DescriptorProto`.
final $typed_data.Uint8List reconnectResponseDescriptor =
    $convert.base64Decode('ChFSZWNvbm5lY3RSZXNwb25zZRI3CgtpY2Vfc2VydmVycxgBIAMoCzIWLmdyYXZpeGNsb3VkLk'
        'lDRVNlcnZlclIKaWNlU2VydmVycxJTChRjbGllbnRfY29uZmlndXJhdGlvbhgCIAEoCzIgLmdy'
        'YXZpeGNsb3VkLkNsaWVudENvbmZpZ3VyYXRpb25SE2NsaWVudENvbmZpZ3VyYXRpb24SOAoLc2'
        'VydmVyX2luZm8YAyABKAsyFy5ncmF2aXhjbG91ZC5TZXJ2ZXJJbmZvUgpzZXJ2ZXJJbmZvEigK'
        'EGxhc3RfbWVzc2FnZV9zZXEYBCABKA1SDmxhc3RNZXNzYWdlU2Vx');

@$core.Deprecated('Use trackPublishedResponseDescriptor instead')
const TrackPublishedResponse$json = {
  '1': 'TrackPublishedResponse',
  '2': [
    {'1': 'cid', '3': 1, '4': 1, '5': 9, '10': 'cid'},
    {'1': 'track', '3': 2, '4': 1, '5': 11, '6': '.gravixcloud.TrackInfo', '10': 'track'},
  ],
};

/// Descriptor for `TrackPublishedResponse`. Decode as a `google.protobuf.DescriptorProto`.
final $typed_data.Uint8List trackPublishedResponseDescriptor =
    $convert.base64Decode('ChZUcmFja1B1Ymxpc2hlZFJlc3BvbnNlEhAKA2NpZBgBIAEoCVIDY2lkEiwKBXRyYWNrGAIgAS'
        'gLMhYuZ3Jhdml4Y2xvdWQuVHJhY2tJbmZvUgV0cmFjaw==');

@$core.Deprecated('Use trackUnpublishedResponseDescriptor instead')
const TrackUnpublishedResponse$json = {
  '1': 'TrackUnpublishedResponse',
  '2': [
    {'1': 'track_sid', '3': 1, '4': 1, '5': 9, '10': 'trackSid'},
  ],
};

/// Descriptor for `TrackUnpublishedResponse`. Decode as a `google.protobuf.DescriptorProto`.
final $typed_data.Uint8List trackUnpublishedResponseDescriptor =
    $convert.base64Decode('ChhUcmFja1VucHVibGlzaGVkUmVzcG9uc2USGwoJdHJhY2tfc2lkGAEgASgJUgh0cmFja1NpZA'
        '==');

@$core.Deprecated('Use sessionDescriptionDescriptor instead')
const SessionDescription$json = {
  '1': 'SessionDescription',
  '2': [
    {'1': 'type', '3': 1, '4': 1, '5': 9, '10': 'type'},
    {'1': 'sdp', '3': 2, '4': 1, '5': 9, '10': 'sdp'},
    {'1': 'id', '3': 3, '4': 1, '5': 13, '10': 'id'},
    {
      '1': 'mid_to_track_id',
      '3': 4,
      '4': 3,
      '5': 11,
      '6': '.gravixcloud.SessionDescription.MidToTrackIdEntry',
      '8': {},
      '10': 'midToTrackId'
    },
  ],
  '3': [SessionDescription_MidToTrackIdEntry$json],
};

@$core.Deprecated('Use sessionDescriptionDescriptor instead')
const SessionDescription_MidToTrackIdEntry$json = {
  '1': 'MidToTrackIdEntry',
  '2': [
    {'1': 'key', '3': 1, '4': 1, '5': 9, '10': 'key'},
    {'1': 'value', '3': 2, '4': 1, '5': 9, '10': 'value'},
  ],
  '7': {'7': true},
};

/// Descriptor for `SessionDescription`. Decode as a `google.protobuf.DescriptorProto`.
final $typed_data.Uint8List sessionDescriptionDescriptor =
    $convert.base64Decode('ChJTZXNzaW9uRGVzY3JpcHRpb24SEgoEdHlwZRgBIAEoCVIEdHlwZRIQCgNzZHAYAiABKAlSA3'
        'NkcBIOCgJpZBgDIAEoDVICaWQSaQoPbWlkX3RvX3RyYWNrX2lkGAQgAygLMjEuZ3Jhdml4Y2xv'
        'dWQuU2Vzc2lvbkRlc2NyaXB0aW9uLk1pZFRvVHJhY2tJZEVudHJ5Qg+6UAxtaWRUb1RyYWNrSU'
        'RSDG1pZFRvVHJhY2tJZBo/ChFNaWRUb1RyYWNrSWRFbnRyeRIQCgNrZXkYASABKAlSA2tleRIU'
        'CgV2YWx1ZRgCIAEoCVIFdmFsdWU6AjgB');

@$core.Deprecated('Use participantUpdateDescriptor instead')
const ParticipantUpdate$json = {
  '1': 'ParticipantUpdate',
  '2': [
    {'1': 'participants', '3': 1, '4': 3, '5': 11, '6': '.gravixcloud.ParticipantInfo', '10': 'participants'},
  ],
};

/// Descriptor for `ParticipantUpdate`. Decode as a `google.protobuf.DescriptorProto`.
final $typed_data.Uint8List participantUpdateDescriptor =
    $convert.base64Decode('ChFQYXJ0aWNpcGFudFVwZGF0ZRJACgxwYXJ0aWNpcGFudHMYASADKAsyHC5ncmF2aXhjbG91ZC'
        '5QYXJ0aWNpcGFudEluZm9SDHBhcnRpY2lwYW50cw==');

@$core.Deprecated('Use updateSubscriptionDescriptor instead')
const UpdateSubscription$json = {
  '1': 'UpdateSubscription',
  '2': [
    {'1': 'track_sids', '3': 1, '4': 3, '5': 9, '10': 'trackSids'},
    {'1': 'subscribe', '3': 2, '4': 1, '5': 8, '10': 'subscribe'},
    {
      '1': 'participant_tracks',
      '3': 3,
      '4': 3,
      '5': 11,
      '6': '.gravixcloud.ParticipantTracks',
      '10': 'participantTracks'
    },
  ],
};

/// Descriptor for `UpdateSubscription`. Decode as a `google.protobuf.DescriptorProto`.
final $typed_data.Uint8List updateSubscriptionDescriptor =
    $convert.base64Decode('ChJVcGRhdGVTdWJzY3JpcHRpb24SHQoKdHJhY2tfc2lkcxgBIAMoCVIJdHJhY2tTaWRzEhwKCX'
        'N1YnNjcmliZRgCIAEoCFIJc3Vic2NyaWJlEk0KEnBhcnRpY2lwYW50X3RyYWNrcxgDIAMoCzIe'
        'LmdyYXZpeGNsb3VkLlBhcnRpY2lwYW50VHJhY2tzUhFwYXJ0aWNpcGFudFRyYWNrcw==');

@$core.Deprecated('Use updateDataSubscriptionDescriptor instead')
const UpdateDataSubscription$json = {
  '1': 'UpdateDataSubscription',
  '2': [
    {'1': 'updates', '3': 1, '4': 3, '5': 11, '6': '.gravixcloud.UpdateDataSubscription.Update', '10': 'updates'},
  ],
  '3': [UpdateDataSubscription_Update$json],
};

@$core.Deprecated('Use updateDataSubscriptionDescriptor instead')
const UpdateDataSubscription_Update$json = {
  '1': 'Update',
  '2': [
    {'1': 'track_sid', '3': 1, '4': 1, '5': 9, '10': 'trackSid'},
    {'1': 'subscribe', '3': 2, '4': 1, '5': 8, '10': 'subscribe'},
    {'1': 'options', '3': 3, '4': 1, '5': 11, '6': '.gravixcloud.DataTrackSubscriptionOptions', '10': 'options'},
  ],
};

/// Descriptor for `UpdateDataSubscription`. Decode as a `google.protobuf.DescriptorProto`.
final $typed_data.Uint8List updateDataSubscriptionDescriptor =
    $convert.base64Decode('ChZVcGRhdGVEYXRhU3Vic2NyaXB0aW9uEkQKB3VwZGF0ZXMYASADKAsyKi5ncmF2aXhjbG91ZC'
        '5VcGRhdGVEYXRhU3Vic2NyaXB0aW9uLlVwZGF0ZVIHdXBkYXRlcxqIAQoGVXBkYXRlEhsKCXRy'
        'YWNrX3NpZBgBIAEoCVIIdHJhY2tTaWQSHAoJc3Vic2NyaWJlGAIgASgIUglzdWJzY3JpYmUSQw'
        'oHb3B0aW9ucxgDIAEoCzIpLmdyYXZpeGNsb3VkLkRhdGFUcmFja1N1YnNjcmlwdGlvbk9wdGlv'
        'bnNSB29wdGlvbnM=');

@$core.Deprecated('Use storeDataBlobRequestDescriptor instead')
const StoreDataBlobRequest$json = {
  '1': 'StoreDataBlobRequest',
  '2': [
    {'1': 'request_id', '3': 1, '4': 1, '5': 13, '8': {}, '10': 'requestId'},
    {'1': 'blob', '3': 2, '4': 1, '5': 11, '6': '.gravixcloud.DataBlob', '10': 'blob'},
  ],
};

/// Descriptor for `StoreDataBlobRequest`. Decode as a `google.protobuf.DescriptorProto`.
final $typed_data.Uint8List storeDataBlobRequestDescriptor =
    $convert.base64Decode('ChRTdG9yZURhdGFCbG9iUmVxdWVzdBIrCgpyZXF1ZXN0X2lkGAEgASgNQgy6UAlyZXF1ZXN0SU'
        'RSCXJlcXVlc3RJZBIpCgRibG9iGAIgASgLMhUuZ3Jhdml4Y2xvdWQuRGF0YUJsb2JSBGJsb2I=');

@$core.Deprecated('Use storeDataBlobResponseDescriptor instead')
const StoreDataBlobResponse$json = {
  '1': 'StoreDataBlobResponse',
  '2': [
    {'1': 'request_id', '3': 1, '4': 1, '5': 13, '8': {}, '10': 'requestId'},
    {'1': 'key', '3': 2, '4': 1, '5': 11, '6': '.gravixcloud.DataBlobKey', '10': 'key'},
  ],
};

/// Descriptor for `StoreDataBlobResponse`. Decode as a `google.protobuf.DescriptorProto`.
final $typed_data.Uint8List storeDataBlobResponseDescriptor =
    $convert.base64Decode('ChVTdG9yZURhdGFCbG9iUmVzcG9uc2USKwoKcmVxdWVzdF9pZBgBIAEoDUIMulAJcmVxdWVzdE'
        'lEUglyZXF1ZXN0SWQSKgoDa2V5GAIgASgLMhguZ3Jhdml4Y2xvdWQuRGF0YUJsb2JLZXlSA2tl'
        'eQ==');

@$core.Deprecated('Use getDataBlobRequestDescriptor instead')
const GetDataBlobRequest$json = {
  '1': 'GetDataBlobRequest',
  '2': [
    {'1': 'request_id', '3': 1, '4': 1, '5': 13, '8': {}, '10': 'requestId'},
    {'1': 'participant_identity', '3': 2, '4': 1, '5': 9, '10': 'participantIdentity'},
    {'1': 'key', '3': 3, '4': 1, '5': 11, '6': '.gravixcloud.DataBlobKey', '10': 'key'},
  ],
};

/// Descriptor for `GetDataBlobRequest`. Decode as a `google.protobuf.DescriptorProto`.
final $typed_data.Uint8List getDataBlobRequestDescriptor =
    $convert.base64Decode('ChJHZXREYXRhQmxvYlJlcXVlc3QSKwoKcmVxdWVzdF9pZBgBIAEoDUIMulAJcmVxdWVzdElEUg'
        'lyZXF1ZXN0SWQSMQoUcGFydGljaXBhbnRfaWRlbnRpdHkYAiABKAlSE3BhcnRpY2lwYW50SWRl'
        'bnRpdHkSKgoDa2V5GAMgASgLMhguZ3Jhdml4Y2xvdWQuRGF0YUJsb2JLZXlSA2tleQ==');

@$core.Deprecated('Use getDataBlobResponseDescriptor instead')
const GetDataBlobResponse$json = {
  '1': 'GetDataBlobResponse',
  '2': [
    {'1': 'request_id', '3': 1, '4': 1, '5': 13, '8': {}, '10': 'requestId'},
    {'1': 'blob', '3': 2, '4': 1, '5': 11, '6': '.gravixcloud.DataBlob', '10': 'blob'},
  ],
};

/// Descriptor for `GetDataBlobResponse`. Decode as a `google.protobuf.DescriptorProto`.
final $typed_data.Uint8List getDataBlobResponseDescriptor =
    $convert.base64Decode('ChNHZXREYXRhQmxvYlJlc3BvbnNlEisKCnJlcXVlc3RfaWQYASABKA1CDLpQCXJlcXVlc3RJRF'
        'IJcmVxdWVzdElkEikKBGJsb2IYAiABKAsyFS5ncmF2aXhjbG91ZC5EYXRhQmxvYlIEYmxvYg==');

@$core.Deprecated('Use updateTrackSettingsDescriptor instead')
const UpdateTrackSettings$json = {
  '1': 'UpdateTrackSettings',
  '2': [
    {'1': 'track_sids', '3': 1, '4': 3, '5': 9, '10': 'trackSids'},
    {'1': 'disabled', '3': 3, '4': 1, '5': 8, '10': 'disabled'},
    {'1': 'quality', '3': 4, '4': 1, '5': 14, '6': '.gravixcloud.VideoQuality', '10': 'quality'},
    {'1': 'width', '3': 5, '4': 1, '5': 13, '10': 'width'},
    {'1': 'height', '3': 6, '4': 1, '5': 13, '10': 'height'},
    {'1': 'fps', '3': 7, '4': 1, '5': 13, '10': 'fps'},
    {'1': 'priority', '3': 8, '4': 1, '5': 13, '10': 'priority'},
  ],
};

/// Descriptor for `UpdateTrackSettings`. Decode as a `google.protobuf.DescriptorProto`.
final $typed_data.Uint8List updateTrackSettingsDescriptor =
    $convert.base64Decode('ChNVcGRhdGVUcmFja1NldHRpbmdzEh0KCnRyYWNrX3NpZHMYASADKAlSCXRyYWNrU2lkcxIaCg'
        'hkaXNhYmxlZBgDIAEoCFIIZGlzYWJsZWQSMwoHcXVhbGl0eRgEIAEoDjIZLmdyYXZpeGNsb3Vk'
        'LlZpZGVvUXVhbGl0eVIHcXVhbGl0eRIUCgV3aWR0aBgFIAEoDVIFd2lkdGgSFgoGaGVpZ2h0GA'
        'YgASgNUgZoZWlnaHQSEAoDZnBzGAcgASgNUgNmcHMSGgoIcHJpb3JpdHkYCCABKA1SCHByaW9y'
        'aXR5');

@$core.Deprecated('Use updateLocalAudioTrackDescriptor instead')
const UpdateLocalAudioTrack$json = {
  '1': 'UpdateLocalAudioTrack',
  '2': [
    {'1': 'track_sid', '3': 1, '4': 1, '5': 9, '10': 'trackSid'},
    {'1': 'features', '3': 2, '4': 3, '5': 14, '6': '.gravixcloud.AudioTrackFeature', '10': 'features'},
  ],
};

/// Descriptor for `UpdateLocalAudioTrack`. Decode as a `google.protobuf.DescriptorProto`.
final $typed_data.Uint8List updateLocalAudioTrackDescriptor =
    $convert.base64Decode('ChVVcGRhdGVMb2NhbEF1ZGlvVHJhY2sSGwoJdHJhY2tfc2lkGAEgASgJUgh0cmFja1NpZBI6Cg'
        'hmZWF0dXJlcxgCIAMoDjIeLmdyYXZpeGNsb3VkLkF1ZGlvVHJhY2tGZWF0dXJlUghmZWF0dXJl'
        'cw==');

@$core.Deprecated('Use updateLocalVideoTrackDescriptor instead')
const UpdateLocalVideoTrack$json = {
  '1': 'UpdateLocalVideoTrack',
  '2': [
    {'1': 'track_sid', '3': 1, '4': 1, '5': 9, '10': 'trackSid'},
    {'1': 'width', '3': 2, '4': 1, '5': 13, '10': 'width'},
    {'1': 'height', '3': 3, '4': 1, '5': 13, '10': 'height'},
  ],
};

/// Descriptor for `UpdateLocalVideoTrack`. Decode as a `google.protobuf.DescriptorProto`.
final $typed_data.Uint8List updateLocalVideoTrackDescriptor =
    $convert.base64Decode('ChVVcGRhdGVMb2NhbFZpZGVvVHJhY2sSGwoJdHJhY2tfc2lkGAEgASgJUgh0cmFja1NpZBIUCg'
        'V3aWR0aBgCIAEoDVIFd2lkdGgSFgoGaGVpZ2h0GAMgASgNUgZoZWlnaHQ=');

@$core.Deprecated('Use leaveRequestDescriptor instead')
const LeaveRequest$json = {
  '1': 'LeaveRequest',
  '2': [
    {'1': 'can_reconnect', '3': 1, '4': 1, '5': 8, '10': 'canReconnect'},
    {'1': 'reason', '3': 2, '4': 1, '5': 14, '6': '.gravixcloud.DisconnectReason', '10': 'reason'},
    {'1': 'action', '3': 3, '4': 1, '5': 14, '6': '.gravixcloud.LeaveRequest.Action', '10': 'action'},
    {'1': 'regions', '3': 4, '4': 1, '5': 11, '6': '.gravixcloud.RegionSettings', '10': 'regions'},
  ],
  '4': [LeaveRequest_Action$json],
};

@$core.Deprecated('Use leaveRequestDescriptor instead')
const LeaveRequest_Action$json = {
  '1': 'Action',
  '2': [
    {'1': 'DISCONNECT', '2': 0},
    {'1': 'RESUME', '2': 1},
    {'1': 'RECONNECT', '2': 2},
  ],
};

/// Descriptor for `LeaveRequest`. Decode as a `google.protobuf.DescriptorProto`.
final $typed_data.Uint8List leaveRequestDescriptor =
    $convert.base64Decode('CgxMZWF2ZVJlcXVlc3QSIwoNY2FuX3JlY29ubmVjdBgBIAEoCFIMY2FuUmVjb25uZWN0EjUKBn'
        'JlYXNvbhgCIAEoDjIdLmdyYXZpeGNsb3VkLkRpc2Nvbm5lY3RSZWFzb25SBnJlYXNvbhI4CgZh'
        'Y3Rpb24YAyABKA4yIC5ncmF2aXhjbG91ZC5MZWF2ZVJlcXVlc3QuQWN0aW9uUgZhY3Rpb24SNQ'
        'oHcmVnaW9ucxgEIAEoCzIbLmdyYXZpeGNsb3VkLlJlZ2lvblNldHRpbmdzUgdyZWdpb25zIjMK'
        'BkFjdGlvbhIOCgpESVNDT05ORUNUEAASCgoGUkVTVU1FEAESDQoJUkVDT05ORUNUEAI=');

@$core.Deprecated('Use updateVideoLayersDescriptor instead')
const UpdateVideoLayers$json = {
  '1': 'UpdateVideoLayers',
  '2': [
    {'1': 'track_sid', '3': 1, '4': 1, '5': 9, '10': 'trackSid'},
    {'1': 'layers', '3': 2, '4': 3, '5': 11, '6': '.gravixcloud.VideoLayer', '10': 'layers'},
  ],
  '7': {'3': true},
};

/// Descriptor for `UpdateVideoLayers`. Decode as a `google.protobuf.DescriptorProto`.
final $typed_data.Uint8List updateVideoLayersDescriptor =
    $convert.base64Decode('ChFVcGRhdGVWaWRlb0xheWVycxIbCgl0cmFja19zaWQYASABKAlSCHRyYWNrU2lkEi8KBmxheW'
        'VycxgCIAMoCzIXLmdyYXZpeGNsb3VkLlZpZGVvTGF5ZXJSBmxheWVyczoCGAE=');

@$core.Deprecated('Use updateParticipantMetadataDescriptor instead')
const UpdateParticipantMetadata$json = {
  '1': 'UpdateParticipantMetadata',
  '2': [
    {'1': 'metadata', '3': 1, '4': 1, '5': 9, '8': {}, '10': 'metadata'},
    {'1': 'name', '3': 2, '4': 1, '5': 9, '8': {}, '10': 'name'},
    {
      '1': 'attributes',
      '3': 3,
      '4': 3,
      '5': 11,
      '6': '.gravixcloud.UpdateParticipantMetadata.AttributesEntry',
      '8': {},
      '10': 'attributes'
    },
    {'1': 'request_id', '3': 4, '4': 1, '5': 13, '8': {}, '10': 'requestId'},
  ],
  '3': [UpdateParticipantMetadata_AttributesEntry$json],
};

@$core.Deprecated('Use updateParticipantMetadataDescriptor instead')
const UpdateParticipantMetadata_AttributesEntry$json = {
  '1': 'AttributesEntry',
  '2': [
    {'1': 'key', '3': 1, '4': 1, '5': 9, '10': 'key'},
    {'1': 'value', '3': 2, '4': 1, '5': 9, '10': 'value'},
  ],
  '7': {'7': true},
};

/// Descriptor for `UpdateParticipantMetadata`. Decode as a `google.protobuf.DescriptorProto`.
final $typed_data.Uint8List updateParticipantMetadataDescriptor =
    $convert.base64Decode('ChlVcGRhdGVQYXJ0aWNpcGFudE1ldGFkYXRhEkAKCG1ldGFkYXRhGAEgASgJQiSyUB48cmVkYW'
        'N0ZWQgKHt7IC5TaXplIH19IGJ5dGVzKT7AUAFSCG1ldGFkYXRhEjgKBG5hbWUYAiABKAlCJLJQ'
        'HjxyZWRhY3RlZCAoe3sgLlNpemUgfX0gYnl0ZXMpPsBQAVIEbmFtZRJ8CgphdHRyaWJ1dGVzGA'
        'MgAygLMjYuZ3Jhdml4Y2xvdWQuVXBkYXRlUGFydGljaXBhbnRNZXRhZGF0YS5BdHRyaWJ1dGVz'
        'RW50cnlCJLJQHjxyZWRhY3RlZCAoe3sgLlNpemUgfX0gYnl0ZXMpPsBQAVIKYXR0cmlidXRlcx'
        'IrCgpyZXF1ZXN0X2lkGAQgASgNQgy6UAlyZXF1ZXN0SURSCXJlcXVlc3RJZBo9Cg9BdHRyaWJ1'
        'dGVzRW50cnkSEAoDa2V5GAEgASgJUgNrZXkSFAoFdmFsdWUYAiABKAlSBXZhbHVlOgI4AQ==');

@$core.Deprecated('Use iCEServerDescriptor instead')
const ICEServer$json = {
  '1': 'ICEServer',
  '2': [
    {'1': 'urls', '3': 1, '4': 3, '5': 9, '10': 'urls'},
    {'1': 'username', '3': 2, '4': 1, '5': 9, '8': {}, '10': 'username'},
    {'1': 'credential', '3': 3, '4': 1, '5': 9, '8': {}, '10': 'credential'},
  ],
};

/// Descriptor for `ICEServer`. Decode as a `google.protobuf.DescriptorProto`.
final $typed_data.Uint8List iCEServerDescriptor =
    $convert.base64Decode('CglJQ0VTZXJ2ZXISEgoEdXJscxgBIAMoCVIEdXJscxIfCgh1c2VybmFtZRgCIAEoCUIDwFABUg'
        'h1c2VybmFtZRIjCgpjcmVkZW50aWFsGAMgASgJQgPAUAJSCmNyZWRlbnRpYWw=');

@$core.Deprecated('Use speakersChangedDescriptor instead')
const SpeakersChanged$json = {
  '1': 'SpeakersChanged',
  '2': [
    {'1': 'speakers', '3': 1, '4': 3, '5': 11, '6': '.gravixcloud.SpeakerInfo', '10': 'speakers'},
  ],
};

/// Descriptor for `SpeakersChanged`. Decode as a `google.protobuf.DescriptorProto`.
final $typed_data.Uint8List speakersChangedDescriptor =
    $convert.base64Decode('Cg9TcGVha2Vyc0NoYW5nZWQSNAoIc3BlYWtlcnMYASADKAsyGC5ncmF2aXhjbG91ZC5TcGVha2'
        'VySW5mb1IIc3BlYWtlcnM=');

@$core.Deprecated('Use roomUpdateDescriptor instead')
const RoomUpdate$json = {
  '1': 'RoomUpdate',
  '2': [
    {'1': 'room', '3': 1, '4': 1, '5': 11, '6': '.gravixcloud.Room', '10': 'room'},
  ],
};

/// Descriptor for `RoomUpdate`. Decode as a `google.protobuf.DescriptorProto`.
final $typed_data.Uint8List roomUpdateDescriptor =
    $convert.base64Decode('CgpSb29tVXBkYXRlEiUKBHJvb20YASABKAsyES5ncmF2aXhjbG91ZC5Sb29tUgRyb29t');

@$core.Deprecated('Use connectionQualityInfoDescriptor instead')
const ConnectionQualityInfo$json = {
  '1': 'ConnectionQualityInfo',
  '2': [
    {'1': 'participant_sid', '3': 1, '4': 1, '5': 9, '10': 'participantSid'},
    {'1': 'quality', '3': 2, '4': 1, '5': 14, '6': '.gravixcloud.ConnectionQuality', '10': 'quality'},
    {'1': 'score', '3': 3, '4': 1, '5': 2, '10': 'score'},
  ],
};

/// Descriptor for `ConnectionQualityInfo`. Decode as a `google.protobuf.DescriptorProto`.
final $typed_data.Uint8List connectionQualityInfoDescriptor =
    $convert.base64Decode('ChVDb25uZWN0aW9uUXVhbGl0eUluZm8SJwoPcGFydGljaXBhbnRfc2lkGAEgASgJUg5wYXJ0aW'
        'NpcGFudFNpZBI4CgdxdWFsaXR5GAIgASgOMh4uZ3Jhdml4Y2xvdWQuQ29ubmVjdGlvblF1YWxp'
        'dHlSB3F1YWxpdHkSFAoFc2NvcmUYAyABKAJSBXNjb3Jl');

@$core.Deprecated('Use connectionQualityUpdateDescriptor instead')
const ConnectionQualityUpdate$json = {
  '1': 'ConnectionQualityUpdate',
  '2': [
    {'1': 'updates', '3': 1, '4': 3, '5': 11, '6': '.gravixcloud.ConnectionQualityInfo', '10': 'updates'},
  ],
};

/// Descriptor for `ConnectionQualityUpdate`. Decode as a `google.protobuf.DescriptorProto`.
final $typed_data.Uint8List connectionQualityUpdateDescriptor =
    $convert.base64Decode('ChdDb25uZWN0aW9uUXVhbGl0eVVwZGF0ZRI8Cgd1cGRhdGVzGAEgAygLMiIuZ3Jhdml4Y2xvdW'
        'QuQ29ubmVjdGlvblF1YWxpdHlJbmZvUgd1cGRhdGVz');

@$core.Deprecated('Use streamStateInfoDescriptor instead')
const StreamStateInfo$json = {
  '1': 'StreamStateInfo',
  '2': [
    {'1': 'participant_sid', '3': 1, '4': 1, '5': 9, '10': 'participantSid'},
    {'1': 'track_sid', '3': 2, '4': 1, '5': 9, '10': 'trackSid'},
    {'1': 'state', '3': 3, '4': 1, '5': 14, '6': '.gravixcloud.StreamState', '10': 'state'},
  ],
};

/// Descriptor for `StreamStateInfo`. Decode as a `google.protobuf.DescriptorProto`.
final $typed_data.Uint8List streamStateInfoDescriptor =
    $convert.base64Decode('Cg9TdHJlYW1TdGF0ZUluZm8SJwoPcGFydGljaXBhbnRfc2lkGAEgASgJUg5wYXJ0aWNpcGFudF'
        'NpZBIbCgl0cmFja19zaWQYAiABKAlSCHRyYWNrU2lkEi4KBXN0YXRlGAMgASgOMhguZ3Jhdml4'
        'Y2xvdWQuU3RyZWFtU3RhdGVSBXN0YXRl');

@$core.Deprecated('Use streamStateUpdateDescriptor instead')
const StreamStateUpdate$json = {
  '1': 'StreamStateUpdate',
  '2': [
    {'1': 'stream_states', '3': 1, '4': 3, '5': 11, '6': '.gravixcloud.StreamStateInfo', '10': 'streamStates'},
  ],
};

/// Descriptor for `StreamStateUpdate`. Decode as a `google.protobuf.DescriptorProto`.
final $typed_data.Uint8List streamStateUpdateDescriptor =
    $convert.base64Decode('ChFTdHJlYW1TdGF0ZVVwZGF0ZRJBCg1zdHJlYW1fc3RhdGVzGAEgAygLMhwuZ3Jhdml4Y2xvdW'
        'QuU3RyZWFtU3RhdGVJbmZvUgxzdHJlYW1TdGF0ZXM=');

@$core.Deprecated('Use subscribedQualityDescriptor instead')
const SubscribedQuality$json = {
  '1': 'SubscribedQuality',
  '2': [
    {'1': 'quality', '3': 1, '4': 1, '5': 14, '6': '.gravixcloud.VideoQuality', '10': 'quality'},
    {'1': 'enabled', '3': 2, '4': 1, '5': 8, '10': 'enabled'},
  ],
};

/// Descriptor for `SubscribedQuality`. Decode as a `google.protobuf.DescriptorProto`.
final $typed_data.Uint8List subscribedQualityDescriptor =
    $convert.base64Decode('ChFTdWJzY3JpYmVkUXVhbGl0eRIzCgdxdWFsaXR5GAEgASgOMhkuZ3Jhdml4Y2xvdWQuVmlkZW'
        '9RdWFsaXR5UgdxdWFsaXR5EhgKB2VuYWJsZWQYAiABKAhSB2VuYWJsZWQ=');

@$core.Deprecated('Use subscribedCodecDescriptor instead')
const SubscribedCodec$json = {
  '1': 'SubscribedCodec',
  '2': [
    {'1': 'codec', '3': 1, '4': 1, '5': 9, '10': 'codec'},
    {'1': 'qualities', '3': 2, '4': 3, '5': 11, '6': '.gravixcloud.SubscribedQuality', '10': 'qualities'},
  ],
};

/// Descriptor for `SubscribedCodec`. Decode as a `google.protobuf.DescriptorProto`.
final $typed_data.Uint8List subscribedCodecDescriptor =
    $convert.base64Decode('Cg9TdWJzY3JpYmVkQ29kZWMSFAoFY29kZWMYASABKAlSBWNvZGVjEjwKCXF1YWxpdGllcxgCIA'
        'MoCzIeLmdyYXZpeGNsb3VkLlN1YnNjcmliZWRRdWFsaXR5UglxdWFsaXRpZXM=');

@$core.Deprecated('Use subscribedQualityUpdateDescriptor instead')
const SubscribedQualityUpdate$json = {
  '1': 'SubscribedQualityUpdate',
  '2': [
    {'1': 'track_sid', '3': 1, '4': 1, '5': 9, '10': 'trackSid'},
    {
      '1': 'subscribed_qualities',
      '3': 2,
      '4': 3,
      '5': 11,
      '6': '.gravixcloud.SubscribedQuality',
      '8': {'3': true},
      '10': 'subscribedQualities',
    },
    {'1': 'subscribed_codecs', '3': 3, '4': 3, '5': 11, '6': '.gravixcloud.SubscribedCodec', '10': 'subscribedCodecs'},
  ],
};

/// Descriptor for `SubscribedQualityUpdate`. Decode as a `google.protobuf.DescriptorProto`.
final $typed_data.Uint8List subscribedQualityUpdateDescriptor =
    $convert.base64Decode('ChdTdWJzY3JpYmVkUXVhbGl0eVVwZGF0ZRIbCgl0cmFja19zaWQYASABKAlSCHRyYWNrU2lkEl'
        'UKFHN1YnNjcmliZWRfcXVhbGl0aWVzGAIgAygLMh4uZ3Jhdml4Y2xvdWQuU3Vic2NyaWJlZFF1'
        'YWxpdHlCAhgBUhNzdWJzY3JpYmVkUXVhbGl0aWVzEkkKEXN1YnNjcmliZWRfY29kZWNzGAMgAy'
        'gLMhwuZ3Jhdml4Y2xvdWQuU3Vic2NyaWJlZENvZGVjUhBzdWJzY3JpYmVkQ29kZWNz');

@$core.Deprecated('Use subscribedAudioCodecUpdateDescriptor instead')
const SubscribedAudioCodecUpdate$json = {
  '1': 'SubscribedAudioCodecUpdate',
  '2': [
    {'1': 'track_sid', '3': 1, '4': 1, '5': 9, '10': 'trackSid'},
    {
      '1': 'subscribed_audio_codecs',
      '3': 2,
      '4': 3,
      '5': 11,
      '6': '.gravixcloud.SubscribedAudioCodec',
      '10': 'subscribedAudioCodecs'
    },
  ],
};

/// Descriptor for `SubscribedAudioCodecUpdate`. Decode as a `google.protobuf.DescriptorProto`.
final $typed_data.Uint8List subscribedAudioCodecUpdateDescriptor =
    $convert.base64Decode('ChpTdWJzY3JpYmVkQXVkaW9Db2RlY1VwZGF0ZRIbCgl0cmFja19zaWQYASABKAlSCHRyYWNrU2'
        'lkElkKF3N1YnNjcmliZWRfYXVkaW9fY29kZWNzGAIgAygLMiEuZ3Jhdml4Y2xvdWQuU3Vic2Ny'
        'aWJlZEF1ZGlvQ29kZWNSFXN1YnNjcmliZWRBdWRpb0NvZGVjcw==');

@$core.Deprecated('Use trackPermissionDescriptor instead')
const TrackPermission$json = {
  '1': 'TrackPermission',
  '2': [
    {'1': 'participant_sid', '3': 1, '4': 1, '5': 9, '10': 'participantSid'},
    {'1': 'all_tracks', '3': 2, '4': 1, '5': 8, '10': 'allTracks'},
    {'1': 'track_sids', '3': 3, '4': 3, '5': 9, '10': 'trackSids'},
    {'1': 'participant_identity', '3': 4, '4': 1, '5': 9, '10': 'participantIdentity'},
  ],
};

/// Descriptor for `TrackPermission`. Decode as a `google.protobuf.DescriptorProto`.
final $typed_data.Uint8List trackPermissionDescriptor =
    $convert.base64Decode('Cg9UcmFja1Blcm1pc3Npb24SJwoPcGFydGljaXBhbnRfc2lkGAEgASgJUg5wYXJ0aWNpcGFudF'
        'NpZBIdCgphbGxfdHJhY2tzGAIgASgIUglhbGxUcmFja3MSHQoKdHJhY2tfc2lkcxgDIAMoCVIJ'
        'dHJhY2tTaWRzEjEKFHBhcnRpY2lwYW50X2lkZW50aXR5GAQgASgJUhNwYXJ0aWNpcGFudElkZW'
        '50aXR5');

@$core.Deprecated('Use subscriptionPermissionDescriptor instead')
const SubscriptionPermission$json = {
  '1': 'SubscriptionPermission',
  '2': [
    {'1': 'all_participants', '3': 1, '4': 1, '5': 8, '10': 'allParticipants'},
    {'1': 'track_permissions', '3': 2, '4': 3, '5': 11, '6': '.gravixcloud.TrackPermission', '10': 'trackPermissions'},
  ],
};

/// Descriptor for `SubscriptionPermission`. Decode as a `google.protobuf.DescriptorProto`.
final $typed_data.Uint8List subscriptionPermissionDescriptor =
    $convert.base64Decode('ChZTdWJzY3JpcHRpb25QZXJtaXNzaW9uEikKEGFsbF9wYXJ0aWNpcGFudHMYASABKAhSD2FsbF'
        'BhcnRpY2lwYW50cxJJChF0cmFja19wZXJtaXNzaW9ucxgCIAMoCzIcLmdyYXZpeGNsb3VkLlRy'
        'YWNrUGVybWlzc2lvblIQdHJhY2tQZXJtaXNzaW9ucw==');

@$core.Deprecated('Use subscriptionPermissionUpdateDescriptor instead')
const SubscriptionPermissionUpdate$json = {
  '1': 'SubscriptionPermissionUpdate',
  '2': [
    {'1': 'participant_sid', '3': 1, '4': 1, '5': 9, '10': 'participantSid'},
    {'1': 'track_sid', '3': 2, '4': 1, '5': 9, '10': 'trackSid'},
    {'1': 'allowed', '3': 3, '4': 1, '5': 8, '10': 'allowed'},
  ],
};

/// Descriptor for `SubscriptionPermissionUpdate`. Decode as a `google.protobuf.DescriptorProto`.
final $typed_data.Uint8List subscriptionPermissionUpdateDescriptor =
    $convert.base64Decode('ChxTdWJzY3JpcHRpb25QZXJtaXNzaW9uVXBkYXRlEicKD3BhcnRpY2lwYW50X3NpZBgBIAEoCV'
        'IOcGFydGljaXBhbnRTaWQSGwoJdHJhY2tfc2lkGAIgASgJUgh0cmFja1NpZBIYCgdhbGxvd2Vk'
        'GAMgASgIUgdhbGxvd2Vk');

@$core.Deprecated('Use roomMovedResponseDescriptor instead')
const RoomMovedResponse$json = {
  '1': 'RoomMovedResponse',
  '2': [
    {'1': 'room', '3': 1, '4': 1, '5': 11, '6': '.gravixcloud.Room', '10': 'room'},
    {'1': 'token', '3': 2, '4': 1, '5': 9, '10': 'token'},
    {'1': 'participant', '3': 3, '4': 1, '5': 11, '6': '.gravixcloud.ParticipantInfo', '10': 'participant'},
    {
      '1': 'other_participants',
      '3': 4,
      '4': 3,
      '5': 11,
      '6': '.gravixcloud.ParticipantInfo',
      '10': 'otherParticipants'
    },
  ],
};

/// Descriptor for `RoomMovedResponse`. Decode as a `google.protobuf.DescriptorProto`.
final $typed_data.Uint8List roomMovedResponseDescriptor =
    $convert.base64Decode('ChFSb29tTW92ZWRSZXNwb25zZRIlCgRyb29tGAEgASgLMhEuZ3Jhdml4Y2xvdWQuUm9vbVIEcm'
        '9vbRIUCgV0b2tlbhgCIAEoCVIFdG9rZW4SPgoLcGFydGljaXBhbnQYAyABKAsyHC5ncmF2aXhj'
        'bG91ZC5QYXJ0aWNpcGFudEluZm9SC3BhcnRpY2lwYW50EksKEm90aGVyX3BhcnRpY2lwYW50cx'
        'gEIAMoCzIcLmdyYXZpeGNsb3VkLlBhcnRpY2lwYW50SW5mb1IRb3RoZXJQYXJ0aWNpcGFudHM=');

@$core.Deprecated('Use syncStateDescriptor instead')
const SyncState$json = {
  '1': 'SyncState',
  '2': [
    {'1': 'answer', '3': 1, '4': 1, '5': 11, '6': '.gravixcloud.SessionDescription', '10': 'answer'},
    {'1': 'subscription', '3': 2, '4': 1, '5': 11, '6': '.gravixcloud.UpdateSubscription', '10': 'subscription'},
    {'1': 'publish_tracks', '3': 3, '4': 3, '5': 11, '6': '.gravixcloud.TrackPublishedResponse', '10': 'publishTracks'},
    {'1': 'data_channels', '3': 4, '4': 3, '5': 11, '6': '.gravixcloud.DataChannelInfo', '10': 'dataChannels'},
    {'1': 'offer', '3': 5, '4': 1, '5': 11, '6': '.gravixcloud.SessionDescription', '10': 'offer'},
    {'1': 'track_sids_disabled', '3': 6, '4': 3, '5': 9, '10': 'trackSidsDisabled'},
    {
      '1': 'datachannel_receive_states',
      '3': 7,
      '4': 3,
      '5': 11,
      '6': '.gravixcloud.DataChannelReceiveState',
      '10': 'datachannelReceiveStates'
    },
    {
      '1': 'publish_data_tracks',
      '3': 8,
      '4': 3,
      '5': 11,
      '6': '.gravixcloud.PublishDataTrackResponse',
      '10': 'publishDataTracks'
    },
  ],
};

/// Descriptor for `SyncState`. Decode as a `google.protobuf.DescriptorProto`.
final $typed_data.Uint8List syncStateDescriptor =
    $convert.base64Decode('CglTeW5jU3RhdGUSNwoGYW5zd2VyGAEgASgLMh8uZ3Jhdml4Y2xvdWQuU2Vzc2lvbkRlc2NyaX'
        'B0aW9uUgZhbnN3ZXISQwoMc3Vic2NyaXB0aW9uGAIgASgLMh8uZ3Jhdml4Y2xvdWQuVXBkYXRl'
        'U3Vic2NyaXB0aW9uUgxzdWJzY3JpcHRpb24SSgoOcHVibGlzaF90cmFja3MYAyADKAsyIy5ncm'
        'F2aXhjbG91ZC5UcmFja1B1Ymxpc2hlZFJlc3BvbnNlUg1wdWJsaXNoVHJhY2tzEkEKDWRhdGFf'
        'Y2hhbm5lbHMYBCADKAsyHC5ncmF2aXhjbG91ZC5EYXRhQ2hhbm5lbEluZm9SDGRhdGFDaGFubm'
        'VscxI1CgVvZmZlchgFIAEoCzIfLmdyYXZpeGNsb3VkLlNlc3Npb25EZXNjcmlwdGlvblIFb2Zm'
        'ZXISLgoTdHJhY2tfc2lkc19kaXNhYmxlZBgGIAMoCVIRdHJhY2tTaWRzRGlzYWJsZWQSYgoaZG'
        'F0YWNoYW5uZWxfcmVjZWl2ZV9zdGF0ZXMYByADKAsyJC5ncmF2aXhjbG91ZC5EYXRhQ2hhbm5l'
        'bFJlY2VpdmVTdGF0ZVIYZGF0YWNoYW5uZWxSZWNlaXZlU3RhdGVzElUKE3B1Ymxpc2hfZGF0YV'
        '90cmFja3MYCCADKAsyJS5ncmF2aXhjbG91ZC5QdWJsaXNoRGF0YVRyYWNrUmVzcG9uc2VSEXB1'
        'Ymxpc2hEYXRhVHJhY2tz');

@$core.Deprecated('Use dataChannelReceiveStateDescriptor instead')
const DataChannelReceiveState$json = {
  '1': 'DataChannelReceiveState',
  '2': [
    {'1': 'publisher_sid', '3': 1, '4': 1, '5': 9, '10': 'publisherSid'},
    {'1': 'last_seq', '3': 2, '4': 1, '5': 13, '10': 'lastSeq'},
  ],
};

/// Descriptor for `DataChannelReceiveState`. Decode as a `google.protobuf.DescriptorProto`.
final $typed_data.Uint8List dataChannelReceiveStateDescriptor =
    $convert.base64Decode('ChdEYXRhQ2hhbm5lbFJlY2VpdmVTdGF0ZRIjCg1wdWJsaXNoZXJfc2lkGAEgASgJUgxwdWJsaX'
        'NoZXJTaWQSGQoIbGFzdF9zZXEYAiABKA1SB2xhc3RTZXE=');

@$core.Deprecated('Use dataChannelInfoDescriptor instead')
const DataChannelInfo$json = {
  '1': 'DataChannelInfo',
  '2': [
    {'1': 'label', '3': 1, '4': 1, '5': 9, '10': 'label'},
    {'1': 'id', '3': 2, '4': 1, '5': 13, '10': 'id'},
    {'1': 'target', '3': 3, '4': 1, '5': 14, '6': '.gravixcloud.SignalTarget', '10': 'target'},
  ],
};

/// Descriptor for `DataChannelInfo`. Decode as a `google.protobuf.DescriptorProto`.
final $typed_data.Uint8List dataChannelInfoDescriptor =
    $convert.base64Decode('Cg9EYXRhQ2hhbm5lbEluZm8SFAoFbGFiZWwYASABKAlSBWxhYmVsEg4KAmlkGAIgASgNUgJpZB'
        'IxCgZ0YXJnZXQYAyABKA4yGS5ncmF2aXhjbG91ZC5TaWduYWxUYXJnZXRSBnRhcmdldA==');

@$core.Deprecated('Use simulateScenarioDescriptor instead')
const SimulateScenario$json = {
  '1': 'SimulateScenario',
  '2': [
    {'1': 'speaker_update', '3': 1, '4': 1, '5': 5, '9': 0, '10': 'speakerUpdate'},
    {'1': 'node_failure', '3': 2, '4': 1, '5': 8, '9': 0, '10': 'nodeFailure'},
    {'1': 'migration', '3': 3, '4': 1, '5': 8, '9': 0, '10': 'migration'},
    {'1': 'server_leave', '3': 4, '4': 1, '5': 8, '9': 0, '10': 'serverLeave'},
    {
      '1': 'switch_candidate_protocol',
      '3': 5,
      '4': 1,
      '5': 14,
      '6': '.gravixcloud.CandidateProtocol',
      '9': 0,
      '10': 'switchCandidateProtocol'
    },
    {'1': 'subscriber_bandwidth', '3': 6, '4': 1, '5': 3, '9': 0, '10': 'subscriberBandwidth'},
    {'1': 'disconnect_signal_on_resume', '3': 7, '4': 1, '5': 8, '9': 0, '10': 'disconnectSignalOnResume'},
    {
      '1': 'disconnect_signal_on_resume_no_messages',
      '3': 8,
      '4': 1,
      '5': 8,
      '9': 0,
      '10': 'disconnectSignalOnResumeNoMessages'
    },
    {'1': 'leave_request_full_reconnect', '3': 9, '4': 1, '5': 8, '9': 0, '10': 'leaveRequestFullReconnect'},
  ],
  '8': [
    {'1': 'scenario'},
  ],
};

/// Descriptor for `SimulateScenario`. Decode as a `google.protobuf.DescriptorProto`.
final $typed_data.Uint8List simulateScenarioDescriptor =
    $convert.base64Decode('ChBTaW11bGF0ZVNjZW5hcmlvEicKDnNwZWFrZXJfdXBkYXRlGAEgASgFSABSDXNwZWFrZXJVcG'
        'RhdGUSIwoMbm9kZV9mYWlsdXJlGAIgASgISABSC25vZGVGYWlsdXJlEh4KCW1pZ3JhdGlvbhgD'
        'IAEoCEgAUgltaWdyYXRpb24SIwoMc2VydmVyX2xlYXZlGAQgASgISABSC3NlcnZlckxlYXZlEl'
        'wKGXN3aXRjaF9jYW5kaWRhdGVfcHJvdG9jb2wYBSABKA4yHi5ncmF2aXhjbG91ZC5DYW5kaWRh'
        'dGVQcm90b2NvbEgAUhdzd2l0Y2hDYW5kaWRhdGVQcm90b2NvbBIzChRzdWJzY3JpYmVyX2Jhbm'
        'R3aWR0aBgGIAEoA0gAUhNzdWJzY3JpYmVyQmFuZHdpZHRoEj8KG2Rpc2Nvbm5lY3Rfc2lnbmFs'
        'X29uX3Jlc3VtZRgHIAEoCEgAUhhkaXNjb25uZWN0U2lnbmFsT25SZXN1bWUSVQonZGlzY29ubm'
        'VjdF9zaWduYWxfb25fcmVzdW1lX25vX21lc3NhZ2VzGAggASgISABSImRpc2Nvbm5lY3RTaWdu'
        'YWxPblJlc3VtZU5vTWVzc2FnZXMSQQocbGVhdmVfcmVxdWVzdF9mdWxsX3JlY29ubmVjdBgJIA'
        'EoCEgAUhlsZWF2ZVJlcXVlc3RGdWxsUmVjb25uZWN0QgoKCHNjZW5hcmlv');

@$core.Deprecated('Use pingDescriptor instead')
const Ping$json = {
  '1': 'Ping',
  '2': [
    {'1': 'timestamp', '3': 1, '4': 1, '5': 3, '10': 'timestamp'},
    {'1': 'rtt', '3': 2, '4': 1, '5': 3, '10': 'rtt'},
  ],
};

/// Descriptor for `Ping`. Decode as a `google.protobuf.DescriptorProto`.
final $typed_data.Uint8List pingDescriptor =
    $convert.base64Decode('CgRQaW5nEhwKCXRpbWVzdGFtcBgBIAEoA1IJdGltZXN0YW1wEhAKA3J0dBgCIAEoA1IDcnR0');

@$core.Deprecated('Use pongDescriptor instead')
const Pong$json = {
  '1': 'Pong',
  '2': [
    {'1': 'last_ping_timestamp', '3': 1, '4': 1, '5': 3, '10': 'lastPingTimestamp'},
    {'1': 'timestamp', '3': 2, '4': 1, '5': 3, '10': 'timestamp'},
  ],
};

/// Descriptor for `Pong`. Decode as a `google.protobuf.DescriptorProto`.
final $typed_data.Uint8List pongDescriptor =
    $convert.base64Decode('CgRQb25nEi4KE2xhc3RfcGluZ190aW1lc3RhbXAYASABKANSEWxhc3RQaW5nVGltZXN0YW1wEh'
        'wKCXRpbWVzdGFtcBgCIAEoA1IJdGltZXN0YW1w');

@$core.Deprecated('Use regionSettingsDescriptor instead')
const RegionSettings$json = {
  '1': 'RegionSettings',
  '2': [
    {'1': 'regions', '3': 1, '4': 3, '5': 11, '6': '.gravixcloud.RegionInfo', '10': 'regions'},
  ],
};

/// Descriptor for `RegionSettings`. Decode as a `google.protobuf.DescriptorProto`.
final $typed_data.Uint8List regionSettingsDescriptor =
    $convert.base64Decode('Cg5SZWdpb25TZXR0aW5ncxIxCgdyZWdpb25zGAEgAygLMhcuZ3Jhdml4Y2xvdWQuUmVnaW9uSW'
        '5mb1IHcmVnaW9ucw==');

@$core.Deprecated('Use regionInfoDescriptor instead')
const RegionInfo$json = {
  '1': 'RegionInfo',
  '2': [
    {'1': 'region', '3': 1, '4': 1, '5': 9, '10': 'region'},
    {'1': 'url', '3': 2, '4': 1, '5': 9, '10': 'url'},
    {'1': 'distance', '3': 3, '4': 1, '5': 3, '10': 'distance'},
  ],
};

/// Descriptor for `RegionInfo`. Decode as a `google.protobuf.DescriptorProto`.
final $typed_data.Uint8List regionInfoDescriptor =
    $convert.base64Decode('CgpSZWdpb25JbmZvEhYKBnJlZ2lvbhgBIAEoCVIGcmVnaW9uEhAKA3VybBgCIAEoCVIDdXJsEh'
        'oKCGRpc3RhbmNlGAMgASgDUghkaXN0YW5jZQ==');

@$core.Deprecated('Use subscriptionResponseDescriptor instead')
const SubscriptionResponse$json = {
  '1': 'SubscriptionResponse',
  '2': [
    {'1': 'track_sid', '3': 1, '4': 1, '5': 9, '10': 'trackSid'},
    {'1': 'err', '3': 2, '4': 1, '5': 14, '6': '.gravixcloud.SubscriptionError', '10': 'err'},
  ],
};

/// Descriptor for `SubscriptionResponse`. Decode as a `google.protobuf.DescriptorProto`.
final $typed_data.Uint8List subscriptionResponseDescriptor =
    $convert.base64Decode('ChRTdWJzY3JpcHRpb25SZXNwb25zZRIbCgl0cmFja19zaWQYASABKAlSCHRyYWNrU2lkEjAKA2'
        'VychgCIAEoDjIeLmdyYXZpeGNsb3VkLlN1YnNjcmlwdGlvbkVycm9yUgNlcnI=');

@$core.Deprecated('Use requestResponseDescriptor instead')
const RequestResponse$json = {
  '1': 'RequestResponse',
  '2': [
    {'1': 'request_id', '3': 1, '4': 1, '5': 13, '8': {}, '10': 'requestId'},
    {'1': 'reason', '3': 2, '4': 1, '5': 14, '6': '.gravixcloud.RequestResponse.Reason', '10': 'reason'},
    {'1': 'message', '3': 3, '4': 1, '5': 9, '10': 'message'},
    {'1': 'trickle', '3': 4, '4': 1, '5': 11, '6': '.gravixcloud.TrickleRequest', '9': 0, '10': 'trickle'},
    {'1': 'add_track', '3': 5, '4': 1, '5': 11, '6': '.gravixcloud.AddTrackRequest', '9': 0, '10': 'addTrack'},
    {'1': 'mute', '3': 6, '4': 1, '5': 11, '6': '.gravixcloud.MuteTrackRequest', '9': 0, '10': 'mute'},
    {
      '1': 'update_metadata',
      '3': 7,
      '4': 1,
      '5': 11,
      '6': '.gravixcloud.UpdateParticipantMetadata',
      '9': 0,
      '10': 'updateMetadata'
    },
    {
      '1': 'update_audio_track',
      '3': 8,
      '4': 1,
      '5': 11,
      '6': '.gravixcloud.UpdateLocalAudioTrack',
      '9': 0,
      '10': 'updateAudioTrack'
    },
    {
      '1': 'update_video_track',
      '3': 9,
      '4': 1,
      '5': 11,
      '6': '.gravixcloud.UpdateLocalVideoTrack',
      '9': 0,
      '10': 'updateVideoTrack'
    },
    {
      '1': 'publish_data_track',
      '3': 10,
      '4': 1,
      '5': 11,
      '6': '.gravixcloud.PublishDataTrackRequest',
      '9': 0,
      '10': 'publishDataTrack'
    },
    {
      '1': 'unpublish_data_track',
      '3': 11,
      '4': 1,
      '5': 11,
      '6': '.gravixcloud.UnpublishDataTrackRequest',
      '9': 0,
      '10': 'unpublishDataTrack'
    },
  ],
  '4': [RequestResponse_Reason$json],
  '8': [
    {'1': 'request'},
  ],
};

@$core.Deprecated('Use requestResponseDescriptor instead')
const RequestResponse_Reason$json = {
  '1': 'Reason',
  '2': [
    {'1': 'OK', '2': 0},
    {'1': 'NOT_FOUND', '2': 1},
    {'1': 'NOT_ALLOWED', '2': 2},
    {'1': 'LIMIT_EXCEEDED', '2': 3},
    {'1': 'QUEUED', '2': 4},
    {'1': 'UNSUPPORTED_TYPE', '2': 5},
    {'1': 'UNCLASSIFIED_ERROR', '2': 6},
    {'1': 'INVALID_HANDLE', '2': 7},
    {'1': 'INVALID_NAME', '2': 8},
    {'1': 'DUPLICATE_HANDLE', '2': 9},
    {'1': 'DUPLICATE_NAME', '2': 10},
    {'1': 'INVALID_REQUEST', '2': 11},
  ],
};

/// Descriptor for `RequestResponse`. Decode as a `google.protobuf.DescriptorProto`.
final $typed_data.Uint8List requestResponseDescriptor =
    $convert.base64Decode('Cg9SZXF1ZXN0UmVzcG9uc2USKwoKcmVxdWVzdF9pZBgBIAEoDUIMulAJcmVxdWVzdElEUglyZX'
        'F1ZXN0SWQSOwoGcmVhc29uGAIgASgOMiMuZ3Jhdml4Y2xvdWQuUmVxdWVzdFJlc3BvbnNlLlJl'
        'YXNvblIGcmVhc29uEhgKB21lc3NhZ2UYAyABKAlSB21lc3NhZ2USNwoHdHJpY2tsZRgEIAEoCz'
        'IbLmdyYXZpeGNsb3VkLlRyaWNrbGVSZXF1ZXN0SABSB3RyaWNrbGUSOwoJYWRkX3RyYWNrGAUg'
        'ASgLMhwuZ3Jhdml4Y2xvdWQuQWRkVHJhY2tSZXF1ZXN0SABSCGFkZFRyYWNrEjMKBG11dGUYBi'
        'ABKAsyHS5ncmF2aXhjbG91ZC5NdXRlVHJhY2tSZXF1ZXN0SABSBG11dGUSUQoPdXBkYXRlX21l'
        'dGFkYXRhGAcgASgLMiYuZ3Jhdml4Y2xvdWQuVXBkYXRlUGFydGljaXBhbnRNZXRhZGF0YUgAUg'
        '51cGRhdGVNZXRhZGF0YRJSChJ1cGRhdGVfYXVkaW9fdHJhY2sYCCABKAsyIi5ncmF2aXhjbG91'
        'ZC5VcGRhdGVMb2NhbEF1ZGlvVHJhY2tIAFIQdXBkYXRlQXVkaW9UcmFjaxJSChJ1cGRhdGVfdm'
        'lkZW9fdHJhY2sYCSABKAsyIi5ncmF2aXhjbG91ZC5VcGRhdGVMb2NhbFZpZGVvVHJhY2tIAFIQ'
        'dXBkYXRlVmlkZW9UcmFjaxJUChJwdWJsaXNoX2RhdGFfdHJhY2sYCiABKAsyJC5ncmF2aXhjbG'
        '91ZC5QdWJsaXNoRGF0YVRyYWNrUmVxdWVzdEgAUhBwdWJsaXNoRGF0YVRyYWNrEloKFHVucHVi'
        'bGlzaF9kYXRhX3RyYWNrGAsgASgLMiYuZ3Jhdml4Y2xvdWQuVW5wdWJsaXNoRGF0YVRyYWNrUm'
        'VxdWVzdEgAUhJ1bnB1Ymxpc2hEYXRhVHJhY2si4wEKBlJlYXNvbhIGCgJPSxAAEg0KCU5PVF9G'
        'T1VORBABEg8KC05PVF9BTExPV0VEEAISEgoOTElNSVRfRVhDRUVERUQQAxIKCgZRVUVVRUQQBB'
        'IUChBVTlNVUFBPUlRFRF9UWVBFEAUSFgoSVU5DTEFTU0lGSUVEX0VSUk9SEAYSEgoOSU5WQUxJ'
        'RF9IQU5ETEUQBxIQCgxJTlZBTElEX05BTUUQCBIUChBEVVBMSUNBVEVfSEFORExFEAkSEgoORF'
        'VQTElDQVRFX05BTUUQChITCg9JTlZBTElEX1JFUVVFU1QQC0IJCgdyZXF1ZXN0');

@$core.Deprecated('Use trackSubscribedDescriptor instead')
const TrackSubscribed$json = {
  '1': 'TrackSubscribed',
  '2': [
    {'1': 'track_sid', '3': 1, '4': 1, '5': 9, '10': 'trackSid'},
  ],
};

/// Descriptor for `TrackSubscribed`. Decode as a `google.protobuf.DescriptorProto`.
final $typed_data.Uint8List trackSubscribedDescriptor =
    $convert.base64Decode('Cg9UcmFja1N1YnNjcmliZWQSGwoJdHJhY2tfc2lkGAEgASgJUgh0cmFja1NpZA==');

@$core.Deprecated('Use connectionSettingsDescriptor instead')
const ConnectionSettings$json = {
  '1': 'ConnectionSettings',
  '2': [
    {'1': 'auto_subscribe', '3': 1, '4': 1, '5': 8, '10': 'autoSubscribe'},
    {'1': 'adaptive_stream', '3': 2, '4': 1, '5': 8, '10': 'adaptiveStream'},
    {'1': 'subscriber_allow_pause', '3': 3, '4': 1, '5': 8, '9': 0, '10': 'subscriberAllowPause', '17': true},
    {'1': 'disable_ice_lite', '3': 4, '4': 1, '5': 8, '10': 'disableIceLite'},
    {'1': 'auto_subscribe_data_track', '3': 5, '4': 1, '5': 8, '9': 1, '10': 'autoSubscribeDataTrack', '17': true},
  ],
  '8': [
    {'1': '_subscriber_allow_pause'},
    {'1': '_auto_subscribe_data_track'},
  ],
};

/// Descriptor for `ConnectionSettings`. Decode as a `google.protobuf.DescriptorProto`.
final $typed_data.Uint8List connectionSettingsDescriptor =
    $convert.base64Decode('ChJDb25uZWN0aW9uU2V0dGluZ3MSJQoOYXV0b19zdWJzY3JpYmUYASABKAhSDWF1dG9TdWJzY3'
        'JpYmUSJwoPYWRhcHRpdmVfc3RyZWFtGAIgASgIUg5hZGFwdGl2ZVN0cmVhbRI5ChZzdWJzY3Jp'
        'YmVyX2FsbG93X3BhdXNlGAMgASgISABSFHN1YnNjcmliZXJBbGxvd1BhdXNliAEBEigKEGRpc2'
        'FibGVfaWNlX2xpdGUYBCABKAhSDmRpc2FibGVJY2VMaXRlEj4KGWF1dG9fc3Vic2NyaWJlX2Rh'
        'dGFfdHJhY2sYBSABKAhIAVIWYXV0b1N1YnNjcmliZURhdGFUcmFja4gBAUIZChdfc3Vic2NyaW'
        'Jlcl9hbGxvd19wYXVzZUIcChpfYXV0b19zdWJzY3JpYmVfZGF0YV90cmFjaw==');

@$core.Deprecated('Use joinRequestDescriptor instead')
const JoinRequest$json = {
  '1': 'JoinRequest',
  '2': [
    {'1': 'client_info', '3': 1, '4': 1, '5': 11, '6': '.gravixcloud.ClientInfo', '10': 'clientInfo'},
    {
      '1': 'connection_settings',
      '3': 2,
      '4': 1,
      '5': 11,
      '6': '.gravixcloud.ConnectionSettings',
      '10': 'connectionSettings'
    },
    {'1': 'metadata', '3': 3, '4': 1, '5': 9, '8': {}, '10': 'metadata'},
    {
      '1': 'participant_attributes',
      '3': 4,
      '4': 3,
      '5': 11,
      '6': '.gravixcloud.JoinRequest.ParticipantAttributesEntry',
      '8': {},
      '10': 'participantAttributes'
    },
    {'1': 'add_track_requests', '3': 5, '4': 3, '5': 11, '6': '.gravixcloud.AddTrackRequest', '10': 'addTrackRequests'},
    {'1': 'publisher_offer', '3': 6, '4': 1, '5': 11, '6': '.gravixcloud.SessionDescription', '10': 'publisherOffer'},
    {'1': 'reconnect', '3': 7, '4': 1, '5': 8, '10': 'reconnect'},
    {'1': 'reconnect_reason', '3': 8, '4': 1, '5': 14, '6': '.gravixcloud.ReconnectReason', '10': 'reconnectReason'},
    {'1': 'participant_sid', '3': 9, '4': 1, '5': 9, '10': 'participantSid'},
    {'1': 'sync_state', '3': 10, '4': 1, '5': 11, '6': '.gravixcloud.SyncState', '10': 'syncState'},
  ],
  '3': [JoinRequest_ParticipantAttributesEntry$json],
};

@$core.Deprecated('Use joinRequestDescriptor instead')
const JoinRequest_ParticipantAttributesEntry$json = {
  '1': 'ParticipantAttributesEntry',
  '2': [
    {'1': 'key', '3': 1, '4': 1, '5': 9, '10': 'key'},
    {'1': 'value', '3': 2, '4': 1, '5': 9, '10': 'value'},
  ],
  '7': {'7': true},
};

/// Descriptor for `JoinRequest`. Decode as a `google.protobuf.DescriptorProto`.
final $typed_data.Uint8List joinRequestDescriptor =
    $convert.base64Decode('CgtKb2luUmVxdWVzdBI4CgtjbGllbnRfaW5mbxgBIAEoCzIXLmdyYXZpeGNsb3VkLkNsaWVudE'
        'luZm9SCmNsaWVudEluZm8SUAoTY29ubmVjdGlvbl9zZXR0aW5ncxgCIAEoCzIfLmdyYXZpeGNs'
        'b3VkLkNvbm5lY3Rpb25TZXR0aW5nc1ISY29ubmVjdGlvblNldHRpbmdzEkAKCG1ldGFkYXRhGA'
        'MgASgJQiSyUB48cmVkYWN0ZWQgKHt7IC5TaXplIH19IGJ5dGVzKT7AUAFSCG1ldGFkYXRhEpAB'
        'ChZwYXJ0aWNpcGFudF9hdHRyaWJ1dGVzGAQgAygLMjMuZ3Jhdml4Y2xvdWQuSm9pblJlcXVlc3'
        'QuUGFydGljaXBhbnRBdHRyaWJ1dGVzRW50cnlCJLJQHjxyZWRhY3RlZCAoe3sgLlNpemUgfX0g'
        'Ynl0ZXMpPsBQAVIVcGFydGljaXBhbnRBdHRyaWJ1dGVzEkoKEmFkZF90cmFja19yZXF1ZXN0cx'
        'gFIAMoCzIcLmdyYXZpeGNsb3VkLkFkZFRyYWNrUmVxdWVzdFIQYWRkVHJhY2tSZXF1ZXN0cxJI'
        'Cg9wdWJsaXNoZXJfb2ZmZXIYBiABKAsyHy5ncmF2aXhjbG91ZC5TZXNzaW9uRGVzY3JpcHRpb2'
        '5SDnB1Ymxpc2hlck9mZmVyEhwKCXJlY29ubmVjdBgHIAEoCFIJcmVjb25uZWN0EkcKEHJlY29u'
        'bmVjdF9yZWFzb24YCCABKA4yHC5ncmF2aXhjbG91ZC5SZWNvbm5lY3RSZWFzb25SD3JlY29ubm'
        'VjdFJlYXNvbhInCg9wYXJ0aWNpcGFudF9zaWQYCSABKAlSDnBhcnRpY2lwYW50U2lkEjUKCnN5'
        'bmNfc3RhdGUYCiABKAsyFi5ncmF2aXhjbG91ZC5TeW5jU3RhdGVSCXN5bmNTdGF0ZRpIChpQYX'
        'J0aWNpcGFudEF0dHJpYnV0ZXNFbnRyeRIQCgNrZXkYASABKAlSA2tleRIUCgV2YWx1ZRgCIAEo'
        'CVIFdmFsdWU6AjgB');

@$core.Deprecated('Use wrappedJoinRequestDescriptor instead')
const WrappedJoinRequest$json = {
  '1': 'WrappedJoinRequest',
  '2': [
    {
      '1': 'compression',
      '3': 1,
      '4': 1,
      '5': 14,
      '6': '.gravixcloud.WrappedJoinRequest.Compression',
      '10': 'compression'
    },
    {'1': 'join_request', '3': 2, '4': 1, '5': 12, '10': 'joinRequest'},
  ],
  '4': [WrappedJoinRequest_Compression$json],
};

@$core.Deprecated('Use wrappedJoinRequestDescriptor instead')
const WrappedJoinRequest_Compression$json = {
  '1': 'Compression',
  '2': [
    {'1': 'NONE', '2': 0},
    {'1': 'GZIP', '2': 1},
  ],
};

/// Descriptor for `WrappedJoinRequest`. Decode as a `google.protobuf.DescriptorProto`.
final $typed_data.Uint8List wrappedJoinRequestDescriptor =
    $convert.base64Decode('ChJXcmFwcGVkSm9pblJlcXVlc3QSTQoLY29tcHJlc3Npb24YASABKA4yKy5ncmF2aXhjbG91ZC'
        '5XcmFwcGVkSm9pblJlcXVlc3QuQ29tcHJlc3Npb25SC2NvbXByZXNzaW9uEiEKDGpvaW5fcmVx'
        'dWVzdBgCIAEoDFILam9pblJlcXVlc3QiIQoLQ29tcHJlc3Npb24SCAoETk9ORRAAEggKBEdaSV'
        'AQAQ==');

@$core.Deprecated('Use mediaSectionsRequirementDescriptor instead')
const MediaSectionsRequirement$json = {
  '1': 'MediaSectionsRequirement',
  '2': [
    {'1': 'num_audios', '3': 1, '4': 1, '5': 13, '10': 'numAudios'},
    {'1': 'num_videos', '3': 2, '4': 1, '5': 13, '10': 'numVideos'},
  ],
};

/// Descriptor for `MediaSectionsRequirement`. Decode as a `google.protobuf.DescriptorProto`.
final $typed_data.Uint8List mediaSectionsRequirementDescriptor =
    $convert.base64Decode('ChhNZWRpYVNlY3Rpb25zUmVxdWlyZW1lbnQSHQoKbnVtX2F1ZGlvcxgBIAEoDVIJbnVtQXVkaW'
        '9zEh0KCm51bV92aWRlb3MYAiABKA1SCW51bVZpZGVvcw==');
