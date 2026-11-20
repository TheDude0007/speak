import AppKit
import CoreGraphics

enum HotkeyKey: String, CaseIterable {
    case fn, rightOption, rightCommand, rightControl

    var title: String {
        switch self {
        case .fn: return "fn / 🌐 Globe"
        case .rightOption: return "Right Option ⌥"
        case .rightCommand: return "Right Command ⌘"
        case .rightControl: return "Right Control ⌃"
        }
    }
    var keyCodes: Set<Int64> {
        switch self {
        case .fn: return [63, 179]
        case .rightOption: return [61]
        case .rightCommand: return [54]
        case .rightControl: return [62]
        }
    }
    var flag: CGEventFlags {
        switch self {
        case .fn: return .maskSecondaryFn
        case .rightOption: return .maskAlternate
        case .rightCommand: return .maskCommand
        case .rightControl: return .maskControl
        }
    }
}

/// Listen-only global event tap. Listen-only means Speak can never block or delay
/// your typing, even if the app were to hang.
final class HotkeyTap {
    var key: HotkeyKey = .fn
    var onDown: (() -> Void)?
    var onUp: (() -> Void)?
    var onOtherKey: (() -> Void)?
    var onEscape: (() -> Void)?

    private var tap: CFMachPort?
    private var source: CFRunLoopSource?
    private var isDown = false

    @discardableResult
    func start() -> Bool {
        stop()
        let mask = (1 << CGEventType.flagsChanged.rawValue) | (1 << CGEventType.keyDown.rawValue)
        let ref = Unmanaged.passUnretained(self).toOpaque()
        Log.write("event tap: starting (key=\(key.rawValue), AX=\(AXIsProcessTrusted()), listen=\(CGPreflightListenEventAccess()))")
        guard let tap = CGEvent.tapCreate(tap: .cgSessionEventTap,
                                          place: .headInsertEventTap,
                                          options: .listenOnly,
                                          eventsOfInterest: CGEventMask(mask),
                                          callback: hotkeyTapCallback,
                                          userInfo: ref) else { return false }
        self.tap = tap
        source = CFMachPortCreateRunLoopSource(kCFAllocatorDefault, tap, 0)
        CFRunLoopAddSource(CFRunLoopGetMain(), source, .commonModes)
        CGEvent.tapEnable(tap: tap, enable: true)
        return true
    }

    func stop() {
        if let tap { CGEvent.tapEnable(tap: tap, enable: false) }
        if let source { CFRunLoopRemoveSource(CFRunLoopGetMain(), source, .commonModes) }
        tap = nil; source = nil; isDown = false
    }

    fileprivate func handle(_ type: CGEventType, _ event: CGEvent) {
        switch type {
        case .tapDisabledByTimeout, .tapDisabledByUserInput:
            if let tap { CGEvent.tapEnable(tap: tap, enable: true) }
        case .flagsChanged:
            let code = event.getIntegerValueField(.keyboardEventKeycode)
            Log.write("flagsChanged keycode=\(code) flags=0x\(String(event.flags.rawValue, radix: 16)) watching=\(key.rawValue)")
            guard key.keyCodes.contains(code) else {
                // A different modifier changed while ours is held = chord, not dictation.
                if isDown, code != 63 { onOtherKey?() }
                return
            }
            let down = event.flags.contains(key.flag)
            if down && !isDown { isDown = true; onDown?() }
            else if !down && isDown { isDown = false; onUp?() }
        case .keyDown:
            if event.getIntegerValueField(.keyboardEventAutorepeat) != 0 { return }
            if event.getIntegerValueField(.keyboardEventKeycode) == 53 { onEscape?() } else { if isDown { Log.write("other key while holding") }; onOtherKey?() }
        default:
            break
        }
    }
}

private func hotkeyTapCallback(proxy: CGEventTapProxy, type: CGEventType, event: CGEvent, refcon: UnsafeMutableRawPointer?) -> Unmanaged<CGEvent>? {
    if let refcon {
        Unmanaged<HotkeyTap>.fromOpaque(refcon).takeUnretainedValue().handle(type, event)
    }
    return Unmanaged.passUnretained(event)
}
