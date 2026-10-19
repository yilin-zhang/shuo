import Foundation
import Testing

@testable import QwenStreaming

@Test
func rollbackUsesTokensAndAvoidsBrokenUnicode() {
  #expect(
    QwenStreamingText.rollback(tokens: [1, 2, 3, 4], count: 1) { ids in
      ids.count == 3 ? "你好\u{fffd}" : "你好"
    } == "你好")
  #expect(QwenStreamingText.rollback(tokens: [1, 2], count: 5) { _ in "unexpected" } == "")
  #expect(QwenStreamingText.transcript("language Chinese<asr_text>人人平等") == "人人平等")
  #expect(QwenStreamingText.transcript("language Chin") == "")
}

@MainActor
private final class Updates {
  var texts = [String]()
}

private actor DecoderProbe {
  struct Call: Sendable {
    let audio: [Float]
    let prefix: String
  }
  var calls = [Call]()
  var blocked: CheckedContinuation<Void, Never>?
  let blockFirst: Bool

  init(blockFirst: Bool = false) { self.blockFirst = blockFirst }

  func decode(_ audio: [Float], _ prefix: String) async -> QwenStreamingResult {
    calls.append(Call(audio: audio, prefix: prefix))
    let index = calls.count
    if blockFirst && index == 1 {
      await withCheckedContinuation { blocked = $0 }
    }
    return QwenStreamingResult(text: "result-\(index)", nextPrefix: "prefix-\(index)")
  }

  func release() {
    blocked?.resume()
    blocked = nil
  }
}

private enum TestError: Error { case timeout, decodeFailed }

@MainActor
private func eventually(_ predicate: () async -> Bool) async throws {
  let deadline = ContinuousClock.now + .seconds(3)
  while !(await predicate()) {
    guard ContinuousClock.now < deadline else { throw TestError.timeout }
    await Task.yield()
  }
}

@Test
@MainActor
func cumulativeAudioAndPrefixRollbackReachTheDecoder() async throws {
  let probe = DecoderProbe()
  let updates = Updates()
  let session = QwenStreamingSession(
    chunkSamples: 2,
    decode: { await probe.decode($0, $1) },
    update: { updates.texts.append($0) }
  )
  session.append([1, 2])
  try await eventually { updates.texts.count == 1 }
  session.append([3, 4])
  try await eventually { updates.texts.count == 2 }
  session.append([5, 6])
  try await eventually { updates.texts.count == 3 }
  let result = try await session.finish(audio: [1, 2, 3, 4, 5, 6, 7])
  let calls = await probe.calls
  #expect(calls.map(\.prefix) == ["", "", "prefix-2", "prefix-3"])
  #expect(
    calls.map(\.audio) == [[1, 2], [1, 2, 3, 4], [1, 2, 3, 4, 5, 6], [1, 2, 3, 4, 5, 6, 7]])
  #expect(result == "result-4")
}

@Test
@MainActor
func finalCaptureIncludesUndeliveredTailWhilePreviewIsInFlight() async throws {
  let probe = DecoderProbe(blockFirst: true)
  let session = QwenStreamingSession(
    chunkSamples: 2, decode: { await probe.decode($0, $1) }, update: { _ in }
  )
  session.append([1, 2])
  try await eventually { await probe.calls.count == 1 }
  session.append([3, 4, 5, 6])
  let finish = Task { try await session.finish(audio: [1, 2, 3, 4, 5, 6, 7]) }
  await Task.yield()
  await probe.release()
  _ = try await finish.value
  let calls = await probe.calls
  #expect(calls.last?.audio == [1, 2, 3, 4, 5, 6, 7])
  #expect(calls.count <= 3)
}

@Test
@MainActor
func shortUtteranceStillDecodesAtFinishAndSessionCannotBeReused() async throws {
  let probe = DecoderProbe()
  let session = QwenStreamingSession(
    chunkSamples: 32_000, decode: { await probe.decode($0, $1) }, update: { _ in }
  )
  session.append([1])
  _ = try await session.finish()
  #expect(await probe.calls.count == 1)
  await #expect(throws: QwenStreamingError.closed) { try await session.finish() }
}

@Test
@MainActor
func cancellationResumesFinishAndDiscardsLateResults() async throws {
  let probe = DecoderProbe(blockFirst: true)
  let updates = Updates()
  let session = QwenStreamingSession(
    chunkSamples: 2, decode: { await probe.decode($0, $1) },
    update: { updates.texts.append($0) }
  )
  let finish = Task { try await session.finish(audio: [1, 2]) }
  try await eventually { await probe.calls.count == 1 }
  session.cancel()
  await probe.release()
  await #expect(throws: CancellationError.self) { try await finish.value }
  #expect(updates.texts.isEmpty)
}

@Test
@MainActor
func decodingFailureReachesFinish() async {
  let session = QwenStreamingSession(
    decode: { _, _ in throw TestError.decodeFailed }, update: { _ in }
  )
  await #expect(throws: TestError.decodeFailed) { try await session.finish(audio: [1]) }
}
