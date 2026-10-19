@preconcurrency import AVFoundation
import Accelerate
import Foundation

final class NativeAudioCapture: @unchecked Sendable {
  static let sampleRate = 16_000.0

  private let lock = NSLock()
  private var engine: AVAudioEngine?
  private var converter: AVAudioConverter?
  private var samples = [Float]()
  private var bufferHandler: (@Sendable ([Float]) -> Void)?

  func start(bufferHandler: (@Sendable ([Float]) -> Void)? = nil) throws {
    stop()

    let engine = AVAudioEngine()
    let input = engine.inputNode
    let inputFormat = input.outputFormat(forBus: 0)
    guard
      inputFormat.sampleRate > 0,
      let outputFormat = AVAudioFormat(
        commonFormat: .pcmFormatFloat32,
        sampleRate: Self.sampleRate,
        channels: 1,
        interleaved: false
      ),
      let converter = AVAudioConverter(from: inputFormat, to: outputFormat)
    else {
      throw NativeAudioCaptureError.unavailable
    }

    lock.lock()
    samples.removeAll(keepingCapacity: true)
    self.engine = engine
    self.converter = converter
    self.bufferHandler = bufferHandler
    lock.unlock()

    input.installTap(
      onBus: 0,
      bufferSize: 1_600,
      format: inputFormat
    ) { [weak self] buffer, _ in
      self?.consume(buffer, outputFormat: outputFormat)
    }
    engine.prepare()
    try engine.start()
  }

  @discardableResult
  func stop() -> [Float] {
    lock.lock()
    let engine = self.engine
    self.engine = nil
    converter = nil
    bufferHandler = nil
    let result = samples
    lock.unlock()

    if let engine {
      engine.inputNode.removeTap(onBus: 0)
      engine.stop()
    }
    return result
  }

  private func consume(_ input: AVAudioPCMBuffer, outputFormat: AVAudioFormat) {
    // Serialize conversion and sample commit with stop(), so the final snapshot
    // cannot lose a buffer that was already being converted.
    let delivery = lock.withLock { () -> ([Float], (@Sendable ([Float]) -> Void)?)? in
      guard let converter, engine != nil else { return nil }
      let ratio = outputFormat.sampleRate / input.format.sampleRate
      let capacity = AVAudioFrameCount(ceil(Double(input.frameLength) * ratio)) + 16
      guard let output = AVAudioPCMBuffer(pcmFormat: outputFormat, frameCapacity: capacity) else {
        return nil
      }
      let provider = AudioInputProvider(input)
      var conversionError: NSError?
      let status = converter.convert(to: output, error: &conversionError) { _, state in
        provider.next(state: state)
      }
      guard status != .error, conversionError == nil, let channel = output.floatChannelData?[0]
      else { return nil }
      let chunk = Array(UnsafeBufferPointer(start: channel, count: Int(output.frameLength)))
      guard !chunk.isEmpty else { return nil }
      samples.append(contentsOf: chunk)
      return (chunk, bufferHandler)
    }
    if let (chunk, handler) = delivery { handler?(chunk) }
  }
}

private final class AudioInputProvider: @unchecked Sendable {
  private let lock = NSLock()
  private let input: AVAudioPCMBuffer
  private var supplied = false

  init(_ input: AVAudioPCMBuffer) {
    self.input = input
  }

  func next(state: UnsafeMutablePointer<AVAudioConverterInputStatus>) -> AVAudioBuffer? {
    lock.lock()
    defer { lock.unlock() }
    guard !supplied else {
      state.pointee = .noDataNow
      return nil
    }
    supplied = true
    state.pointee = .haveData
    return input
  }
}

struct EnergyEndpointDetector: Sendable {
  private(set) var isSpeaking = false
  private var noiseFloor: Float = 0.002
  private var voicedSamples = 0
  private var silentSamples = 0

  let startDuration: Double
  let endDuration: Double

  init(startDuration: Double = 0.16, endDuration: Double = 0.36) {
    self.startDuration = startDuration
    self.endDuration = endDuration
  }

  mutating func consume(_ samples: [Float]) -> Bool {
    guard !samples.isEmpty else { return false }
    let rms = Self.rootMeanSquare(samples)
    let threshold = max(0.006, noiseFloor * 3.2)
    let voiced = rms >= threshold

    if !isSpeaking {
      if voiced {
        voicedSamples += samples.count
      } else {
        voicedSamples = 0
        noiseFloor = noiseFloor * 0.96 + rms * 0.04
      }
      if Double(voicedSamples) / NativeAudioCapture.sampleRate >= startDuration {
        isSpeaking = true
        silentSamples = 0
      }
      return false
    }

    if voiced {
      silentSamples = 0
    } else {
      silentSamples += samples.count
    }
    if Double(silentSamples) / NativeAudioCapture.sampleRate >= endDuration {
      self = Self(startDuration: startDuration, endDuration: endDuration)
      return true
    }
    return false
  }

  static func rootMeanSquare(_ samples: [Float]) -> Float {
    guard !samples.isEmpty else { return 0 }
    var value: Float = 0
    vDSP_rmsqv(samples, 1, &value, vDSP_Length(samples.count))
    return value
  }
}

enum NativeAudioCaptureError: LocalizedError {
  case unavailable

  var errorDescription: String? {
    L10n.string("error.audioUnavailable")
  }
}
