import Foundation
import MLX
import MLXAudioSTT

/// A model adapter for the Qwen cumulative-audio streaming algorithm.
/// The caller must reserve the supplied model for this session until decoding ends.
public final class QwenMLXDecoder: @unchecked Sendable {
  private let model: Qwen3ASRModel
  private let context: String
  private let rollbackTokens: Int

  public init(model: Qwen3ASRModel, context: String = "", rollbackTokens: Int = 5) {
    self.model = model
    self.context = context
    self.rollbackTokens = rollbackTokens
  }

  public func decode(audio: [Float], prefix: String) async throws -> QwenStreamingResult {
    let worker = Task.detached(priority: .userInitiated) { [self] in
      try generate(audio: audio, prefix: prefix)
    }
    return try await withTaskCancellationHandler {
      try await worker.value
    } onCancel: {
      worker.cancel()
    }
  }

  private func generate(audio: [Float], prefix: String) throws -> QwenStreamingResult {
    try Task.checkCancellation()
    guard let tokenizer = model.tokenizer else { throw QwenStreamingError.tokenizerUnavailable }
    guard audio.count >= 1_600 else { return QwenStreamingResult(text: "", nextPrefix: "") }
    let energy = audio.reduce(Float.zero) { $0 + $1 * $1 } / Float(audio.count)
    guard energy > 0.000004 else { return QwenStreamingResult(text: "", nextPrefix: "") }

    let (features, mask, audioTokenCount) = model.preprocessAudio(MLXArray(audio))
    let baseIDs = model.buildPrompt(numAudioTokens: audioTokenCount, context: context)
    // Re-tokenize the full prompt, matching the official prompt + prefix behavior.
    let prompt = tokenizer.decode(tokens: baseIDs.asArray(Int32.self).map(Int.init)) + prefix
    let ids = MLXArray(tokenizer.encode(text: prompt).map(Int32.init)).expandedDimensions(axis: 0)
    // New audio changes the multimodal prefix. Never reuse a previous decode's KV cache.
    let cache = model.makeCache()
    var logits = model(
      inputIds: ids, inputFeatures: features, featureAttentionMask: mask, cache: cache
    )
    eval(logits)
    try Task.checkCancellation()
    var tokens = [Int]()
    let limit = min(8192, max(256, audio.count / 400 + 64))
    var ended = false
    for _ in 0..<limit {
      try Task.checkCancellation()
      let token = logits[0..., -1, 0...].argMax(axis: -1).item(Int.self)
      if token == 151645 || token == 151643 {
        ended = true
        break
      }
      tokens.append(token)
      logits = model(inputIds: MLXArray([Int32(token)]).expandedDimensions(axis: 0), cache: cache)
      eval(logits)
    }
    // Do not silently treat a token-budget cutoff as a complete transcription.
    guard ended else { throw QwenStreamingError.generationLimit }
    let raw = prefix + tokenizer.decode(tokens: tokens)
    let nextPrefix = QwenStreamingText.rollback(
      tokens: tokenizer.encode(text: raw), count: rollbackTokens,
      decode: { tokenizer.decode(tokens: $0) }
    )
    return QwenStreamingResult(text: QwenStreamingText.transcript(raw), nextPrefix: nextPrefix)
  }
}
