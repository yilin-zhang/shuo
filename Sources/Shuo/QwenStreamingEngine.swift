import Foundation
import MLXAudioSTT
import QwenStreaming

struct QwenStreamingUpdate: Sendable {
  let stableText: String
  let previewText: String
}

/// Shuo presentation adapter. The reusable engine has no UI or capture dependencies.
@MainActor
final class QwenStreamingEngine {
  typealias UpdateHandler = @MainActor @Sendable (QwenStreamingUpdate) -> Void

  private let session: QwenStreamingSession
  private let updateHandler: UpdateHandler

  init(
    qwen: Qwen3ASRModel,
    context: String,
    updateHandler: @escaping UpdateHandler
  ) {
    self.updateHandler = updateHandler
    let decoder = QwenMLXDecoder(model: qwen, context: context)
    session = QwenStreamingSession(
      decode: { audio, prefix in try await decoder.decode(audio: audio, prefix: prefix) },
      update: { text in
        // A prefix may still change. Refine only the final result, not partial sentences.
        updateHandler(QwenStreamingUpdate(stableText: "", previewText: text))
      }
    )
  }

  func append(_ samples: [Float]) {
    session.append(samples)
  }

  func finish(audio: [Float]) async throws -> String {
    let text = try await session.finish(audio: audio)
    guard !text.isEmpty else { throw ASRError.noSpeechDetected }
    updateHandler(QwenStreamingUpdate(stableText: text, previewText: text))
    return text
  }

  func cancel() {
    session.cancel()
  }
}
