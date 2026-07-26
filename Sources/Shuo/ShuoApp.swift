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
        ForEach(ModelCatalog.asrModels) { option in
          Text(option.name).tag(option.id)
        }
      }

      if model.isInitialModelSetup {
        Divider()
        Toggle(L10n.string("setup.downloadRefine"), isOn: $includeRefine)
        if includeRefine {
          Picker(L10n.string("setup.refine"), selection: $refineID) {
            ForEach(ModelCatalog.refineModels) { option in
              Text("\(option.name) — \(option.detail)").tag(option.id)
            }
          }
        }
      }

      HStack {
        Spacer()
        Button(L10n.string("setup.continue")) {
          model.installSelectedModels(
            asrID: asrID,
            includeRefine: model.isInitialModelSetup && includeRefine,
            refineID: refineID
          )
          dismissWindow(id: "model-setup")
        }
        .keyboardShortcut(.defaultAction)
      }
    }
    .padding(24)
    .frame(width: 480)
    .interactiveDismissDisabled()
  }
}

private struct MenuContent: View {
  @ObservedObject var model: AppModel
  @Environment(\.openSettings) private var openSettings

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
            get: { model.settings.enabled && model.canEnableApp },
            set: { model.setEnabled($0) }
          )
        )
        .labelsHidden()
        .toggleStyle(.switch)
        .disabled(!model.canEnableApp)
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
    switch model.settings.hotkeyMode {
    case .hold:
      L10n.format("menu.holdHelp", model.settings.hotkeyShortcut.label)
    case .toggle:
      L10n.format("menu.toggleHelp", model.settings.hotkeyShortcut.label)
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
          options: ModelCatalog.asrModels,
          status: model.asrModelStatus
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
          options: ModelCatalog.refineModels,
          status: model.refineModelStatus
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
        .disabled(!model.canEnableRefine)
        if !model.canEnableRefine {
          Text(L10n.string("settings.refineUnavailable"))
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
        PermissionRow(L10n.string("settings.microphone"), granted: model.microphoneGranted)
        PermissionRow(L10n.string("settings.accessibility"), granted: model.accessibilityGranted)
        PermissionRow(
          L10n.string("settings.inputMonitoring"), granted: model.inputMonitoringGranted)
      }

      HStack {
        Button(L10n.string("settings.refreshPermissions")) { model.refreshPermissions() }
        Spacer()
        Button(L10n.string("settings.applyReload")) {
          model.reloadModels()
        }
        .buttonStyle(.borderedProminent)
      }
    }
    .formStyle(.grouped)
    .padding()
    .frame(width: 560, height: 560)
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

private struct ModelList: View {
  let title: String
  let options: [ModelOption]
  let status: (String) -> ModelStatus
  let delete: (ModelOption) -> Void
  let select: (ModelOption) -> Void

  var body: some View {
    VStack(alignment: .leading, spacing: 8) {
      Text(title).font(.headline)
      ScrollView {
        LazyVStack(alignment: .leading, spacing: 8) {
          ForEach(options) { option in
            ModelRow(
              name: option.name,
              detail: option.detail,
              status: status(option.id),
              deleteAction: { delete(option) },
              action: { select(option) }
            )
          }
        }
      }
      .scrollIndicators(.visible)
      .frame(maxHeight: 180)
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

private struct ModelDeletion {
  enum Kind {
    case transcription
    case refine
  }

  let id: String
  let name: String
  let kind: Kind
}

private struct ModelRow: View {
  let name: String
  let detail: String
  let status: ModelStatus
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
            Text(detail)
              .font(.caption)
              .foregroundStyle(.secondary)
          }
          Spacer()
          Text(status.label)
            .font(.caption)
            .foregroundStyle(status == .active ? .green : .secondary)
        }
        .contentShape(Rectangle())
      }
      .buttonStyle(.plain)
      .disabled(
        status == .active || status == .downloading || status == .activating
          || status == .deleting
      )

      if status == .downloaded || status == .active {
        Button(action: deleteAction) {
          Image(systemName: "trash")
            .foregroundStyle(.secondary)
        }
        .buttonStyle(.borderless)
        .help(L10n.string("delete.help"))
      }
    }
    .padding(.vertical, 3)
  }

  @ViewBuilder
  private var statusIcon: some View {
    switch status {
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

  init(_ title: String, granted: Bool) {
    self.title = title
    self.granted = granted
  }

  var body: some View {
    LabeledContent(title) {
      Label(
        granted ? L10n.string("permission.granted") : L10n.string("permission.required"),
        systemImage: granted ? "checkmark.circle.fill" : "exclamationmark.circle"
      )
      .foregroundStyle(granted ? .green : .orange)
    }
  }
}
