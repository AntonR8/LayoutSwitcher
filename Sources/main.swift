import Cocoa
import Carbon.HIToolbox
import ServiceManagement

// Метка на синтезированных нами событиях, чтобы не записывать их обратно в буфер.
let kMagic: Int64 = 0x4C_53_57_54  // "LSWT"

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

    static func isASCII(_ src: TISInputSource) -> Bool {
        bool(src, kTISPropertyInputSourceIsASCIICapable)
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

    static func select(_ src: TISInputSource) {
        TISSelectInputSource(src)
    }

    /// Пара «латинская — нелатинская» из включённых раскладок.
    static func pair() -> (latin: TISInputSource, other: TISInputSource)? {
        let all = enabled()
        guard let latin = all.first(where: { isASCII($0) }),
              let other = all.first(where: { !isASCII($0) }) else { return nil }
        return (latin, other)
    }

    /// Во что превращается нажатие в заданной раскладке.
    static func translate(_ keyCode: UInt16, _ modifierState: UInt32, with src: TISInputSource) -> String? {
        guard let data = layoutData(src) else { return nil }
        var chars = [UniChar](repeating: 0, count: 8)
        var length = 0
        var deadKeyState: UInt32 = 0
        let status: OSStatus = data.withUnsafeBytes { raw in
            guard let base = raw.baseAddress else { return OSStatus(paramErr) }
            return UCKeyTranslate(base.assumingMemoryBound(to: UCKeyboardLayout.self),
                                  keyCode,
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

    /// Запасной буфер: что набрано с клавиатуры. Нужен только там, где поле
    /// не отдаёт текст через Accessibility.
    private var typed: [Character] = []

    private var lastShiftRelease: CFAbsoluteTime = 0
    private var shiftHeld = false
    private var keyPressedDuringShift = false

    /// Насколько широко перебиваем: индекс в списке границ (0 — слово).
    private var expansionLevel = 0
    private var lastConvertAt: CFAbsoluteTime = 0
    /// Текст до первой перебивки в текущей цепочке расширений — от него
    /// каждый следующий уровень считается заново, иначе уже перебитое
    /// перевернулось бы обратно.
    private var chainBase: String?
    private var lastWritten: String?

    /// Пауза между двумя нажатиями Shift, при которой они считаются двойным.
    var doubleTapWindow: CFAbsoluteTime = 0.4
    /// Сколько ждём следующего двойного Shift, чтобы расширить охват, а не начать заново.
    var expandWindow: CFAbsoluteTime = 2.0

    private var retryTimer: Timer?
    private var cachedMappings: (key: String, pair: MappingPair)?

    // MARK: Запуск

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

    // MARK: События

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
        typed.removeAll()
        expansionLevel = 0
        chainBase = nil
    }

    private func handleFlags(_ event: CGEvent) {
        let code = event.getIntegerValueField(.keyboardEventKeycode)
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
        expansionLevel = 0
        chainBase = nil

        let code = event.getIntegerValueField(.keyboardEventKeycode)
        let flags = event.flags

        // Сочетания с Cmd/Ctrl/Option — команды, а не набор текста.
        if flags.contains(.maskCommand) || flags.contains(.maskControl) || flags.contains(.maskAlternate) {
            reset()
            return
        }

        switch Int(code) {
        case kVK_Delete:
            if !typed.isEmpty { typed.removeLast() }
            return
        case kVK_Return, kVK_Tab, kVK_Escape, kVK_ANSI_KeypadEnter, kVK_ForwardDelete,
             kVK_LeftArrow, kVK_RightArrow, kVK_UpArrow, kVK_DownArrow,
             kVK_Home, kVK_End, kVK_PageUp, kVK_PageDown:
            reset()
            return
        default:
            break
        }

        // Символ берём из самого события — так надёжнее, чем пересчитывать раскладку.
        var length = 0
        var buffer = [UniChar](repeating: 0, count: 4)
        event.keyboardGetUnicodeString(maxStringLength: 4, actualStringLength: &length, unicodeString: &buffer)
        guard length > 0 else { reset(); return }

        let produced = String(utf16CodeUnits: buffer, count: length)
        guard !produced.isEmpty, produced.first?.isNewline != true else { reset(); return }

        typed.append(contentsOf: produced)
        if typed.count > 512 { typed.removeFirst(typed.count - 512) }
    }

    // MARK: Таблицы соответствий

    private func mappings() -> MappingPair? {
        guard let (latin, other) = Layouts.pair() else { return nil }
        let key = Layouts.identifier(latin) + "|" + Layouts.identifier(other)
        if let cached = cachedMappings, cached.key == key { return cached.pair }

        let pair = MappingPair(
            latinToCyrillic: Mapping(from: { Layouts.translate($0, $1, with: latin) },
                                     to:   { Layouts.translate($0, $1, with: other) }),
            cyrillicToLatin: Mapping(from: { Layouts.translate($0, $1, with: other) },
                                     to:   { Layouts.translate($0, $1, with: latin) })
        )
        cachedMappings = (key, pair)
        return pair
    }

    /// Алфавит включённой сейчас раскладки. Нужен, когда в охвате нет ни одной
    /// буквы («.», «123») и направление по содержимому не вывести: такой текст
    /// набран в текущей раскладке, значит перебивать его надо из неё.
    private func currentScript() -> Script {
        guard let src = Layouts.current() else { return .latin }
        return Layouts.isASCII(src) ? .latin : .cyrillic
    }

    /// Переключить ввод под алфавит, который получился после перебивки.
    private func selectLayout(for script: Script) {
        guard let (latin, other) = Layouts.pair() else { return }
        switch script {
        case .latin:    Layouts.select(latin)
        case .cyrillic: Layouts.select(other)
        case .other:    break
        }
    }

    // MARK: Диагностика

    /// Состояние всех узлов, на которых перебивка может молча остановиться.
    /// Каждая строка отвечает на вопрос «а этот шаг вообще отработал?».
    func diagnostics() -> String {
        var out: [String] = []
        let version = Bundle.main.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String ?? "?"
        out.append("LayoutSwitcher \(version)")
        out.append("путь: \(Bundle.main.bundlePath)")
        out.append("доступ к клавиатуре: \(AXIsProcessTrusted() ? "есть" : "НЕТ")")
        out.append("перехват событий: \(tap != nil ? "поднят" : "НЕ ПОДНЯТ")")

        let sources = Layouts.enabled()
        out.append("включённых раскладок: \(sources.count)")
        for s in sources {
            out.append("  • \(Layouts.identifier(s)) — \(Layouts.isASCII(s) ? "латинская" : "нелатинская")")
        }

        guard let (latin, other) = Layouts.pair() else {
            out.append("ПАРА РАСКЛАДОК НЕ СОБРАНА — нужна одна латинская и одна нелатинская")
            return out.joined(separator: "\n")
        }
        out.append("пара: \(Layouts.identifier(latin)) ↔ \(Layouts.identifier(other))")

        guard let pair = mappings() else {
            out.append("ТАБЛИЦЫ НЕ ПОСТРОИЛИСЬ")
            return out.joined(separator: "\n")
        }
        out.append("таблица лат→нелат: \(pair.latinToCyrillic.forward.count) символов")
        out.append("таблица нелат→лат: \(pair.cyrillicToLatin.forward.count) символов")
        out.append("проверка «ghjdthrf» → «\(pair.convert("ghjdthrf"))»")

        if let field = AXText.read() {
            out.append("чтение поля: работает, в фокусе \(field.text.count) симв., каретка \(field.caret)")
        } else {
            out.append("чтение поля: НЕТ (это нормально, если отчёт вызван из меню)")
        }
        return out.joined(separator: "\n")
    }

    // MARK: Перебивка

    /// Первый уровень охвата начиная с `level`, на котором перебивка что-то меняет.
    /// Возвращает начало охвата, результат и номер уровня.
    private func firstChange(in starts: [Int],
                             from level: Int,
                             using pair: MappingPair,
                             fragment: (Int) -> String) -> (Int, String, Int)? {
        let script = currentScript()
        for level in min(level, starts.count - 1)..<starts.count {
            let start = starts[level]
            let text = fragment(start)
            let converted = pair.convert(text, fallback: script)
            if converted != text { return (start, converted, level) }
        }
        return nil
    }

    /// - Parameter expanding: `false` — всегда начинать со слова (вызов из меню).
    func convert(expanding: Bool = true) {
        guard let pair = mappings() else { return }
        if let field = AXText.read() {
            convertInField(field, using: pair, expanding: expanding)
        } else {
            convertByTyping(using: pair, expanding: expanding)
        }
    }

    /// Основной путь: читаем поле через Accessibility и переписываем его целиком.
    private func convertInField(_ field: AXText.Field, using pair: MappingPair, expanding: Bool) {
        let now = CFAbsoluteTimeGetCurrent()

        // Цепочка расширений продолжается, только если с прошлого раза
        // в поле ничего не менялось помимо нашей же записи.
        let continues = expanding
            && now - lastConvertAt < expandWindow
            && chainBase != nil
            && lastWritten == field.text

        let base: String
        if continues {
            base = chainBase!
            expansionLevel += 1
        } else {
            base = field.text
            chainBase = base
            expansionLevel = 0
        }

        let characters = Array(base)
        let caret = min(field.caret, characters.count)
        let before = Array(characters[0..<caret])

        let starts = Extent.starts(in: before)
        guard !starts.isEmpty else { return }

        // Уровень, на котором перебивка ничего не меняет (охват вроде «!», одинаковый
        // в обеих раскладках), пропускаем: иначе цепочка расширений на нём залипает.
        guard let (start, converted, level) = firstChange(
            in: starts, from: expansionLevel, using: pair,
            fragment: { String(characters[$0..<caret]) }
        ) else { return }
        expansionLevel = level

        let result = String(characters[0..<start]) + converted + String(characters[caret...])
        guard AXText.write(field, text: result, caret: start + converted.count) else { return }

        lastWritten = result
        lastConvertAt = CFAbsoluteTimeGetCurrent()
        selectLayout(for: MappingPair.dominantScript(of: converted))
    }

    /// Запасной путь для полей, которые не отдают текст через Accessibility:
    /// стираем забоями и печатаем заново. Опирается на буфер набранного,
    /// поэтому в полях с автодополнением работает хуже.
    private func convertByTyping(using pair: MappingPair, expanding: Bool) {
        guard !typed.isEmpty else { return }

        let now = CFAbsoluteTimeGetCurrent()
        if expanding && now - lastConvertAt < expandWindow {
            expansionLevel += 1
        } else {
            expansionLevel = 0
        }

        let starts = Extent.starts(in: typed)
        guard !starts.isEmpty else { return }

        guard let (start, converted, level) = firstChange(
            in: starts, from: expansionLevel, using: pair,
            fragment: { [typed] in String(typed[$0...]) }
        ) else { return }
        expansionLevel = level
        let fragment = String(typed[start...])

        selectLayout(for: MappingPair.dominantScript(of: converted))

        // Дать системе применить раскладку прежде, чем печатать.
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.05) { [weak self] in
            guard let self else { return }
            self.sendBackspaces(fragment.count)
            self.sendText(converted)
            self.typed.replaceSubrange(start..., with: Array(converted))
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
            usleep(3000)
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
            usleep(3000)
        }
    }
}

// MARK: - Приложение

final class AppDelegate: NSObject, NSApplicationDelegate {
    private var statusItem: NSStatusItem!
    private var loginItem: NSMenuItem!

    /// Значок в строке меню. Любое имя из SF Symbols — посмотреть можно в SF Symbols.app.
    /// Тот же символ, что и в значке приложения, чтобы программа опознавалась одинаково
    /// в строке меню, в Finder и в списке «Универсального доступа».
    /// Доступен с macOS 11.0 — ниже LSMinimumSystemVersion, так что запасной путь не нужен.
    private static let symbolName = "keyboard.macwindow"
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

        let diag = NSMenuItem(title: "Скопировать диагностику", action: #selector(copyDiagnostics), keyEquivalent: "")
        diag.target = self
        menu.addItem(diag)
        menu.addItem(.separator())

        loginItem = NSMenuItem(title: "Запускать при входе", action: #selector(toggleLogin), keyEquivalent: "")
        loginItem.target = self
        menu.addItem(loginItem)
        menu.addItem(.separator())

        menu.addItem(NSMenuItem(title: "Выйти", action: #selector(NSApplication.terminate(_:)), keyEquivalent: "q"))
        statusItem.menu = menu

        refreshLoginState()

        // Gatekeeper запускает скачанное приложение из случайной папки только для
        // чтения (App Translocation), пока его не перенесли в Finder. Путь меняется
        // при каждом запуске, поэтому выданный «Универсальный доступ» перестаёт
        // действовать, а автозапуск не регистрируется. Снаружи это выглядит как
        // «разрешения дал, значок есть, ничего не работает» — предупреждаем сразу.
        if Self.isTranslocated() {
            FileHandle.standardError.write(Data("LayoutSwitcher: запущен из временной копии (App Translocation), путь \(Bundle.main.bundlePath)\n".utf8))
            let alert = NSAlert()
            alert.messageText = "Перенесите LayoutSwitcher в «Программы»"
            alert.informativeText = """
                Сейчас программа запущена из временной папки: macOS так поступает \
                со скачанными приложениями, пока их не перенесли.

                В этом режиме выданный доступ к клавиатуре слетает при каждом \
                запуске, а автозапуск не работает.

                Перетащите LayoutSwitcher.app в «Программы» через Finder и \
                запустите оттуда.
                """
            alert.addButton(withTitle: "Понятно")
            alert.runModal()
        }

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

    /// Запущены ли мы из читаемой только временной копии, которую делает Gatekeeper.
    /// Проверяем путь, а не SecTranslocateIsTranslocatedURL: тот требует, чтобы
    /// вызывающий процесс сам был translocated-совместим, и в песочнице шумит.
    private static func isTranslocated() -> Bool {
        Bundle.main.bundlePath.contains("/AppTranslocation/")
    }

    private func requestAccessibilityIfNeeded() {
        let options = [kAXTrustedCheckOptionPrompt.takeUnretainedValue() as String: true] as CFDictionary
        _ = AXIsProcessTrustedWithOptions(options)
    }

    @objc private func convertNow() {
        Engine.shared.convert(expanding: false)
    }

    /// Отчёт о состоянии — чтобы не гадать по переписке, почему «ничего не работает».
    /// Кладём в буфер обмена: человеку остаётся вставить его в сообщение.
    @objc private func copyDiagnostics() {
        let report = Engine.shared.diagnostics()
        NSPasteboard.general.clearContents()
        NSPasteboard.general.setString(report, forType: .string)

        let alert = NSAlert()
        alert.messageText = "Отчёт скопирован"
        alert.informativeText = "Вставьте его в сообщение — по нему видно, что именно не работает.\n\n" + report
        alert.addButton(withTitle: "ОК")
        alert.runModal()
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

// Тот же отчёт, что и в меню, но без запуска интерфейса — чтобы его можно было
// получить из Терминала:  /Applications/LayoutSwitcher.app/Contents/MacOS/LayoutSwitcher --diagnostics
if CommandLine.arguments.contains("--diagnostics") {
    print(Engine.shared.diagnostics())
    exit(0)
}

let app = NSApplication.shared
let delegate = AppDelegate()
app.delegate = delegate
app.setActivationPolicy(.accessory)
app.run()
