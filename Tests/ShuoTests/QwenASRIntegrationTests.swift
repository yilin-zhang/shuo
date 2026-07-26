import AVFoundation
import Foundation
import Testing

@testable import Shuo

@Test
@MainActor
func qwenTranscribesWithModelContextWhenIntegrationFixtureIsAvailable() async throws {
  let environment = ProcessInfo.processInfo.environment
  guard environment["SHUO_RUN_QWEN_INTEGRATION"] == "1",
    let audioPath = environment["SHUO_QWEN_AUDIO_FIXTURE"],
    let terminology = environment["SHUO_QWEN_TERMINOLOGY"],
    let expectedText = environment["SHUO_QWEN_EXPECTED_TEXT"]
  else { return }

  let engine = NativeASREngine()
  try await engine.load(modelID: ASRBackend.qwenModelID)
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
  let buffer = AVAudioPCMBuffer(
    pcmFormat: file.processingFormat,
    frameCapacity: frameCount
  )!
  try file.read(into: buffer)
  return Array(
    UnsafeBufferPointer(
      start: buffer.floatChannelData![0],
      count: Int(buffer.frameLength)
    )
  )
}

private enum QwenIntegrationFixtureError: Error {
  case requires16kMono
}
