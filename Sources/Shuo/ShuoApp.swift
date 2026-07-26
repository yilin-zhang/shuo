import AppKit
import SwiftUI

final class AppDelegate: NSObject, NSApplicationDelegate {
  private var lifetimeActivity: NSObjectProtocol?

  override init() {
    super.init()
    ProcessInfo.processInfo.disableAutomaticTermination(
      "Shuo must remain available as a menu bar dictation service"
    )
    ProcessInfo.processInfo.disableSuddenTermination()
    lifetimeActivity = ProcessInfo.processInfo.beginActivity(
      options: [.automaticTerminationDisabled, .suddenTerminationDisabled],
      reason: "Shuo is an always-available menu bar dictation service"
    )
  }

  func applicationShouldTerminateAfterLastWindowClosed(_ sender: NSApplication) -> Bool {
    false
  }
}

@main
struct ShuoApp: App {
  @NSApplicationDelegateAdaptor(AppDelegate.self) private var appDelegate
  @StateObject private var model = AppModel()

  var body: some Scene {
    MenuBarExtra {
      MenuContent(model: model)
    } label: {
      ShuoStatusIcon(state: model.state)
        .background(ModelSetupLauncher(model: model))
    }
    .menuBarExtraStyle(.window)

    Window(L10n.string("setup.title"), id: "model-setup") {
      ModelSetupView(model: model)
    }
    .defaultLaunchBehavior(.suppressed)
    .windowResizability(.contentSize)

    Settings {
      SettingsView(model: model)
    }
  }
}

private struct ModelSetupLauncher: View {
  @ObservedObject var model: AppModel
  @Environment(\.openWindow) private var openWindow

  var body: some View {
    Color.clear
      .frame(width: 0, height: 0)
      .onAppear(perform: openIfNeeded)
      .onChange(of: model.needsModelSetup) { _, _ in openIfNeeded() }
  }

  private func openIfNeeded() {
    guard model.needsModelSetup else { return }
    openWindow(id: "model-setup")
    NSApplication.shared.activate(ignoringOtherApps: true)
  }
}

private struct ModelSetupView: View {
  @ObservedObject var model: AppModel
  @Environment(\.dismissWindow) private var dismissWindow
  @State private var asrID = ModelCatalog.asrModels[0].id
  @State private var includeRefine = true
  @State private var refineID = ModelCatalog.refineModels[0].id

  var body: some View {
    VStack(alignment: .leading, spacing: 18) {
      VStack(alignment: .leading, spacing: 6) {
        Text(L10n.string("setup.heading"))
          .font(.title2.bold())
        Text(L10n.string("setup.privacy"))
          .foregroundStyle(.secondary)
      }

      Picker(L10n.string("setup.asr"), selection: $asrID) {
        ForEach(ModelCatalog.asrGroups) { group in
          Section(group.title ?? "") {
            ForEach(group.options) { option in
              Text(option.name).tag(option.id)
            }
          }
        }
      }
      .disabled(model.isManagingModels)

      if model.isInitialModelSetup {
        Divider()
        Toggle(L10n.string("setup.downloadRefine"), isOn: $includeRefine)
          .disabled(model.isManagingModels)
        if includeRefine {
          Picker(L10n.string("setup.refine"), selection: $refineID) {
            ForEach(ModelCatalog.refineModels) { option in
              Text("\(option.name) — \(option.detail)").tag(option.id)
            }
          }
          .disabled(model.isManagingModels)
        }
      }

      if let operation = model.modelOperation {
        ModelOperationProgress(operation: operation)
      }
      if let error = model.modelSetupError {
        Text(error)
          .font(.caption)
          .foregroundStyle(.red)
      }

      HStack {
        Spacer()
        Button(L10n.string("setup.continue")) {
          model.installSelectedModels(
            asrID: asrID,
            includeRefine: model.isInitialModelSetup && includeRefine,
            refineID: refineID
          )
        }
        .keyboardShortcut(.defaultAction)
        .disabled(model.isManagingModels)
      }
    }
    .padding(24)
    .frame(width: 480)
    .interactiveDismissDisabled()
    .onChange(of: model.needsModelSetup) { _, needsSetup in
      if !needsSetup {
        dismissWindow(id: "model-setup")
      }
    }
  }
}

private struct MenuContent: View {
  @ObservedObject var model: AppModel
  @ObservedObject private var settings: AppSettings
  @Environment(\.openSettings) private var openSettings

  init(model: AppModel) {
    self.model = model
    settings = model.settings
  }

  var body: some View {
    VStack(alignment: .leading, spacing: 14) {
      HStack {
        ShuoStatusIcon(state: model.state)
          .font(.title2)
        VStack(alignment: .leading) {
          Text("Shuo").font(.headline)
          Text(model.state.label)
            .font(.caption)
            .foregroundStyle(.secondary)
        }
        Spacer()
        Toggle(
          "",
          isOn: Binding(
            get: { settings.enabled && model.canEnableApp },
            set: { model.setEnabled($0) }
          )
        )
        .labelsHidden()
        .toggleStyle(.switch)
        .disabled(!model.canEnableApp || model.isManagingModels)
      }

      Text(shortcutHelp)
        .font(.caption)
        .foregroundStyle(.secondary)

      Divider()
      Button {
        openSettings()
        NSApplication.shared.activate(ignoringOtherApps: true)
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.1) {
          NSApplication.shared.windows
            .first(where: { $0.canBecomeKey && !($0 is NSPanel) })?
            .makeKeyAndOrderFront(nil)
        }
      } label: {
        Label(L10n.string("menu.settings"), systemImage: "gear")
      }
      Button {
        model.reloadModels()
      } label: {
        Label(L10n.string("menu.reload"), systemImage: "arrow.clockwise")
      }
      .disabled(model.isManagingModels)
      Divider()
      Button {
        NSApplication.shared.terminate(nil)
      } label: {
        Label(L10n.string("menu.quit"), systemImage: "power")
      }
    }
    .padding(16)
    .frame(width: 290)
  }

  private var shortcutHelp: String {
    switch settings.hotkeyMode {
    case .hold:
      L10n.format("menu.holdHelp", settings.hotkeyShortcut.label)
    case .toggle:
      L10n.format("menu.toggleHelp", settings.hotkeyShortcut.label)
    }
  }
}

private struct SettingsView: View {
  @ObservedObject var model: AppModel
  @ObservedObject private var settings: AppSettings
  @State private var pendingModelDeletion: ModelDeletion?

  init(model: AppModel) {
    self.model = model
    settings = model.settings
  }

  var body: some View {
    Form {
      Section(L10n.string("settings.models")) {
        ModelList(
          title: L10n.string("settings.transcription"),
          groups: ModelCatalog.asrGroups,
          interactionsDisabled: model.isManagingModels,
          status: model.asrModelStatus,
          progress: { model.modelDownloadProgress(kind: .transcription, id: $0) }
        ) { option in
          pendingModelDeletion = ModelDeletion(
            id: option.id,
            name: option.name,
            kind: .transcription
          )
        } select: { option in
          model.selectASRModel(option.id)
        }
        ModelList(
          title: L10n.string("settings.refine"),
          groups: ModelCatalog.refineGroups,
          interactionsDisabled: model.isManagingModels,
          status: model.refineModelStatus,
          progress: { model.modelDownloadProgress(kind: .refine, id: $0) }
        ) { option in
          pendingModelDeletion = ModelDeletion(
            id: option.id,
            name: option.name,
            kind: .refine
          )
        } select: { option in
          model.selectRefineModel(option.id)
        }
        Toggle(
          L10n.string("settings.refineEvery"),
          isOn: Binding(
            get: { settings.refineEnabled },
            set: { model.setRefineEnabled($0) }
          )
        )
        .disabled(!model.canEnableRefine || model.isManagingModels)
        if !model.canEnableRefine {
          Text(L10n.string("settings.refineUnavailable"))
            .font(.caption)
            .foregroundStyle(.secondary)
        }
      }

      if ASRBackend.resolve(modelID: settings.asrModel) == .qwen3 {
        Section(L10n.string("settings.transcriptionTerms")) {
          TerminologyEditor(terms: $settings.transcriptionTerms)
          Text(L10n.string("settings.transcriptionTermsHelp"))
            .font(.caption)
            .foregroundStyle(.secondary)
        }
      }

      Section(L10n.string("settings.refinePrompt")) {
        TextEditor(text: $settings.refinePrompt)
          .font(.system(.body, design: .monospaced))
          .frame(height: 145)
      }

      Section(L10n.string("settings.shortcut")) {
        LabeledContent(L10n.string("settings.key")) {
          HStack {
            Text(
              model.isRecordingShortcut
                ? L10n.string("settings.pressShortcut")
                : settings.hotkeyShortcut.label
            )
            .font(.system(.body, design: .rounded))
            .foregroundStyle(model.isRecordingShortcut ? .orange : .primary)
            Button(
              model.isRecordingShortcut
                ? L10n.string("settings.cancel")
                : L10n.string("settings.recordShortcut")
            ) {
              if model.isRecordingShortcut {
                model.cancelShortcutRecording()
              } else {
                model.recordShortcut()
              }
            }
          }
        }
        Picker(L10n.string("settings.behavior"), selection: $settings.hotkeyMode) {
          ForEach(HotkeyMode.allCases) { mode in
            Text(mode.label).tag(mode)
          }
        }
      }

      Section(L10n.string("settings.system")) {
        Toggle(
          L10n.string("settings.launchAtLogin"),
          isOn: Binding(
            get: { settings.launchAtLogin },
            set: {
              settings.launchAtLogin = $0
              model.applyLaunchAtLogin()
            }
          ))
        PermissionRow(
          L10n.string("settings.microphone"),
          granted: model.microphoneGranted
        ) {
          model.openPermissionSettings(.microphone)
        }
        PermissionRow(
          L10n.string("settings.accessibility"),
          granted: model.accessibilityGranted
        ) {
          model.openPermissionSettings(.accessibility)
        }
        PermissionRow(
          L10n.string("settings.inputMonitoring"),
          granted: model.inputMonitoringGranted
        ) {
          model.openPermissionSettings(.inputMonitoring)
        }
      }

      HStack {
        Button(L10n.string("settings.refreshPermissions")) { model.refreshPermissions() }
        Spacer()
        Button(L10n.string("settings.applyReload")) {
          model.reloadModels()
        }
        .buttonStyle(.borderedProminent)
        .disabled(model.isManagingModels)
      }
    }
    .formStyle(.grouped)
    .padding()
    .frame(
      width: 560,
      height: ASRBackend.resolve(modelID: settings.asrModel) == .qwen3 ? 680 : 560
    )
    .onReceive(NotificationCenter.default.publisher(for: NSApplication.didBecomeActiveNotification))
    {
      _ in
      model.refreshPermissions()
    }
    .alert(
      L10n.string("delete.title"),
      isPresented: Binding(
        get: { pendingModelDeletion != nil },
        set: { if !$0 { pendingModelDeletion = nil } }
      ),
      presenting: pendingModelDeletion
    ) { candidate in
      Button(L10n.string("delete.action"), role: .destructive) {
        switch candidate.kind {
        case .transcription:
          model.deleteASRModel(candidate.id)
        case .refine:
          model.deleteRefineModel(candidate.id)
        }
        pendingModelDeletion = nil
      }
      Button(L10n.string("delete.cancel"), role: .cancel) {
        pendingModelDeletion = nil
      }
    } message: { candidate in
      Text(L10n.format("delete.message", candidate.name))
    }
  }
}

private struct TerminologyEditor: View {
  @Binding var terms: [String]

  var body: some View {
    VStack(alignment: .leading, spacing: 8) {
      if !terms.isEmpty {
        ScrollView {
          LazyVStack(spacing: 6) {
            ForEach(terms.indices, id: \.self) { index in
              HStack {
                TextField("", text: binding(for: index))
                  .textFieldStyle(.roundedBorder)
                Button {
                  terms.remove(at: index)
                } label: {
                  Image(systemName: "minus.circle.fill")
                    .foregroundStyle(.secondary)
                }
                .buttonStyle(.plain)
                .help(L10n.string("settings.removeTranscriptionTerm"))
              }
            }
          }
        }
        .scrollIndicators(.visible)
        .frame(maxHeight: 132)
      }

      Button {
        terms.append("")
      } label: {
        Label(
          L10n.string("settings.addTranscriptionTerm"),
          systemImage: "plus"
        )
      }
      .disabled(terms.last?.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty == true)
    }
  }

  private func binding(for index: Int) -> Binding<String> {
    Binding(
      get: { terms.indices.contains(index) ? terms[index] : "" },
      set: { if terms.indices.contains(index) { terms[index] = $0 } }
    )
  }
}

private struct ModelList: View {
  let title: String
  let groups: [ModelGroup]
  let interactionsDisabled: Bool
  let status: (String) -> ModelStatus
  let progress: (String) -> Double?
  let delete: (ModelOption) -> Void
  let select: (ModelOption) -> Void

  var body: some View {
    VStack(alignment: .leading, spacing: 8) {
      Text(title).font(.headline)
      ForEach(groups) { group in
        VStack(alignment: .leading, spacing: 6) {
          if let groupTitle = group.title {
            Text(groupTitle)
              .font(.caption.weight(.semibold))
              .foregroundStyle(.secondary)
          }
          ScrollView {
            LazyVStack(alignment: .leading, spacing: 8) {
              ForEach(group.options) { option in
                ModelRow(
                  name: option.name,
                  detail: option.detail,
                  state: ModelRowState(
                    status: status(option.id),
                    downloadProgress: progress(option.id),
                    interactionsDisabled: interactionsDisabled
                  ),
                  deleteAction: { delete(option) },
                  action: { select(option) }
                )
              }
            }
          }
          .scrollIndicators(.visible)
          .frame(maxHeight: group.options.count > 3 ? 132 : nil)
          .padding(8)
          .background(.background)
          .clipShape(RoundedRectangle(cornerRadius: 8))
          .overlay {
            RoundedRectangle(cornerRadius: 8)
              .stroke(.separator, lineWidth: 1)
          }
        }
      }
    }
  }
}

private struct ModelDeletion {
  let id: String
  let name: String
  let kind: ModelKind
}

private struct ModelRowState {
  let status: ModelStatus
  let downloadProgress: Double?
  let interactionsDisabled: Bool

  var actionDisabled: Bool {
    interactionsDisabled
      || status == .active
      || status == .downloading
      || status == .activating
      || status == .deleting
  }

  var canDelete: Bool {
    !interactionsDisabled && (status == .downloaded || status == .active)
  }
}

private struct ModelRow: View {
  let name: String
  let detail: String
  let state: ModelRowState
  let deleteAction: () -> Void
  let action: () -> Void

  var body: some View {
    HStack(spacing: 10) {
      Button(action: action) {
        HStack(spacing: 10) {
          statusIcon
            .frame(width: 18)
          VStack(alignment: .leading, spacing: 2) {
            Text(name)
            if !detail.isEmpty {
              Text(detail)
                .font(.caption)
                .foregroundStyle(.secondary)
            }
          }
          Spacer()
          Text(statusLabel)
            .font(.caption)
            .foregroundStyle(state.status == .active ? .green : .secondary)
        }
        .contentShape(Rectangle())
      }
      .buttonStyle(.plain)
      .disabled(state.actionDisabled)

      if state.status == .downloaded || state.status == .active {
        Button(action: deleteAction) {
          Image(systemName: "trash")
            .foregroundStyle(.secondary)
        }
        .buttonStyle(.borderless)
        .disabled(!state.canDelete)
        .help(L10n.string("delete.help"))
      }
    }
    .padding(.vertical, 3)
  }

  private var statusLabel: String {
    guard state.status == .downloading, let progress = state.downloadProgress else {
      return state.status.label
    }
    return L10n.format("model.downloadingProgress", Int(progress * 100))
  }

  @ViewBuilder
  private var statusIcon: some View {
    switch state.status {
    case .active:
      Image(systemName: "checkmark.circle.fill").foregroundStyle(.green)
    case .downloaded:
      Image(systemName: "internaldrive").foregroundStyle(.secondary)
    case .downloadRequired:
      Image(systemName: "arrow.down.circle").foregroundStyle(.secondary)
    case .downloading, .activating, .deleting:
      ProgressView().controlSize(.small)
    }
  }
}

private struct ModelOperationProgress: View {
  let operation: ModelOperation

  var body: some View {
    VStack(alignment: .leading, spacing: 6) {
      switch operation.event {
      case .downloading(let progress):
        Text(L10n.format("model.downloadingProgress", Int(progress * 100)))
          .font(.caption)
          .foregroundStyle(.secondary)
        ProgressView(value: progress)
      case .activating:
        HStack(spacing: 8) {
          ProgressView().controlSize(.small)
          Text(L10n.string("model.activating"))
            .font(.caption)
            .foregroundStyle(.secondary)
        }
      }
    }
  }
}

extension ModelStatus {
  fileprivate var label: String {
    switch self {
    case .active: L10n.string("model.active")
    case .downloaded: L10n.string("model.downloaded")
    case .downloadRequired: L10n.string("model.downloadRequired")
    case .downloading: L10n.string("model.downloading")
    case .activating: L10n.string("model.activating")
    case .deleting: L10n.string("model.deleting")
    }
  }
}

private struct ShuoStatusIcon: View {
  let state: ShuoState

  var body: some View {
    if case .loading = state {
      Image(systemName: "arrow.trianglehead.2.clockwise.rotate.90")
    } else {
      Image(nsImage: MenuBarIcon.image)
    }
  }
}

private enum MenuBarIcon {
  static let image: NSImage = {
    guard
      let url = Bundle.main.url(
        forResource: "ShuoMenuBarIconTemplate",
        withExtension: "png"
      ), let image = NSImage(contentsOf: url)
    else {
      fatalError("ShuoMenuBarIconTemplate.png is missing from the app bundle")
    }
    image.size = NSSize(width: 22, height: 22)
    image.isTemplate = true
    return image
  }()
}

private struct PermissionRow: View {
  let title: String
  let granted: Bool
  let openSettings: () -> Void

  init(_ title: String, granted: Bool, openSettings: @escaping () -> Void) {
    self.title = title
    self.granted = granted
    self.openSettings = openSettings
  }

  var body: some View {
    LabeledContent(title) {
      HStack {
        Label(
          granted ? L10n.string("permission.granted") : L10n.string("permission.required"),
          systemImage: granted ? "checkmark.circle.fill" : "exclamationmark.circle"
        )
        .foregroundStyle(granted ? .green : .orange)
        if !granted {
          Button(L10n.string("permission.openSettings"), action: openSettings)
        }
      }
    }
  }
}
