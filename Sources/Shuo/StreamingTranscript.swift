import Foundation

struct StreamingAgreement: Equatable, Sendable {
  private(set) var previousHypothesis = ""

  mutating func compare(with hypothesis: String) -> String {
    defer { previousHypothesis = hypothesis }
    guard !previousHypothesis.isEmpty, !hypothesis.isEmpty else { return "" }
    return Self.longestCommonPrefix(previousHypothesis, hypothesis)
      .trimmingCharacters(in: .whitespacesAndNewlines)
  }

  mutating func reset(to hypothesis: String = "") {
    previousHypothesis = hypothesis
  }

  static func longestCommonPrefix(_ lhs: String, _ rhs: String) -> String {
    var left = lhs.startIndex
    var right = rhs.startIndex
    while left < lhs.endIndex, right < rhs.endIndex, lhs[left] == rhs[right] {
      left = lhs.index(after: left)
      right = rhs.index(after: right)
    }
    return String(lhs[..<left])
  }
}

struct StreamingTranscriptPresentation: Equatable, Sendable {
  private(set) var rawStableText = ""
  private(set) var rawPreviewText = ""
  private(set) var refinedRawPrefix = ""
  private(set) var refinedPrefix = ""

  var displayText: String {
    guard
      !refinedRawPrefix.isEmpty,
      rawPreviewText.hasPrefix(refinedRawPrefix)
    else { return rawPreviewText }
    return Self.join(
      refinedPrefix,
      String(rawPreviewText.dropFirst(refinedRawPrefix.count))
    )
  }

  mutating func update(stable: String, preview: String) {
    rawStableText = stable
    rawPreviewText = preview
  }

  mutating func applyRefinement(_ refined: String, for rawPrefix: String) {
    guard rawStableText.hasPrefix(rawPrefix) else { return }
    refinedRawPrefix = rawPrefix
    refinedPrefix = refined
  }

  static func join(_ lhs: String, _ rhs: String) -> String {
    guard !lhs.isEmpty else { return rhs }
    guard !rhs.isEmpty else { return lhs }
    let needsSpace =
      lhs.last?.isWhitespace == false
      && rhs.first?.isWhitespace == false
      && lhs.last?.isASCII == true
      && rhs.first?.isASCII == true
      && lhs.last?.isLetter == true
      && rhs.first?.isLetter == true
    return lhs + (needsSpace ? " " : "") + rhs
  }
}
