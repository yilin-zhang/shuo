import AVFoundation
import Foundation
import MLX
import MLXAudioSTT
import Testing

@testable import QwenStreaming

/// Opt-in: uses an already-downloaded model and a 16 kHz mono WAV; no network or microphone.
@Test(.enabled(if: ProcessInfo.processInfo.environment["SHUO_RUN_STREAMING_INTEGRATION"] == "1"))
func mlxStreamingDecodesCumulativeAudioWithPrefixAndTail() async throws {
  let environment = ProcessInfo.processInfo.environment
  let modelPath = try #require(environment["SHUO_STREAMING_MODEL_DIR"])
  let fixturePath = try #require(environment["SHUO_QWEN_AUDIO_FIXTURE"])
  let expected = try #require(environment["SHUO_QWEN_EXPECTED_TEXT"])
  let file = try AVAudioFile(
    forReading: URL(fileURLWithPath: fixturePath), commonFormat: .pcmFormatFloat32,
    interleaved: false
  )
  #expect(file.processingFormat.sampleRate == 16_000)
  #expect(file.processingFormat.channelCount == 1)
  let buffer = try #require(
    AVAudioPCMBuffer(
      pcmFormat: file.processingFormat, frameCapacity: AVAudioFrameCount(file.length)))
  try file.read(into: buffer)
  let samples = Array(
    UnsafeBufferPointer(
      start: try #require(buffer.floatChannelData)[0], count: Int(buffer.frameLength)))
  let model = try await Qwen3ASRModel.fromModelDirectory(URL(fileURLWithPath: modelPath))
  let tokenizer = try #require(model.tokenizer)
  let promptIDs = model.buildPrompt(numAudioTokens: 3, context: "")
  let roundTrip = tokenizer.decode(tokens: promptIDs.asArray(Int32.self).map(Int.init))
  #expect(roundTrip.contains("<|audio_pad|>"))
  #expect(roundTrip.hasSuffix("<|im_start|>assistant\n"))
  let decoder = QwenMLXDecoder(model: model)
  var prefix = ""
  var result = QwenStreamingResult(text: "", nextPrefix: "")
  var index = 0
  for end in stride(from: 32_000, to: samples.count, by: 32_000) {
    let start = ContinuousClock.now
    result = try await decoder.decode(
      audio: Array(samples.prefix(end)), prefix: index < 2 ? "" : prefix)
    print("STREAMING \(end / 16_000)s: \(result.text) [\(ContinuousClock.now - start)]")
    prefix = result.nextPrefix
    index += 1
  }
  result = try await decoder.decode(audio: samples, prefix: index < 2 ? "" : prefix)
  print("STREAMING FINAL: \(result.text)")
  #expect(result.text.contains(expected))
  #expect(!result.text.contains("\u{fffd}"))
  #expect(!result.text.contains("<asr_text>"))
  if let tail = environment["SHUO_QWEN_EXPECTED_TAIL"] {
    #expect(result.text.contains(tail))
  }
}
