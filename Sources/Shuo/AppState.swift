import Foundation

enum RefineOutcome: Equatable {
  case applied
  case unchanged
  case rejected

  var label: String {
    switch self {
    case .applied: L10n.string("refine.applied")
    case .unchanged: L10n.string("refine.unchanged")
    case .rejected: L10n.string("refine.skipped")
    }
  }

  var symbol: String {
    switch self {
    case .applied: "checkmark.circle.fill"
    case .unchanged: "equal.circle"
    case .rejected: "exclamationmark.triangle.fill"
    }
  }
}

enum ShuoState: Equatable {
  case disabled
  case loading(String)
  case idle
  case listening
  case transcribing
  case refining
  case outputting
  case error(String)

  var label: String {
    switch self {
    case .disabled: L10n.string("state.disabled")
    case .loading(let item): L10n.format("state.loading", item)
    case .idle: L10n.string("state.ready")
    case .listening: L10n.string("state.listening")
    case .transcribing: L10n.string("state.transcribing")
    case .refining: L10n.string("state.refining")
    case .outputting: L10n.string("state.typing")
    case .error(let message): message
    }
  }

  var symbol: String {
    switch self {
    case .disabled: "mic.slash"
    case .loading: "arrow.trianglehead.2.clockwise.rotate.90"
    case .idle: "waveform"
    case .listening: "mic.fill"
    case .transcribing: "text.bubble"
    case .refining: "sparkles"
    case .outputting: "keyboard"
    case .error: "exclamationmark.triangle.fill"
    }
  }

  var showsOverlay: Bool {
    switch self {
    case .listening, .transcribing, .refining, .outputting, .error:
      true
    default:
      false
    }
  }
}
