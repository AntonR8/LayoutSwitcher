import Cocoa

/// Доступ к тексту поля, в котором сейчас каретка, через Accessibility.
///
/// Нужен потому, что вслепую эмулировать забои нельзя: в поле может лежать не то,
/// что набирал пользователь, — прошлый запрос в Spotlight, автодополнение в адресной
/// строке, вставленный из буфера текст. Здесь мы читаем реальное содержимое.
enum AXText {

    struct Field {
        let element: AXUIElement
        let text: String
        /// Позиция каретки в символах от начала.
        let caret: Int
    }

    private static func focusedElement() -> AXUIElement? {
        let system = AXUIElementCreateSystemWide()
        var focused: CFTypeRef?
        guard AXUIElementCopyAttributeValue(system, kAXFocusedUIElementAttribute as CFString, &focused) == .success,
              let focused else { return nil }
        return (focused as! AXUIElement)
    }

    /// Читает поле в фокусе. nil — если программа не отдаёт текст через Accessibility
    /// (так ведут себя, например, некоторые терминалы и игры); тогда вызывающий
    /// откатывается на эмуляцию клавиш.
    static func read() -> Field? {
        guard let element = focusedElement() else { return nil }

        var raw: CFTypeRef?
        guard AXUIElementCopyAttributeValue(element, kAXValueAttribute as CFString, &raw) == .success,
              let text = raw as? String else { return nil }

        // Без права на запись читать смысла нет.
        var settable: DarwinBoolean = false
        guard AXUIElementIsAttributeSettable(element, kAXValueAttribute as CFString, &settable) == .success,
              settable.boolValue else { return nil }

        var caret = text.count
        var rangeValue: CFTypeRef?
        if AXUIElementCopyAttributeValue(element, kAXSelectedTextRangeAttribute as CFString, &rangeValue) == .success,
           let rangeValue, CFGetTypeID(rangeValue) == AXValueGetTypeID() {
            var range = CFRange()
            if AXValueGetValue(rangeValue as! AXValue, .cfRange, &range) {
                // Диапазон приходит в UTF-16, а работаем мы в символах.
                let utf16Offset = min(max(range.location, 0), text.utf16.count)
                if let index = String.Index(text.utf16.index(text.utf16.startIndex, offsetBy: utf16Offset),
                                            within: text) {
                    caret = text.distance(from: text.startIndex, to: index)
                }
            }
        }
        return Field(element: element, text: text, caret: caret)
    }

    /// Записывает текст обратно и ставит каретку в заданную позицию.
    @discardableResult
    static func write(_ field: Field, text: String, caret: Int) -> Bool {
        guard AXUIElementSetAttributeValue(field.element, kAXValueAttribute as CFString,
                                           text as CFString) == .success else { return false }

        let clamped = min(max(caret, 0), text.count)
        let index = text.index(text.startIndex, offsetBy: clamped)
        let utf16Offset = text.utf16.distance(from: text.utf16.startIndex, to: index.samePosition(in: text.utf16)!)

        var range = CFRange(location: utf16Offset, length: 0)
        if let value = AXValueCreate(.cfRange, &range) {
            AXUIElementSetAttributeValue(field.element, kAXSelectedTextRangeAttribute as CFString, value)
        }
        return true
    }
}
