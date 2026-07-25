import Foundation

enum RefineOutcome: Equatable {
  case applied
  case unchanged
  case rejected

  var label: String {
    switch self {
    case .applied: "Refine applied"
    case .unchanged: "No changes"
    case .rejected: "Refine skipped"
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
    case .disabled: "Disabled"
    case .loading(let item): "Loading \(item)…"
    case .idle: "Ready"
    case .listening: "Listening…"
    case .transcribing: "Transcribing…"
    case .refining: "Refining…"
    case .outputting: "Typing…"
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
