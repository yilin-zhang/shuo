import Foundation
import HuggingFace
import MLX
import MLXAudioCore
import MLXAudioSTT
import WhisperKit

enum ASRBackend: Equatable {
  case whisper
  case qwen3

  static let qwenModelID = "mlx-community/Qwen3-ASR-0.6B-4bit"

  static func resolve(modelID: String) -> Self {
    modelID == qwenModelID ? .qwen3 : .whisper
  }
}

@MainActor
final class NativeASREngine {
  private let audioProcessor = AudioProcessor()
  private var whisper: WhisperKit?
  private var qwen: Qwen3ASRModel?
  private var loadedModelID: String?

  func load(
    modelID: String,
    eventHandler: @Sendable @escaping (ModelLoadEvent) -> Void = { _ in }
  ) async throws {
    let isLoaded =
      loadedModelID == modelID
      && (ASRBackend.resolve(modelID: modelID) == .whisper ? whisper != nil : qwen != nil)
    guard !isLoaded else { return }
    stopRecording()

    switch ASRBackend.resolve(modelID: modelID) {
    case .whisper:
      try await loadWhisper(modelID: modelID, eventHandler: eventHandler)
    case .qwen3:
      try await loadQwen(modelID: modelID, eventHandler: eventHandler)
    }
    loadedModelID = modelID
  }

  nonisolated static func isDownloaded(modelID: String) -> Bool {
    switch ASRBackend.resolve(modelID: modelID) {
    case .whisper:
      isCompleteWhisperModelDirectory(whisperModelDirectory(modelID: modelID))
    case .qwen3:
      isCompleteQwenModelDirectory(qwenModelDirectory(modelID: modelID))
    }
  }

  nonisolated static func isCompleteWhisperModelDirectory(_ directory: URL) -> Bool {
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

  nonisolated static func isCompleteQwenModelDirectory(_ directory: URL) -> Bool {
    let requiredPaths = [
      directory.appending(path: "config.json"),
      directory.appending(path: "tokenizer_config.json"),
    ]
    guard
      requiredPaths.allSatisfy({
        FileManager.default.fileExists(atPath: $0.path)
      })
    else { return false }
    let files =
      (try? FileManager.default.contentsOfDirectory(
        at: directory,
        includingPropertiesForKeys: [.fileSizeKey]
      )) ?? []
    return files.contains {
      guard $0.pathExtension == "safetensors" else { return false }
      return ((try? $0.resourceValues(forKeys: [.fileSizeKey]).fileSize) ?? 0) > 0
    }
  }

  nonisolated static func deleteDownloadedModel(modelID: String) throws {
    let backend = ASRBackend.resolve(modelID: modelID)
    let directory =
      backend == .qwen3
      ? qwenModelDirectory(modelID: modelID)
      : whisperModelDirectory(modelID: modelID)
    if FileManager.default.fileExists(atPath: directory.path) {
      try FileManager.default.removeItem(at: directory)
    }
    if backend == .qwen3, let repoID = Repo.ID(rawValue: modelID) {
      let hubDirectory = qwenCache.repoDirectory(repo: repoID, kind: .model)
      if FileManager.default.fileExists(atPath: hubDirectory.path) {
        try FileManager.default.removeItem(at: hubDirectory)
      }
    }
  }

  func unload() {
    stopRecording()
    whisper = nil
    qwen = nil
    loadedModelID = nil
  }

  private nonisolated static func whisperModelDirectory(modelID: String) -> URL {
    FileManager.default.homeDirectoryForCurrentUser
      .appending(path: "Documents/huggingface/models/argmaxinc/whisperkit-coreml")
      .appending(path: "openai_whisper-\(modelID)")
  }

  private nonisolated static let qwenCache = HubCache(
    cacheDirectory: FileManager.default.urls(
      for: .applicationSupportDirectory,
      in: .userDomainMask
    )[0].appending(path: "Shuo/Models")
  )

  private nonisolated static func qwenModelDirectory(modelID: String) -> URL {
    qwenCache.cacheDirectory
      .appending(path: "mlx-audio")
      .appending(path: modelID.replacingOccurrences(of: "/", with: "_"))
  }

  func startRecording() throws {
    guard loadedModelID != nil else { throw ASRError.modelNotLoaded }
    audioProcessor.purgeAudioSamples(keepingLast: 0)
    try audioProcessor.startRecordingLive(inputDeviceID: nil, callback: nil)
  }

  @discardableResult
  func stopRecording() -> [Float] {
    audioProcessor.stopRecording()
    return Array(audioProcessor.audioSamples)
  }

  func transcribe(_ audio: [Float], context: String = "") async throws -> String {
    guard let loadedModelID else { throw ASRError.modelNotLoaded }
    guard audio.count >= 1_600 else { throw ASRError.recordingTooShort }
    guard Self.rootMeanSquare(audio) > 0.002 else { throw ASRError.noSpeechDetected }

    let text: String
    switch ASRBackend.resolve(modelID: loadedModelID) {
    case .whisper:
      guard let whisper else { throw ASRError.modelNotLoaded }
      text = try await transcribeWhisper(audio, using: whisper)
    case .qwen3:
      guard let qwen else { throw ASRError.modelNotLoaded }
      let model = UncheckedSendable(value: qwen)
      let maxTokens = min(1024, max(64, audio.count / 400 + 32))
      text = await Task.detached(priority: .userInitiated) {
        model.value.generate(
          audio: MLXArray(audio),
          maxTokens: maxTokens,
          context: context
        ).text
      }.value
    }
    let normalized = text.trimmingCharacters(in: .whitespacesAndNewlines)
    guard !normalized.isEmpty else { throw ASRError.noSpeechDetected }
    return normalized
  }

  private func loadWhisper(
    modelID: String,
    eventHandler: @Sendable @escaping (ModelLoadEvent) -> Void
  ) async throws {
    let modelFolder: URL
    if Self.isDownloaded(modelID: modelID) {
      modelFolder = Self.whisperModelDirectory(modelID: modelID)
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
    let loaded = try await WhisperKit(
      WhisperKitConfig(
        modelFolder: modelFolder.path,
        verbose: false,
        prewarm: true,
        load: true,
        download: false
      )
    )
    try Task.checkCancellation()
    qwen = nil
    whisper = loaded
  }

  private func loadQwen(
    modelID: String,
    eventHandler: @Sendable @escaping (ModelLoadEvent) -> Void
  ) async throws {
    guard let repoID = Repo.ID(rawValue: modelID) else {
      throw ASRError.invalidModelID
    }
    let wasDownloaded = Self.isDownloaded(modelID: modelID)
    if !wasDownloaded {
      eventHandler(.downloading(0))
      let modelDirectory = Self.qwenModelDirectory(modelID: modelID)
      if FileManager.default.fileExists(atPath: modelDirectory.path) {
        try Self.deleteDownloadedModel(modelID: modelID)
      }
    }
    let modelFolder = try await ModelUtils.resolveOrDownloadModel(
      client: HubClient(cache: Self.qwenCache),
      cache: Self.qwenCache,
      repoID: repoID,
      requiredExtension: "safetensors",
      progressHandler: { progress in
        eventHandler(.downloading(progress.fractionCompleted))
      }
    )
    try Task.checkCancellation()
    eventHandler(.activating)
    let loaded = try await Task.detached(priority: .userInitiated) {
      UncheckedSendable(
        value: try await Qwen3ASRModel.fromModelDirectory(modelFolder)
      )
    }.value.value
    try Task.checkCancellation()
    whisper = nil
    qwen = loaded
  }

  private func transcribeWhisper(_ audio: [Float], using whisper: WhisperKit) async throws
    -> String
  {
    let options = DecodingOptions(
      language: nil,
      temperature: 0,
      usePrefillPrompt: false,
      detectLanguage: true
    )
    let results = try await whisper.transcribe(audioArray: audio, decodeOptions: options)
    return results.map(\.text).joined(separator: " ")
  }

  private static func rootMeanSquare(_ samples: [Float]) -> Float {
    guard !samples.isEmpty else { return 0 }
    let sum = samples.reduce(Float.zero) { $0 + $1 * $1 }
    return sqrt(sum / Float(samples.count))
  }
}

enum ASRError: LocalizedError {
  case modelNotLoaded
  case invalidModelID
  case recordingTooShort
  case noSpeechDetected

  var errorDescription: String? {
    switch self {
    case .modelNotLoaded, .invalidModelID:
      L10n.string("error.asrLoading")
    case .recordingTooShort:
      L10n.string("error.tooShort")
    case .noSpeechDetected:
      L10n.string("error.noSpeech")
    }
  }
}

private struct UncheckedSendable<Value>: @unchecked Sendable {
  let value: Value
}
