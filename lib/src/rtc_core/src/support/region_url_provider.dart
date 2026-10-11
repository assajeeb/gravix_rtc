import 'dart:convert' show json;

import 'package:fixnum/fixnum.dart';

import '../../../connect/gravix_region_failover.dart'; // GRAVIX (0.4.15)
import '../exceptions.dart';
import '../logger.dart';
import '../options.dart';
import '../proto/gravixcloud_rtc.pb.dart' as lk_models;
import 'http_client.dart';

class RegionUrlProvider {
  Uri serverUrl;

  String token;

  final NetworkOptions networkOptions;

  lk_models.RegionSettings? regionSettings;

  List<lk_models.RegionInfo> attemptedRegions = [];

  int lastUpdateAt = 0;

  int settingsCacheTime = 5000; // 5 seconds

  RegionUrlProvider({required String url, required this.token, this.networkOptions = const NetworkOptions()})
    : serverUrl = Uri.parse(url);

  void updateToken(String token) {
    this.token = token;
  }

  bool isCloud() => isCloudUrl(serverUrl);

  Uri getServerUrl() {
    return serverUrl;
  }

  /// The next region to try. GRAVIX (0.4.15): with [measuredOrder]
  /// (GravixRecoveryOptions.measuredRegionFailover) the untried regions go in
  /// the order of the fresh start-up measurement (gravixOrderFailoverRegions:
  /// nearest first, near-only cap, the server's order as the last resort), and
  /// the entry for [currentUrl] (the url that just failed) goes last. Without a
  /// fresh measurement, the server's order (field 2026-10-09: blr1 -> doh1).
  /// [fetchTimeout]: see [fetchRegionSettings].
  /// [lastGoodFallback] (GravixRecoveryOptions.lastGoodRegionList): a failed
  /// fetch of the list uses the last list this provider had instead of failing.
  /// With it, [currentUrlFailed] (the caller just failed at [currentUrl], not
  /// by a refusal) and a kept list: when the list would be fetched from
  /// [currentUrl]'s host, that host is not asked (the list changes only on a
  /// server deploy; asking a host that just failed costs the fetch's bound).
  Future<String?> getNextBestRegionUrl({
    String? currentUrl,
    bool measuredOrder = false,
    Duration? fetchTimeout,
    bool lastGoodFallback = false,
    bool currentUrlFailed = false,
  }) async {
    if (!isCloud()) {
      throw Exception('region availability is only supported for Gravix Cloud domains');
    }
    final stale =
        regionSettings == null || DateTime.timestamp().millisecondsSinceEpoch - lastUpdateAt > settingsCacheTime;
    // GRAVIX (2026-10-11, lastGoodRegionList): the list's host is the url that
    // just failed. EMU r504 (SIMULATED, blr1 DROP): asking it again waited the
    // fetch's whole bound (10 s) for nothing before the failover.
    final kept = regionSettings;
    if (stale &&
        lastGoodFallback &&
        currentUrlFailed &&
        kept != null &&
        currentUrl != null &&
        Uri.tryParse(currentUrl)?.host.toLowerCase() == serverUrl.host.toLowerCase()) {
      final ageS = (DateTime.timestamp().millisecondsSinceEpoch - lastUpdateAt) ~/ 1000;
      logger.info(
        'region list: not asking ${getCloudConfigUrl(serverUrl)}/regions, its host just failed ($currentUrl); '
        'using the last good list (${kept.regions.length} regions, ${ageS} s old)',
      );
    } else if (stale) {
      try {
        regionSettings = await fetchRegionSettings(timeout: fetchTimeout);
      } catch (e) {
        // GRAVIX (2026-10-11, lastGoodRegionList): the list is fetched from the
        // url the app connected to, which is usually the region that just
        // failed. EMU-OLD (blr1 refused / dropped): this fetch failed on every
        // attempt and the session never left blr1 (0 of 9). The list fetched at
        // connect is still right: a region set changes on a deploy. Not for a
        // refusal (401/403): that is the token, every region would refuse it.
        final refused = e is ConnectException && e.reason == ConnectionErrorReason.NotAllowed;
        final lastGood = regionSettings;
        if (!lastGoodFallback || refused || lastGood == null) rethrow;
        final ageS = (DateTime.timestamp().millisecondsSinceEpoch - lastUpdateAt) ~/ 1000;
        logger.info(
          'region list: ${getCloudConfigUrl(serverUrl)}/regions failed ($e); '
          'using the last good list (${lastGood.regions.length} regions, ${ageS} s old)',
        );
      }
    }
    Iterable<lk_models.RegionInfo>? regionsLeft = regionSettings?.regions.where(
      (region) => !attemptedRegions.any((attempted) => attempted.region == region.region),
    );
    if (measuredOrder && regionsLeft != null) {
      final current = currentUrl == null ? null : gravixNormalizeRegionUrl(currentUrl);
      bool isCurrent(lk_models.RegionInfo r) => current != null && gravixNormalizeRegionUrl(r.url) == current;
      final others = regionsLeft.where((r) => !isCurrent(r)).toList();
      regionsLeft = [
        ...gravixOrderFailoverRegions(others, regionOf: (r) => r.region, urlOf: (r) => r.url),
        ...regionsLeft.where(isCurrent),
      ];
    }
    if (regionsLeft?.isNotEmpty ?? false) {
      final nextRegion = regionsLeft!.first;
      attemptedRegions.add(nextRegion);
      logger.fine('next region: ${nextRegion.region}');
      return nextRegion.url;
    } else {
      return null;
    }
  }

  void resetAttempts() {
    attemptedRegions = [];
  }

  /// [timeout] (GRAVIX, 2026-10-11): the request gives up after it and closes
  /// its socket. Soak 2026-10-11: during a blackholed path the failover's fetch
  /// waited for Android's SYN timeout (31 s on the Xiaomi) before the next
  /// reconnect attempt could start. Null: unbounded (the 0.4.14 fetch).
  /* @internal */
  Future<lk_models.RegionSettings> fetchRegionSettings({Duration? timeout}) async {
    final url = '${getCloudConfigUrl(serverUrl)}/regions';
    final regionSettingsResponse = await sdkHttpGet(
      Uri.parse(url),
      headers: {'authorization': 'Bearer $token'},
      networkOptions: networkOptions,
      timeout: timeout,
    );
    if (regionSettingsResponse.statusCode == 200) {
      final mapData = json.decode(regionSettingsResponse.body);
      final regions = (mapData['regions'] as List<dynamic>)
          .map(
            (region) => lk_models.RegionInfo(
              distance: Int64(int.parse(region['distance'])),
              region: region['region'],
              url: region['url'],
            ),
          )
          .toList();
      final regionSettings = lk_models.RegionSettings(regions: regions);
      lastUpdateAt = DateTime.timestamp().millisecondsSinceEpoch;
      // GRAVIX (2026-10-11): shows on a device log that the list a failover
      // falls back to (lastGoodRegionList) was fetched, and from where
      logger.fine('region list: ${regions.length} regions from ${serverUrl.host}');
      return regionSettings;
    } else {
      throw ConnectException(
        'Could not fetch region settings: ${regionSettingsResponse.body}, status: ${regionSettingsResponse.statusCode}',
        reason: regionSettingsResponse.statusCode == 401
            ? ConnectionErrorReason.NotAllowed
            : ConnectionErrorReason.InternalError,
        statusCode: regionSettingsResponse.statusCode,
      );
    }
  }

  void setServerReportedRegions(lk_models.RegionSettings regions) {
    regionSettings = regions;
    lastUpdateAt = DateTime.timestamp().millisecondsSinceEpoch;
  }

  String getCloudConfigUrl(Uri serverUrl) {
    return '${serverUrl.scheme.replaceAll('ws', 'http')}://${serverUrl.host}/settings';
  }
}

extension RegionInfoExtension on lk_models.RegionInfo {
  lk_models.RegionInfo fromJson(Map<String, dynamic> json) =>
      lk_models.RegionInfo(region: json['region'], url: json['url'], distance: json['distance']);
}

extension RegionSettingsExtension on lk_models.RegionSettings {
  lk_models.RegionSettings fromJson(Map<String, dynamic> json) => lk_models.RegionSettings(
    regions: json['regions'].map((region) => lk_models.RegionInfo.fromJson(region)).toList(),
  );
}

bool isCloudUrl(Uri uri) {
  return uri.host.contains('.gravixcloud.com') || uri.host.contains('.gravixcloud.run');
}

String toHttpUrl(String url) {
  if (url.startsWith('ws')) {
    return url.replaceFirst('ws', 'http');
  }
  return url;
}

String toWebsocketUrl(String url) {
  if (url.startsWith('http')) {
    return url.replaceFirst('http', 'ws');
  }
  return url;
}
