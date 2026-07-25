import Testing

@testable import Shuo

@Test
func freshInstallWithoutASRRequiresInitialSetup() {
  let plan = ModelStartupPlan.resolve(
    hasASR: false,
    hasRefine: false,
    refineEnabled: true,
    hasCompletedInitialSetup: false
  )

  #expect(plan.needsSetup)
  #expect(plan.isInitialSetup)
  #expect(plan.shouldDisableRefine)
}

@Test
func missingASRAfterSetupRequiresASROnlySetup() {
  let plan = ModelStartupPlan.resolve(
    hasASR: false,
    hasRefine: false,
    refineEnabled: false,
    hasCompletedInitialSetup: true
  )

  #expect(plan.needsSetup)
  #expect(!plan.isInitialSetup)
}

@Test
func missingRefineModelDisablesRefineWithoutReopeningSetup() {
  let plan = ModelStartupPlan.resolve(
    hasASR: true,
    hasRefine: false,
    refineEnabled: true,
    hasCompletedInitialSetup: true
  )

  #expect(!plan.needsSetup)
  #expect(plan.shouldDisableRefine)
}

@Test
func downloadedRefineModelKeepsRefinePreference() {
  let plan = ModelStartupPlan.resolve(
    hasASR: true,
    hasRefine: true,
    refineEnabled: true,
    hasCompletedInitialSetup: true
  )

  #expect(!plan.needsSetup)
  #expect(!plan.shouldDisableRefine)
}

@Test
func modelStatusPrioritizesActiveThenLoadingThenAvailability() {
  let id = "placeholder-model"

  #expect(
    ModelStatus.resolve(id: id, activeID: id, loadingID: id, isDownloaded: true)
      == .active
  )
  #expect(
    ModelStatus.resolve(id: id, activeID: nil, loadingID: id, isDownloaded: true)
      == .activating
  )
  #expect(
    ModelStatus.resolve(id: id, activeID: nil, loadingID: id, isDownloaded: false)
      == .downloading
  )
  #expect(
    ModelStatus.resolve(id: id, activeID: nil, loadingID: nil, isDownloaded: true)
      == .downloaded
  )
  #expect(
    ModelStatus.resolve(id: id, activeID: nil, loadingID: nil, isDownloaded: false)
      == .downloadRequired
  )
  #expect(
    ModelStatus.resolve(
      id: id,
      activeID: id,
      loadingID: nil,
      isDownloaded: true,
      isDeleting: true
    ) == .deleting
  )
}
