import Foundation
import Testing

@testable import Shuo

@Test
@MainActor
func modelCatalogHasValidDefaults() {
  #expect(ModelCatalog.asrModels.first?.id == "large-v3-v20240930_turbo_632MB")
  #expect(ModelCatalog.refineModels.first?.id == "mlx-community/Qwen3-0.6B-4bit")
  #expect(!AppSettings.defaultRefinePrompt.isEmpty)
  #expect(AppSettings.defaultRefinePrompt.contains("not a conversational assistant"))
}

@Test
func refineOutputRemovesCorrectionTags() {
  #expect(
    NativeRefineEngine.extractCorrection(
      from: "<corrected>placeholder text</correct>"
    ) == "placeholder text"
  )
  #expect(
    NativeRefineEngine.extractCorrection(
      from: "<correct>plain text</corrected>"
    ) == "plain text"
  )
  #expect(
    NativeRefineEngine.extractCorrection(
      from: "<corrected>missing closing tag"
    ) == "missing closing tag"
  )
}

@Test
@MainActor
func shortcutDefaultsPreservePushToTalkBehavior() {
  let suite = "ShuoTests.\(UUID().uuidString)"
  let defaults = UserDefaults(suiteName: suite)!
  defer { defaults.removePersistentDomain(forName: suite) }
  let settings = AppSettings(defaults: defaults)
  #expect(settings.hotkeyShortcut == .rightOption)
  #expect(settings.hotkeyMode == .hold)
}
