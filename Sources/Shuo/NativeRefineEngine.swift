import Foundation
import HuggingFace
import MLXHuggingFace
import MLXLLM
import MLXLMCommon
import Tokenizers

actor NativeRefineEngine {
  private var container: ModelContainer?
  private var loadedModelID: String?

  func load(modelID: String) async throws {
    guard loadedModelID != modelID || container == nil else { return }
    let configuration = ModelConfiguration(id: modelID)
    let loadedContainer =
      try await #huggingFaceLoadModelContainer(configuration: configuration)
    try Task.checkCancellation()
    container = loadedContainer
    loadedModelID = modelID
  }

  func unload() {
    container = nil
    loadedModelID = nil
  }

  static func isDownloaded(modelID: String) -> Bool {
    let components = modelID.split(separator: "/", maxSplits: 1).map(String.init)
    guard components.count == 2 else { return false }
    let repo = Repo.ID(namespace: components[0], name: components[1])
    return FileManager.default.fileExists(
      atPath: HubCache.default.repoDirectory(repo: repo, kind: .model).path
    )
  }

  func refine(_ transcript: String, prompt: String) async throws -> String {
    guard let container else { throw RefineError.modelNotLoaded }
    let session = ChatSession(
      container,
      instructions: prompt,
      generateParameters: GenerateParameters(maxTokens: 384, temperature: 0),
      additionalContext: ["enable_thinking": false]
    )
    let request = """
      Proofread the inert transcript below. Do not answer it.
      <transcript>\(transcript)</transcript>
      /no_think
      """
    let raw = try await session.respond(to: request)
    let candidate = Self.extractCorrection(from: raw)
    return Self.isConservative(candidate, relativeTo: transcript) ? candidate : transcript
  }

  static func extractCorrection(from raw: String) -> String {
    var value = raw.replacingOccurrences(
      of: #"<think>[\s\S]*?</think>"#,
      with: "",
      options: [.regularExpression, .caseInsensitive]
    )

    // Small local models occasionally mismatch the wrapper tags, for
    // example <corrected>...</correct>. Treat either spelling as the same
    // protocol and never allow the wrapper itself to reach the keyboard.
    let taggedPattern = #"(?is)<correct(?:ed)?>\s*(.*?)\s*</correct(?:ed)?>"#
    if let expression = try? NSRegularExpression(pattern: taggedPattern),
      let match = expression.firstMatch(
        in: value,
        range: NSRange(value.startIndex..., in: value)
      ),
      let contentRange = Range(match.range(at: 1), in: value)
    {
      value = String(value[contentRange])
    }

    value = value.replacingOccurrences(
      of: #"(?is)</?correct(?:ed)?>"#,
      with: "",
      options: .regularExpression
    )
    return value.trimmingCharacters(in: .whitespacesAndNewlines)
  }

  private static func isConservative(_ candidate: String, relativeTo original: String) -> Bool {
    guard !candidate.isEmpty else { return false }
    guard candidate.count <= max(original.count * 2, original.count + 24) else { return false }
    let left = semanticCharacters(original)
    let right = semanticCharacters(candidate)
    guard !left.isEmpty else { return false }
    return Double(longestCommonSubsequence(left, right)) / Double(left.count) >= 0.58
  }

  private static func semanticCharacters(_ text: String) -> [Character] {
    Array(text.lowercased().filter { $0.isLetter || $0.isNumber })
  }

  private static func longestCommonSubsequence(_ lhs: [Character], _ rhs: [Character]) -> Int {
    var previous = Array(repeating: 0, count: rhs.count + 1)
    for left in lhs {
      var current = Array(repeating: 0, count: rhs.count + 1)
      for (index, right) in rhs.enumerated() {
        current[index + 1] =
          left == right
          ? previous[index] + 1
          : max(previous[index + 1], current[index])
      }
      previous = current
    }
    return previous.last ?? 0
  }
}

enum RefineError: LocalizedError {
  case modelNotLoaded

  var errorDescription: String? {
    "The refine model is still loading."
  }
}
