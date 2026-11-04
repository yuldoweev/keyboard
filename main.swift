import Cocoa

// MARK: - Tarjima (Google'ning ochiq endpoint'i orqali)

final class Translator {
    var source: String            // "uz", "ru" yoki "auto"
    private var cache: [String: String] = [:]

    init(source: String) { self.source = source }

    static func normalize(_ s: String) -> String {
        var t = s
        for c in ["\u{02BB}", "\u{02BC}", "\u{2019}", "\u{2018}", "`"] { t = t.replacingOccurrences(of: c, with: "'") }
        // Yangi alifbo harflarini Google tushunadigan eski yozuvga qaytaramiz
        let map: [(String, String)] = [
            ("\u{011F}", "g'"), ("\u{011E}", "G'"),
            ("\u{00F6}", "o'"), ("\u{00D6}", "O'"),
            ("\u{015F}", "sh"), ("\u{015E}", "Sh"),
            ("\u{00E7}", "ch"), ("\u{00C7}", "Ch")
        ]
        for (a, b) in map { t = t.replacingOccurrences(of: a, with: b) }
        return t
    }

    func translate(_ word: String, completion: @escaping (String?) -> Void) {
        let q = Translator.normalize(word)
        let key = source + "|" + q.lowercased()
        if let hit = cache[key] { completion(hit); return }

        var comps = URLComponents(string: "https://translate.googleapis.com/translate_a/single")!
        comps.queryItems = [
            URLQueryItem(name: "client", value: "gtx"),
            URLQueryItem(name: "sl", value: source),
            URLQueryItem(name: "tl", value: "en"),
            URLQueryItem(name: "dt", value: "t"),
            URLQueryItem(name: "dt", value: "bd"),
            URLQueryItem(name: "q", value: q)
        ]
        guard let url = comps.url else { completion(nil); return }
        let req = URLRequest(url: url, timeoutInterval: 5)

        URLSession.shared.dataTask(with: req) { [weak self] data, _, _ in
            var result: String?
            if let data = data,
               let json = (try? JSONSerialization.jsonObject(with: data)) as? [Any] {
                result = Translator.parse(json, original: q)
            }
            DispatchQueue.main.async {
                if let r = result { self?.cache[key] = r }
                completion(result)
            }
        }.resume()
    }

    // Javob: [[["book","kitob",...]], [["noun",["book","volume"],...]], "uz", ...]
    static func parse(_ json: [Any], original: String) -> String? {
        guard let segments = json.first as? [Any] else { return nil }
        var main = ""
        for seg in segments {
            if let arr = seg as? [Any], let t = arr.first as? String { main += t }
        }
        main = main.trimmingCharacters(in: .whitespacesAndNewlines)
        if main.isEmpty { return nil }

        var parts = [main]
        if json.count > 1, let dictEntries = json[1] as? [Any] {
            for entry in dictEntries {
                guard let e = entry as? [Any], e.count > 1, let terms = e[1] as? [String] else { continue }
                for t in terms where parts.count < 4 {
                    if !parts.contains(where: { $0.caseInsensitiveCompare(t) == .orderedSame }) {
                        parts.append(t)
                    }
                }
            }
        }
        // Tarjima so'zning o'ziga teng bo'lsa (tushunilmadi) — ko'rsatmaymiz
        if parts.count == 1 && main.caseInsensitiveCompare(original) == .orderedSame { return nil }
        return parts.joined(separator: "  ·  ")
    }
}

// MARK: - Kursor (yozayotgan joy) o'rnini topish

enum Caret {
    /// Cocoa koordinatalarida (pastki-chap boshi) yozilayotgan so'zning to'rtburchagi.
    static func cocoaRect(wordLength: Int) -> NSRect? {
        guard AXIsProcessTrusted() else { return nil }
        let system = AXUIElementCreateSystemWide()
        var focusedRef: CFTypeRef?
        guard AXUIElementCopyAttributeValue(system, kAXFocusedUIElementAttribute as CFString, &focusedRef) == .success,
              let f = focusedRef else { return nil }
        let el = f as! AXUIElement
        let primaryH = NSScreen.screens.first?.frame.height ?? 0

        func toCocoa(_ r: CGRect) -> NSRect {
            NSRect(x: r.minX, y: primaryH - r.maxY, width: r.width, height: r.height)
        }

        if let r = wordBounds(el, wordLength: wordLength) { return toCocoa(r) }
        if let r = elementFrame(el), r.height > 0, r.height < 200 { return toCocoa(r) }
        return nil
    }

    private static func wordBounds(_ el: AXUIElement, wordLength: Int) -> CGRect? {
        var rangeRef: CFTypeRef?
        guard AXUIElementCopyAttributeValue(el, kAXSelectedTextRangeAttribute as CFString, &rangeRef) == .success,
              let rr = rangeRef else { return nil }
        var sel = CFRange()
        guard AXValueGetValue(rr as! AXValue, .cfRange, &sel) else { return nil }
        let end = sel.location + sel.length

        var candidates: [CFRange] = []
        if wordLength > 0 && end >= wordLength {
            candidates.append(CFRange(location: end - wordLength, length: wordLength))
        }
        if end > 0 { candidates.append(CFRange(location: end - 1, length: 1)) }

        for var range in candidates {
            guard let v = AXValueCreate(.cfRange, &range) else { continue }
            var out: CFTypeRef?
            if AXUIElementCopyParameterizedAttributeValue(el, kAXBoundsForRangeParameterizedAttribute as CFString, v, &out) == .success,
               let o = out {
                var rect = CGRect.zero
                if AXValueGetValue(o as! AXValue, .cgRect, &rect),
                   rect.width > 0 || rect.height > 0,
                   rect.height < 120 {
                    return rect
                }
            }
        }
        return nil
    }

    private static func elementFrame(_ el: AXUIElement) -> CGRect? {
        var posRef: CFTypeRef?
        var sizeRef: CFTypeRef?
        guard AXUIElementCopyAttributeValue(el, kAXPositionAttribute as CFString, &posRef) == .success,
              AXUIElementCopyAttributeValue(el, kAXSizeAttribute as CFString, &sizeRef) == .success,
              let p = posRef, let s = sizeRef else { return nil }
        var pt = CGPoint.zero
        var sz = CGSize.zero
        guard AXValueGetValue(p as! AXValue, .cgPoint, &pt),
              AXValueGetValue(s as! AXValue, .cgSize, &sz) else { return nil }
        return CGRect(origin: pt, size: sz)
    }
}

// MARK: - Tepada chiqadigan oynacha

final class Popup {
    private let panel: NSPanel
    private let label = NSTextField(labelWithString: "")

    init() {
        panel = NSPanel(contentRect: NSRect(x: 0, y: 0, width: 100, height: 30),
                        styleMask: [.borderless, .nonactivatingPanel],
                        backing: .buffered, defer: false)
        panel.level = .popUpMenu
        panel.isOpaque = false
        panel.backgroundColor = .clear
        panel.hasShadow = true
        panel.ignoresMouseEvents = true
        panel.hidesOnDeactivate = false
        panel.appearance = NSAppearance(named: .darkAqua)
        panel.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary, .stationary, .ignoresCycle]

        let bg = NSVisualEffectView()
        bg.material = .hudWindow
        bg.state = .active
        bg.blendingMode = .behindWindow
        bg.wantsLayer = true
        bg.layer?.cornerRadius = 8
        bg.layer?.masksToBounds = true
        panel.contentView = bg

        label.font = .systemFont(ofSize: 15, weight: .medium)
        label.textColor = .white
        label.lineBreakMode = .byTruncatingTail
        label.maximumNumberOfLines = 1
        bg.addSubview(label)
    }

    /// anchor — Cocoa koordinatalaridagi so'z/kursor to'rtburchagi
    func show(_ text: String, anchor: NSRect) {
        label.stringValue = text
        label.sizeToFit()

        let padX: CGFloat = 12
        let padY: CGFloat = 6
        let w = min(label.frame.width, 420)
        let h = label.frame.height
        label.frame = NSRect(x: padX, y: padY, width: w, height: h)
        let size = NSSize(width: w + padX * 2, height: h + padY * 2)

        let mid = NSPoint(x: anchor.midX, y: anchor.midY)
        let screen = NSScreen.screens.first(where: { $0.frame.contains(mid) })
            ?? NSScreen.main ?? NSScreen.screens[0]
        let vis = screen.visibleFrame

        var origin = NSPoint(x: anchor.minX, y: anchor.maxY + 6)       // so'zning tepasida
        if origin.y + size.height > vis.maxY {                          // joy yetmasa — pastida
            origin.y = anchor.minY - size.height - 6
        }
        origin.x = max(vis.minX + 4, min(origin.x, vis.maxX - size.width - 4))

        panel.setFrame(NSRect(origin: origin, size: size), display: true)
        panel.orderFrontRegardless()
    }

    func hide() { panel.orderOut(nil) }
}

// MARK: - Klaviatura kuzatuvchi

final class Controller {
    let translator: Translator
    let popup = Popup()
    var enabled = true
    var isLayoutKey: ((NSEvent) -> Bool)?      // o'ng ⌘+G kabi klaviatura tugmasi ekanini aytadi

    private var buffer = ""
    private var pending: DispatchWorkItem?
    private var token = 0
    private var monitors: [Any] = []
    private let apostrophes: Set<Character> = ["'", "ʻ", "ʼ", "’", "‘", "`"]

    init(source: String) { translator = Translator(source: source) }

    func start() {
        if let m = NSEvent.addGlobalMonitorForEvents(matching: .keyDown, handler: { [weak self] e in
            self?.handleKey(e)
        }) { monitors.append(m) }

        if let m = NSEvent.addGlobalMonitorForEvents(matching: [.leftMouseDown, .rightMouseDown], handler: { [weak self] _ in
            self?.reset()
        }) { monitors.append(m) }

        NSWorkspace.shared.notificationCenter.addObserver(
            forName: NSWorkspace.didActivateApplicationNotification, object: nil, queue: .main
        ) { [weak self] _ in self?.reset() }
    }

    func reset() {
        pending?.cancel()
        token += 1
        buffer = ""
        popup.hide()
    }

    /// Yangi alifbo harfi yozilganda (o'ng ⌘+G va h.k.) chaqiriladi
    func appendTyped(_ s: String) {
        guard enabled else { return }
        for ch in s {
            if ch.isLetter || (apostrophes.contains(ch) && !buffer.isEmpty) {
                buffer.append(ch)
            } else {
                reset()
                return
            }
        }
        schedule()
    }

    private func handleKey(_ e: NSEvent) {
        guard enabled else { return }
        // O'zimiz yuborgan sintetik tugmalar appendTyped orqali qo'shiladi — bu yerda e'tiborsiz
        if e.cgEvent?.getIntegerValueField(.eventSourceUserData) == UzbekLayout.marker { return }
        let mods = e.modifierFlags.intersection(.deviceIndependentFlagsMask)
        if mods.contains(.command), isLayoutKey?(e) == true { return }
        if mods.contains(.command) || mods.contains(.control) { reset(); return }

        switch e.keyCode {
        case 51:                                   // Backspace
            if !buffer.isEmpty { buffer.removeLast() }
            if buffer.isEmpty { reset() } else { schedule() }
            return
        case 36, 76, 48, 53, 117, 115, 119, 116, 121, 123, 124, 125, 126:
            reset()                                // Return, Tab, Esc, Delete, Home/End, strelkalar...
            return
        default:
            break
        }

        guard let chars = e.characters, !chars.isEmpty else { return }
        for ch in chars {
            if ch.isLetter || (apostrophes.contains(ch) && !buffer.isEmpty) {
                buffer.append(ch)
            } else {
                reset()                            // probel, raqam, belgi — so'z tugadi
                return
            }
        }
        schedule()
    }

    private func schedule() {
        pending?.cancel()
        token += 1
        let myToken = token
        let word = buffer
        guard word.count >= 2 else { popup.hide(); return }

        let work = DispatchWorkItem { [weak self] in
            guard let self = self else { return }
            self.translator.translate(word) { result in
                guard self.token == myToken, self.buffer == word else { return }
                if let r = result { self.present(r) } else { self.popup.hide() }
            }
        }
        pending = work
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.3, execute: work)
    }

    private func present(_ text: String) {
        let anchor = Caret.cocoaRect(wordLength: buffer.count) ?? mouseAnchor()
        popup.show(text, anchor: anchor)
    }

    private func mouseAnchor() -> NSRect {
        let p = NSEvent.mouseLocation
        return NSRect(x: p.x + 8, y: p.y - 4, width: 1, height: 20)
    }
}

// MARK: - Yangi o'zbek alifbosi klaviaturasi (2026-yil 21-oktabrdagi qonun)
// O'NG Command (⌘) bilan ishlaydi. Chap Command odatdagidek (Copy, Save...) qoladi.
//   o'ng ⌘ + G → ğ   (+ Shift → Ğ)
//   o'ng ⌘ + O → ö   (+ Shift → Ö)
//   o'ng ⌘ + S → ş   (+ Shift → Ş)
//   o'ng ⌘ + C → ç   (+ Shift → Ç)
//   o'ng ⌘ + ' → ʼ   tutuq belgisi

final class UzbekLayout {
    static let marker: Int64 = 0x555A4C59                 // o'zimiz yuborgan tugmalar belgisi
    static let tutuq = "\u{02BC}"                          // ʼ  (tutuq belgisi)

    private static let excludedApps: Set<String> = []

    var enabled = true
    var onTyped: ((String) -> Void)?

    private var tap: CFMachPort?
    private var swallowed: Set<Int64> = []

    static func replacement(key: String, upper: Bool) -> String? {
        let isUpper = upper || key != key.lowercased()
        switch key.lowercased() {
        case "g": return isUpper ? "\u{011E}" : "\u{011F}"      // Ğ ğ
        case "o": return isUpper ? "\u{00D6}" : "\u{00F6}"      // Ö ö
        case "s": return isUpper ? "\u{015E}" : "\u{015F}"      // Ş ş
        case "c": return isUpper ? "\u{00C7}" : "\u{00E7}"      // Ç ç
        case "'", "\"": return tutuq                             // tutuq belgisi
        default: return nil
        }
    }

    static func frontmostIsExcluded() -> Bool {
        guard let id = NSWorkspace.shared.frontmostApplication?.bundleIdentifier else { return false }
        return excludedApps.contains(id)
    }

    /// O'ng Command bosilganmi (chap Command emas)?
    static func isRightCommand(_ raw: UInt64) -> Bool {
        (raw & 0x10) != 0 && (raw & 0x08) == 0        // NX_DEVICERCMDKEYMASK / NX_DEVICELCMDKEYMASK
    }

    /// NSEvent o'ng ⌘ + G/O/S/C/' kombinatsiyasimi?
    func isLayoutKey(_ e: NSEvent) -> Bool {
        guard enabled else { return false }
        let m = e.modifierFlags.intersection(.deviceIndependentFlagsMask)
        guard m.contains(.command), !m.contains(.control), !m.contains(.option),
              UzbekLayout.isRightCommand(UInt64(e.modifierFlags.rawValue)) else { return false }
        guard let k = e.charactersIgnoringModifiers else { return false }
        return UzbekLayout.replacement(key: k, upper: false) != nil
    }

    @discardableResult
    func start() -> Bool {
        if tap != nil { return true }
        let mask: CGEventMask = (CGEventMask(1) << CGEventType.keyDown.rawValue)
                              | (CGEventMask(1) << CGEventType.keyUp.rawValue)
        let callback: CGEventTapCallBack = { _, type, event, refcon in
            guard let refcon = refcon else { return Unmanaged.passUnretained(event) }
            let me = Unmanaged<UzbekLayout>.fromOpaque(refcon).takeUnretainedValue()
            return me.handle(type: type, event: event)
        }
        guard let t = CGEvent.tapCreate(tap: .cgSessionEventTap,
                                        place: .headInsertEventTap,
                                        options: .defaultTap,
                                        eventsOfInterest: mask,
                                        callback: callback,
                                        userInfo: Unmanaged.passUnretained(self).toOpaque()) else {
            return false                                   // Accessibility ruxsati hali yo'q
        }
        tap = t
        let src = CFMachPortCreateRunLoopSource(kCFAllocatorDefault, t, 0)
        CFRunLoopAddSource(CFRunLoopGetMain(), src, .commonModes)
        CGEvent.tapEnable(tap: t, enable: true)
        return true
    }

    func handle(type: CGEventType, event: CGEvent) -> Unmanaged<CGEvent>? {
        let pass = Unmanaged.passUnretained(event)

        if type == .tapDisabledByTimeout || type == .tapDisabledByUserInput {
            if let t = tap { CGEvent.tapEnable(tap: t, enable: true) }
            return pass
        }
        guard enabled else { return pass }
        if event.getIntegerValueField(.eventSourceUserData) == UzbekLayout.marker { return pass }

        let keyCode = event.getIntegerValueField(.keyboardEventKeycode)

        if type == .keyUp {
            if swallowed.remove(keyCode) != nil { return nil }
            return pass
        }
        guard type == .keyDown else { return pass }

        let flags = event.flags
        guard flags.contains(.maskCommand),
              !flags.contains(.maskControl),
              !flags.contains(.maskAlternate),
              UzbekLayout.isRightCommand(flags.rawValue),
              let ns = NSEvent(cgEvent: event),
              let key = ns.charactersIgnoringModifiers,
              let out = UzbekLayout.replacement(key: key,
                                                upper: flags.contains(.maskShift) || flags.contains(.maskAlphaShift))
        else { return pass }

        swallowed.insert(keyCode)
        DispatchQueue.main.async { [weak self] in
            self?.insertText(out)
            self?.onTyped?(out)
        }
        return nil                                         // asl ⌘+G ni yutib yuboramiz
    }

    private func insertText(_ s: String) {
        let units = Array(s.utf16)
        let src = CGEventSource(stateID: .privateState)
        for down in [true, false] {
            guard let ev = CGEvent(keyboardEventSource: src, virtualKey: 0, keyDown: down) else { continue }
            ev.flags = []                                  // ⌘ bosilib turgan bo'lsa ham, oddiy matn sifatida
            ev.setIntegerValueField(.eventSourceUserData, value: UzbekLayout.marker)
            ev.keyboardSetUnicodeString(stringLength: units.count, unicodeString: units)
            ev.post(tap: .cgSessionEventTap)
        }
    }
}

// MARK: - Menyu paneli va ilova

final class AppDelegate: NSObject, NSApplicationDelegate {
    private var statusItem: NSStatusItem!
    private var controller: Controller!
    private var toggleItem: NSMenuItem!
    private var layoutItem: NSMenuItem!
    private var statusLine: NSMenuItem!
    private var layout: UzbekLayout!
    private var langItems: [String: NSMenuItem] = [:]

    func applicationDidFinishLaunching(_ notification: Notification) {
        let saved = UserDefaults.standard.string(forKey: "source") ?? "uz"
        controller = Controller(source: saved)

        layout = UzbekLayout()
        layout.enabled = (UserDefaults.standard.object(forKey: "layout") as? Bool) ?? true
        layout.onTyped = { [weak self] s in self?.controller.appendTyped(s) }
        controller.isLayoutKey = { [weak self] e in self?.layout.isLayoutKey(e) ?? false }

        _ = AXIsProcessTrustedWithOptions(["AXTrustedCheckOptionPrompt": true] as CFDictionary)
        if !CGPreflightListenEventAccess() { _ = CGRequestListenEventAccess() }

        controller.start()
        buildMenu(selected: saved)
        startLayoutWithRetry()
    }

    /// Ruxsat berilmaguncha har 2 soniyada qayta urinadi
    private func startLayoutWithRetry() {
        if layout.start() { setStatus(ok: true); return }
        setStatus(ok: false)
        Timer.scheduledTimer(withTimeInterval: 2, repeats: true) { [weak self] t in
            if self?.layout.start() == true {
                self?.setStatus(ok: true)
                t.invalidate()
            }
        }
    }

    private func setStatus(ok: Bool) {
        statusLine?.title = ok ? "Klaviatura: tayyor \u{2713}" : "Klaviatura: ruxsat kerak \u{2717} (Accessibility)"
    }

    private func buildMenu(selected: String) {
        statusItem = NSStatusBar.system.statusItem(withLength: NSStatusItem.variableLength)
        statusItem.button?.title = "→EN"

        let menu = NSMenu()

        statusLine = NSMenuItem(title: "Klaviatura: tekshirilmoqda...", action: nil, keyEquivalent: "")
        statusLine.isEnabled = false
        menu.addItem(statusLine)
        menu.addItem(.separator())

        toggleItem = NSMenuItem(title: "Tarjima oynachasi", action: #selector(toggle), keyEquivalent: "")
        toggleItem.target = self
        toggleItem.state = .on
        menu.addItem(toggleItem)

        layoutItem = NSMenuItem(title: "Yangi alifbo: o'ng Command + G/O/S/C/'", action: #selector(toggleLayout), keyEquivalent: "")
        layoutItem.target = self
        layoutItem.state = layout.enabled ? .on : .off
        menu.addItem(layoutItem)

        let langMenu = NSMenu()
        let langs: [(String, String)] = [("uz", "O'zbekcha"), ("ru", "Ruscha"), ("auto", "Avtomatik aniqlash")]
        for (code, title) in langs {
            let item = NSMenuItem(title: title, action: #selector(pickLang(_:)), keyEquivalent: "")
            item.target = self
            item.representedObject = code
            item.state = (code == selected) ? .on : .off
            langMenu.addItem(item)
            langItems[code] = item
        }
        let langParent = NSMenuItem(title: "Qaysi tildan tarjima", action: nil, keyEquivalent: "")
        langParent.submenu = langMenu
        menu.addItem(langParent)

        menu.addItem(.separator())

        let acc = NSMenuItem(title: "Ruxsat: Accessibility…", action: #selector(openAccessibility), keyEquivalent: "")
        acc.target = self
        menu.addItem(acc)
        let inp = NSMenuItem(title: "Ruxsat: Input Monitoring…", action: #selector(openInputMonitoring), keyEquivalent: "")
        inp.target = self
        menu.addItem(inp)

        menu.addItem(.separator())
        menu.addItem(NSMenuItem(title: "Chiqish", action: #selector(NSApplication.terminate(_:)), keyEquivalent: "q"))

        statusItem.menu = menu
    }

    @objc private func toggle() {
        controller.enabled.toggle()
        toggleItem.state = controller.enabled ? .on : .off
        if !controller.enabled { controller.reset() }
    }

    @objc private func toggleLayout() {
        layout.enabled.toggle()
        layoutItem.state = layout.enabled ? .on : .off
        UserDefaults.standard.set(layout.enabled, forKey: "layout")
    }

    @objc private func pickLang(_ sender: NSMenuItem) {
        guard let code = sender.representedObject as? String else { return }
        controller.translator.source = code
        UserDefaults.standard.set(code, forKey: "source")
        for (c, item) in langItems { item.state = (c == code) ? .on : .off }
    }

    @objc private func openAccessibility() {
        open("x-apple.systempreferences:com.apple.preference.security?Privacy_Accessibility")
    }

    @objc private func openInputMonitoring() {
        open("x-apple.systempreferences:com.apple.preference.security?Privacy_ListenEvent")
    }

    private func open(_ s: String) {
        if let url = URL(string: s) { NSWorkspace.shared.open(url) }
    }
}

let app = NSApplication.shared
let delegate = AppDelegate()
app.delegate = delegate
app.setActivationPolicy(.accessory)      // Dock'da ko'rinmaydi, faqat menyu panelida
app.run()
