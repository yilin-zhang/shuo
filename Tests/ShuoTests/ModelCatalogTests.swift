import Testing

@testable import Shuo

@Test
@MainActor
func qwenModelsAreCatalogDefaults() {
  #expect(ModelCatalog.asrModels.first?.id == NativeASREngine.defaultModelID)
  #expect(ModelCatalog.refineModels.first?.id == ModelCatalog.defaultRefineModelID)
  #expect(ModelCatalog.asrModels.first?.isRecommended == true)
  #expect(ModelCatalog.refineModels.first?.isRecommended == true)
}

@Test
func transcriptionModelsAreQwen3ASR() {
  #expect(ModelCatalog.asrGroups.count == 1)
  #expect(ModelCatalog.asrGroups[0].id == "qwen3-asr")
  #expect(ModelCatalog.asrModels.count == 1)
}

@Test
func refineModelsAreLightweight() {
  #expect(ModelCatalog.refineModels.count == 2)
  #expect(ModelCatalog.refineModels[0].id == "mlx-community/Qwen3-0.6B-4bit")
  #expect(ModelCatalog.refineModels[1].id == "mlx-community/Qwen3-1.7B-4bit")
}
