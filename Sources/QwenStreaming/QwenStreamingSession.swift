import Foundation

public struct QwenStreamingResult: Sendable, Equatable {
  public let text: String
  public let nextPrefix: String

  public init(text: String, nextPrefix: String) {
    self.text = text
    self.nextPrefix = nextPrefix
  }
}

/// One utterance of 16 kHz mono Float PCM. Preview results may be revised.
/// Decodes accumulated audio, carrying a token-rolled-back assistant prefix.
@MainActor
public final class QwenStreamingSession {
  public typealias Decode = @Sendable ([Float], String) async throws -> QwenStreamingResult
  public typealias Update = @MainActor @Sendable (String) -> Void

  private let decode: Decode
  private let update: Update
  private let chunkSamples: Int
  private let unfixedChunks: Int
  private var audio = [Float]()
  private var requestedSamples = 0
  private var decodedChunks = 0
  private var prefix = ""
  private var text = ""
  private var task: Task<Void, Never>?
  private var continuation: CheckedContinuation<String, Error>?
  private var finishing = false
  private var closed = false
  private var failure: Error?

  public init(
    chunkSamples: Int = 32_000,
    unfixedChunks: Int = 2,
    decode: @escaping Decode,
    update: @escaping Update
  ) {
    precondition(chunkSamples > 0 && unfixedChunks >= 0)
    self.chunkSamples = chunkSamples
    self.unfixedChunks = unfixedChunks
    self.decode = decode
    self.update = update
  }

  public func append(_ samples: [Float]) {
    guard !finishing, !closed, failure == nil else { return }
    audio.append(contentsOf: samples)
    schedule()
  }

  /// The capture's complete recording is authoritative: queued UI deliveries may lag.
  /// Always performs a final decode, including a tail shorter than one chunk.
  public func finish(audio completeAudio: [Float]? = nil) async throws -> String {
    guard !finishing, !closed else { throw QwenStreamingError.closed }
    finishing = true
    if let completeAudio { audio = completeAudio }
    return try await withTaskCancellationHandler {
      try await withCheckedThrowingContinuation { continuation in
        self.continuation = continuation
        schedule()
      }
    } onCancel: {
      Task { @MainActor in self.cancel() }
    }
  }

  public func cancel() {
    closed = true
    task?.cancel()
    continuation?.resume(throwing: CancellationError())
    continuation = nil
  }

  private func schedule() {
    guard task == nil, !closed else { return }
    if let failure {
      if let continuation {
        closed = true
        self.continuation = nil
        continuation.resume(throwing: failure)
      }
      return
    }
    let isFinal = finishing
    guard isFinal || audio.count - requestedSamples >= chunkSamples else { return }
    let snapshot = audio
    requestedSamples = snapshot.count
    let promptPrefix = decodedChunks < unfixedChunks ? "" : prefix
    task = Task { [weak self, decode] in
      do {
        let result = try await decode(snapshot, promptPrefix)
        try Task.checkCancellation()
        guard let self, !closed else { return }
        text = result.text
        prefix = result.nextPrefix
        decodedChunks += 1
        update(text)
        task = nil
        if isFinal {
          closed = true
          continuation?.resume(returning: text)
          continuation = nil
        } else {
          schedule()
        }
      } catch {
        guard let self, !closed else { return }
        failure = error
        task = nil
        schedule()
      }
    }
  }
}

public enum QwenStreamingError: Error {
  case closed
  case tokenizerUnavailable
  case generationLimit
}

/// Kept independent of MLX so UTF-8 token-boundary behavior can be tested directly.
public enum QwenStreamingText {
  public static func rollback(
    tokens: [Int], count: Int, decode: ([Int]) -> String
  ) -> String {
    var end = max(0, tokens.count - max(0, count))
    while end > 0 {
      let prefix = decode(Array(tokens.prefix(end)))
      if !prefix.contains("\u{fffd}") { return prefix }
      end -= 1
    }
    return ""
  }

  public static func transcript(_ raw: String) -> String {
    let trimmed = raw.trimmingCharacters(in: .whitespacesAndNewlines)
    if let marker = trimmed.range(of: "<asr_text>") {
      return String(trimmed[marker.upperBound...]).trimmingCharacters(in: .whitespacesAndNewlines)
    }
    // An unfinished language header is not transcription text.
    return trimmed.hasPrefix("language ") ? "" : trimmed
  }
}
