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
    operation: ModelOperation?,
    isDownloaded: Bool,
    isDeleting: Bool = false
  ) -> Self {
    if isDeleting { return .deleting }
    if activeID == id { return .active }
    if operation?.id == id {
      switch operation?.event {
      case .downloading: return .downloading
      case .activating: return .activating
      case nil: break
      }
    }
    return isDownloaded ? .downloaded : .downloadRequired
  }
}

enum ModelKind: Equatable {
  case transcription
  case refine
}

struct ModelOperation: Equatable {
  let token: UUID
  let kind: ModelKind
  let id: String
  let event: ModelLoadEvent
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
  @Published private(set) var modelOperation: ModelOperation?
  @Published private(set) var modelSetupError: String?
  @Published private(set) var isRecordingShortcut = false
  @Published private(set) var needsModelSetup = false
  @Published private(set) var isInitialModelSetup = false
  @Published private var downloadedASRModels = Set<String>()
  @Published private var downloadedRefineModels = Set<String>()
  @Published private var isDiscoveringModels = true
  @Published private var deletingASRModels = Set<String>()
  @Published private var deletingRefineModels = Set<String>()

  let settings = AppSettings()

  var canEnableRefine: Bool {
    activeRefineModel != nil
  }

  var canEnableApp: Bool {
    activeASRModel != nil
  }

  var isManagingModels: Bool {
    isDiscoveringModels || modelOperation != nil || !deletingASRModels.isEmpty
      || !deletingRefineModels.isEmpty
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
    let asrIDs = ModelCatalog.asrModels.map(\.id)
    let refineIDs = ModelCatalog.refineModels.map(\.id)
    let downloadedModels = await Task.detached(priority: .utility) {
      let asr = Set(asrIDs.filter(NativeASREngine.isDownloaded))
      let refine = Set(refineIDs.filter(NativeRefineEngine.isDownloaded))
      return (asr, refine)
    }.value
    downloadedASRModels = downloadedModels.0
    downloadedRefineModels = downloadedModels.1
    isDiscoveringModels = false

    await PermissionManager.requestAll()
    refreshPermissions()
    do {
      try hotkey.start()
      let plan = ModelStartupPlan.resolve(
        hasASR: downloadedASRModels.contains(settings.asrModel),
        hasRefine: downloadedRefineModels.contains(settings.refineModel),
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
    runModelOperation(kind: .transcription, id: settings.asrModel) { [self] token in
      try await loadConfiguredModels(token: token)
    }
  }

  func selectASRModel(_ id: String) {
    runModelOperation(kind: .transcription, id: id) { [self] token in
      try await loadASR(id, token: token)
      settings.asrModel = id
    }
  }

  func selectRefineModel(_ id: String) {
    runModelOperation(kind: .refine, id: id) { [self] token in
      try await loadRefiner(id, token: token)
      settings.refineModel = id
    }
  }

  func installSelectedModels(asrID: String, includeRefine: Bool, refineID: String) {
    modelSetupError = nil
    runModelOperation(kind: .transcription, id: asrID) { [self] token in
      try await loadASR(asrID, token: token)
      settings.asrModel = asrID
      if includeRefine {
        try await loadRefiner(refineID, token: token)
        settings.refineModel = refineID
      }
      settings.refineEnabled = includeRefine
      settings.hasCompletedInitialSetup = true
      needsModelSetup = false
    }
  }

  func deleteASRModel(_ id: String) {
    guard !isManagingModels else { return }
    let status = asrModelStatus(id)
    guard status == .downloaded || status == .active else { return }
    if status == .active {
      modelTask?.cancel()
      settings.enabled = false
      activeASRModel = nil
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
    guard !isManagingModels else { return }
    let status = refineModelStatus(id)
    guard status == .downloaded || status == .active else { return }
    if status == .active {
      modelTask?.cancel()
      settings.refineEnabled = false
      activeRefineModel = nil
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
    guard !state.isDictating, !isManagingModels else { return }
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
      kind: .transcription,
      activeID: activeASRModel,
      isDownloaded: downloadedASRModels.contains(id),
      isDeleting: deletingASRModels.contains(id)
    )
  }

  func refineModelStatus(_ id: String) -> ModelStatus {
    modelStatus(
      id: id,
      kind: .refine,
      activeID: activeRefineModel,
      isDownloaded: downloadedRefineModels.contains(id),
      isDeleting: deletingRefineModels.contains(id)
    )
  }

  func modelDownloadProgress(kind: ModelKind, id: String) -> Double? {
    guard
      modelOperation?.kind == kind,
      modelOperation?.id == id,
      case .downloading(let progress) = modelOperation?.event
    else { return nil }
    return progress
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

  func openPermissionSettings(_ permission: PermissionKind) {
    PermissionManager.openSettings(for: permission)
  }

  func setEnabled(_ enabled: Bool) {
    guard !isManagingModels else { return }
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

  private func loadConfiguredModels(token: UUID) async throws {
    try await loadASR(settings.asrModel, token: token)
    if settings.refineEnabled {
      try await loadRefiner(settings.refineModel, token: token)
    }
  }

  private func requestModelSetup(isInitial: Bool? = nil) {
    isInitialModelSetup = isInitial ?? !settings.hasCompletedInitialSetup
    needsModelSetup = true
    modelSetupError = nil
    transition(to: .disabled)
  }

  private func loadASR(_ id: String, token: UUID) async throws {
    updateOperation(
      token: token,
      kind: .transcription,
      id: id,
      event: downloadedASRModels.contains(id) ? .activating : .downloading(0)
    )
    transition(to: .loading(L10n.string("loading.transcription")))
    let relay = makeEventRelay(token: token, kind: .transcription, id: id)
    try await asr.load(modelID: id, eventHandler: relay.send)
    try Task.checkCancellation()
    guard modelOperation?.token == token else { throw CancellationError() }
    activeASRModel = id
    downloadedASRModels.insert(id)
  }

  private func loadRefiner(_ id: String, token: UUID) async throws {
    updateOperation(
      token: token,
      kind: .refine,
      id: id,
      event: downloadedRefineModels.contains(id) ? .activating : .downloading(0)
    )
    transition(to: .loading(L10n.string("loading.refine")))
    let relay = makeEventRelay(token: token, kind: .refine, id: id)
    try await refiner.load(modelID: id, eventHandler: relay.send)
    try Task.checkCancellation()
    guard modelOperation?.token == token else { throw CancellationError() }
    activeRefineModel = id
    downloadedRefineModels.insert(id)
  }

  private func runModelOperation(
    kind: ModelKind,
    id: String,
    _ operation: @escaping @MainActor (UUID) async throws -> Void
  ) {
    guard !state.isDictating, !isManagingModels else { return }
    let token = UUID()
    modelOperation = ModelOperation(
      token: token,
      kind: kind,
      id: id,
      event: .activating
    )
    modelTask = Task { [weak self] in
      guard let self else { return }
      do {
        try await operation(token)
        try Task.checkCancellation()
        finishModelOperation(token: token)
      } catch is CancellationError {
        cancelModelOperation(token: token)
      } catch {
        failModelOperation(error, token: token)
      }
    }
  }

  private func updateOperation(
    token: UUID,
    kind: ModelKind,
    id: String,
    event: ModelLoadEvent
  ) {
    guard modelOperation?.token == token else { return }
    if case .activating = modelOperation?.event, case .downloading = event {
      return
    }
    if case .downloading(let previous) = modelOperation?.event,
      case .downloading(let current) = event,
      Int(current * 100) <= Int(previous * 100)
    {
      return
    }
    modelOperation = ModelOperation(token: token, kind: kind, id: id, event: event)
  }

  private func makeEventRelay(token: UUID, kind: ModelKind, id: String) -> ModelLoadEventRelay {
    ModelLoadEventRelay { [weak self] event in
      Task { @MainActor in
        self?.updateOperation(token: token, kind: kind, id: id, event: event)
      }
    }
  }

  private func finishModelOperation(token: UUID) {
    guard modelOperation?.token == token else { return }
    modelOperation = nil
    modelTask = nil
    modelSetupError = nil
    transition(to: settings.enabled ? .idle : .disabled)
  }

  private func cancelModelOperation(token: UUID) {
    guard modelOperation?.token == token else { return }
    modelOperation = nil
    modelTask = nil
    transition(to: settings.enabled && canEnableApp ? .idle : .disabled)
  }

  private func failModelOperation(_ error: Error, token: UUID) {
    guard modelOperation?.token == token else { return }
    modelOperation = nil
    modelTask = nil
    if needsModelSetup {
      modelSetupError = error.localizedDescription
    }
    showError(error)
  }

  private func modelStatus(
    id: String,
    kind: ModelKind,
    activeID: String?,
    isDownloaded: Bool,
    isDeleting: Bool
  ) -> ModelStatus {
    ModelStatus.resolve(
      id: id,
      activeID: activeID,
      operation: modelOperation?.kind == kind ? modelOperation : nil,
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
    asr.stopRecording()
    transition(to: .error(error.localizedDescription))
    errorResetTask?.cancel()
    errorResetTask = Task { [weak self] in
      try? await Task.sleep(for: .seconds(2.5))
      guard !Task.isCancelled, let self, case .error = state else { return }
      transition(to: settings.enabled && canEnableApp ? .idle : .disabled)
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
