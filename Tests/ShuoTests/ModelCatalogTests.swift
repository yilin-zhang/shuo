import Testing

@testable import Shuo

@Test
@MainActor
func preferredModelsAreCatalogDefaults() {
  #expect(ModelCatalog.asrModels.first?.id == "large-v3-v20240930_turbo_632MB")
  #expect(ModelCatalog.refineModels.first?.id == "mlx-community/Qwen3-0.6B-4bit")
}
