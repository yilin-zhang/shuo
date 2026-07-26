import AVFoundation
import AppKit
import ApplicationServices
import CoreGraphics

enum PermissionKind: String {
  case microphone = "Privacy_Microphone"
  case accessibility = "Privacy_Accessibility"
  case inputMonitoring = "Privacy_ListenEvent"

  var settingsURL: URL {
    URL(
      string: "x-apple.systempreferences:com.apple.preference.security?\(rawValue)"
    )!
  }
}

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

  @MainActor
  static func openSettings(for permission: PermissionKind) {
    NSWorkspace.shared.open(permission.settingsURL)
  }
}
