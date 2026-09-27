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
  s.source_files = 'gravix_rtc/Sources/gravix_rtc/**/*.swift'
  s.dependency 'Flutter'
  # The native RTC plugin talks to flutter_webrtc's audio device module and
  # RTCAudioSession. Pin WebRTC-SDK to the exact version flutter_webrtc 1.6.0
  # uses so CocoaPods resolves a single WebRTC binary.
  s.dependency 'flutter_webrtc'
  s.dependency 'WebRTC-SDK', '144.7559.09'
  s.static_framework = true
  s.frameworks = 'AVFoundation', 'ReplayKit'
  s.platform = :ios, '13.0'

  # Flutter.framework does not contain a i386 slice.
  s.pod_target_xcconfig = { 'DEFINES_MODULE' => 'YES', 'EXCLUDED_ARCHS[sdk=iphonesimulator*]' => 'i386' }
  s.swift_version = '5.0'

  # If your plugin requires a privacy manifest, for example if it uses any
  # required reason APIs, update the PrivacyInfo.xcprivacy file to describe your
  # plugin's privacy impact, and then uncomment this line. For more information,
  # see https://developer.apple.com/documentation/bundleresources/privacy_manifest_files
  s.resource_bundles = {'gravix_rtc_privacy' => ['gravix_rtc/Sources/gravix_rtc/PrivacyInfo.xcprivacy']}
end
