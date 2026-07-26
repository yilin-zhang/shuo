import Testing

@testable import Shuo

@Test
func permissionSettingsURLsTargetTheirPrivacyPages() {
  #expect(
    PermissionKind.microphone.settingsURL.absoluteString
      == "x-apple.systempreferences:com.apple.preference.security?Privacy_Microphone"
  )
  #expect(
    PermissionKind.accessibility.settingsURL.absoluteString
      == "x-apple.systempreferences:com.apple.preference.security?Privacy_Accessibility"
  )
  #expect(
    PermissionKind.inputMonitoring.settingsURL.absoluteString
      == "x-apple.systempreferences:com.apple.preference.security?Privacy_ListenEvent"
  )
}
