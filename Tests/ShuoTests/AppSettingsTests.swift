import Foundation
import Testing

@testable import Shuo

@MainActor
private func withIsolatedDefaults(
  _ label: String,
  run: (UserDefaults) -> Void
) {
  let suite = "ShuoTests.\(label).\(UUID().uuidString)"
  let defaults = UserDefaults(suiteName: suite)!
  defer { defaults.removePersistentDomain(forName: suite) }
  run(defaults)
}

@Test
@MainActor
func settingsPreservePushToTalkAndSetupDefaults() {
  withIsolatedDefaults("Defaults") { defaults in
    let settings = AppSettings(defaults: defaults)

    #expect(settings.hotkeyShortcut == .rightOption)
    #expect(settings.hotkeyMode == .hold)
    #expect(settings.asrModel == ASRBackend.qwenModelID)
    #expect(settings.refineModel == ModelCatalog.defaultRefineModelID)
    #expect(!settings.hasCompletedInitialSetup)
    settings.hasCompletedInitialSetup = true
    #expect(settings.hasCompletedInitialSetup)
  }
}

@Test
@MainActor
func newDefaultsDoNotOverwriteExistingModelChoices() {
  withIsolatedDefaults("ExistingModels") { defaults in
    defaults.set("placeholder-asr-model", forKey: "asrModel")
    defaults.set("placeholder-refine-model", forKey: "refineModel")

    let settings = AppSettings(defaults: defaults)

    #expect(settings.asrModel == "placeholder-asr-model")
    #expect(settings.refineModel == "placeholder-refine-model")
  }
}

@Test
@MainActor
func transcriptionTermsBecomeDeduplicatedModelContext() {
  withIsolatedDefaults("TranscriptionTerms") { defaults in
    let settings = AppSettings(defaults: defaults)
    settings.transcriptionTerms = [
      "ExampleFramework",
      "",
      "Sample API",
      "exampleframework",
    ]

    #expect(settings.transcriptionContext == "ExampleFramework Sample API")
  }
}

@Test
@MainActor
func legacyMultilineTerminologyMigratesToRows() {
  withIsolatedDefaults("LegacyTranscriptionTerms") { defaults in
    defaults.set("ExampleFramework\nSample API", forKey: "transcriptionTerms")

    let settings = AppSettings(defaults: defaults)

    #expect(settings.transcriptionTerms == ["ExampleFramework", "Sample API"])
    #expect(defaults.stringArray(forKey: "transcriptionTerms") == settings.transcriptionTerms)
  }
}
