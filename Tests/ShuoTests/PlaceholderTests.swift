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
  #expect(!AppSettings.defaultRefinePrompt.contains("<corrected>"))
  #expect(
    NativeRefineEngine.instructions(userPrompt: "Apply placeholder preferences.")
      .contains("<corrected>...</corrected>")
  )
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
    ) == nil
  )
  #expect(
    NativeRefineEngine.extractCorrection(
      from: "extra output <corrected>placeholder text</corrected>"
    ) == nil
  )
  #expect(
    NativeRefineEngine.correctedText(
      from: "<corrected>placeholder text plus unrelated generated content</corrected>",
      fallback: "placeholder text"
    ) == "placeholder text"
  )
  #expect(
    NativeRefineEngine.correctedText(
      from: "<corrected>placeholder text</corrected>",
      fallback: "placeholder txt"
    ) == "placeholder text"
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

@Test
@MainActor
func legacyDefaultRefinePromptMigratesToUserFacingInstructions() {
  let suite = "ShuoTests.LegacyRefinePrompt.\(UUID().uuidString)"
  let defaults = UserDefaults(suiteName: suite)!
  defer { defaults.removePersistentDomain(forName: suite) }
  defaults.set(AppSettings.legacyDefaultRefinePrompt, forKey: "refinePrompt")

  let settings = AppSettings(defaults: defaults)

  #expect(settings.refinePrompt == AppSettings.defaultRefinePrompt)
  #expect(defaults.string(forKey: "refinePrompt") == AppSettings.defaultRefinePrompt)
}
