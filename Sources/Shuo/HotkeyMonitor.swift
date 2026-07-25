import CoreGraphics
import Foundation

struct HotkeyShortcut: Codable, Equatable {
  let keyCode: Int64
  let modifierFlags: UInt64
  let modifierOnly: Bool

  static let rightOption = HotkeyShortcut(
    keyCode: 61,
    modifierFlags: CGEventFlags.maskAlternate.rawValue,
    modifierOnly: true
  )

  var label: String {
    if modifierOnly {
      return Self.modifierName(for: keyCode)
    }
    let flags = CGEventFlags(rawValue: modifierFlags)
    var value = ""
    if flags.contains(.maskControl) { value += "⌃" }
    if flags.contains(.maskAlternate) { value += "⌥" }
    if flags.contains(.maskShift) { value += "⇧" }
    if flags.contains(.maskCommand) { value += "⌘" }
    if flags.contains(.maskSecondaryFn) { value += "fn " }
    return value + Self.keyName(for: keyCode)
  }

  fileprivate var flags: CGEventFlags { CGEventFlags(rawValue: modifierFlags) }

  private static func modifierName(for keyCode: Int64) -> String {
    switch keyCode {
    case 54: "Right Command (⌘)"
    case 55: "Left Command (⌘)"
    case 56: "Left Shift (⇧)"
    case 58: "Left Option (⌥)"
    case 59: "Left Control (⌃)"
    case 60: "Right Shift (⇧)"
    case 61: "Right Option (⌥)"
    case 62: "Right Control (⌃)"
    case 63: "Fn"
    default: "Key \(keyCode)"
    }
  }

  private static func keyName(for keyCode: Int64) -> String {
    let names: [Int64: String] = [
      0: "A", 1: "S", 2: "D", 3: "F", 4: "H", 5: "G", 6: "Z", 7: "X",
      8: "C", 9: "V", 11: "B", 12: "Q", 13: "W", 14: "E", 15: "R",
      16: "Y", 17: "T", 18: "1", 19: "2", 20: "3", 21: "4", 22: "6",
      23: "5", 24: "=", 25: "9", 26: "7", 27: "-", 28: "8", 29: "0",
      30: "]", 31: "O", 32: "U", 33: "[", 34: "I", 35: "P", 36: "↩",
      37: "L", 38: "J", 39: "'", 40: "K", 41: ";", 42: "\\", 43: ",",
      44: "/", 45: "N", 46: "M", 47: ".", 48: "⇥", 49: "Space",
      50: "`", 51: "⌫", 53: "Esc", 96: "F5", 97: "F6", 98: "F7",
      99: "F3", 100: "F8", 101: "F9", 103: "F11", 109: "F10",
      111: "F12", 118: "F4", 120: "F2", 122: "F1", 123: "←",
      124: "→", 125: "↓", 126: "↑",
    ]
    return names[keyCode] ?? "Key \(keyCode)"
  }
}

@MainActor
final class HotkeyMonitor {
  typealias Handler = @MainActor (Bool) -> Void
  typealias RecordingHandler = @MainActor (HotkeyShortcut) -> Void

  private static let relevantFlags: CGEventFlags = [
    .maskCommand, .maskControl, .maskAlternate, .maskShift, .maskSecondaryFn,
  ]

  private var eventTap: CFMachPort?
  private var runLoopSource: CFRunLoopSource?
  private var isDown = false
  private var shortcut: HotkeyShortcut
  private var recordingHandler: RecordingHandler?
  private var pendingModifier: (keyCode: Int64, flags: CGEventFlags)?
  private let handler: Handler

  init(shortcut: HotkeyShortcut, handler: @escaping Handler) {
    self.shortcut = shortcut
    self.handler = handler
  }

  func update(shortcut: HotkeyShortcut) {
    self.shortcut = shortcut
    isDown = false
  }

  func recordNextShortcut(handler: @escaping RecordingHandler) {
    recordingHandler = handler
    pendingModifier = nil
    isDown = false
  }

  func cancelRecording() {
    recordingHandler = nil
    pendingModifier = nil
  }

  func start() throws {
    guard eventTap == nil else { return }
    let mask =
      CGEventMask(1 << CGEventType.flagsChanged.rawValue)
      | CGEventMask(1 << CGEventType.keyDown.rawValue)
      | CGEventMask(1 << CGEventType.keyUp.rawValue)
    let pointer = Unmanaged.passUnretained(self).toOpaque()

    guard
      let tap = CGEvent.tapCreate(
        tap: .cgSessionEventTap,
        place: .headInsertEventTap,
        options: .listenOnly,
        eventsOfInterest: mask,
        callback: { _, type, event, userInfo in
          guard let userInfo else { return Unmanaged.passUnretained(event) }
          let monitor = Unmanaged<HotkeyMonitor>.fromOpaque(userInfo)
            .takeUnretainedValue()
          MainActor.assumeIsolated {
            monitor.receive(type: type, event: event)
          }
          return Unmanaged.passUnretained(event)
        },
        userInfo: pointer
      )
    else {
      throw HotkeyError.couldNotCreateEventTap
    }

    eventTap = tap
    runLoopSource = CFMachPortCreateRunLoopSource(kCFAllocatorDefault, tap, 0)
    if let runLoopSource {
      CFRunLoopAddSource(CFRunLoopGetMain(), runLoopSource, .commonModes)
    }
    CGEvent.tapEnable(tap: tap, enable: true)
  }

  private func receive(type: CGEventType, event: CGEvent) {
    if recordingHandler != nil {
      record(type: type, event: event)
      return
    }

    let keyCode = event.getIntegerValueField(.keyboardEventKeycode)
    guard keyCode == shortcut.keyCode else { return }
    if shortcut.modifierOnly {
      guard type == .flagsChanged else { return }
      handle(down: !event.flags.intersection(shortcut.flags).isEmpty)
    } else {
      if type == .keyUp { handle(down: false) }
      if type == .keyDown,
        event.flags.intersection(Self.relevantFlags) == shortcut.flags
      {
        handle(down: true)
      }
    }
  }

  private func record(type: CGEventType, event: CGEvent) {
    let keyCode = event.getIntegerValueField(.keyboardEventKeycode)
    let flags = event.flags.intersection(Self.relevantFlags)
    switch type {
    case .flagsChanged:
      if flags.isEmpty, let pendingModifier, pendingModifier.keyCode == keyCode {
        finishRecording(
          HotkeyShortcut(
            keyCode: keyCode,
            modifierFlags: pendingModifier.flags.rawValue,
            modifierOnly: true
          )
        )
      } else {
        pendingModifier = (keyCode, flags)
      }
    case .keyDown:
      guard event.getIntegerValueField(.keyboardEventAutorepeat) == 0 else { return }
      finishRecording(
        HotkeyShortcut(
          keyCode: keyCode,
          modifierFlags: flags.rawValue,
          modifierOnly: false
        )
      )
    default:
      break
    }
  }

  private func finishRecording(_ shortcut: HotkeyShortcut) {
    let completion = recordingHandler
    recordingHandler = nil
    pendingModifier = nil
    completion?(shortcut)
  }

  private func handle(down: Bool) {
    guard down != isDown else { return }
    isDown = down
    handler(down)
  }
}

enum HotkeyError: LocalizedError {
  case couldNotCreateEventTap

  var errorDescription: String? {
    "Shuo could not monitor the shortcut key. Enable Input Monitoring for Shuo."
  }
}
