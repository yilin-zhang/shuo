import Foundation
import WhisperKit

@MainActor
final class NativeASREngine {
  private var whisper: WhisperKit?
  private var loadedModelID: String?

  func load(
    modelID: String,
    eventHandler: @Sendable @escaping (ModelLoadEvent) -> Void = { _ in }
  ) async throws {
    guard loadedModelID != modelID || whisper == nil else { return }
    stopRecording()

    let modelFolder: URL
    if Self.isDownloaded(modelID: modelID) {
      modelFolder = Self.modelDirectory(modelID: modelID)
    } else {
      eventHandler(.downloading(0))
      modelFolder = try await WhisperKit.download(
        variant: modelID,
        progressCallback: { progress in
          eventHandler(.downloading(progress.fractionCompleted))
        }
      )
    }
    try Task.checkCancellation()
    eventHandler(.activating)

    let config = WhisperKitConfig(
      modelFolder: modelFolder.path,
      verbose: false,
      prewarm: true,
      load: true,
      download: false
    )
    let loadedWhisper = try await WhisperKit(config)
    try Task.checkCancellation()
    whisper = loadedWhisper
    loadedModelID = modelID
  }

  nonisolated static func isDownloaded(modelID: String) -> Bool {
    isCompleteModelDirectory(modelDirectory(modelID: modelID))
  }

  nonisolated static func isCompleteModelDirectory(_ directory: URL) -> Bool {
    let requiredPaths = [
      directory.appending(path: "config.json"),
      directory.appending(path: "AudioEncoder.mlmodelc/coremldata.bin"),
      directory.appending(path: "TextDecoder.mlmodelc/coremldata.bin"),
      directory.appending(path: "MelSpectrogram.mlmodelc/coremldata.bin"),
    ]
    return requiredPaths.allSatisfy {
      FileManager.default.fileExists(atPath: $0.path)
    }
  }

  nonisolated static func deleteDownloadedModel(modelID: String) throws {
    let directory = modelDirectory(modelID: modelID)
    guard FileManager.default.fileExists(atPath: directory.path) else { return }
    try FileManager.default.removeItem(at: directory)
  }

  func unload() {
    stopRecording()
    whisper = nil
    loadedModelID = nil
  }

  private nonisolated static func modelDirectory(modelID: String) -> URL {
    FileManager.default.homeDirectoryForCurrentUser
      .appending(path: "Documents/huggingface/models/argmaxinc/whisperkit-coreml")
      .appending(path: "openai_whisper-\(modelID)")
  }

  func startRecording() throws {
    guard let whisper else { throw ASRError.modelNotLoaded }
    whisper.audioProcessor.purgeAudioSamples(keepingLast: 0)
    try whisper.audioProcessor.startRecordingLive(inputDeviceID: nil, callback: nil)
  }

  @discardableResult
  func stopRecording() -> [Float] {
    guard let whisper else { return [] }
    whisper.audioProcessor.stopRecording()
    return Array(whisper.audioProcessor.audioSamples)
  }

  func transcribe(_ audio: [Float]) async throws -> String {
    guard let whisper else { throw ASRError.modelNotLoaded }
    guard audio.count >= 1_600 else { throw ASRError.recordingTooShort }
    guard Self.rootMeanSquare(audio) > 0.002 else { throw ASRError.noSpeechDetected }

    let options = DecodingOptions(
      language: nil,
      temperature: 0,
      usePrefillPrompt: false,
      detectLanguage: true
    )
    let results = try await whisper.transcribe(audioArray: audio, decodeOptions: options)
    let text = results.map(\.text).joined(separator: " ")
      .trimmingCharacters(in: .whitespacesAndNewlines)
    guard !text.isEmpty else { throw ASRError.noSpeechDetected }
    return text
  }

  private static func rootMeanSquare(_ samples: [Float]) -> Float {
    guard !samples.isEmpty else { return 0 }
    let sum = samples.reduce(Float.zero) { $0 + $1 * $1 }
    return sqrt(sum / Float(samples.count))
  }
}

enum ASRError: LocalizedError {
  case modelNotLoaded
  case recordingTooShort
  case noSpeechDetected

  var errorDescription: String? {
    switch self {
    case .modelNotLoaded:
      L10n.string("error.asrLoading")
    case .recordingTooShort:
      L10n.string("error.tooShort")
    case .noSpeechDetected:
      L10n.string("error.noSpeech")
    }
  }
}
