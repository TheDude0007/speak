import AppKit
import ApplicationServices
import Carbon

/// Puts text at the caret of whatever app is focused.
///
/// 1. Native AppKit text fields: direct Accessibility insert (no clipboard touched,
///    undo works), verified by character count.
/// 2. Everything else (Chromium, Electron, terminals, or if AX didn't take):
///    paste via a *transient* pasteboard item that clipboard managers skip, then
///    restore the user's original clipboard.
enum Inserter {
    enum Method: String { case accessibility = "AX", paste = "paste" }

    private static let noAXBundles: Set<String> = [
        "com.google.Chrome", "com.google.Chrome.canary", "com.brave.Browser", "com.microsoft.edgemac",
        "company.thebrowser.Browser", "com.vivaldi.Vivaldi", "com.operasoftware.Opera", "org.chromium.Chromium",
        "com.apple.Terminal", "com.googlecode.iterm2", "com.mitchellh.ghostty", "dev.warp.Warp-Stable",
        "net.kovidgoyal.kitty", "org.alacritty", "com.microsoft.VSCode", "com.todesktop.230313mzl4w4u92",
        "org.mozilla.firefox",
    ]
    private static var electronCache: [String: Bool] = [:]

    static var isTrusted: Bool { AXIsProcessTrusted() }

    static func promptForTrust() {
        let opts = ["AXTrustedCheckOptionPrompt": true] as CFDictionary
        _ = AXIsProcessTrustedWithOptions(opts)
    }

    private static func focusedElement() -> AXUIElement? {
        let sys = AXUIElementCreateSystemWide()
        AXUIElementSetMessagingTimeout(sys, 0.15)
        var value: CFTypeRef?
        guard AXUIElementCopyAttributeValue(sys, kAXFocusedUIElementAttribute as CFString, &value) == .success,
              let value, CFGetTypeID(value) == AXUIElementGetTypeID() else { return nil }
        let el = value as! AXUIElement
        AXUIElementSetMessagingTimeout(el, 0.15)
        return el
    }

    private static func selectedRange(_ el: AXUIElement) -> CFRange? {
        var v: CFTypeRef?
        guard AXUIElementCopyAttributeValue(el, kAXSelectedTextRangeAttribute as CFString, &v) == .success,
              let v, CFGetTypeID(v) == AXValueGetTypeID() else { return nil }
        var r = CFRange()
        return AXValueGetValue(v as! AXValue, .cfRange, &r) ? r : nil
    }

    private static func charCount(_ el: AXUIElement) -> Int? {
        var v: CFTypeRef?
        guard AXUIElementCopyAttributeValue(el, kAXNumberOfCharactersAttribute as CFString, &v) == .success else { return nil }
        return (v as? NSNumber)?.intValue
    }

    /// Up to 120 characters before the caret, for smart spacing/capitalization.
    static func textBeforeCaret() -> String? {
        guard isTrusted, let el = focusedElement(), let sel = selectedRange(el) else { return nil }
        if sel.location == 0 { return "" }
        let start = max(0, sel.location - 120)
        var range = CFRange(location: start, length: sel.location - start)
        guard let axRange = AXValueCreate(.cfRange, &range) else { return nil }
        var v: CFTypeRef?
        if AXUIElementCopyParameterizedAttributeValue(el, kAXStringForRangeParameterizedAttribute as CFString, axRange, &v) == .success,
           let s = v as? String { return s }
        // fallback: whole value (bounded)
        if AXUIElementCopyAttributeValue(el, kAXValueAttribute as CFString, &v) == .success, let s = v as? String {
            let ns = s as NSString
            guard sel.location <= ns.length else { return nil }
            return ns.substring(with: NSRange(location: start, length: sel.location - start))
        }
        return nil
    }

    private static func axEligible() -> Bool {
        guard let app = NSWorkspace.shared.frontmostApplication, let id = app.bundleIdentifier else { return false }
        if noAXBundles.contains(id) { return false }
        if let cached = electronCache[id] { return !cached }
        var electron = false
        if let url = app.bundleURL {
            let fw = url.appendingPathComponent("Contents/Frameworks")
            electron = FileManager.default.fileExists(atPath: fw.appendingPathComponent("Electron Framework.framework").path)
                || FileManager.default.fileExists(atPath: fw.appendingPathComponent("Chromium Embedded Framework.framework").path)
        }
        electronCache[id] = electron
        return !electron
    }

    @discardableResult
    static func insert(_ text: String) -> Method {
        if isTrusted, axEligible(), insertViaAX(text) { return .accessibility }
        paste(text)
        return .paste
    }

    private static func insertViaAX(_ text: String) -> Bool {
        guard let el = focusedElement(), let before = charCount(el), let sel = selectedRange(el) else { return false }
        var settable: DarwinBoolean = false
        guard AXUIElementIsAttributeSettable(el, kAXSelectedTextAttribute as CFString, &settable) == .success,
              settable.boolValue else { return false }
        guard AXUIElementSetAttributeValue(el, kAXSelectedTextAttribute as CFString, text as CFString) == .success else { return false }
        guard let after = charCount(el) else { return true }
        if after == before && !(sel.length == (text as NSString).length) {
            return false // nothing changed -> app ignored AX write; fall back to paste
        }
        return true
    }

    // MARK: paste

    private static func paste(_ text: String) {
        let pb = NSPasteboard.general
        // Snapshot existing clipboard (all representations).
        let saved: [[NSPasteboard.PasteboardType: Data]] = (pb.pasteboardItems ?? []).map { item in
            var d: [NSPasteboard.PasteboardType: Data] = [:]
            for t in item.types { if let data = item.data(forType: t) { d[t] = data } }
            return d
        }
        pb.clearContents()
        let item = NSPasteboardItem()
        item.setString(text, forType: .string)
        // nspasteboard.org conventions: clipboard managers ignore these.
        item.setString("", forType: NSPasteboard.PasteboardType("org.nspasteboard.TransientType"))
        item.setString("", forType: NSPasteboard.PasteboardType("org.nspasteboard.AutoGeneratedType"))
        item.setString("Speak", forType: NSPasteboard.PasteboardType("org.nspasteboard.source"))
        pb.writeObjects([item])
        let ourChange = pb.changeCount

        sendCmdV()

        DispatchQueue.main.asyncAfter(deadline: .now() + 0.35) {
            guard pb.changeCount == ourChange else { return } // user copied something meanwhile
            pb.clearContents()
            guard !saved.isEmpty else { return }
            let items = saved.map { dict -> NSPasteboardItem in
                let it = NSPasteboardItem()
                for (t, data) in dict { it.setData(data, forType: t) }
                return it
            }
            pb.writeObjects(items)
        }
    }

    /// Key code that produces "v" *with Command held* in the current layout.
    /// Handles Dvorak, AZERTY, Colemak and "Dvorak – QWERTY ⌘" (which swaps to QWERTY under ⌘).
    static func commandVKeyCode() -> CGKeyCode {
        guard let src = TISCopyCurrentKeyboardLayoutInputSource()?.takeRetainedValue(),
              let ptr = TISGetInputSourceProperty(src, kTISPropertyUnicodeKeyLayoutData) else { return 9 }
        let data = Unmanaged<CFData>.fromOpaque(ptr).takeUnretainedValue() as Data
        let target = UniChar(("v" as Unicode.Scalar).value)
        let cmdState = UInt32((cmdKey >> 8) & 0xFF)
        return data.withUnsafeBytes { raw -> CGKeyCode in
            guard let base = raw.baseAddress else { return 9 }
            let layout = base.assumingMemoryBound(to: UCKeyboardLayout.self)
            var chars = [UniChar](repeating: 0, count: 4)
            for code in 0..<128 {
                var dead: UInt32 = 0
                var len = 0
                let st = UCKeyTranslate(layout, UInt16(code), UInt16(kUCKeyActionDown), cmdState,
                                        UInt32(LMGetKbdType()), OptionBits(kUCKeyTranslateNoDeadKeysBit),
                                        &dead, 4, &len, &chars)
                if st == noErr, len == 1, chars[0] == target || chars[0] == target - 32 { return CGKeyCode(code) }
            }
            return 9
        }
    }

    private static func sendCmdV() {
        let src = CGEventSource(stateID: .privateState) // independent of keys the user is still holding
        let vKey = commandVKeyCode()
        let down = CGEvent(keyboardEventSource: src, virtualKey: vKey, keyDown: true)
        let up = CGEvent(keyboardEventSource: src, virtualKey: vKey, keyDown: false)
        down?.flags = .maskCommand
        up?.flags = .maskCommand
        down?.post(tap: .cghidEventTap)
        up?.post(tap: .cghidEventTap)
    }
}
