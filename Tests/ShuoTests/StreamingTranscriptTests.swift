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
