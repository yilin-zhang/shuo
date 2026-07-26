import ApplicationServices
import CoreGraphics
import Foundation

enum TextInjector {
  static func type(_ text: String) throws {
    guard AXIsProcessTrusted() else {
      throw TextInjectionError.accessibilityPermissionMissing
    }

    for chunk in text.chunked(maxCharacters: 20) {
      var units = Array(chunk.utf16)
      guard
        let keyDown = CGEvent(
          keyboardEventSource: nil,
          virtualKey: 0,
          keyDown: true
        ),
        let keyUp = CGEvent(
          keyboardEventSource: nil,
          virtualKey: 0,
          keyDown: false
        )
      else {
        throw TextInjectionError.eventCreationFailed
      }
      units.withUnsafeMutableBufferPointer { buffer in
        keyDown.keyboardSetUnicodeString(
          stringLength: buffer.count,
          unicodeString: buffer.baseAddress
        )
        keyUp.keyboardSetUnicodeString(
          stringLength: buffer.count,
          unicodeString: buffer.baseAddress
        )
      }
      keyDown.post(tap: .cghidEventTap)
      keyUp.post(tap: .cghidEventTap)
    }
  }
}

enum TextInjectionError: LocalizedError {
  case accessibilityPermissionMissing
  case eventCreationFailed

  var errorDescription: String? {
    switch self {
    case .accessibilityPermissionMissing:
      L10n.string("error.accessibility")
    case .eventCreationFailed:
      L10n.string("error.textEvent")
    }
  }
}

extension String {
  fileprivate func chunked(maxCharacters: Int) -> [String] {
    var chunks: [String] = []
    var start = startIndex
    while start < endIndex {
      let end = index(start, offsetBy: maxCharacters, limitedBy: endIndex) ?? endIndex
      chunks.append(String(self[start..<end]))
      start = end
    }
    return chunks
  }
}
