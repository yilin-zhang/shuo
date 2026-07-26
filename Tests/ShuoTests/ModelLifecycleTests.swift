import Foundation
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
  let token = UUID()
  let activating = ModelOperation(
    token: token,
    kind: .transcription,
    id: id,
    event: .activating
  )
  let downloading = ModelOperation(
    token: token,
    kind: .transcription,
    id: id,
    event: .downloading(0.5)
  )

  #expect(
    ModelStatus.resolve(id: id, activeID: id, operation: activating, isDownloaded: true)
      == .active
  )
  #expect(
    ModelStatus.resolve(id: id, activeID: nil, operation: activating, isDownloaded: true)
      == .activating
  )
  #expect(
    ModelStatus.resolve(id: id, activeID: nil, operation: downloading, isDownloaded: false)
      == .downloading
  )
  #expect(
    ModelStatus.resolve(id: id, activeID: nil, operation: nil, isDownloaded: true)
      == .downloaded
  )
  #expect(
    ModelStatus.resolve(id: id, activeID: nil, operation: nil, isDownloaded: false)
      == .downloadRequired
  )
  #expect(
    ModelStatus.resolve(
      id: id,
      activeID: id,
      operation: nil,
      isDownloaded: true,
      isDeleting: true
    ) == .deleting
  )
}

@Test
func incompleteASRCacheIsNotDownloadable() throws {
  let directory = try temporaryDirectory()
  defer { try? FileManager.default.removeItem(at: directory) }

  try createFile("config.json", in: directory)
  #expect(!NativeASREngine.isCompleteWhisperModelDirectory(directory))

  for path in [
    "AudioEncoder.mlmodelc/coremldata.bin",
    "TextDecoder.mlmodelc/coremldata.bin",
    "MelSpectrogram.mlmodelc/coremldata.bin",
  ] {
    try createFile(path, in: directory)
  }
  #expect(NativeASREngine.isCompleteWhisperModelDirectory(directory))
}

@Test
func qwenCacheRequiresConfigTokenizerAndWeights() throws {
  let directory = try temporaryDirectory()
  defer { try? FileManager.default.removeItem(at: directory) }

  try createFile("config.json", in: directory)
  try createFile("tokenizer_config.json", in: directory)
  #expect(!NativeASREngine.isCompleteQwenModelDirectory(directory))

  try createFile("model.safetensors", contents: "placeholder", in: directory)
  #expect(NativeASREngine.isCompleteQwenModelDirectory(directory))
}

@Test
func refineCacheRequiresEveryIndexedWeight() throws {
  let directory = try temporaryDirectory()
  defer { try? FileManager.default.removeItem(at: directory) }

  try createFile("config.json", in: directory)
  try createFile("tokenizer_config.json", in: directory)
  try createFile(
    "model.safetensors.index.json",
    contents:
      #"{"weight_map":{"placeholder-a":"weights-00001-of-00002.safetensors","placeholder-b":"weights-00002-of-00002.safetensors"}}"#,
    in: directory
  )
  #expect(!NativeRefineEngine.isCompleteSnapshot(directory))

  try createFile("weights-00001-of-00002.safetensors", in: directory)
  #expect(!NativeRefineEngine.isCompleteSnapshot(directory))
  try createFile("weights-00002-of-00002.safetensors", in: directory)
  #expect(NativeRefineEngine.isCompleteSnapshot(directory))
}

@Test
func refineCacheAcceptsSingleWeightFile() throws {
  let directory = try temporaryDirectory()
  defer { try? FileManager.default.removeItem(at: directory) }

  try createFile("config.json", in: directory)
  try createFile("tokenizer_config.json", in: directory)
  try createFile("model.safetensors", in: directory)

  #expect(NativeRefineEngine.isCompleteSnapshot(directory))
}

@Test
func modelLoadEventsAreMonotonicAndCoalesced() {
  let recorder = EventRecorder()
  let relay = ModelLoadEventRelay { recorder.append($0) }

  relay.send(.downloading(0))
  relay.send(.downloading(0.009))
  relay.send(.downloading(0.01))
  relay.send(.downloading(0.005))
  relay.send(.activating)
  relay.send(.downloading(1))

  #expect(recorder.events == [.downloading(0), .downloading(0.01), .activating])
}

@Test
func dictationAndProcessingStatesExposeInteractionBoundaries() {
  #expect(ShuoState.listening.isDictating)
  #expect(!ShuoState.listening.isProcessing)
  #expect(ShuoState.transcribing.isDictating)
  #expect(ShuoState.transcribing.isProcessing)
  #expect(ShuoState.refining.isProcessing)
  #expect(ShuoState.outputting.isProcessing)
  #expect(!ShuoState.idle.isDictating)
  #expect(!ShuoState.disabled.isProcessing)
}

@Test
func launchAtLoginReflectsSystemServiceStatus() {
  #expect(AppModel.launchAtLoginEnabled(for: .enabled))
  #expect(AppModel.launchAtLoginEnabled(for: .requiresApproval))
  #expect(!AppModel.launchAtLoginEnabled(for: .notRegistered))
  #expect(!AppModel.launchAtLoginEnabled(for: .notFound))
}

private func temporaryDirectory() throws -> URL {
  let directory = FileManager.default.temporaryDirectory
    .appending(path: "shuo-tests-\(UUID().uuidString)")
  try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
  return directory
}

private func createFile(_ path: String, contents: String = "", in directory: URL) throws {
  let file = directory.appending(path: path)
  try FileManager.default.createDirectory(
    at: file.deletingLastPathComponent(),
    withIntermediateDirectories: true
  )
  try Data(contents.utf8).write(to: file)
}

private final class EventRecorder: @unchecked Sendable {
  private let lock = NSLock()
  private(set) var events: [ModelLoadEvent] = []

  func append(_ event: ModelLoadEvent) {
    lock.withLock {
      events.append(event)
    }
  }
}
