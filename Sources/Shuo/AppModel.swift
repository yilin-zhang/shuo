import AppKit
import Combine
import ServiceManagement

enum ModelStatus: Equatable {
  case active
  case downloaded
  case downloadRequired
  case downloading
  case activating
  case deleting

  static func resolve(
    id: String,
    activeID: String?,
    loadingID: String?,
    isDownloaded: Bool,
    isDeleting: Bool = false
  ) -> Self {
    if isDeleting { return .deleting }
    if activeID == id { return .active }
    if loadingID == id { return isDownloaded ? .activating : .downloading }
    return isDownloaded ? .downloaded : .downloadRequired
  }
}

struct ModelStartupPlan: Equatable {
  let needsSetup: Bool
  let isInitialSetup: Bool
  let shouldDisableRefine: Bool

  static func resolve(
    hasASR: Bool,
    hasRefine: Bool,
    refineEnabled: Bool,
    hasCompletedInitialSetup: Bool
  ) -> Self {
    Self(
      needsSetup: !hasASR,
      isInitialSetup: !hasASR && !hasCompletedInitialSetup,
      shouldDisableRefine: refineEnabled && !hasRefine
    )
  }
}

@MainActor
final class AppModel: ObservableObject {
  @Published private(set) var state: ShuoState = .loading(
    L10n.string("loading.transcription")
  )
  @Published private(set) var microphoneGranted = false
  @Published private(set) var accessibilityGranted = false
  @Published private(set) var inputMonitoringGranted = false
  @Published private(set) var activeASRModel: String?
  @Published private(set) var activeRefineModel: String?
  @Published private(set) var loadingModel: String?
  @Published private(set) var isRecordingShortcut = false
  @Published private(set) var needsModelSetup = false
  @Published private(set) var isInitialModelSetup = false
  @Published private var downloadedASRModels = Set(
    ModelCatalog.asrModels.lazy.map(\.id).filter(NativeASREngine.isDownloaded)
  )
  @Published private var downloadedRefineModels = Set(
    ModelCatalog.refineModels.lazy.map(\.id).filter(NativeRefineEngine.isDownloaded)
  )
  @Published private var deletingASRModels = Set<String>()
  @Published private var deletingRefineModels = Set<String>()

  let settings = AppSettings()

  var canEnableRefine: Bool {
    activeRefineModel != nil
  }

  var canEnableApp: Bool {
    activeASRModel != nil
  }

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
      let plan = ModelStartupPlan.resolve(
        hasASR: NativeASREngine.isDownloaded(modelID: settings.asrModel),
        hasRefine: NativeRefineEngine.isDownloaded(modelID: settings.refineModel),
        refineEnabled: settings.refineEnabled,
        hasCompletedInitialSetup: settings.hasCompletedInitialSetup
      )
      if plan.shouldDisableRefine {
        settings.refineEnabled = false
      }
      if !plan.needsSetup {
        if !settings.hasCompletedInitialSetup {
          settings.hasCompletedInitialSetup = true
        }
        reloadModels()
      } else {
        requestModelSetup(isInitial: plan.isInitialSetup)
      }
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

  func installSelectedModels(asrID: String, includeRefine: Bool, refineID: String) {
    needsModelSetup = false
    settings.hasCompletedInitialSetup = true
    runModelOperation { [self] in
      do {
        try await loadASR(asrID)
        settings.asrModel = asrID
        settings.refineEnabled = includeRefine
        if includeRefine {
          try await loadRefiner(refineID)
          settings.refineModel = refineID
        }
      } catch {
        if activeRefineModel == nil {
          settings.refineEnabled = false
        }
        if !NativeASREngine.isDownloaded(modelID: settings.asrModel) {
          requestModelSetup()
        }
        throw error
      }
    }
  }

  func deleteASRModel(_ id: String) {
    let status = asrModelStatus(id)
    guard status == .downloaded || status == .active else { return }
    if status == .active {
      modelTask?.cancel()
      settings.enabled = false
      activeASRModel = nil
      loadingModel = nil
      transition(to: .disabled)
    }
    deletingASRModels.insert(id)
    Task {
      if status == .active {
        asr.unload()
      }
      do {
        try await Task.detached(priority: .utility) {
          try NativeASREngine.deleteDownloadedModel(modelID: id)
        }.value
        downloadedASRModels.remove(id)
      } catch {
        showError(error)
      }
      deletingASRModels.remove(id)
    }
  }

  func deleteRefineModel(_ id: String) {
    let status = refineModelStatus(id)
    guard status == .downloaded || status == .active else { return }
    if status == .active {
      modelTask?.cancel()
      settings.refineEnabled = false
      activeRefineModel = nil
      loadingModel = nil
      transition(to: settings.enabled ? .idle : .disabled)
    }
    deletingRefineModels.insert(id)
    Task {
      if status == .active {
        await refiner.unload()
      }
      do {
        try await Task.detached(priority: .utility) {
          try NativeRefineEngine.deleteDownloadedModel(modelID: id)
        }.value
        downloadedRefineModels.remove(id)
        if downloadedRefineModels.isEmpty {
          settings.refineEnabled = false
        }
      } catch {
        showError(error)
      }
      deletingRefineModels.remove(id)
    }
  }

  func setRefineEnabled(_ enabled: Bool) {
    guard !state.isDictating else { return }
    if enabled {
      guard canEnableRefine else {
        settings.refineEnabled = false
        return
      }
      settings.refineEnabled = true
      transition(to: settings.enabled ? .idle : .disabled)
    } else {
      settings.refineEnabled = false
      transition(to: settings.enabled ? .idle : .disabled)
    }
  }

  func asrModelStatus(_ id: String) -> ModelStatus {
    modelStatus(
      id: id,
      activeID: activeASRModel,
      isDownloaded: downloadedASRModels.contains(id),
      isDeleting: deletingASRModels.contains(id)
    )
  }

  func refineModelStatus(_ id: String) -> ModelStatus {
    modelStatus(
      id: id,
      activeID: activeRefineModel,
      isDownloaded: downloadedRefineModels.contains(id),
      isDeleting: deletingRefineModels.contains(id)
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
    guard !enabled || canEnableApp else {
      settings.enabled = false
      return
    }
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

  private func requestModelSetup(isInitial: Bool? = nil) {
    isInitialModelSetup = isInitial ?? !settings.hasCompletedInitialSetup
    needsModelSetup = true
    transition(to: .disabled)
  }

  private func loadASR(_ id: String) async throws {
    loadingModel = id
    transition(to: .loading(L10n.string("loading.transcription")))
    try await asr.load(modelID: id)
    try Task.checkCancellation()
    activeASRModel = id
    downloadedASRModels.insert(id)
  }

  private func loadRefiner(_ id: String) async throws {
    loadingModel = id
    transition(to: .loading(L10n.string("loading.refine")))
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
    isDownloaded: Bool,
    isDeleting: Bool
  ) -> ModelStatus {
    ModelStatus.resolve(
      id: id,
      activeID: activeID,
      loadingID: loadingModel,
      isDownloaded: isDownloaded,
      isDeleting: isDeleting
    )
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
      var refineOutcome: RefineOutcome?
      if settings.refineEnabled {
        transition(to: .refining)
        let result = try await refiner.refine(text, prompt: settings.refinePrompt)
        text = result.text
        refineOutcome = result.outcome
      }
      transition(to: .outputting)
      try TextInjector.type(text)
      transition(to: settings.enabled ? .idle : .disabled)
      if let refineOutcome {
        overlay.showRefineOutcome(refineOutcome)
      }
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
