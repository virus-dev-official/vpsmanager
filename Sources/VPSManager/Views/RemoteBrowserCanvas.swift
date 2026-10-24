import SwiftUI
import AppKit
import Carbon.HIToolbox

/// The live page surface: shows screencast frames and turns every mouse, scroll
/// and keyboard event into the equivalent Chrome DevTools input event.
///
/// A plain layer-backed NSView rather than a SwiftUI `Image`: frames arrive at up
/// to 60 fps and go straight into `layer.contents` with no view diffing, and an
/// NSView is the only way to get raw key events, first-responder focus, cursor
/// control and precise trackpad scrolling.
final class BrowserCanvasNSView: NSView {
    weak var session: RemoteBrowserSession? {
        didSet { attach() }
    }
    var onFocusAddressBar: (() -> Void)?

    private let imageLayer = CALayer()
    private var cssSize: CGSize = .zero
    private var trackingArea: NSTrackingArea?
    private var buttonsDown = 0
    private var pendingMove: NSEvent?
    private var moveScheduled = false
    private var pendingScroll: (dx: CGFloat, dy: CGFloat, point: CGPoint, modifiers: Int)?
    private var scrollScheduled = false
    private var cursorProbeTask: Task<Void, Never>?
    private var currentCursor = NSCursor.arrow

    override init(frame frameRect: NSRect) {
        super.init(frame: frameRect)
        wantsLayer = true
        layer?.backgroundColor = NSColor.white.cgColor
        imageLayer.contentsGravity = .resizeAspect
        imageLayer.magnificationFilter = .linear
        imageLayer.minificationFilter = .trilinear
        imageLayer.actions = ["contents": NSNull(), "bounds": NSNull(), "position": NSNull(), "frame": NSNull()]
        layer?.addSublayer(imageLayer)
    }

    required init?(coder: NSCoder) { fatalError("init(coder:) is not supported") }

    override var acceptsFirstResponder: Bool { true }
    override func acceptsFirstMouse(for event: NSEvent?) -> Bool { true }
    override var isOpaque: Bool { true }

    private func attach() {
        guard let session else { return }
        session.frameSink = { [weak self] frame in self?.show(frame) }
        session.frameSinkOwner = self
        if let frame = session.lastFrame { show(frame) } else { imageLayer.contents = nil }
        reportViewport()
    }

    private func show(_ frame: BrowserFrame) {
        imageLayer.contents = frame.image
        cssSize = frame.cssSize
    }

    // A plain (non-Auto Layout) NSView isn't guaranteed a layout() pass when
    // SwiftUI resizes it, so track size changes here as well.
    override func setFrameSize(_ newSize: NSSize) {
        super.setFrameSize(newSize)
        CATransaction.begin()
        CATransaction.setDisableActions(true)
        imageLayer.frame = bounds
        CATransaction.commit()
        reportViewport()
    }

    override func layout() {
        super.layout()
        CATransaction.begin()
        CATransaction.setDisableActions(true)
        imageLayer.frame = bounds
        CATransaction.commit()
        reportViewport()
    }

    override func viewDidChangeBackingProperties() {
        super.viewDidChangeBackingProperties()
        let scale = window?.backingScaleFactor ?? 2
        layer?.contentsScale = scale
        imageLayer.contentsScale = scale
        reportViewport()
    }

    override func viewDidMoveToWindow() {
        super.viewDidMoveToWindow()
        reportViewport()
    }

    private func reportViewport() {
        guard bounds.width > 0, bounds.height > 0 else { return }
        session?.viewportChanged(size: bounds.size, backingScale: window?.backingScaleFactor ?? 2)
    }

    // MARK: Coordinates

    /// The rect the frame actually occupies (aspect-fit, centred) in view space.
    private var imageRect: CGRect {
        guard cssSize.width > 0, cssSize.height > 0 else { return bounds }
        let scale = min(bounds.width / cssSize.width, bounds.height / cssSize.height)
        let size = CGSize(width: cssSize.width * scale, height: cssSize.height * scale)
        return CGRect(x: (bounds.width - size.width) / 2, y: (bounds.height - size.height) / 2, width: size.width, height: size.height)
    }

    /// Converts a window-space event location into page CSS pixels (origin top-left).
    private func pagePoint(_ event: NSEvent) -> CGPoint {
        let local = convert(event.locationInWindow, from: nil)
        let rect = imageRect
        let width = cssSize.width > 0 ? cssSize.width : bounds.width
        let height = cssSize.height > 0 ? cssSize.height : bounds.height
        let x = (local.x - rect.minX) / max(rect.width, 1) * width
        let yFromTop = (rect.maxY - local.y) / max(rect.height, 1) * height
        return CGPoint(x: min(max(x, 0), width - 1), y: min(max(yFromTop, 0), height - 1))
    }

    private func viewPoint(fromPage point: CGPoint) -> CGPoint {
        let rect = imageRect
        let width = cssSize.width > 0 ? cssSize.width : bounds.width
        let height = cssSize.height > 0 ? cssSize.height : bounds.height
        return CGPoint(x: rect.minX + point.x / width * rect.width,
                       y: rect.maxY - point.y / height * rect.height)
    }

    // MARK: Mouse

    override func updateTrackingAreas() {
        super.updateTrackingAreas()
        if let trackingArea { removeTrackingArea(trackingArea) }
        let area = NSTrackingArea(rect: .zero,
                                  options: [.mouseMoved, .mouseEnteredAndExited, .cursorUpdate, .activeInKeyWindow, .inVisibleRect],
                                  owner: self, userInfo: nil)
        addTrackingArea(area)
        trackingArea = area
    }

    override func cursorUpdate(with event: NSEvent) {
        currentCursor.set()
    }

    override func mouseDown(with event: NSEvent) { press(event, button: "left", mask: 1) }
    override func rightMouseDown(with event: NSEvent) { press(event, button: "right", mask: 2) }
    override func otherMouseDown(with event: NSEvent) { press(event, button: "middle", mask: 4) }
    override func mouseUp(with event: NSEvent) { release(event, button: "left", mask: 1) }
    override func rightMouseUp(with event: NSEvent) { release(event, button: "right", mask: 2) }
    override func otherMouseUp(with event: NSEvent) { release(event, button: "middle", mask: 4) }
    override func mouseMoved(with event: NSEvent) { queueMove(event) }
    override func mouseDragged(with event: NSEvent) { queueMove(event) }
    override func rightMouseDragged(with event: NSEvent) { queueMove(event) }
    override func otherMouseDragged(with event: NSEvent) { queueMove(event) }

    override func mouseExited(with event: NSEvent) {
        NSCursor.arrow.set()
    }

    private func press(_ event: NSEvent, button: String, mask: Int) {
        window?.makeFirstResponder(self)
        flushMove()
        buttonsDown |= mask
        let point = pagePoint(event)
        let modifiers = Self.mouseModifiers(event.modifierFlags)
        session?.dispatchMouse([
            "type": "mousePressed", "x": point.x, "y": point.y,
            "button": button, "buttons": buttonsDown,
            "clickCount": max(1, event.clickCount), "modifiers": modifiers
        ], modifiedClick: modifiers & (2 | 4) != 0)
    }

    private func release(_ event: NSEvent, button: String, mask: Int) {
        flushMove()
        buttonsDown &= ~mask
        let point = pagePoint(event)
        session?.dispatchMouse([
            "type": "mouseReleased", "x": point.x, "y": point.y,
            "button": button, "buttons": buttonsDown,
            "clickCount": max(1, event.clickCount), "modifiers": Self.mouseModifiers(event.modifierFlags)
        ])
        if button == "left", event.clickCount == 1 {
            probeSelectElement(at: point)
        }
    }

    /// Mouse moves are coalesced to one per display frame — a trackpad can emit
    /// several hundred per second, which would just queue up latency on the wire.
    private func queueMove(_ event: NSEvent) {
        pendingMove = event
        guard !moveScheduled else { return }
        moveScheduled = true
        DispatchQueue.main.asyncAfter(deadline: .now() + 1.0 / 60) { [weak self] in
            self?.flushMove()
        }
    }

    private func flushMove() {
        moveScheduled = false
        guard let event = pendingMove else { return }
        pendingMove = nil
        let point = pagePoint(event)
        let button: String
        if buttonsDown & 1 != 0 { button = "left" } else if buttonsDown & 2 != 0 { button = "right" } else if buttonsDown & 4 != 0 { button = "middle" } else { button = "none" }
        session?.dispatchMouse([
            "type": "mouseMoved", "x": point.x, "y": point.y,
            "button": button, "buttons": buttonsDown,
            "modifiers": Self.mouseModifiers(event.modifierFlags)
        ])
        if buttonsDown == 0 { scheduleCursorProbe(at: point) }
    }

    override func scrollWheel(with event: NSEvent) {
        let multiplier: CGFloat = event.hasPreciseScrollingDeltas ? 1 : 40
        let dx = -event.scrollingDeltaX * multiplier
        let dy = -event.scrollingDeltaY * multiplier
        guard dx != 0 || dy != 0 else { return }
        let point = pagePoint(event)
        let modifiers = Self.mouseModifiers(event.modifierFlags)
        if let pending = pendingScroll {
            pendingScroll = (pending.dx + dx, pending.dy + dy, point, modifiers)
        } else {
            pendingScroll = (dx, dy, point, modifiers)
        }
        guard !scrollScheduled else { return }
        scrollScheduled = true
        DispatchQueue.main.asyncAfter(deadline: .now() + 1.0 / 60) { [weak self] in
            guard let self else { return }
            self.scrollScheduled = false
            guard let scroll = self.pendingScroll else { return }
            self.pendingScroll = nil
            self.session?.dispatchMouse([
                "type": "mouseWheel", "x": scroll.point.x, "y": scroll.point.y,
                "deltaX": scroll.dx, "deltaY": scroll.dy,
                "button": "none", "modifiers": scroll.modifiers
            ])
        }
    }

    // MARK: Cursor

    /// CDP has no "cursor changed" event, so after the pointer settles we ask the
    /// page what's under it and mirror the CSS cursor with the native one.
    private func scheduleCursorProbe(at point: CGPoint) {
        cursorProbeTask?.cancel()
        cursorProbeTask = Task { @MainActor [weak self] in
            try? await Task.sleep(nanoseconds: 70_000_000)
            guard !Task.isCancelled, let self, let session = self.session else { return }
            let value = await session.evaluate(RemoteBrowserSession.cursorScript(x: point.x, y: point.y), timeout: 2) as? String
            guard !Task.isCancelled, let value else { return }
            self.currentCursor = Self.cursor(forCSS: value)
            if let window = self.window, window.isKeyWindow,
               self.bounds.contains(self.convert(window.mouseLocationOutsideOfEventStream, from: nil)) {
                self.currentCursor.set()
            }
        }
    }

    private static func cursor(forCSS css: String) -> NSCursor {
        switch css.split(separator: ",").last.map({ $0.trimmingCharacters(in: .whitespaces) }) ?? css {
        case "pointer": return .pointingHand
        case "text": return .iBeam
        case "vertical-text": return .iBeamCursorForVerticalLayout
        case "crosshair": return .crosshair
        case "grab", "move", "all-scroll": return .openHand
        case "grabbing": return .closedHand
        case "not-allowed", "no-drop": return .operationNotAllowed
        case "ew-resize", "col-resize", "e-resize", "w-resize": return .resizeLeftRight
        case "ns-resize", "row-resize", "n-resize", "s-resize": return .resizeUpDown
        case "copy": return .dragCopy
        case "alias": return .dragLink
        case "context-menu": return .contextualMenu
        default: return .arrow
        }
    }

    // MARK: <select> popups

    /// Headless Chromium never paints native <select> dropdowns into the
    /// screencast, so clicking one would appear to do nothing. Instead, when a
    /// click lands on a focused <select>, show its options as a native menu and
    /// apply the choice in the page (firing input/change like a real pick).
    private func probeSelectElement(at point: CGPoint) {
        Task { @MainActor [weak self] in
            guard let self, let session = self.session else { return }
            guard let json = await session.evaluate(RemoteBrowserSession.selectProbeScript(x: point.x, y: point.y)) as? String,
                  let data = json.data(using: .utf8),
                  let info = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
                  let options = info["options"] as? [[String: Any]], !options.isEmpty else { return }
            let selected = info["selected"] as? Int ?? -1
            let left = (info["left"] as? NSNumber)?.doubleValue ?? point.x
            let bottom = (info["bottom"] as? NSNumber)?.doubleValue ?? point.y

            let menu = NSMenu()
            menu.autoenablesItems = false
            var lastGroup: String?
            for (index, option) in options.enumerated() {
                let group = option["group"] as? String
                if group != lastGroup {
                    if let group {
                        if menu.numberOfItems > 0 { menu.addItem(.separator()) }
                        let header = NSMenuItem(title: group, action: nil, keyEquivalent: "")
                        header.isEnabled = false
                        menu.addItem(header)
                    }
                    lastGroup = group
                }
                let item = NSMenuItem(title: option["label"] as? String ?? "", action: #selector(self.chooseSelectOption(_:)), keyEquivalent: "")
                item.target = self
                item.tag = index
                item.state = index == selected ? .on : .off
                item.isEnabled = !(option["disabled"] as? Bool ?? false)
                if group != nil { item.indentationLevel = 1 }
                menu.addItem(item)
            }
            let anchor = self.viewPoint(fromPage: CGPoint(x: left, y: bottom))
            menu.popUp(positioning: nil, at: anchor, in: self)
        }
    }

    @objc private func chooseSelectOption(_ sender: NSMenuItem) {
        let index = sender.tag
        Task { @MainActor [weak self] in
            _ = await self?.session?.evaluate(RemoteBrowserSession.selectChooseScript(index: index))
        }
    }

    // MARK: Keyboard

    override func performKeyEquivalent(with event: NSEvent) -> Bool {
        // performKeyEquivalent is offered to every view in the window, not just the
        // focused one — only act when the page actually has keyboard focus.
        guard window?.firstResponder === self, event.type == .keyDown else {
            return super.performKeyEquivalent(with: event)
        }
        let flags = event.modifierFlags.intersection(.deviceIndependentFlagsMask)
        guard flags.contains(.command) else { return super.performKeyEquivalent(with: event) }
        return handleCommandKey(event, flags: flags)
    }

    override func keyDown(with event: NSEvent) {
        let flags = event.modifierFlags.intersection(.deviceIndependentFlagsMask)
        if flags.contains(.command) {
            if !handleCommandKey(event, flags: flags) { super.keyDown(with: event) }
            return
        }
        sendKey(event, flags: flags)
    }

    override func keyUp(with event: NSEvent) {
        guard let info = KeyMap.info(for: event.keyCode) else { return }
        let flags = event.modifierFlags.intersection(.deviceIndependentFlagsMask)
        let (key, code, vk) = translated(event, info: info, flags: flags)
        session?.dispatchKey([
            "type": "keyUp", "key": key.key, "code": code, "windowsVirtualKeyCode": vk,
            "modifiers": key.modifiers
        ])
    }

    /// ⌘ shortcuts: browser-level ones (address bar, reload, tabs, zoom) are handled
    /// here; clipboard goes through the Mac pasteboard; everything else becomes
    /// the Ctrl-equivalent Linux Chrome expects (⌘A → Ctrl+A, ⌘Z → Ctrl+Z, …).
    /// Returns false for app-level shortcuts so the menu bar still gets them.
    private func handleCommandKey(_ event: NSEvent, flags: NSEvent.ModifierFlags) -> Bool {
        guard let session else { return false }
        let char = (event.charactersIgnoringModifiers ?? "").lowercased()
        let shift = flags.contains(.shift)

        switch (char, shift) {
        case ("q", _), ("h", _), ("m", _), (",", _), ("`", _), ("n", _), ("k", _), ("w", true):
            return false
        case ("l", false):
            onFocusAddressBar?()
            return true
        case ("r", _):
            session.reload(ignoreCache: shift)
            return true
        case ("t", false):
            Task { await session.newTab() }
            return true
        case ("w", false):
            if let id = session.activeTabID { session.closeTab(id) }
            return true
        case ("[", false):
            session.goBack()
            return true
        case ("]", false):
            session.goForward()
            return true
        case ("=", _), ("+", _):
            session.zoomIn()
            return true
        case ("-", false):
            session.zoomOut()
            return true
        case ("0", false):
            session.setZoom(1)
            return true
        case ("c", false):
            Task { _ = await session.copySelection() }
            return true
        case ("x", false):
            Task { @MainActor in
                if await session.copySelection() {
                    self.sendSyntheticKey(KeyMap.info(for: UInt16(kVK_Delete))!, modifiers: 0)
                }
            }
            return true
        case ("v", _):
            if let text = NSPasteboard.general.string(forType: .string) {
                session.insertText(text)
            }
            return true
        default:
            break
        }

        guard let info = KeyMap.info(for: event.keyCode) else { return true }
        // Mac line/document navigation → Linux equivalents.
        switch Int(event.keyCode) {
        case kVK_LeftArrow:
            sendSyntheticKey(KeyMap.info(for: UInt16(kVK_Home))!, modifiers: shift ? 8 : 0); return true
        case kVK_RightArrow:
            sendSyntheticKey(KeyMap.info(for: UInt16(kVK_End))!, modifiers: shift ? 8 : 0); return true
        case kVK_UpArrow:
            sendSyntheticKey(KeyMap.info(for: UInt16(kVK_Home))!, modifiers: 2 | (shift ? 8 : 0)); return true
        case kVK_DownArrow:
            sendSyntheticKey(KeyMap.info(for: UInt16(kVK_End))!, modifiers: 2 | (shift ? 8 : 0)); return true
        case kVK_Delete:
            // ⌘⌫ deletes to the start of the line.
            sendSyntheticKey(KeyMap.info(for: UInt16(kVK_Home))!, modifiers: 8)
            sendSyntheticKey(info, modifiers: 0)
            return true
        default:
            break
        }

        var modifiers = 2 // Ctrl
        if shift { modifiers |= 8 }
        if flags.contains(.option) { modifiers |= 1 }
        let key = info.printable ? (event.charactersIgnoringModifiers ?? info.key).lowercased() : info.key
        session.dispatchKey(["type": "rawKeyDown", "key": key, "code": info.code, "windowsVirtualKeyCode": info.vk, "modifiers": modifiers])
        session.dispatchKey(["type": "keyUp", "key": key, "code": info.code, "windowsVirtualKeyCode": info.vk, "modifiers": modifiers])
        return true
    }

    private func sendKey(_ event: NSEvent, flags: NSEvent.ModifierFlags) {
        guard let session else { return }
        guard let info = KeyMap.info(for: event.keyCode) else {
            // Keys we don't have a mapping for (e.g. from exotic layouts) still
            // type their text.
            if let text = event.characters, !text.isEmpty, text.unicodeScalars.allSatisfy({ $0.value >= 32 && $0.value != 127 }) {
                session.insertText(text)
            }
            return
        }
        let (key, code, vk) = translated(event, info: info, flags: flags)
        var params: [String: Any] = [
            "key": key.key, "code": code, "windowsVirtualKeyCode": vk,
            "nativeVirtualKeyCode": vk, "modifiers": key.modifiers,
            "autoRepeat": event.isARepeat, "isKeypad": info.isKeypad
        ]
        if let text = key.text {
            params["type"] = "keyDown"
            params["text"] = text
            params["unmodifiedText"] = text
        } else {
            params["type"] = "rawKeyDown"
        }
        session.dispatchKey(params)
    }

    private func sendSyntheticKey(_ info: KeyMap.Info, modifiers: Int) {
        session?.dispatchKey(["type": "rawKeyDown", "key": info.key, "code": info.code, "windowsVirtualKeyCode": info.vk, "modifiers": modifiers])
        session?.dispatchKey(["type": "keyUp", "key": info.key, "code": info.code, "windowsVirtualKeyCode": info.vk, "modifiers": modifiers])
    }

    /// Works out the DOM key/text/modifiers for a non-⌘ key press, translating
    /// Mac editing conventions (⌥⌫, ⌥←) to their Linux Chrome counterparts.
    private func translated(_ event: NSEvent, info: KeyMap.Info, flags: NSEvent.ModifierFlags) -> (key: (key: String, text: String?, modifiers: Int), code: String, vk: Int) {
        var modifiers = 0
        if flags.contains(.shift) { modifiers |= 8 }
        if flags.contains(.control) { modifiers |= 2 }

        let wordNavigation: Set<Int> = [kVK_LeftArrow, kVK_RightArrow, kVK_Delete, kVK_ForwardDelete]
        if flags.contains(.option) {
            if wordNavigation.contains(Int(event.keyCode)) {
                // ⌥← / ⌥⌫ = word-wise on Mac; Ctrl is the Linux equivalent.
                modifiers |= 2
            } else if !info.printable {
                modifiers |= 1
            }
        }

        if info.printable {
            if flags.contains(.control) {
                let base = (event.charactersIgnoringModifiers ?? info.key).lowercased()
                return ((base, nil, modifiers), info.code, info.vk)
            }
            // ⌥ on Mac composes characters (⌥2 → ™); send the composed text, not Alt.
            let text = event.characters ?? ""
            let valid = !text.isEmpty && text.unicodeScalars.allSatisfy { $0.value >= 32 && $0.value != 127 && !(0xF700...0xF8FF).contains($0.value) }
            return ((valid ? text : info.key, valid ? text : nil, modifiers), info.code, info.vk)
        }
        let text: String?
        switch Int(event.keyCode) {
        case kVK_Return, kVK_ANSI_KeypadEnter: text = flags.contains(.control) ? nil : "\r"
        default: text = nil
        }
        return ((info.key, text, modifiers), info.code, info.vk)
    }

    private static func mouseModifiers(_ flags: NSEvent.ModifierFlags) -> Int {
        var modifiers = 0
        if flags.contains(.option) { modifiers |= 1 }
        // ⌘-click on Mac = Ctrl-click on Linux (open link in a background tab).
        if flags.contains(.control) || flags.contains(.command) { modifiers |= 2 }
        if flags.contains(.shift) { modifiers |= 8 }
        return modifiers
    }

    // Edit-menu actions (when the user picks Copy/Paste from the menu bar rather
    // than pressing the shortcut).
    @objc func copy(_ sender: Any?) { Task { _ = await session?.copySelection() } }
    @objc func paste(_ sender: Any?) {
        if let text = NSPasteboard.general.string(forType: .string) { session?.insertText(text) }
    }
    @objc override func selectAll(_ sender: Any?) {
        guard let info = KeyMap.info(for: UInt16(kVK_ANSI_A)) else { return }
        sendSyntheticKey(info, modifiers: 2)
    }
}

// MARK: - Key map

/// Mac virtual key code → DOM `code`, DOM `key` (for non-printing keys) and the
/// Windows virtual key code Chrome uses for `keyCode`/`which`.
enum KeyMap {
    struct Info {
        let code: String
        let key: String
        let vk: Int
        let printable: Bool
        var isKeypad = false
    }

    static func info(for keyCode: UInt16) -> Info? { table[Int(keyCode)] }

    private static let table: [Int: Info] = {
        var t: [Int: Info] = [:]
        let letters: [(Int, String)] = [
            (kVK_ANSI_A, "a"), (kVK_ANSI_B, "b"), (kVK_ANSI_C, "c"), (kVK_ANSI_D, "d"), (kVK_ANSI_E, "e"),
            (kVK_ANSI_F, "f"), (kVK_ANSI_G, "g"), (kVK_ANSI_H, "h"), (kVK_ANSI_I, "i"), (kVK_ANSI_J, "j"),
            (kVK_ANSI_K, "k"), (kVK_ANSI_L, "l"), (kVK_ANSI_M, "m"), (kVK_ANSI_N, "n"), (kVK_ANSI_O, "o"),
            (kVK_ANSI_P, "p"), (kVK_ANSI_Q, "q"), (kVK_ANSI_R, "r"), (kVK_ANSI_S, "s"), (kVK_ANSI_T, "t"),
            (kVK_ANSI_U, "u"), (kVK_ANSI_V, "v"), (kVK_ANSI_W, "w"), (kVK_ANSI_X, "x"), (kVK_ANSI_Y, "y"),
            (kVK_ANSI_Z, "z")
        ]
        for (code, letter) in letters {
            t[code] = Info(code: "Key\(letter.uppercased())", key: letter, vk: Int(letter.uppercased().unicodeScalars.first!.value), printable: true)
        }
        let digits: [(Int, Int)] = [
            (kVK_ANSI_0, 0), (kVK_ANSI_1, 1), (kVK_ANSI_2, 2), (kVK_ANSI_3, 3), (kVK_ANSI_4, 4),
            (kVK_ANSI_5, 5), (kVK_ANSI_6, 6), (kVK_ANSI_7, 7), (kVK_ANSI_8, 8), (kVK_ANSI_9, 9)
        ]
        for (code, digit) in digits {
            t[code] = Info(code: "Digit\(digit)", key: "\(digit)", vk: 48 + digit, printable: true)
        }
        let keypad: [(Int, String, String, Int)] = [
            (kVK_ANSI_Keypad0, "Numpad0", "0", 96), (kVK_ANSI_Keypad1, "Numpad1", "1", 97),
            (kVK_ANSI_Keypad2, "Numpad2", "2", 98), (kVK_ANSI_Keypad3, "Numpad3", "3", 99),
            (kVK_ANSI_Keypad4, "Numpad4", "4", 100), (kVK_ANSI_Keypad5, "Numpad5", "5", 101),
            (kVK_ANSI_Keypad6, "Numpad6", "6", 102), (kVK_ANSI_Keypad7, "Numpad7", "7", 103),
            (kVK_ANSI_Keypad8, "Numpad8", "8", 104), (kVK_ANSI_Keypad9, "Numpad9", "9", 105),
            (kVK_ANSI_KeypadMultiply, "NumpadMultiply", "*", 106), (kVK_ANSI_KeypadPlus, "NumpadAdd", "+", 107),
            (kVK_ANSI_KeypadMinus, "NumpadSubtract", "-", 109), (kVK_ANSI_KeypadDecimal, "NumpadDecimal", ".", 110),
            (kVK_ANSI_KeypadDivide, "NumpadDivide", "/", 111), (kVK_ANSI_KeypadEquals, "NumpadEqual", "=", 187)
        ]
        for (code, dom, key, vk) in keypad {
            t[code] = Info(code: dom, key: key, vk: vk, printable: true, isKeypad: true)
        }
        let punctuation: [(Int, String, String, Int)] = [
            (kVK_ANSI_Equal, "Equal", "=", 187), (kVK_ANSI_Minus, "Minus", "-", 189),
            (kVK_ANSI_RightBracket, "BracketRight", "]", 221), (kVK_ANSI_LeftBracket, "BracketLeft", "[", 219),
            (kVK_ANSI_Quote, "Quote", "'", 222), (kVK_ANSI_Semicolon, "Semicolon", ";", 186),
            (kVK_ANSI_Backslash, "Backslash", "\\", 220), (kVK_ANSI_Comma, "Comma", ",", 188),
            (kVK_ANSI_Slash, "Slash", "/", 191), (kVK_ANSI_Period, "Period", ".", 190),
            (kVK_ANSI_Grave, "Backquote", "`", 192), (kVK_Space, "Space", " ", 32),
            (kVK_ISO_Section, "IntlBackslash", "§", 226)
        ]
        for (code, dom, key, vk) in punctuation {
            t[code] = Info(code: dom, key: key, vk: vk, printable: true)
        }
        let special: [(Int, String, String, Int)] = [
            (kVK_Return, "Enter", "Enter", 13), (kVK_ANSI_KeypadEnter, "NumpadEnter", "Enter", 13),
            (kVK_Tab, "Tab", "Tab", 9), (kVK_Delete, "Backspace", "Backspace", 8),
            (kVK_ForwardDelete, "Delete", "Delete", 46), (kVK_Escape, "Escape", "Escape", 27),
            (kVK_LeftArrow, "ArrowLeft", "ArrowLeft", 37), (kVK_UpArrow, "ArrowUp", "ArrowUp", 38),
            (kVK_RightArrow, "ArrowRight", "ArrowRight", 39), (kVK_DownArrow, "ArrowDown", "ArrowDown", 40),
            (kVK_Home, "Home", "Home", 36), (kVK_End, "End", "End", 35),
            (kVK_PageUp, "PageUp", "PageUp", 33), (kVK_PageDown, "PageDown", "PageDown", 34),
            (kVK_Help, "Insert", "Insert", 45), (kVK_ANSI_KeypadClear, "NumLock", "Clear", 12),
            (kVK_F1, "F1", "F1", 112), (kVK_F2, "F2", "F2", 113), (kVK_F3, "F3", "F3", 114),
            (kVK_F4, "F4", "F4", 115), (kVK_F5, "F5", "F5", 116), (kVK_F6, "F6", "F6", 117),
            (kVK_F7, "F7", "F7", 118), (kVK_F8, "F8", "F8", 119), (kVK_F9, "F9", "F9", 120),
            (kVK_F10, "F10", "F10", 121), (kVK_F11, "F11", "F11", 122), (kVK_F12, "F12", "F12", 123)
        ]
        for (code, dom, key, vk) in special {
            t[code] = Info(code: dom, key: key, vk: vk, printable: false)
        }
        return t
    }()
}

// MARK: - SwiftUI bridge

struct BrowserCanvas: NSViewRepresentable {
    let session: RemoteBrowserSession
    var onFocusAddressBar: () -> Void

    func makeNSView(context: Context) -> BrowserCanvasNSView {
        let view = BrowserCanvasNSView(frame: .zero)
        view.onFocusAddressBar = onFocusAddressBar
        view.session = session
        return view
    }

    func updateNSView(_ nsView: BrowserCanvasNSView, context: Context) {
        nsView.onFocusAddressBar = onFocusAddressBar
        if nsView.session !== session { nsView.session = session }
    }

    static func dismantleNSView(_ nsView: BrowserCanvasNSView, coordinator: ()) {
        // Only detach if this canvas is still the one receiving frames (another
        // window showing the same server may have taken over since).
        if let session = nsView.session, session.frameSinkOwner === nsView {
            session.frameSink = nil
            session.frameSinkOwner = nil
        }
    }
}
