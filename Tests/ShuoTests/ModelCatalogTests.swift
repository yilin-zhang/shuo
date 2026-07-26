import Testing

@testable import Shuo

@Test
@MainActor
func preferredModelsAreCatalogDefaults() {
  #expect(ModelCatalog.asrModels.first?.id == "large-v3-v20240930_turbo_632MB")
  #expect(ModelCatalog.refineModels.first?.id == "mlx-community/Qwen3-0.6B-4bit")
}

@Test
func modelCatalogIncludesNativeQwenASR() {
  #expect(
    ModelCatalog.asrModels.contains {
      $0.id == ASRBackend.qwenModelID
    }
  )
}

@Test
func transcriptionModelsAreGroupedByBackend() {
  #expect(ModelCatalog.asrGroups.map(\.title) == ["WhisperKit", "Qwen3-ASR"])
  #expect(
    ModelCatalog.asrGroups[0].options.allSatisfy {
      ASRBackend.resolve(modelID: $0.id) == .whisper
    })
  #expect(
    ModelCatalog.asrGroups[1].options.allSatisfy {
      ASRBackend.resolve(modelID: $0.id) == .qwen3
    })
}
