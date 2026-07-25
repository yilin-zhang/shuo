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
    }
    .menuBarExtraStyle(.window)

    Settings {
      SettingsView(model: model)
    }
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
            get: { model.settings.enabled },
            set: { model.setEnabled($0) }
          )
        )
        .labelsHidden()
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
        Label("Settings…", systemImage: "gear")
      }
      Button("Reload models") {
        model.reloadModels()
      }
      Divider()
      Button("Quit Shuo") { NSApplication.shared.terminate(nil) }
    }
    .padding(16)
    .frame(width: 290)
  }

  private var shortcutHelp: String {
    switch model.settings.hotkeyMode {
    case .hold:
      "Hold \(model.settings.hotkeyShortcut.label) to speak. Release to type."
    case .toggle:
      "Press \(model.settings.hotkeyShortcut.label) to start. Press again to type."
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
      Section("Models") {
        VStack(alignment: .leading, spacing: 8) {
          Text("Transcription").font(.headline)
          ScrollView {
            LazyVStack(alignment: .leading, spacing: 8) {
              ForEach(ModelCatalog.asrModels) { option in
                ModelRow(
                  name: option.name,
                  detail: option.detail,
                  status: model.asrModelStatus(option.id),
                  deleteAction: {
                    pendingModelDeletion = ModelDeletion(
                      id: option.id,
                      name: option.name,
                      kind: .transcription
                    )
                  }
                ) {
                  model.selectASRModel(option.id)
                }
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
        Divider()
        VStack(alignment: .leading, spacing: 8) {
          Text("Refine").font(.headline)
          ForEach(ModelCatalog.refineModels) { option in
            ModelRow(
              name: option.name,
              detail: option.detail,
              status: model.refineModelStatus(option.id),
              deleteAction: {
                pendingModelDeletion = ModelDeletion(
                  id: option.id,
                  name: option.name,
                  kind: .refine
                )
              }
            ) {
              model.selectRefineModel(option.id)
            }
          }
        }
        Toggle(
          "Refine every transcription",
          isOn: Binding(
            get: { settings.refineEnabled },
            set: { model.setRefineEnabled($0) }
          ))
      }

      Section("Refine prompt") {
        TextEditor(text: $settings.refinePrompt)
          .font(.system(.body, design: .monospaced))
          .frame(height: 145)
      }

      Section("Shortcut") {
        LabeledContent("Key") {
          HStack {
            Text(
              model.isRecordingShortcut
                ? "Press shortcut…"
                : settings.hotkeyShortcut.label
            )
            .font(.system(.body, design: .rounded))
            .foregroundStyle(model.isRecordingShortcut ? .orange : .primary)
            Button(model.isRecordingShortcut ? "Cancel" : "Record Shortcut") {
              if model.isRecordingShortcut {
                model.cancelShortcutRecording()
              } else {
                model.recordShortcut()
              }
            }
          }
        }
        Picker("Behavior", selection: $settings.hotkeyMode) {
          ForEach(HotkeyMode.allCases) { mode in
            Text(mode.label).tag(mode)
          }
        }
      }

      Section("System") {
        Toggle(
          "Launch at login",
          isOn: Binding(
            get: { settings.launchAtLogin },
            set: {
              settings.launchAtLogin = $0
              model.applyLaunchAtLogin()
            }
          ))
        PermissionRow("Microphone", granted: model.microphoneGranted)
        PermissionRow("Accessibility", granted: model.accessibilityGranted)
        PermissionRow("Input Monitoring", granted: model.inputMonitoringGranted)
      }

      HStack {
        Button("Refresh permissions") { model.refreshPermissions() }
        Spacer()
        Button("Apply and reload models") {
          model.reloadModels()
        }
        .buttonStyle(.borderedProminent)
      }
    }
    .formStyle(.grouped)
    .padding()
    .frame(width: 560, height: 560)
    .alert(
      "Delete downloaded model?",
      isPresented: Binding(
        get: { pendingModelDeletion != nil },
        set: { if !$0 { pendingModelDeletion = nil } }
      ),
      presenting: pendingModelDeletion
    ) { candidate in
      Button("Delete", role: .destructive) {
        switch candidate.kind {
        case .transcription:
          model.deleteASRModel(candidate.id)
        case .refine:
          model.deleteRefineModel(candidate.id)
        }
        pendingModelDeletion = nil
      }
      Button("Cancel", role: .cancel) {
        pendingModelDeletion = nil
      }
    } message: { candidate in
      Text("This removes \(candidate.name) from this Mac. You can download it again later.")
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
      .disabled(status == .active || status == .downloading || status == .activating)

      if status == .downloaded {
        Button(action: deleteAction) {
          Image(systemName: "trash")
            .foregroundStyle(.secondary)
        }
        .buttonStyle(.borderless)
        .help("Delete downloaded model")
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
    case .downloading, .activating:
      ProgressView().controlSize(.small)
    }
  }
}

extension ModelStatus {
  fileprivate var label: String {
    switch self {
    case .active: "Active"
    case .downloaded: "Downloaded"
    case .downloadRequired: "Download required"
    case .downloading: "Downloading…"
    case .activating: "Activating…"
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
        granted ? "Granted" : "Required",
        systemImage: granted ? "checkmark.circle.fill" : "exclamationmark.circle"
      )
      .foregroundStyle(granted ? .green : .orange)
    }
  }
}
