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

    private var shiftTap = ShiftTap()
    /// Раскладка до переключения одиночным Shift. Если следом пришло второе
    /// нажатие, это был двойной Shift: возвращаем её перед перебивкой, чтобы
    /// направление определялось по той раскладке, в которой набирали.
    private var layoutBeforeSingleTap: TISInputSource?

    /// Насколько широко перебиваем: индекс в списке границ (0 — слово).
    private var expansionLevel = 0
    private var lastConvertAt: CFAbsoluteTime = 0
    /// Текст до первой перебивки в текущей цепочке расширений — от него
    /// каждый следующий уровень считается заново, иначе уже перебитое
    /// перевернулось бы обратно.
    private var chainBase: String?
    private var lastWritten: String?
    /// То же самое для запасного пути: буфер набранного до первой перебивки
    /// в текущей цепочке. Сам `typed` по ходу цепочки хранит то, что на экране.
    private var typedBase: [Character]?

    /// Короткое нажатие любого Shift переключает раскладку.
    var switchLayoutOnShiftTap = true
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
            guard let self else { timer.invalidate(); return }
            if self.start() {
                timer.invalidate()
                self.retryTimer = nil
            }
        }
    }

    @discardableResult
    func start() -> Bool {
        // Без доступа к клавиатуре tapCreate всё равно отдаёт порт — но перехватчик
        // приходит выключенным и без клавиатурных событий. Если считать это успехом,
        // ожидание разрешения заканчивается, выданный потом доступ никто не подхватит,
        // и программа молча не работает до перезапуска. Поэтому спрашиваем заранее.
        guard AXIsProcessTrusted() else { return false }

        if let old = tap {
            CGEvent.tapEnable(tap: old, enable: false)
            CFMachPortInvalidate(old)
            tap = nil
        }

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

        let source = CFMachPortCreateRunLoopSource(kCFAllocatorDefault, tap, 0)
        CFRunLoopAddSource(CFRunLoopGetMain(), source, .commonModes)
        CGEvent.tapEnable(tap: tap, enable: true)

        // Последняя проверка: перехватчик, созданный без прав, включиться не может.
        guard CGEvent.tapIsEnabled(tap: tap) else {
            CFRunLoopRemoveSource(CFRunLoopGetMain(), source, .commonModes)
            CFMachPortInvalidate(tap)
            return false
        }

        self.tap = tap
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
            shiftTap.interrupt()        // Shift+клик — выделение, а не нажатие
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
        typedBase = nil
    }

    private func handleFlags(_ event: CGEvent) {
        let code = event.getIntegerValueField(.keyboardEventKeycode)
        let now = CFAbsoluteTimeGetCurrent()

        // Другой модификатор при зажатом Shift — это сочетание.
        guard code == 56 || code == 60 else {     // левый / правый Shift
            shiftTap.interrupt()
            return
        }

        let flags = event.flags
        if flags.contains(.maskShift) && !releasedShift(code: code, flags: flags) {
            let others = flags.contains(.maskCommand) || flags.contains(.maskControl)
                      || flags.contains(.maskAlternate)
            shiftTap.down(at: now, otherModifiers: others)
            return
        }

        switch shiftTap.up(at: now) {
        case .none:
            layoutBeforeSingleTap = nil
        case .single:
            // Меняем сразу, не дожидаясь, будет ли второе нажатие: ожидание
            // и есть та задержка, из-за которой переключение казалось медленным.
            layoutBeforeSingleTap = nil
            if switchLayoutOnShiftTap { toggleLayout() }
        case .double:
            if let previous = layoutBeforeSingleTap {
                Layouts.select(previous)
                layoutBeforeSingleTap = nil
            }
            convert()
        }
    }

    /// Флаг Shift остаётся, пока зажат хотя бы один из двух Shift, поэтому
    /// отпускание одного при зажатом другом видно только по битам устройства.
    private func releasedShift(code: Int64, flags: CGEventFlags) -> Bool {
        let left: UInt64 = 0x02, right: UInt64 = 0x04   // NX_DEVICELSHIFTKEYMASK / RSHIFT
        let bit = code == 56 ? left : right
        return flags.rawValue & bit == 0
    }

    // MARK: Смена раскладки по короткому Shift

    /// Переключить ввод на другую раскладку из пары «латинская — нелатинская».
    /// Напрямую через TIS, минуя системное сочетание клавиш с его задержкой
    /// и всплывающим переключателем.
    func toggleLayout() {
        guard let (latin, other) = Layouts.pair(), let current = Layouts.current() else { return }
        layoutBeforeSingleTap = current
        Layouts.select(Layouts.isASCII(current) ? other : latin)
    }

    private func handleKey(_ event: CGEvent) {
        shiftTap.interrupt()
        layoutBeforeSingleTap = nil
        expansionLevel = 0
        chainBase = nil
        typedBase = nil

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
        let tapUp = tap.map { CGEvent.tapIsEnabled(tap: $0) } ?? false
        out.append("перехват событий: \(tapUp ? "поднят" : "НЕ ПОДНЯТ")")
        out.append("короткий Shift меняет раскладку: \(switchLayoutOnShiftTap ? "да" : "нет")")

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

        // В поле ровно наша прошлая перебивка и с тех пор ничего не набирали:
        // любой ввод и клик мышью обнуляют chainBase.
        let untouched = chainBase != nil && lastWritten == field.text
        let action = ChainAction.decide(untouched: untouched, expanding: expanding,
                                        elapsed: now - lastConvertAt, window: expandWindow)

        if action == .undo, let previous = chainBase {
            undoInField(field, to: previous)
            return
        }

        let base: String
        if action == .expand {
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

    /// Вернуть поле к тому, что было до перебивки. Длина при перебивке не меняется
    /// (символ в символ), поэтому каретка остаётся на месте.
    private func undoInField(_ field: AXText.Field, to previous: String) {
        guard AXText.write(field, text: previous, caret: min(field.caret, previous.count)) else { return }
        chainBase = nil
        lastWritten = nil
        expansionLevel = 0
        lastConvertAt = CFAbsoluteTimeGetCurrent()
        selectLayout(for: MappingPair.dominantScript(of: previous))
    }

    /// Запасной путь для полей, которые не отдают текст через Accessibility:
    /// стираем забоями и печатаем заново. Опирается на буфер набранного,
    /// поэтому в полях с автодополнением работает хуже.
    private func convertByTyping(using pair: MappingPair, expanding: Bool) {
        guard !typed.isEmpty else { return }

        let now = CFAbsoluteTimeGetCurrent()

        // Цепочка расширений считается от текста до первой перебивки — так же,
        // как на пути через Accessibility. Иначе следующий уровень перебивал бы
        // уже перебитое: «.выва» → «.dsdf» → «ювыва».
        // typedBase обнуляется на любом наборе, так что он же и признак того,
        // что на экране по-прежнему наша перебивка.
        let action = ChainAction.decide(untouched: typedBase != nil, expanding: expanding,
                                        elapsed: now - lastConvertAt, window: expandWindow)

        if action == .undo, let previous = typedBase, previous.count == typed.count {
            undoByTyping(to: previous)
            return
        }

        let base: [Character]
        if action == .expand {
            base = typedBase!
            expansionLevel += 1
        } else {
            base = typed
            typedBase = base
            expansionLevel = 0
        }

        let starts = Extent.starts(in: base)
        guard !starts.isEmpty else { return }

        guard let (start, converted, level) = firstChange(
            in: starts, from: expansionLevel, using: pair,
            fragment: { String(base[$0...]) }
        ) else { return }
        expansionLevel = level

        // Стираем то, что сейчас на экране, а не то, что было набрано: при
        // расширении там уже лежит результат прошлого уровня. Длины совпадают —
        // перебивка идёт символ в символ.
        let onScreen = typed.count - start
        guard onScreen >= 0 else { return }

        selectLayout(for: MappingPair.dominantScript(of: converted))

        // Дать системе применить раскладку прежде, чем печатать.
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.05) { [weak self] in
            guard let self else { return }
            self.sendBackspaces(onScreen)
            self.sendText(converted)
            self.typed = Array(base[0..<start]) + Array(converted)
            self.lastConvertAt = CFAbsoluteTimeGetCurrent()
        }
    }

    /// Возврат на запасном пути: стираем разошедшийся хвост и печатаем исходный.
    private func undoByTyping(to previous: [Character]) {
        var index = 0
        while index < previous.count && previous[index] == typed[index] { index += 1 }
        guard index < previous.count else { return }

        let tail = String(previous[index...])
        selectLayout(for: MappingPair.dominantScript(of: tail))

        let erase = typed.count - index
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.05) { [weak self] in
            guard let self else { return }
            self.sendBackspaces(erase)
            self.sendText(tail)
            self.typed = previous
            self.typedBase = nil
            self.expansionLevel = 0
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
    private var shiftTapItem: NSMenuItem!
    /// Пункт-предупреждение «нет доступа». Появляется в меню, пока доступа нет.
    private var accessItem: NSMenuItem?

    /// Ключ настройки «короткий Shift меняет раскладку».
    private static let shiftTapKey = "SwitchLayoutOnShiftTap"

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

        shiftTapItem = NSMenuItem(title: "Короткий Shift меняет раскладку",
                                   action: #selector(toggleShiftTapSwitch), keyEquivalent: "")
        shiftTapItem.target = self
        menu.addItem(shiftTapItem)
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

        UserDefaults.standard.register(defaults: [Self.shiftTapKey: true])
        applyShiftTapSetting(UserDefaults.standard.bool(forKey: Self.shiftTapKey))

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

        if !AXIsProcessTrusted() { showAccessWarning() }
    }

    /// Пока доступа нет: треугольник в строке меню и пункт с объяснением.
    /// Своего окна тут не показываем — система в этот момент уже показывает
    /// собственный запрос, и два окна встают друг на друга: наше перекрывает
    /// системное, а нажать надо именно системное.
    private func showAccessWarning() {
        setSymbol(Self.alertSymbolName)

        if accessItem == nil, let menu = statusItem.menu {
            let item = NSMenuItem(title: "Нет доступа к клавиатуре — выдать…",
                                  action: #selector(explainAccess), keyEquivalent: "")
            item.target = self
            menu.insertItem(item, at: 0)
            menu.insertItem(.separator(), at: 1)
            accessItem = item
        }

        // Вернуть обычный значок и убрать предупреждение, когда доступ появится.
        Timer.scheduledTimer(withTimeInterval: 2.0, repeats: true) { [weak self] timer in
            guard AXIsProcessTrusted(), let self else { return }
            self.setSymbol(Self.symbolName)
            self.clearAccessWarning()
            timer.invalidate()
        }
    }

    private func clearAccessWarning() {
        guard let item = accessItem, let menu = statusItem.menu else { return }
        let index = menu.index(of: item)
        if index >= 0 {
            if index + 1 < menu.numberOfItems, menu.item(at: index + 1)?.isSeparatorItem == true {
                menu.removeItem(at: index + 1)
            }
            menu.removeItem(at: index)
        }
        accessItem = nil
    }

    /// Объяснение по требованию — когда системный запрос уже закрыт или больше
    /// не появляется (система показывает его один раз, отказ она запоминает).
    @objc private func explainAccess() {
        let alert = NSAlert()
        alert.messageText = "Нужен доступ к клавиатуре"
        alert.informativeText = "Откройте Настройки → Конфиденциальность и безопасность → Универсальный доступ и включите LayoutSwitcher. Перезапускать программу не нужно — она подхватит разрешение сама."
        alert.addButton(withTitle: "Открыть настройки")
        alert.addButton(withTitle: "Позже")
        NSApp.activate(ignoringOtherApps: true)
        if alert.runModal() == .alertFirstButtonReturn,
           let url = URL(string: "x-apple.systempreferences:com.apple.preference.security?Privacy_Accessibility") {
            NSWorkspace.shared.open(url)
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

    @objc private func toggleShiftTapSwitch() {
        let enabled = !Engine.shared.switchLayoutOnShiftTap
        UserDefaults.standard.set(enabled, forKey: Self.shiftTapKey)
        applyShiftTapSetting(enabled)
    }

    private func applyShiftTapSetting(_ enabled: Bool) {
        Engine.shared.switchLayoutOnShiftTap = enabled
        shiftTapItem.state = enabled ? .on : .off
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
    // Перехват поднимаем прямо здесь: иначе строка о нём в отчёте из Терминала
    // всегда говорила «НЕ ПОДНЯТ» и скрывала настоящий отказ системы.
    Engine.shared.start()
    print(Engine.shared.diagnostics())
    // Запущенный из Терминала процесс числится за Терминалом: если доступ к
    // клавиатуре выдан Терминалу, здесь напишется «есть», хотя у самой программы
    // его нет. Отчёт из меню значка такой ошибки не даёт.
    print("")
    print("ВНИМАНИЕ: отчёт снят из Терминала — строки о доступе относятся к правам")
    print("Терминала, а не программы. Проверяйте через меню значка.")
    exit(0)
}

let app = NSApplication.shared
let delegate = AppDelegate()
app.delegate = delegate
app.setActivationPolicy(.accessory)
app.run()
