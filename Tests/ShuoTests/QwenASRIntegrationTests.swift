import AVFoundation
import Foundation
import Testing

@testable import Shuo

private let qwenIntegrationEnabled =
  ProcessInfo.processInfo.environment["SHUO_RUN_QWEN_INTEGRATION"] == "1"
private let qwenAlignerIntegrationEnabled =
  ProcessInfo.processInfo.environment["SHUO_RUN_QWEN_ALIGNER_INTEGRATION"] == "1"

@Test(.enabled(if: qwenAlignerIntegrationEnabled))
@MainActor
func qwenStreamingUsesASRModelWithoutCompanion() async throws {
  let engine = NativeASREngine()
  try await engine.load(
    modelID: NativeASREngine.defaultModelID,
    streamingEnabled: true
  )

  #expect(
    NativeASREngine.isReady(
      modelID: NativeASREngine.defaultModelID,
      streamingEnabled: true
    )
  )
}

@Test(.enabled(if: qwenIntegrationEnabled))
@MainActor
func qwenTranscribesWithModelContextWhenIntegrationFixtureIsAvailable() async throws {
  let environment = ProcessInfo.processInfo.environment
  let audioPath = try #require(environment["SHUO_QWEN_AUDIO_FIXTURE"])
  let terminology = try #require(environment["SHUO_QWEN_TERMINOLOGY"])
  let expectedText = try #require(environment["SHUO_QWEN_EXPECTED_TEXT"])

  let engine = NativeASREngine()
  try await engine.load(modelID: NativeASREngine.defaultModelID)
  let text = try await engine.transcribe(
    try loadMonoFloatAudio(URL(fileURLWithPath: audioPath)),
    context: terminology
  )

  #expect(text.contains(terminology))
  #expect(text.contains(expectedText))
}

private func loadMonoFloatAudio(_ url: URL) throws -> [Float] {
  let file = try AVAudioFile(
    forReading: url,
    commonFormat: .pcmFormatFloat32,
    interleaved: false
  )
  guard file.processingFormat.sampleRate == 16_000,
    file.processingFormat.channelCount == 1
  else {
    throw QwenIntegrationFixtureError.requires16kMono
  }
  let frameCount = AVAudioFrameCount(file.length)
  let buffer = try #require(
    AVAudioPCMBuffer(
      pcmFormat: file.processingFormat,
      frameCapacity: frameCount
    ))
  try file.read(into: buffer)
  let channelData = try #require(buffer.floatChannelData)
  return Array(
    UnsafeBufferPointer(
      start: channelData[0],
      count: Int(buffer.frameLength)
    )
  )
}

private enum QwenIntegrationFixtureError: Error {
  case requires16kMono
}
