import AppKit
import SwiftUI

@MainActor
final class OverlayController {
  private let panel: NSPanel

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
  }

  func update(_ state: ShuoState) {
    guard state.showsOverlay else {
      panel.orderOut(nil)
      return
    }
    panel.contentView = NSHostingView(rootView: OverlayBubble(state: state))
    position()
    panel.orderFrontRegardless()
  }

  private func position() {
    let screen = NSScreen.main ?? NSScreen.screens.first
    guard let frame = screen?.visibleFrame else { return }
    panel.setFrameOrigin(
      NSPoint(x: frame.midX - panel.frame.width / 2, y: frame.minY + 72)
    )
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
