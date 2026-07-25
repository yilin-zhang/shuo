import AVFoundation
import ApplicationServices
import CoreGraphics

enum PermissionManager {
  static func requestAll() async {
    _ = await AVCaptureDevice.requestAccess(for: .audio)

    let options = ["AXTrustedCheckOptionPrompt": true] as CFDictionary
    _ = AXIsProcessTrustedWithOptions(options)

    if !CGPreflightListenEventAccess() {
      _ = CGRequestListenEventAccess()
    }
  }

  static var microphoneGranted: Bool {
    AVCaptureDevice.authorizationStatus(for: .audio) == .authorized
  }

  static var accessibilityGranted: Bool {
    AXIsProcessTrusted()
  }

  static var inputMonitoringGranted: Bool {
    CGPreflightListenEventAccess()
  }
}
