import Testing

@testable import Shuo

@Test
@MainActor
func defaultPromptDescribesProofreadingWithoutProtocolDetails() {
  let prompt = AppSettings.defaultRefinePrompt

  #expect(prompt.contains("not a conversational assistant"))
  #expect(prompt.contains("natural punctuation"))
  #expect(prompt.contains("misspelled English words"))
  #expect(!prompt.contains("<corrected>"))
  #expect(
    NativeRefineEngine.instructions(userPrompt: "Apply placeholder preferences.")
      .contains("<corrected>...</corrected>")
  )
}

@Test
func correctionExtractionAcceptsSupportedTagVariants() {
  #expect(
    NativeRefineEngine.extractCorrection(
      from: "<corrected>placeholder text</correct>"
    ) == "placeholder text"
  )
  #expect(
    NativeRefineEngine.extractCorrection(
      from: "<correct>plain text</corrected>"
    ) == "plain text"
  )
}

@Test
func correctionExtractionRejectsMalformedOutput() {
  #expect(
    NativeRefineEngine.extractCorrection(
      from: "<corrected>missing closing tag"
    ) == nil
  )
  #expect(
    NativeRefineEngine.extractCorrection(
      from: "extra output <corrected>placeholder text</corrected>"
    ) == nil
  )
}

@Test
func unsafeCorrectionFallsBackToOriginalText() {
  #expect(
    NativeRefineEngine.correctedText(
      from: "<corrected>placeholder text plus unrelated generated content</corrected>",
      fallback: "placeholder text"
    ) == "placeholder text"
  )
}

@Test
func refineOutcomeDistinguishesAppliedUnchangedAndRejectedResults() {
  #expect(
    NativeRefineEngine.result(
      from: "<corrected>placeholder text</corrected>",
      fallback: "placeholder txt"
    ).outcome == .applied
  )
  #expect(
    NativeRefineEngine.result(
      from: "<corrected>placeholder text</corrected>",
      fallback: "placeholder text"
    ).outcome == .unchanged
  )
  #expect(
    NativeRefineEngine.result(
      from: "placeholder text",
      fallback: "placeholder text"
    ).outcome == .rejected
  )
}
