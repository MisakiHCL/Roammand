#
# To learn more about a Podspec see http://guides.cocoapods.org/syntax/podspec.html
#
Pod::Spec.new do |s|
  s.name             = 'flutter_webrtc'
  s.version          = '1.5.2-roammand.1'
  s.summary          = 'Roammand-vendored Flutter WebRTC plugin for macOS.'
  s.description      = <<-DESC
flutter_webrtc 1.5.2 with Roammand's downstream ReplayKit picker fix.
                       DESC
  s.homepage         = 'https://github.com/cloudwebrtc/flutter-webrtc'
  s.license          = { :file => '../LICENSE' }
  s.author           = { 'CloudWebRTC' => 'duanweiwei1982@gmail.com' }
  s.source           = { :path => '.' }
  s.source_files     = ['Classes/**/*']

  s.dependency 'FlutterMacOS'
  s.weak_frameworks = 'ScreenCaptureKit'
  s.dependency 'WebRTC-SDK', '144.7559.09'
  s.osx.deployment_target = '10.15'
end
