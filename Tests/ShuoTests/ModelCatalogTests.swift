import Testing

@testable import Shuo

@Test
@MainActor
func qwenModelsAreCatalogDefaults() {
  #expect(ModelCatalog.asrModels.first?.id == ASRBackend.qwenModelID)
  #expect(ModelCatalog.refineModels.first?.id == ModelCatalog.defaultRefineModelID)
  #expect(ModelCatalog.asrModels.first?.isRecommended == true)
  #expect(ModelCatalog.refineModels.first?.isRecommended == true)
}

@Test
func transcriptionModelsAreGroupedByBackend() {
  #expect(ModelCatalog.asrGroups.count == 2)
  #expect(
    ModelCatalog.asrGroups[0].options.allSatisfy {
      ASRBackend.resolve(modelID: $0.id) == .qwen3
    })
  #expect(
    ModelCatalog.asrGroups[1].options.allSatisfy {
      ASRBackend.resolve(modelID: $0.id) == .whisper
    })
}
