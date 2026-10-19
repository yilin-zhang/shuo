import Foundation
import HuggingFace
import MLX
import MLXAudioCore
import MLXAudioSTT

@MainActor
final class NativeASREngine {
  nonisolated static let defaultModelID = "mlx-community/Qwen3-ASR-1.7B-4bit"
  nonisolated static let qwenAlignerModelID =
    "mlx-community/Qwen3-ForcedAligner-0.6B-4bit"

  private let audioCapture = NativeAudioCapture()
  private var qwen: Qwen3ASRModel?
  private var audioDeliveryTask: Task<Void, Never>?
  private var audioDelivery: AsyncStream<[Float]>.Continuation?
  private var streamingEngine: QwenStreamingEngine?
  private var loadedModelID: String?

  func load(
    modelID: String,
    streamingEnabled: Bool = false,
    eventHandler: @Sendable @escaping (ModelLoadEvent) -> Void = { _ in }
  ) async throws {
    let isLoaded =
      loadedModelID == modelID
      && qwen != nil
    guard !isLoaded else { return }
    stopRecording()
    try await loadQwen(
      modelID: modelID,
      streamingEnabled: streamingEnabled,
      eventHandler: eventHandler
    )
    loadedModelID = modelID
  }

  nonisolated static func isDownloaded(modelID: String) -> Bool {
    isCompleteQwenModelDirectory(qwenModelDirectory(modelID: modelID))
  }

  nonisolated static func isReady(modelID: String, streamingEnabled: Bool) -> Bool {
    isDownloaded(modelID: modelID)
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
    let directory = qwenModelDirectory(modelID: modelID)
    if FileManager.default.fileExists(atPath: directory.path) {
      try FileManager.default.removeItem(at: directory)
    }
    if let repoID = Repo.ID(rawValue: modelID) {
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
    qwen = nil
    streamingEngine = nil
    loadedModelID = nil
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
    try audioCapture.start(bufferHandler: nil)
  }

  @discardableResult
  func stopRecording() -> [Float] {
    audioDelivery?.finish()
    audioDelivery = nil
    audioDeliveryTask?.cancel()
    audioDeliveryTask = nil
    if let streamingEngine {
      streamingEngine.cancel()
      self.streamingEngine = nil
      return audioCapture.stop()
    }
    return audioCapture.stop()
  }

  func startStreaming(
    context: String,
    updateHandler: @escaping QwenStreamingEngine.UpdateHandler
  ) throws {
    guard let qwen else { throw ASRError.modelNotLoaded }
    let engine = QwenStreamingEngine(
      qwen: qwen,
      context: context,
      updateHandler: updateHandler
    )
    streamingEngine = engine
    let (stream, delivery) = AsyncStream<[Float]>.makeStream()
    audioDelivery = delivery
    audioDeliveryTask = Task { [weak engine] in
      for await samples in stream {
        guard !Task.isCancelled else { return }
        engine?.append(samples)
      }
    }
    do {
      try audioCapture.start { samples in delivery.yield(samples) }
    } catch {
      stopRecording()
      throw error
    }
  }

  func finishStreaming() async throws -> String {
    let audio = audioCapture.stop()
    audioDelivery?.finish()
    audioDelivery = nil
    audioDeliveryTask?.cancel()
    audioDeliveryTask = nil
    guard let streamingEngine else { throw ASRError.modelNotLoaded }
    defer { self.streamingEngine = nil }
    return try await streamingEngine.finish(audio: audio)
  }

  func setStreamingEnabled(_ enabled: Bool) {
    guard !enabled else { return }
    streamingEngine?.cancel()
    streamingEngine = nil
  }

  func transcribe(_ audio: [Float], context: String = "") async throws -> String {
    guard let qwen else { throw ASRError.modelNotLoaded }
    guard audio.count >= 1_600 else { throw ASRError.recordingTooShort }
    guard Self.rootMeanSquare(audio) > 0.002 else { throw ASRError.noSpeechDetected }

    let model = UncheckedSendable(value: qwen)
    let maxTokens = min(1024, max(64, audio.count / 400 + 32))
    let text = await Task.detached(priority: .userInitiated) {
      model.value.generate(
        audio: MLXArray(audio),
        maxTokens: maxTokens,
        context: context
      ).text
    }.value

    let normalized = text.trimmingCharacters(in: .whitespacesAndNewlines)
    guard !normalized.isEmpty else { throw ASRError.noSpeechDetected }
    return normalized
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
    qwen = loaded
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
