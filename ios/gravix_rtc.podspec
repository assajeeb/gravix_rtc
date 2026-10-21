#
# To learn more about a Podspec see http://guides.cocoapods.org/syntax/podspec.html.
# Run `pod lib lint gravix_rtc.podspec` to validate before publishing.
#
Pod::Spec.new do |s|
  s.name             = 'gravix_rtc'
  s.version          = '0.0.1'
  s.summary          = 'A new Flutter plugin project.'
  s.description      = <<-DESC
A new Flutter plugin project.
                       DESC
  s.homepage         = 'http://example.com'
  s.license          = { :file => '../LICENSE' }
  s.author           = { 'Your Company' => 'email@example.com' }
  s.source           = { :path => '.' }
  # Swift plugin + the on-device noise suppression C core. The C files in
  # Sources/gxns are forwarders that #include native/gxns (shared with Android
  # and the host tests); their headers are reached through the search paths
  # below, not listed here, so CocoaPods never copies a forwarder header into
  # the framework (its relative #include would break there). Swift imports the
  # core as `gxns` through include/module.modulemap (SWIFT_INCLUDE_PATHS).
  s.source_files = 'gravix_rtc/Sources/gravix_rtc/**/*.swift', 'gravix_rtc/Sources/gxns/*.c'
  s.preserve_paths = 'gravix_rtc/Sources/gxns/**/*'
  s.dependency 'Flutter'
  # The native RTC plugin talks to flutter_webrtc's audio device module and
  # RTCAudioSession. WebRTC-SDK without a version: flutter_webrtc pins it
  # (144.7559.09 for 1.6.0, 150.7871.01 for 1.6.2+hotfix.3), and one WebRTC
  # binary is resolved. 0.4.10: was pinned to 144, which conflicted with every
  # flutter_webrtc after 1.6.0.
  s.dependency 'flutter_webrtc'
  s.dependency 'WebRTC-SDK'
  s.static_framework = true
  s.frameworks = 'AVFoundation', 'ReplayKit', 'CoreML'
  s.platform = :ios, '13.0'

  # Flutter.framework does not contain a i386 slice.
  s.pod_target_xcconfig = {
    'DEFINES_MODULE' => 'YES',
    'EXCLUDED_ARCHS[sdk=iphonesimulator*]' => 'i386',
    'HEADER_SEARCH_PATHS' => '$(inherited) "$(PODS_TARGET_SRCROOT)/gravix_rtc/Sources/gxns/include" "$(PODS_TARGET_SRCROOT)/gravix_rtc/Sources/gxns/shim"',
    'SWIFT_INCLUDE_PATHS' => '$(inherited) "$(PODS_TARGET_SRCROOT)/gravix_rtc/Sources/gxns/include"',
    # The noise suppression core runs on the real-time capture thread: keep it
    # optimised in Debug builds too (only C is affected; Swift keeps -Onone).
    'GCC_OPTIMIZATION_LEVEL' => '2',
  }
  s.swift_version = '5.0'

  # If your plugin requires a privacy manifest, for example if it uses any
  # required reason APIs, update the PrivacyInfo.xcprivacy file to describe your
  # plugin's privacy impact, and then uncomment this line. For more information,
  # see https://developer.apple.com/documentation/bundleresources/privacy_manifest_files
  s.resource_bundles = {
    'gravix_rtc_privacy' => ['gravix_rtc/Sources/gravix_rtc/PrivacyInfo.xcprivacy'],
    # Noise suppression studio model (DeepFilterNet3 standard, precompiled
    # Core ML .mlmodelc, ~2.7 MB) + its licences.
    'gravix_rtc_ns' => ['gravix_rtc/Sources/gravix_rtc/Resources/ns/*'],
  }
end
