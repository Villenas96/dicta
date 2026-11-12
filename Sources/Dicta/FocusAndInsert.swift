import AppKit
import ApplicationServices
import Carbon.HIToolbox

/// Foto del campo de texto enfocado, leída con Accessibility (como `getTextBoxInfo`
/// de Wispr o `InputTextReading` de Typeless).
struct FocusSnapshot {
    var appName = ""
    var bundleID = ""
    var pid: pid_t = 0
    var element: AXUIElement?
    var role = ""
    var isEditable = false
    var isTerminal = false
    var value: String?
    var selection: CFRange?
    var beforeCursor = ""
    var afterCursor = ""
    var selectedText = ""
    var elementID = ""

    var hasTarget: Bool { element != nil && (isEditable || isTerminal) }
}

enum AX {
    static let terminals: Set<String> = [
        "com.apple.Terminal", "com.googlecode.iterm2", "dev.warp.Warp-Stable", "com.mitchellh.ghostty",
        "net.kovidgoyal.kitty", "io.alacritty", "org.alacritty", "com.github.wez.wezterm", "co.zeit.hyper",
    ]
    static let editableRoles: Set<String> = ["AXTextField", "AXTextArea", "AXComboBox", "AXSearchField"]

    static func attr(_ el: AXUIElement, _ name: String) -> CFTypeRef? {
        var v: CFTypeRef?
        return AXUIElementCopyAttributeValue(el, name as CFString, &v) == .success ? v : nil
    }

    static func string(_ el: AXUIElement, _ name: String) -> String? { attr(el, name) as? String }

    static func range(_ el: AXUIElement) -> CFRange? {
        guard let v = attr(el, kAXSelectedTextRangeAttribute), CFGetTypeID(v) == AXValueGetTypeID() else { return nil }
        var r = CFRange()
        return AXValueGetValue(v as! AXValue, .cfRange, &r) ? r : nil
    }

    static func settable(_ el: AXUIElement, _ name: String) -> Bool {
        var b: DarwinBoolean = false
        return AXUIElementIsAttributeSettable(el, name as CFString, &b) == .success && b.boolValue
    }

    @discardableResult
    static func setSelection(_ el: AXUIElement, _ r: CFRange) -> Bool {
        var r = r
        guard let v = AXValueCreate(.cfRange, &r) else { return false }
        return AXUIElementSetAttributeValue(el, kAXSelectedTextRangeAttribute as CFString, v) == .success
    }

    /// Lee el campo enfocado de la app en primer plano.
    static func snapshot() -> FocusSnapshot {
        var s = FocusSnapshot()
        guard let app = NSWorkspace.shared.frontmostApplication else { return s }
        s.appName = app.localizedName ?? ""
        s.bundleID = app.bundleIdentifier ?? ""
        s.pid = app.processIdentifier
        s.isTerminal = terminals.contains(s.bundleID)

        let appEl = AXUIElementCreateApplication(app.processIdentifier)
        AXUIElementSetMessagingTimeout(appEl, 0.25)
        // Electron/Chromium solo exponen el árbol de accesibilidad si se lo pides.
        AXUIElementSetAttributeValue(appEl, "AXManualAccessibility" as CFString, kCFBooleanTrue)

        var focused = attr(appEl, kAXFocusedUIElementAttribute)
        if focused == nil {
            let sys = AXUIElementCreateSystemWide()
            AXUIElementSetMessagingTimeout(sys, 0.25)
            focused = attr(sys, kAXFocusedUIElementAttribute)
        }
        guard let f = focused, CFGetTypeID(f) == AXUIElementGetTypeID() else { return s }
        let el = f as! AXUIElement
        s.element = el
        s.role = string(el, kAXRoleAttribute) ?? ""
        s.elementID = "\(s.pid)-\(CFHash(el))"
        s.value = string(el, kAXValueAttribute)
        s.selection = range(el)
        s.selectedText = string(el, kAXSelectedTextAttribute) ?? ""
        let editableFlag = (attr(el, "AXEditable") as? Bool) ?? false
        s.isEditable = editableRoles.contains(s.role) || editableFlag
            || settable(el, kAXValueAttribute) || (s.selection != nil && settable(el, kAXSelectedTextRangeAttribute))

        if let value = s.value as NSString?, let sel = s.selection, sel.location != kCFNotFound {
            let loc = min(max(0, sel.location), value.length)
            let end = min(loc + max(0, sel.length), value.length)
            s.beforeCursor = value.substring(to: loc)
            s.afterCursor = value.substring(from: end)
        }
        if s.isTerminal, s.beforeCursor.isEmpty, let v = s.value {
            // En terminales solo interesa la línea actual.
            s.beforeCursor = String(v.split(separator: "\n", omittingEmptySubsequences: false).last ?? "")
        }
        return s
    }

    static var isTrusted: Bool { AXIsProcessTrusted() }

    /// Convierte un rectángulo de Accesibilidad (origen arriba-izquierda) a coordenadas de AppKit.
    private static func toCocoa(_ r: CGRect) -> CGRect {
        let h = NSScreen.screens.first?.frame.height ?? 0
        return CGRect(x: r.minX, y: h - r.maxY, width: r.width, height: r.height)
    }

    /// Zona que la píldora no debe tapar: la línea del cursor si se puede leer;
    /// si no, la casilla entera (salvo que ocupe media pantalla, como un editor).
    static func avoidRect(for snap: FocusSnapshot) -> CGRect? {
        guard let el = snap.element else { return nil }
        if var sel = snap.selection, sel.location != kCFNotFound {
            sel.length = max(sel.length, 0)
            if let rv = AXValueCreate(.cfRange, &sel) {
                var out: CFTypeRef?
                if AXUIElementCopyParameterizedAttributeValue(el, kAXBoundsForRangeParameterizedAttribute as CFString,
                                                              rv, &out) == .success, let out,
                   CFGetTypeID(out) == AXValueGetTypeID() {
                    var r = CGRect.zero
                    if AXValueGetValue(out as! AXValue, .cgRect, &r), r.height > 0, r.height < 400 {
                        return toCocoa(r).insetBy(dx: -40, dy: -24)
                    }
                }
            }
        }
        var pos = CGPoint.zero, size = CGSize.zero
        guard let pv = attr(el, kAXPositionAttribute), let sv = attr(el, kAXSizeAttribute),
              CFGetTypeID(pv) == AXValueGetTypeID(), CFGetTypeID(sv) == AXValueGetTypeID(),
              AXValueGetValue(pv as! AXValue, .cgPoint, &pos), AXValueGetValue(sv as! AXValue, .cgSize, &size)
        else { return nil }
        let screenH = NSScreen.screens.first?.frame.height ?? 1000
        guard size.height < screenH * 0.5 else { return nil }
        return toCocoa(CGRect(origin: pos, size: size)).insetBy(dx: -12, dy: -12)
    }
}

/// Inserta texto en la app enfocada: guardar portapapeles → poner texto → ⌘V → restaurar.
/// (Typeless: `ArchivedPasteboardItem` + `CGEventPost`; Wispr: `pasteTextAndRelaunchHelperIfNeeded`.)
enum TextInserter {
    private static var vKeyCode: CGKeyCode = findKeyCode(for: "v") ?? CGKeyCode(kVK_ANSI_V)

    /// Busca la tecla que produce `char` en la distribución de teclado actual
    /// (Typeless hace lo mismo con `UCKeyTranslate` en `findKeyCodeForCharacter`).
    static func findKeyCode(for char: String) -> CGKeyCode? {
        guard let source = TISCopyCurrentKeyboardLayoutInputSource()?.takeRetainedValue(),
              let ptr = TISGetInputSourceProperty(source, kTISPropertyUnicodeKeyLayoutData) else { return nil }
        let data = Unmanaged<CFData>.fromOpaque(ptr).takeUnretainedValue() as Data
        return data.withUnsafeBytes { raw -> CGKeyCode? in
            guard let layout = raw.baseAddress?.assumingMemoryBound(to: UCKeyboardLayout.self) else { return nil }
            for code in 0..<128 {
                var dead: UInt32 = 0
                var chars = [UniChar](repeating: 0, count: 4)
                var len = 0
                let st = UCKeyTranslate(layout, UInt16(code), UInt16(kUCKeyActionDisplay), 0, UInt32(LMGetKbdType()),
                                        OptionBits(kUCKeyTranslateNoDeadKeysBit), &dead, 4, &len, &chars)
                if st == noErr, len > 0, String(utf16CodeUnits: chars, count: len) == char { return CGKeyCode(code) }
            }
            return nil
        }
    }

    static func refreshLayout() { vKeyCode = findKeyCode(for: "v") ?? CGKeyCode(kVK_ANSI_V) }

    typealias SavedPasteboard = [[(NSPasteboard.PasteboardType, Data)]]

    static func savePasteboard() -> SavedPasteboard {
        (NSPasteboard.general.pasteboardItems ?? []).map { item in
            item.types.compactMap { t in item.data(forType: t).map { (t, $0) } }
        }
    }

    static func restorePasteboard(_ saved: SavedPasteboard) {
        let pb = NSPasteboard.general
        pb.clearContents()
        let items: [NSPasteboardItem] = saved.map { pairs in
            let it = NSPasteboardItem()
            for (t, d) in pairs { it.setData(d, forType: t) }
            return it
        }
        if !items.isEmpty { pb.writeObjects(items) }
    }

    /// Copia al portapapeles de forma permanente (respaldo cuando no hay casilla).
    static func copyToClipboard(_ text: String) {
        let pb = NSPasteboard.general
        pb.clearContents()
        pb.setString(text, forType: .string)
    }

    static func postKey(_ code: CGKeyCode, flags: CGEventFlags) {
        let src = CGEventSource(stateID: .combinedSessionState)
        let down = CGEvent(keyboardEventSource: src, virtualKey: code, keyDown: true)
        let up = CGEvent(keyboardEventSource: src, virtualKey: code, keyDown: false)
        down?.flags = flags; up?.flags = flags
        down?.post(tap: .cghidEventTap)
        up?.post(tap: .cghidEventTap)
    }

    static func pasteShortcut() { postKey(vKeyCode, flags: .maskCommand) }

    /// Selecciona `characters` caracteres hacia la izquierda del cursor (Mayús+←).
    static func selectBackwards(characters: Int) {
        for _ in 0..<min(max(characters, 0), 3000) { postKey(CGKeyCode(kVK_LeftArrow), flags: .maskShift) }
    }

    /// Lee la selección actual con ⌘C cuando Accesibilidad no la expone
    /// (apps Electron, algunos navegadores). Restaura el portapapeles después.
    @MainActor
    static func copySelection() async -> String? {
        let pb = NSPasteboard.general
        let saved = savePasteboard()
        let before = pb.changeCount
        postKey(findKeyCode(for: "c") ?? CGKeyCode(kVK_ANSI_C), flags: .maskCommand)
        var text: String?
        for _ in 0..<15 {
            try? await Task.sleep(nanoseconds: 20_000_000)
            if pb.changeCount != before { text = pb.string(forType: .string); break }
        }
        if pb.changeCount != before { restorePasteboard(saved) }
        return text
    }
    static func undoShortcut() { postKey(findKeyCode(for: "z") ?? CGKeyCode(kVK_ANSI_Z), flags: .maskCommand) }

    /// Pega `text`. Devuelve true si parece que se insertó.
    @MainActor
    static func paste(_ text: String, into snapshot: FocusSnapshot, keepInClipboard: Bool) async -> Bool {
        let saved = keepInClipboard ? [] : savePasteboard()
        let pb = NSPasteboard.general
        pb.clearContents()
        pb.setString(text, forType: .string)
        // Los gestores de portapapeles ignoran el contenido transitorio.
        if !keepInClipboard { pb.setData(Data(), forType: NSPasteboard.PasteboardType("org.nspasteboard.TransientType")) }
        let changeCount = pb.changeCount

        pasteShortcut()
        try? await Task.sleep(nanoseconds: 180_000_000)

        // Verificación: si podemos leer el campo y no ha cambiado, el pegado falló.
        var ok = true
        if let el = snapshot.element, !snapshot.isTerminal, let before = snapshot.value {
            let after = AX.string(el, kAXValueAttribute)
            if let after, after == before { ok = false }
        }

        if !keepInClipboard {
            try? await Task.sleep(nanoseconds: 450_000_000)
            if pb.changeCount == changeCount { restorePasteboard(saved) }
        }
        return ok
    }
}
