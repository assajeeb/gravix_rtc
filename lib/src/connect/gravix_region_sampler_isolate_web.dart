// Copyright (c) 2026 Gravity Compile. MIT License; see LICENSE.

import 'gravix_region_report.dart';
import 'gravix_region_sampler_isolate.dart';

/// Web: no dart:io helper isolate; the measurement keeps the page's sampler, as
/// before 0.9.1.
String? unavailableReason() => 'web';

Future<GravixRegionSamplingRun> start({
  required List<GravixRegionUrl> regions,
  required int samples,
  required Duration timeout,
  required int concurrency,
  required Duration budget,
  required void Function(GravixRegionSampleEvent event) onEvent,
  void Function()? onExit,
}) => Future.error(UnsupportedError('no helper isolate on web'));
