import AppKit
import SwiftUI

@MainActor
final class OverlayController {
  private let panel: NSPanel
  private let transcriptPanel: NSPanel
  private var transientTask: Task<Void, Never>?

  init() {
    panel = NSPanel(
      contentRect: NSRect(x: 0, y: 0, width: 210, height: 58),
      styleMask: [.borderless, .nonactivatingPanel],
      backing: .buffered,
      defer: false
    )
    panel.level = .floating
    panel.isOpaque = false
    panel.backgroundColor = .clear
    panel.hasShadow = true
    panel.ignoresMouseEvents = true
    panel.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary]

    transcriptPanel = NSPanel(
      contentRect: NSRect(x: 0, y: 0, width: 560, height: 150),
      styleMask: [.borderless, .nonactivatingPanel],
      backing: .buffered,
      defer: false
    )
    transcriptPanel.level = .floating
    transcriptPanel.isOpaque = false
    transcriptPanel.backgroundColor = .clear
    transcriptPanel.hasShadow = true
    transcriptPanel.ignoresMouseEvents = true
    transcriptPanel.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary]
  }

  func showTranscript(_ text: String) {
    transcriptPanel.contentView = NSHostingView(rootView: TranscriptBubble(text: text))
    positionTranscript()
    transcriptPanel.orderFrontRegardless()
  }

  func hideTranscript() {
    transcriptPanel.orderOut(nil)
  }

  func update(_ state: ShuoState) {
    transientTask?.cancel()
    guard state.showsOverlay else {
      panel.orderOut(nil)
      return
    }
    panel.contentView = NSHostingView(rootView: OverlayBubble(state: state))
    position()
    panel.orderFrontRegardless()
  }

  func showRefineOutcome(_ outcome: RefineOutcome) {
    transientTask?.cancel()
    panel.contentView = NSHostingView(rootView: RefineOutcomeBubble(outcome: outcome))
    position()
    panel.orderFrontRegardless()
    transientTask = Task { [weak self] in
      try? await Task.sleep(for: .seconds(1.2))
      guard !Task.isCancelled else { return }
      self?.panel.orderOut(nil)
    }
  }

  private func position() {
    let screen = NSScreen.main ?? NSScreen.screens.first
    guard let frame = screen?.visibleFrame else { return }
    panel.setFrameOrigin(
      NSPoint(x: frame.midX - panel.frame.width / 2, y: frame.minY + 72)
    )
  }

  private func positionTranscript() {
    let screen = NSScreen.main ?? NSScreen.screens.first
    guard let frame = screen?.visibleFrame else { return }
    transcriptPanel.setFrameOrigin(
      NSPoint(
        x: frame.midX - transcriptPanel.frame.width / 2,
        y: frame.minY + 142
      )
    )
  }
}

private struct TranscriptBubble: View {
  let text: String

  var body: some View {
    ScrollViewReader { proxy in
      ScrollView {
        Text(text.isEmpty ? L10n.string("state.listening") : text)
          .font(.system(size: 20, weight: .medium))
          .foregroundStyle(text.isEmpty ? .secondary : .primary)
          .frame(maxWidth: .infinity, alignment: .leading)
          .textSelection(.disabled)
        Color.clear.frame(height: 1).id("transcript-bottom")
      }
      .contentMargins(20)
      .onAppear { proxy.scrollTo("transcript-bottom", anchor: .bottom) }
      .onChange(of: text) { _, _ in
        proxy.scrollTo("transcript-bottom", anchor: .bottom)
      }
    }
    .frame(width: 560, height: 150)
    .background(.regularMaterial, in: RoundedRectangle(cornerRadius: 18))
    .overlay(RoundedRectangle(cornerRadius: 18).stroke(.white.opacity(0.15)))
    .padding(3)
  }
}

private struct RefineOutcomeBubble: View {
  let outcome: RefineOutcome

  var body: some View {
    HStack(spacing: 11) {
      Image(systemName: outcome.symbol)
        .font(.system(size: 19, weight: .semibold))
        .foregroundStyle(color)
      Text(outcome.label)
        .font(.system(size: 14, weight: .medium))
        .lineLimit(1)
    }
    .padding(.horizontal, 18)
    .frame(width: 210, height: 52)
    .background(.regularMaterial, in: Capsule())
    .overlay(Capsule().stroke(.white.opacity(0.15)))
    .padding(3)
  }

  private var color: Color {
    switch outcome {
    case .applied: .green
    case .unchanged: .secondary
    case .rejected: .orange
    }
  }
}

private struct OverlayBubble: View {
  let state: ShuoState

  var body: some View {
    HStack(spacing: 11) {
      Image(systemName: state.symbol)
        .font(.system(size: 19, weight: .semibold))
        .symbolEffect(.pulse, isActive: state == .listening)
        .foregroundStyle(isError ? Color.red : Color.primary)
      Text(state.label)
        .font(.system(size: 14, weight: .medium))
        .lineLimit(1)
    }
    .padding(.horizontal, 18)
    .frame(width: 210, height: 52)
    .background(.regularMaterial, in: Capsule())
    .overlay(Capsule().stroke(.white.opacity(0.15)))
    .padding(3)
  }

  private var isError: Bool {
    if case .error = state { return true }
    return false
  }
}
