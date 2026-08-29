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
  nonisolated static let qwenAlignerModelID =
    "mlx-community/Qwen3-ForcedAligner-0.6B-4bit"

  private let audioProcessor = AudioProcessor()
  private let streamingAudioCapture = NativeAudioCapture()
  private var whisper: WhisperKit?
  private var qwen: Qwen3ASRModel?
  private var qwenAligner: Qwen3ForcedAlignerModel?
  private var streamingEngine: QwenStreamingEngine?
  private var loadedModelID: String?

  func load(
    modelID: String,
    streamingEnabled: Bool = false,
    eventHandler: @Sendable @escaping (ModelLoadEvent) -> Void = { _ in }
  ) async throws {
    let isLoaded =
      loadedModelID == modelID
      && (ASRBackend.resolve(modelID: modelID) == .whisper
        ? whisper != nil
        : qwen != nil && (!streamingEnabled || qwenAligner != nil))
    guard !isLoaded else { return }
    stopRecording()

    switch ASRBackend.resolve(modelID: modelID) {
    case .whisper:
      try await loadWhisper(modelID: modelID, eventHandler: eventHandler)
    case .qwen3:
      try await loadQwen(
        modelID: modelID,
        streamingEnabled: streamingEnabled,
        eventHandler: eventHandler
      )
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

  nonisolated static func isReady(modelID: String, streamingEnabled: Bool) -> Bool {
    guard isDownloaded(modelID: modelID) else { return false }
    return ASRBackend.resolve(modelID: modelID) != .qwen3
      || !streamingEnabled
      || isCompleteQwenModelDirectory(qwenModelDirectory(modelID: qwenAlignerModelID))
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
      try deleteQwenModelDirectory(modelID: qwenAlignerModelID)
    }
  }

  private nonisolated static func deleteQwenModelDirectory(modelID: String) throws {
    let directory = qwenModelDirectory(modelID: modelID)
    if FileManager.default.fileExists(atPath: directory.path) {
      try FileManager.default.removeItem(at: directory)
    }
    if let repoID = Repo.ID(rawValue: modelID) {
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
    qwenAligner = nil
    streamingEngine = nil
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
    if let streamingEngine {
      streamingEngine.cancel()
      self.streamingEngine = nil
      return streamingAudioCapture.stop()
    }
    audioProcessor.stopRecording()
    return Array(audioProcessor.audioSamples)
  }

  func startStreaming(
    context: String,
    updateHandler: @escaping QwenStreamingEngine.UpdateHandler
  ) throws {
    guard let qwen, let qwenAligner else { throw ASRError.modelNotLoaded }
    let engine = QwenStreamingEngine(
      qwen: qwen,
      aligner: qwenAligner,
      context: context,
      updateHandler: updateHandler
    )
    streamingEngine = engine
    try streamingAudioCapture.start { [weak engine] samples in
      Task { @MainActor in engine?.append(samples) }
    }
  }

  func finishStreaming() async throws -> String {
    streamingAudioCapture.stop()
    guard let streamingEngine else { throw ASRError.modelNotLoaded }
    defer { self.streamingEngine = nil }
    return try await streamingEngine.finish()
  }

  func setStreamingEnabled(_ enabled: Bool) {
    guard !enabled else { return }
    streamingEngine?.cancel()
    streamingEngine = nil
    qwenAligner = nil
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
    qwenAligner = nil
    whisper = loaded
  }

  private func loadQwen(
    modelID: String,
    streamingEnabled: Bool,
    eventHandler: @Sendable @escaping (ModelLoadEvent) -> Void
  ) async throws {
    guard let repoID = Repo.ID(rawValue: modelID) else {
      throw ASRError.invalidModelID
    }
    let wasDownloaded = Self.isDownloaded(modelID: modelID)
    let qwenEvents: @Sendable (ModelLoadEvent) -> Void = { event in
      guard streamingEnabled else {
        eventHandler(event)
        return
      }
      if case .downloading(let progress) = event {
        eventHandler(.downloading(progress * 0.5))
      }
    }
    if !wasDownloaded {
      qwenEvents(.downloading(0))
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
        qwenEvents(.downloading(progress.fractionCompleted))
      }
    )
    try Task.checkCancellation()
    qwenEvents(.activating)
    let loaded = try await Task.detached(priority: .userInitiated) {
      UncheckedSendable(
        value: try await Qwen3ASRModel.fromModelDirectory(modelFolder)
      )
    }.value.value
    try Task.checkCancellation()
    whisper = nil
    qwen = loaded
    if streamingEnabled {
      try await loadQwenAligner { event in
        switch event {
        case .downloading(let progress):
          eventHandler(.downloading(0.5 + progress * 0.5))
        case .activating:
          eventHandler(.activating)
        }
      }
    } else {
      qwenAligner = nil
    }
  }

  private func loadQwenAligner(
    eventHandler: @Sendable @escaping (ModelLoadEvent) -> Void
  ) async throws {
    guard qwenAligner == nil else { return }
    guard let repoID = Repo.ID(rawValue: Self.qwenAlignerModelID) else {
      throw ASRError.invalidModelID
    }
    let downloaded = Self.isCompleteQwenModelDirectory(
      Self.qwenModelDirectory(modelID: Self.qwenAlignerModelID)
    )
    if !downloaded { eventHandler(.downloading(0)) }
    let folder = try await ModelUtils.resolveOrDownloadModel(
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
      UnsafeSendable(
        value: try await Qwen3ForcedAlignerModel.fromModelDirectory(folder)
      )
    }.value.value
    try Task.checkCancellation()
    qwenAligner = loaded
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
  case streamingAlreadyFinishing

  var errorDescription: String? {
    switch self {
    case .modelNotLoaded, .invalidModelID, .streamingAlreadyFinishing:
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

private struct UnsafeSendable<Value>: @unchecked Sendable {
  let value: Value
}
