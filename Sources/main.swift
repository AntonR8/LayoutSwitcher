import Cocoa
import Carbon.HIToolbox
import ServiceManagement

// Метка на синтезированных нами событиях, чтобы не записывать их обратно в буфер.
let kMagic: Int64 = 0x4C_53_57_54  // "LSWT"

/// Одно нажатие: физическая клавиша, модификаторы, а также что она дала
/// и в какой раскладке это было набрано.
struct Stroke {
    let keyCode: CGKeyCode
    let modifierState: UInt32
    let produced: String
    let sourceID: String
}

// MARK: - Раскладки

enum Layouts {

    private static func bool(_ src: TISInputSource, _ key: CFString) -> Bool {
        guard let p = TISGetInputSourceProperty(src, key) else { return false }
        return CFBooleanGetValue(Unmanaged<CFBoolean>.fromOpaque(p).takeUnretainedValue())
    }

    static func identifier(_ src: TISInputSource) -> String {
        guard let p = TISGetInputSourceProperty(src, kTISPropertyInputSourceID) else { return "?" }
        return Unmanaged<CFString>.fromOpaque(p).takeUnretainedValue() as String
    }

    static func name(_ src: TISInputSource) -> String {
        guard let p = TISGetInputSourceProperty(src, kTISPropertyLocalizedName) else { return "?" }
        return Unmanaged<CFString>.fromOpaque(p).takeUnretainedValue() as String
    }

    private static func layoutData(_ src: TISInputSource) -> Data? {
        guard let p = TISGetInputSourceProperty(src, kTISPropertyUnicodeKeyLayoutData) else { return nil }
        return Unmanaged<CFData>.fromOpaque(p).takeUnretainedValue() as Data
    }

    /// Включённые раскладки, у которых есть таблица трансляции (отсеивает IME вроде пиньиня).
    static func enabled() -> [TISInputSource] {
        let filter = [kTISPropertyInputSourceCategory as String: kTISCategoryKeyboardInputSource as String] as CFDictionary
        guard let arr = TISCreateInputSourceList(filter, false)?.takeRetainedValue() as? [TISInputSource] else { return [] }
        return arr.filter { layoutData($0) != nil && bool($0, kTISPropertyInputSourceIsSelectCapable) }
    }

    static func current() -> TISInputSource? {
        TISCopyCurrentKeyboardInputSource()?.takeRetainedValue()
    }

    static func source(withID id: String) -> TISInputSource? {
        enabled().first { identifier($0) == id }
    }

    /// Парная раскладка: к латинской — первая нелатинская и наоборот.
    static func counterpart(of src: TISInputSource) -> TISInputSource? {
        let all = enabled()
        let isASCII = bool(src, kTISPropertyInputSourceIsASCIICapable)
        let curID = identifier(src)
        if let match = all.first(where: { bool($0, kTISPropertyInputSourceIsASCIICapable) != isASCII }) {
            return match
        }
        return all.first { identifier($0) != curID }
    }

    static func select(_ src: TISInputSource) {
        TISSelectInputSource(src)
    }

    /// Во что превращается это нажатие в заданной раскладке.
    static func translate(_ keyCode: CGKeyCode, _ modifierState: UInt32, with src: TISInputSource) -> String? {
        guard let data = layoutData(src) else { return nil }
        var chars = [UniChar](repeating: 0, count: 8)
        var length = 0
        var deadKeyState: UInt32 = 0
        let status: OSStatus = data.withUnsafeBytes { raw in
            guard let base = raw.baseAddress else { return OSStatus(paramErr) }
            return UCKeyTranslate(base.assumingMemoryBound(to: UCKeyboardLayout.self),
                                  UInt16(keyCode),
                                  UInt16(kUCKeyActionDown),
                                  modifierState,
                                  UInt32(LMGetKbdType()),
                                  OptionBits(kUCKeyTranslateNoDeadKeysMask),
                                  &deadKeyState,
                                  8, &length, &chars)
        }
        guard status == noErr, length > 0 else { return nil }
        return String(utf16CodeUnits: chars, count: length)
    }
}

// MARK: - Движок

final class Engine {
    static let shared = Engine()

    private var tap: CFMachPort?

    /// Набранное как есть — источник правды, при перебивке не меняется.
    private var buffer: [Stroke] = []
    /// Что сейчас реально на экране для каждого нажатия из буфера.
    private var shown: [String] = []

    private var lastShiftRelease: CFAbsoluteTime = 0
    private var shiftHeld = false
    private var keyPressedDuringShift = false

    /// Насколько широко перебиваем: индекс в списке границ (0 — слово).
    private var expansionLevel = 0
    private var lastConvertAt: CFAbsoluteTime = 0

    /// Пауза между двумя нажатиями Shift, при которой они считаются двойным.
    var doubleTapWindow: CFAbsoluteTime = 0.4
    /// Сколько ждём следующего двойного Shift, чтобы расширить охват, а не начать заново.
    var expandWindow: CFAbsoluteTime = 2.0

    private var retryTimer: Timer?

    /// Пытается поднять перехват; если доступа ещё нет — ждёт его и поднимает сам,
    /// чтобы не требовать перезапуска после выдачи разрешения.
    func startOrWaitForPermission() {
        if start() { return }
        retryTimer?.invalidate()
        retryTimer = Timer.scheduledTimer(withTimeInterval: 2.0, repeats: true) { [weak self] timer in
            guard AXIsProcessTrusted(), let self else { return }
            if self.start() {
                timer.invalidate()
                self.retryTimer = nil
            }
        }
    }

    @discardableResult
    func start() -> Bool {
        let mask = (1 << CGEventType.keyDown.rawValue)
                 | (1 << CGEventType.flagsChanged.rawValue)
                 | (1 << CGEventType.leftMouseDown.rawValue)
                 | (1 << CGEventType.rightMouseDown.rawValue)

        guard let tap = CGEvent.tapCreate(tap: .cgSessionEventTap,
                                          place: .headInsertEventTap,
                                          options: .listenOnly,
                                          eventsOfInterest: CGEventMask(mask),
                                          callback: { _, type, event, _ in
                                              Engine.shared.handle(type: type, event: event)
                                              return Unmanaged.passUnretained(event)
                                          },
                                          userInfo: nil) else {
            return false
        }

        self.tap = tap
        let source = CFMachPortCreateRunLoopSource(kCFAllocatorDefault, tap, 0)
        CFRunLoopAddSource(CFRunLoopGetMain(), source, .commonModes)
        CGEvent.tapEnable(tap: tap, enable: true)
        return true
    }

    fileprivate func handle(type: CGEventType, event: CGEvent) {
        if type == .tapDisabledByTimeout || type == .tapDisabledByUserInput {
            if let tap { CGEvent.tapEnable(tap: tap, enable: true) }
            return
        }
        guard event.getIntegerValueField(.eventSourceUserData) != kMagic else { return }

        switch type {
        case .leftMouseDown, .rightMouseDown:
            reset()
        case .flagsChanged:
            handleFlags(event)
        case .keyDown:
            handleKey(event)
        default:
            break
        }
    }

    private func reset() {
        buffer.removeAll()
        shown.removeAll()
        expansionLevel = 0
    }

    private func handleFlags(_ event: CGEvent) {
        let code = CGKeyCode(event.getIntegerValueField(.keyboardEventKeycode))
        guard code == 56 || code == 60 else { return }   // левый / правый Shift

        if event.flags.contains(.maskShift) {
            shiftHeld = true
            keyPressedDuringShift = false
            return
        }
        guard shiftHeld else { return }
        shiftHeld = false

        // Shift использовали как модификатор — это не «тап».
        if keyPressedDuringShift {
            lastShiftRelease = 0
            return
        }
        let now = CFAbsoluteTimeGetCurrent()
        if now - lastShiftRelease < doubleTapWindow {
            lastShiftRelease = 0
            convert()
        } else {
            lastShiftRelease = now
        }
    }

    private func handleKey(_ event: CGEvent) {
        keyPressedDuringShift = true
        // Любой набор прерывает цепочку расширений.
        expansionLevel = 0

        let code = CGKeyCode(event.getIntegerValueField(.keyboardEventKeycode))
        let flags = event.flags

        // Сочетания с Cmd/Ctrl/Option — команды, а не набор текста.
        if flags.contains(.maskCommand) || flags.contains(.maskControl) || flags.contains(.maskAlternate) {
            reset()
            return
        }

        switch Int(code) {
        case kVK_Delete:
            if !buffer.isEmpty { buffer.removeLast(); shown.removeLast() }
            return
        // Уводят каретку или начинают новую строку — прежний контекст больше не наш.
        case kVK_Return, kVK_Tab, kVK_Escape, kVK_ANSI_KeypadEnter, kVK_ForwardDelete,
             kVK_LeftArrow, kVK_RightArrow, kVK_UpArrow, kVK_DownArrow,
             kVK_Home, kVK_End, kVK_PageUp, kVK_PageDown:
            reset()
            return
        default:
            break
        }

        let modifierState = UInt32((flags.rawValue >> 16) & 0xFF)

        // Клавиши без печатного результата (F1, Caps и т.п.) контекст обрывают.
        guard let current = Layouts.current(),
              let produced = Layouts.translate(code, modifierState, with: current),
              !produced.isEmpty else {
            reset()
            return
        }

        buffer.append(Stroke(keyCode: code, modifierState: modifierState,
                             produced: produced, sourceID: Layouts.identifier(current)))
        shown.append(produced)

        if buffer.count > 512 {
            let extra = buffer.count - 512
            buffer.removeFirst(extra)
            shown.removeFirst(extra)
        }
    }

    // MARK: Границы охвата

    private func isBlank(_ s: String) -> Bool { Extent.isBlank(s) }

    private func expansionStarts() -> [Int] {
        Extent.starts(shown: shown, sourceIDs: buffer.map(\.sourceID))
    }

    // MARK: Перебивка

    /// - Parameter expanding: `false` — всегда начинать со слова (вызов из меню).
    func convert(expanding: Bool = true) {
        guard !buffer.isEmpty else { return }

        let now = CFAbsoluteTimeGetCurrent()
        if expanding && now - lastConvertAt < expandWindow {
            expansionLevel += 1
        } else {
            expansionLevel = 0
        }

        let starts = expansionStarts()
        guard !starts.isEmpty else { return }
        expansionLevel = min(expansionLevel, starts.count - 1)

        let start = starts[expansionLevel]
        let extent = Array(start..<buffer.count)
        guard !extent.isEmpty else { return }

        // Если весь охват уже перебит — вернуть как было набрано.
        let meaningful = extent.filter { !isBlank(buffer[$0].produced) }
        let allConverted = !meaningful.isEmpty
            && meaningful.allSatisfy { shown[$0] != buffer[$0].produced }

        var replacement = ""
        var updated: [String] = []
        var targetCache: [String: TISInputSource] = [:]
        var finalSource: TISInputSource?

        for index in extent {
            let stroke = buffer[index]
            let piece: String
            if allConverted {
                piece = stroke.produced
                finalSource = Layouts.source(withID: stroke.sourceID)
            } else {
                let target: TISInputSource
                if let cached = targetCache[stroke.sourceID] {
                    target = cached
                } else {
                    guard let origin = Layouts.source(withID: stroke.sourceID),
                          let pair = Layouts.counterpart(of: origin) else { return }
                    targetCache[stroke.sourceID] = pair
                    target = pair
                }
                guard let converted = Layouts.translate(stroke.keyCode, stroke.modifierState, with: target) else { return }
                piece = converted
                finalSource = target
            }
            replacement += piece
            updated.append(piece)
        }
        guard !replacement.isEmpty else { return }

        let deleteCount = extent.reduce(0) { $0 + shown[$1].count }
        if let source = finalSource { Layouts.select(source) }

        // Дать системе применить раскладку прежде, чем печатать.
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.05) { [weak self] in
            guard let self else { return }
            self.sendBackspaces(deleteCount)
            self.sendText(replacement)
            for (offset, index) in extent.enumerated() { self.shown[index] = updated[offset] }
            self.lastConvertAt = CFAbsoluteTimeGetCurrent()
        }
    }

    private func post(_ event: CGEvent?) {
        guard let event else { return }
        event.setIntegerValueField(.eventSourceUserData, value: kMagic)
        event.post(tap: .cghidEventTap)
    }

    private func sendBackspaces(_ count: Int) {
        let source = CGEventSource(stateID: .privateState)
        for _ in 0..<count {
            post(CGEvent(keyboardEventSource: source, virtualKey: CGKeyCode(kVK_Delete), keyDown: true))
            post(CGEvent(keyboardEventSource: source, virtualKey: CGKeyCode(kVK_Delete), keyDown: false))
            usleep(1500)
        }
    }

    private func sendText(_ text: String) {
        let source = CGEventSource(stateID: .privateState)
        for character in text {
            var units = Array(String(character).utf16)
            let down = CGEvent(keyboardEventSource: source, virtualKey: 0, keyDown: true)
            down?.keyboardSetUnicodeString(stringLength: units.count, unicodeString: &units)
            post(down)
            let up = CGEvent(keyboardEventSource: source, virtualKey: 0, keyDown: false)
            up?.keyboardSetUnicodeString(stringLength: units.count, unicodeString: &units)
            post(up)
            usleep(1500)
        }
    }
}

// MARK: - Приложение

final class AppDelegate: NSObject, NSApplicationDelegate {
    private var statusItem: NSStatusItem!
    private var loginItem: NSMenuItem!

    /// Значок в строке меню. Любое имя из SF Symbols — посмотреть можно в SF Symbols.app.
    private static let symbolName = "repeat.circle.fill"
    /// Значок, когда нет доступа к клавиатуре.
    private static let alertSymbolName = "exclamationmark.triangle"

    /// Ставит символ на кнопку. Template-режим — чтобы система сама красила
    /// его под светлую/тёмную тему и режим повышенного контраста.
    private func setSymbol(_ name: String) {
        guard let button = statusItem.button else { return }
        let config = NSImage.SymbolConfiguration(pointSize: 16, weight: .regular)
        if let image = NSImage(systemSymbolName: name, accessibilityDescription: "LayoutSwitcher")?
            .withSymbolConfiguration(config) {
            image.isTemplate = true
            button.image = image
            button.title = ""
        } else {
            button.image = nil          // нет такого символа — не оставлять кнопку пустой
            button.title = "⇄"
        }
    }

    func applicationDidFinishLaunching(_ notification: Notification) {
        statusItem = NSStatusBar.system.statusItem(withLength: NSStatusItem.variableLength)
        setSymbol(Self.symbolName)

        let menu = NSMenu()
        let convert = NSMenuItem(title: "Перебить последнее слово",
                                 action: #selector(convertNow), keyEquivalent: "")
        convert.target = self
        menu.addItem(convert)

        let hint = NSMenuItem(title: "Двойной Shift — слово. Ещё раз — шире.", action: nil, keyEquivalent: "")
        hint.isEnabled = false
        menu.addItem(hint)
        menu.addItem(.separator())

        loginItem = NSMenuItem(title: "Запускать при входе", action: #selector(toggleLogin), keyEquivalent: "")
        loginItem.target = self
        menu.addItem(loginItem)
        menu.addItem(.separator())

        menu.addItem(NSMenuItem(title: "Выйти", action: #selector(NSApplication.terminate(_:)), keyEquivalent: "q"))
        statusItem.menu = menu

        refreshLoginState()
        requestAccessibilityIfNeeded()

        Engine.shared.startOrWaitForPermission()

        if !AXIsProcessTrusted() {
            setSymbol(Self.alertSymbolName)
            let alert = NSAlert()
            alert.messageText = "Нужен доступ к клавиатуре"
            alert.informativeText = "Откройте Настройки → Конфиденциальность и безопасность → Универсальный доступ и включите LayoutSwitcher. Перезапускать программу не нужно — она подхватит разрешение сама."
            alert.addButton(withTitle: "Открыть настройки")
            alert.addButton(withTitle: "Позже")
            if alert.runModal() == .alertFirstButtonReturn,
               let url = URL(string: "x-apple.systempreferences:com.apple.preference.security?Privacy_Accessibility") {
                NSWorkspace.shared.open(url)
            }
            // Вернуть обычный значок, когда доступ появится.
            Timer.scheduledTimer(withTimeInterval: 2.0, repeats: true) { [weak self] timer in
                guard AXIsProcessTrusted() else { return }
                self?.setSymbol(Self.symbolName)
                timer.invalidate()
            }
        }
    }

    private func requestAccessibilityIfNeeded() {
        let options = [kAXTrustedCheckOptionPrompt.takeUnretainedValue() as String: true] as CFDictionary
        _ = AXIsProcessTrustedWithOptions(options)
    }

    @objc private func convertNow() {
        Engine.shared.convert(expanding: false)
    }

    @objc private func toggleLogin() {
        do {
            if SMAppService.mainApp.status == .enabled {
                try SMAppService.mainApp.unregister()
            } else {
                try SMAppService.mainApp.register()
            }
        } catch {
            NSLog("login item: \(error)")
        }
        refreshLoginState()
    }

    private func refreshLoginState() {
        loginItem.state = SMAppService.mainApp.status == .enabled ? .on : .off
    }
}

let app = NSApplication.shared
let delegate = AppDelegate()
app.delegate = delegate
app.setActivationPolicy(.accessory)
app.run()
