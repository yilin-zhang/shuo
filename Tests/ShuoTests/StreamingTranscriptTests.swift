import MLXAudioSTT
import Testing

@testable import Shuo

@Test
func localAgreementOnlyConfirmsTheSharedPrefix() {
  var agreement = StreamingAgreement()

  #expect(agreement.compare(with: "我们今天讨论一个新") == "")
  #expect(agreement.compare(with: "我们今天讨论一个新的方案") == "我们今天讨论一个新")
  #expect(agreement.compare(with: "今天换了一个开头") == "")
}

@Test
func refinedPrefixDoesNotOverwriteNewASRTokens() {
  var presentation = StreamingTranscriptPresentation()
  presentation.update(
    stable: "今天我们讨论这个方案",
    preview: "今天我们讨论这个方案后面的新内容"
  )
  presentation.applyRefinement("今天我们来讨论这个方案", for: "今天我们讨论这个方案")

  #expect(presentation.displayText == "今天我们来讨论这个方案后面的新内容")
}

@Test
func energyEndpointRequiresSpeechFollowedBySustainedSilence() {
  var detector = EnergyEndpointDetector(startDuration: 0.1, endDuration: 0.2)
  let speech = [Float](repeating: 0.05, count: 1_600)
  let silence = [Float](repeating: 0, count: 1_600)

  let speechEnded = detector.consume(speech)
  #expect(!speechEnded)
  #expect(detector.isSpeaking)
  let firstSilenceEnded = detector.consume(silence)
  #expect(!firstSilenceEnded)
  let secondSilenceEnded = detector.consume(silence)
  #expect(secondSilenceEnded)
  #expect(!detector.isSpeaking)
}

@Test
@MainActor
func alignerBoundaryKeepsOneStableItemForAcousticContext() {
  let boundary = QwenStreamingEngine.commitBoundary(
    hypothesis: "we discuss the new design tomorrow",
    stablePrefix: "we discuss the new design",
    items: [
      ForcedAlignItem(text: "we", startTime: 0, endTime: 0.2),
      ForcedAlignItem(text: "discuss", startTime: 0.2, endTime: 0.6),
      ForcedAlignItem(text: "the", startTime: 0.6, endTime: 0.8),
      ForcedAlignItem(text: "new", startTime: 0.8, endTime: 1.0),
      ForcedAlignItem(text: "design", startTime: 1.0, endTime: 1.4),
      ForcedAlignItem(text: "tomorrow", startTime: 1.4, endTime: 1.8),
    ]
  )

  #expect(boundary?.text == "we discuss the new")
  #expect(boundary?.remainingText == "design tomorrow")
  #expect(boundary?.endTime == 1.0)
}

@Test
@MainActor
func boundaryReconciliationRemovesAcousticOverlap() {
  #expect(
    QwenStreamingEngine.reconcileBoundary(
      hypothesis: "这个挺不错的",
      expectedRemainder: "个挺不错的",
      committedText: "我感觉这"
    ) == "个挺不错的"
  )
  #expect(
    QwenStreamingEngine.reconcileBoundary(
      hypothesis: "什么好办法",
      expectedRemainder: "么好办法",
      committedText: "并没有什"
    ) == "么好办法"
  )
}

@Test
@MainActor
func boundaryReconciliationPreservesRealRepeatedCharacters() {
  #expect(
    QwenStreamingEngine.reconcileBoundary(
      hypothesis: "人平等",
      expectedRemainder: "人平等",
      committedText: "人人"
    ) == "人平等"
  )
}
