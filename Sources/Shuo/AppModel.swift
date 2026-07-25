import AppKit
import Combine
import ServiceManagement

enum ModelStatus: Equatable {
  case active
  case downloaded
  case downloadRequired
  case downloading
  case activating
}

@MainActor
final class AppModel: ObservableObject {
  @Published private(set) var state: ShuoState = .loading("transcription model")
  @Published private(set) var microphoneGranted = false
  @Published private(set) var accessibilityGranted = false
  @Published private(set) var inputMonitoringGranted = false
  @Published private(set) var activeASRModel: String?
  @Published private(set) var activeRefineModel: String?
  @Published private(set) var loadingModel: String?
  @Published private(set) var isRecordingShortcut = false
  @Published private var downloadedASRModels = Set(
    ModelCatalog.asrModels.lazy.map(\.id).filter(NativeASREngine.isDownloaded)
  )
  @Published private var downloadedRefineModels = Set(
    ModelCatalog.refineModels.lazy.map(\.id).filter(NativeRefineEngine.isDownloaded)
  )

  let settings = AppSettings()

  private let asr = NativeASREngine()
  private let refiner = NativeRefineEngine()
  private let overlay = OverlayController()
  private var hotkey: HotkeyMonitor!
  private var modelTask: Task<Void, Never>?
  private var errorResetTask: Task<Void, Never>?

  init() {
    hotkey = HotkeyMonitor(shortcut: settings.hotkeyShortcut) {
      [weak self] down in self?.handleHotkey(down: down)
    }
    Task { await prepare() }
  }

  func prepare() async {
    await PermissionManager.requestAll()
    refreshPermissions()
    do {
      try hotkey.start()
      reloadModels()
    } catch {
      showError(error)
    }
  }

  func reloadModels() {
    runModelOperation { [self] in
      try await loadConfiguredModels()
    }
  }

  func selectASRModel(_ id: String) {
    runModelOperation { [self] in
      try await loadASR(id)
      settings.asrModel = id
    }
  }

  func selectRefineModel(_ id: String) {
    runModelOperation { [self] in
      try await loadRefiner(id)
      settings.refineModel = id
    }
  }

  func deleteASRModel(_ id: String) {
    guard asrModelStatus(id) == .downloaded else { return }
    do {
      try NativeASREngine.deleteDownloadedModel(modelID: id)
      downloadedASRModels.remove(id)
    } catch {
      showError(error)
    }
  }

  func deleteRefineModel(_ id: String) {
    guard refineModelStatus(id) == .downloaded else { return }
    do {
      try NativeRefineEngine.deleteDownloadedModel(modelID: id)
      downloadedRefineModels.remove(id)
    } catch {
      showError(error)
    }
  }

  func setRefineEnabled(_ enabled: Bool) {
    guard !state.isDictating else { return }
    if enabled {
      runModelOperation { [self] in
        try await loadRefiner(settings.refineModel)
        settings.refineEnabled = true
      }
    } else {
      modelTask?.cancel()
      settings.refineEnabled = false
      activeRefineModel = nil
      loadingModel = nil
      Task { await refiner.unload() }
      transition(to: settings.enabled ? .idle : .disabled)
    }
  }

  func asrModelStatus(_ id: String) -> ModelStatus {
    modelStatus(
      id: id,
      activeID: activeASRModel,
      isDownloaded: downloadedASRModels.contains(id)
    )
  }

  func refineModelStatus(_ id: String) -> ModelStatus {
    modelStatus(
      id: id,
      activeID: activeRefineModel,
      isDownloaded: downloadedRefineModels.contains(id)
    )
  }

  func applyLaunchAtLogin() {
    do {
      if settings.launchAtLogin {
        try SMAppService.mainApp.register()
      } else {
        try SMAppService.mainApp.unregister()
      }
    } catch {
      showError(error)
    }
  }

  func refreshPermissions() {
    microphoneGranted = PermissionManager.microphoneGranted
    accessibilityGranted = PermissionManager.accessibilityGranted
    inputMonitoringGranted = PermissionManager.inputMonitoringGranted
  }

  func setEnabled(_ enabled: Bool) {
    settings.enabled = enabled
    if !enabled, state == .listening {
      asr.stopRecording()
      transition(to: .disabled)
    } else if !state.isBusy {
      transition(to: enabled ? .idle : .disabled)
    }
  }

  func recordShortcut() {
    isRecordingShortcut = true
    hotkey.recordNextShortcut { [weak self] shortcut in
      guard let self else { return }
      settings.hotkeyShortcut = shortcut
      hotkey.update(shortcut: shortcut)
      isRecordingShortcut = false
    }
  }

  func cancelShortcutRecording() {
    hotkey.cancelRecording()
    isRecordingShortcut = false
  }

  private func loadConfiguredModels() async throws {
    try await loadASR(settings.asrModel)
    if settings.refineEnabled {
      try await loadRefiner(settings.refineModel)
    }
  }

  private func loadASR(_ id: String) async throws {
    loadingModel = id
    transition(to: .loading("transcription model"))
    try await asr.load(modelID: id)
    try Task.checkCancellation()
    activeASRModel = id
    downloadedASRModels.insert(id)
  }

  private func loadRefiner(_ id: String) async throws {
    loadingModel = id
    transition(to: .loading("refine model"))
    try await refiner.load(modelID: id)
    try Task.checkCancellation()
    activeRefineModel = id
    downloadedRefineModels.insert(id)
  }

  private func runModelOperation(
    _ operation: @escaping @MainActor () async throws -> Void
  ) {
    guard !state.isDictating else { return }
    modelTask?.cancel()
    modelTask = Task { [weak self] in
      guard let self else { return }
      do {
        try await operation()
        try Task.checkCancellation()
        finishModelOperation()
      } catch is CancellationError {
        return
      } catch {
        showError(error)
      }
    }
  }

  private func finishModelOperation() {
    loadingModel = nil
    transition(to: settings.enabled ? .idle : .disabled)
  }

  private func modelStatus(
    id: String,
    activeID: String?,
    isDownloaded: Bool
  ) -> ModelStatus {
    if activeID == id { return .active }
    if loadingModel == id { return isDownloaded ? .activating : .downloading }
    return isDownloaded ? .downloaded : .downloadRequired
  }

  private func handleHotkey(down: Bool) {
    guard settings.enabled else { return }
    switch settings.hotkeyMode {
    case .hold:
      down ? startRecordingIfPossible() : stopRecordingIfNeeded()
    case .toggle:
      guard down else { return }
      state == .listening ? stopRecordingIfNeeded() : startRecordingIfPossible()
    }
  }

  private func startRecordingIfPossible() {
    guard state == .idle else { return }
    do {
      try asr.startRecording()
      transition(to: .listening)
    } catch {
      showError(error)
    }
  }

  private func stopRecordingIfNeeded() {
    guard state == .listening else { return }
    let audio = asr.stopRecording()
    Task { await process(audio) }
  }

  private func process(_ audio: [Float]) async {
    do {
      transition(to: .transcribing)
      var text = try await asr.transcribe(audio)
      if settings.refineEnabled {
        transition(to: .refining)
        text = try await refiner.refine(text, prompt: settings.refinePrompt)
      }
      transition(to: .outputting)
      try TextInjector.type(text)
      transition(to: settings.enabled ? .idle : .disabled)
    } catch {
      showError(error)
    }
  }

  private func showError(_ error: Error) {
    loadingModel = nil
    asr.stopRecording()
    transition(to: .error(error.localizedDescription))
    errorResetTask?.cancel()
    errorResetTask = Task { [weak self] in
      try? await Task.sleep(for: .seconds(2.5))
      guard !Task.isCancelled, let self, case .error = state else { return }
      transition(to: settings.enabled ? .idle : .disabled)
    }
  }

  private func transition(to newState: ShuoState) {
    state = newState
    overlay.update(newState)
  }
}

extension ShuoState {
  fileprivate var isBusy: Bool {
    switch self {
    case .listening, .transcribing, .refining, .outputting, .loading:
      true
    default:
      false
    }
  }

  fileprivate var isDictating: Bool {
    switch self {
    case .listening, .transcribing, .refining, .outputting:
      true
    default:
      false
    }
  }
}
