import Foundation
import MLX
import MLXAudioSTT

struct QwenStreamingUpdate: Sendable {
  let stableText: String
  let previewText: String
}

@MainActor
final class QwenStreamingEngine {
  typealias UpdateHandler = @MainActor @Sendable (QwenStreamingUpdate) -> Void

  private struct ActiveSegment {
    let id = UUID()
    var audio = [Float]()
    var agreement = StreamingAgreement()
    var latestHypothesis = ""
    var lastRequestedSampleCount = 0
  }

  private struct FinalSegment {
    let id: UUID
    let audio: [Float]
    let expectedText: String
  }

  private enum Work {
    case snapshot(id: UUID, audio: [Float], expectedText: String)
    case final(FinalSegment)
  }

  private let qwen: Qwen3ASRModel
  private let aligner: Qwen3ForcedAlignerModel
  private let context: String
  private let updateHandler: UpdateHandler
  private var active = ActiveSegment()
  private var finalQueue = [FinalSegment]()
  private var endpointDetector = EnergyEndpointDetector()
  private var task: Task<Void, Never>?
  private var finishContinuation: CheckedContinuation<String, Error>?
  private var isFinishing = false
  private var committedText = ""
  private var detectedLanguage = "Chinese"
  private var failure: Error?

  private let minimumSnapshotSamples = Int(NativeAudioCapture.sampleRate * 1.5)
  private let snapshotStepSamples = Int(NativeAudioCapture.sampleRate)

  init(
    qwen: Qwen3ASRModel,
    aligner: Qwen3ForcedAlignerModel,
    context: String,
    updateHandler: @escaping UpdateHandler
  ) {
    self.qwen = qwen
    self.aligner = aligner
    self.context = context
    self.updateHandler = updateHandler
  }

  func append(_ samples: [Float]) {
    guard !isFinishing, failure == nil else { return }
    active.audio.append(contentsOf: samples)
    if endpointDetector.consume(samples), active.audio.count >= 1_600 {
      finalQueue.append(
        FinalSegment(
          id: active.id,
          audio: active.audio,
          expectedText: active.latestHypothesis
        ))
      active = ActiveSegment()
      requestWorkIfNeeded()
      return
    }
    requestWorkIfNeeded()
  }

  func finish() async throws -> String {
    guard finishContinuation == nil else { throw ASRError.streamingAlreadyFinishing }
    isFinishing = true
    return try await withCheckedThrowingContinuation { continuation in
      finishContinuation = continuation
      requestWorkIfNeeded()
    }
  }

  func cancel() {
    task?.cancel()
    task = nil
    finishContinuation?.resume(throwing: CancellationError())
    finishContinuation = nil
  }

  private func requestWorkIfNeeded() {
    guard task == nil else { return }
    if let failure {
      finishContinuation?.resume(throwing: failure)
      finishContinuation = nil
      return
    }
    guard let work = nextWork() else {
      completeIfPossible()
      return
    }
    task = Task { [weak self] in
      guard let self else { return }
      do {
        switch work {
        case .snapshot(let id, let audio, let expectedText):
          try await processSnapshot(id: id, audio: audio, expectedText: expectedText)
        case .final(let segment):
          try await processFinal(segment)
        }
      } catch is CancellationError {
      } catch {
        failure = error
      }
      task = nil
      requestWorkIfNeeded()
    }
  }

  private func nextWork() -> Work? {
    if !finalQueue.isEmpty {
      return .final(finalQueue.removeFirst())
    }
    if isFinishing {
      guard !active.audio.isEmpty else { return nil }
      let segment = FinalSegment(
        id: active.id,
        audio: active.audio,
        expectedText: active.latestHypothesis
      )
      active = ActiveSegment()
      return .final(segment)
    }
    guard
      endpointDetector.isSpeaking,
      active.audio.count >= minimumSnapshotSamples,
      active.audio.count - active.lastRequestedSampleCount >= snapshotStepSamples
    else { return nil }
    active.lastRequestedSampleCount = active.audio.count
    return .snapshot(
      id: active.id,
      audio: active.audio,
      expectedText: active.latestHypothesis
    )
  }

  private func processSnapshot(id: UUID, audio: [Float], expectedText: String) async throws {
    let result = try await transcribe(
      audio: audio,
      id: id,
      isFinal: false,
      expectedText: expectedText
    )
    guard active.id == id else { return }
    detectedLanguage = result.language ?? detectedLanguage
    let hypothesis = Self.reconcileBoundary(
      hypothesis: result.text,
      expectedRemainder: expectedText,
      committedText: committedText
    )
    let stablePrefix = active.agreement.compare(with: hypothesis)
    active.latestHypothesis = hypothesis
    guard !stablePrefix.isEmpty else {
      publish(previewSuffix: hypothesis)
      return
    }

    let alignment = try await align(
      audio: audio,
      text: hypothesis,
      language: Self.alignmentLanguage(detectedLanguage)
    )
    guard active.id == id else { return }
    guard
      let commit = Self.commitBoundary(
        hypothesis: hypothesis,
        stablePrefix: stablePrefix,
        items: alignment.items
      )
    else {
      publish(previewSuffix: result.text)
      return
    }

    let trimCount = min(active.audio.count, Int(commit.endTime * NativeAudioCapture.sampleRate))
    guard trimCount > 0 else {
      publish(previewSuffix: result.text)
      return
    }
    active.audio.removeFirst(trimCount)
    active.latestHypothesis = commit.remainingText
    active.agreement.reset(to: commit.remainingText)
    active.lastRequestedSampleCount = 0
    committedText = StreamingTranscriptPresentation.join(committedText, commit.text)
    publish(previewSuffix: commit.remainingText)
    publishStable()
  }

  private func processFinal(_ segment: FinalSegment) async throws {
    guard segment.audio.count >= 1_600 else { return }
    guard EnergyEndpointDetector.rootMeanSquare(segment.audio) > 0.002 else { return }
    let result = try await transcribe(
      audio: segment.audio,
      id: segment.id,
      isFinal: true,
      expectedText: segment.expectedText
    )
    detectedLanguage = result.language ?? detectedLanguage
    let text = Self.reconcileBoundary(
      hypothesis: result.text,
      expectedRemainder: segment.expectedText,
      committedText: committedText
    ).trimmingCharacters(in: .whitespacesAndNewlines)
    guard !text.isEmpty else { return }
    committedText = StreamingTranscriptPresentation.join(committedText, text)
    publish(previewSuffix: "")
    publishStable()
  }

  private func transcribe(
    audio: [Float],
    id: UUID,
    isFinal: Bool,
    expectedText: String
  ) async throws -> STTOutput {
    let model = UnsafeTransfer(value: qwen)
    let stream = model.value.generateStream(
      audio: MLXArray(audio),
      maxTokens: min(1024, max(64, audio.count / 400 + 32)),
      context: context
    )
    var tokenText = ""
    var output: STTOutput?
    for try await event in stream {
      try Task.checkCancellation()
      switch event {
      case .token(let token):
        tokenText += token
        if isFinal || active.id == id {
          publish(
            previewSuffix: Self.reconcileBoundary(
              hypothesis: tokenText,
              expectedRemainder: expectedText,
              committedText: committedText
            ))
        }
      case .result(let result):
        output = result
      case .info:
        break
      }
    }
    guard let output else { throw ASRError.noSpeechDetected }
    return output
  }

  private func align(audio: [Float], text: String, language: String) async throws
    -> ForcedAlignResult
  {
    let model = UnsafeTransfer(value: aligner)
    return await Task.detached(priority: .userInitiated) {
      model.value.generate(audio: MLXArray(audio), text: text, language: language)
    }.value
  }

  private func publish(previewSuffix: String) {
    updateHandler(
      QwenStreamingUpdate(
        stableText: committedText,
        previewText: StreamingTranscriptPresentation.join(committedText, previewSuffix)
      )
    )
  }

  private func publishStable() {
    updateHandler(QwenStreamingUpdate(stableText: committedText, previewText: committedText))
  }

  private func completeIfPossible() {
    guard isFinishing, task == nil, finalQueue.isEmpty, active.audio.isEmpty else { return }
    guard let continuation = finishContinuation else { return }
    finishContinuation = nil
    if let failure {
      continuation.resume(throwing: failure)
    } else if committedText.isEmpty {
      continuation.resume(throwing: ASRError.noSpeechDetected)
    } else {
      continuation.resume(returning: committedText)
    }
  }

  struct CommitBoundary {
    let text: String
    let remainingText: String
    let endTime: Double
  }

  static func commitBoundary(
    hypothesis: String,
    stablePrefix: String,
    items: [ForcedAlignItem]
  ) -> CommitBoundary? {
    let stableSemanticCount = semanticCharacters(stablePrefix).count
    guard stableSemanticCount > 0 else { return nil }
    var semanticCount = 0
    var stableItemCount = 0
    for item in items {
      let next = semanticCount + semanticCharacters(item.text).count
      guard next <= stableSemanticCount else { break }
      semanticCount = next
      stableItemCount += 1
    }

    // Keep one aligned item uncommitted to protect the acoustic boundary.
    let commitCount = stableItemCount - 1
    guard commitCount > 0 else { return nil }
    let committedItems = items.prefix(commitCount)
    guard let last = committedItems.last else { return nil }

    var cursor = hypothesis.startIndex
    var boundary: String.Index?
    for item in committedItems {
      guard
        let range = hypothesis.range(
          of: item.text,
          options: [.caseInsensitive, .diacriticInsensitive],
          range: cursor..<hypothesis.endIndex
        )
      else { return nil }
      boundary = range.upperBound
      cursor = range.upperBound
    }
    guard let boundary else { return nil }
    return CommitBoundary(
      text: String(hypothesis[..<boundary]).trimmingCharacters(in: .whitespacesAndNewlines),
      remainingText: String(hypothesis[boundary...]).trimmingCharacters(
        in: .whitespacesAndNewlines),
      endTime: last.endTime
    )
  }

  static func reconcileBoundary(
    hypothesis: String,
    expectedRemainder: String,
    committedText: String
  ) -> String {
    guard !expectedRemainder.isEmpty, !committedText.isEmpty, !hypothesis.isEmpty else {
      return hypothesis
    }

    let baseline = StreamingAgreement.longestCommonPrefix(hypothesis, expectedRemainder).count
    var best = hypothesis
    var bestScore = baseline
    let maximumOverlap = min(12, committedText.count, hypothesis.count)
    guard maximumOverlap > 0 else { return hypothesis }

    for overlap in 1...maximumOverlap {
      let committedStart = committedText.index(committedText.endIndex, offsetBy: -overlap)
      let hypothesisEnd = hypothesis.index(hypothesis.startIndex, offsetBy: overlap)
      guard committedText[committedStart...] == hypothesis[..<hypothesisEnd] else { continue }
      let candidate = String(hypothesis[hypothesisEnd...])
      let score = StreamingAgreement.longestCommonPrefix(candidate, expectedRemainder).count
      if score > bestScore {
        best = candidate
        bestScore = score
      }
    }
    return best
  }

  private static func semanticCharacters(_ text: String) -> [Character] {
    Array(text.lowercased().filter { $0.isLetter || $0.isNumber })
  }

  private static func alignmentLanguage(_ language: String) -> String {
    switch language.lowercased() {
    case "zh", "chinese", "mandarin": "Chinese"
    case "yue", "cantonese": "Cantonese"
    case "en", "english": "English"
    default: language
    }
  }
}

private struct UnsafeTransfer<Value>: @unchecked Sendable {
  let value: Value
}
