import Foundation

/// Алфавит символа — по нему определяется, в какую сторону перебивать.
enum Script {
    case latin
    case cyrillic
    case other

    static func of(_ c: Character) -> Script {
        guard let v = c.unicodeScalars.first?.value else { return .other }
        switch v {
        case 0x0400...0x04FF, 0x0500...0x052F:                 return .cyrillic
        case 0x41...0x5A, 0x61...0x7A, 0xC0...0x24F:           return .latin
        default:                                                return .other
        }
    }

    var opposite: Script {
        switch self {
        case .latin:    return .cyrillic
        case .cyrillic: return .latin
        case .other:    return .other
        }
    }
}

/// Таблица «символ одной раскладки → символ другой», построенная перебором
/// физических клавиш. Заменяет прежний подход со скан-кодами: работает с любым
/// текстом, а не только с тем, набор которого программа видела.
struct Mapping {
    let forward: [Character: Character]

    /// - Parameter translate: даёт символ для (скан-код, модификаторы) в нужной раскладке.
    ///   Возвращает nil, если клавиша ничего не печатает.
    init(from source: (UInt16, UInt32) -> String?,
         to target: (UInt16, UInt32) -> String?) {
        var table: [Character: Character] = [:]
        // 0...127 покрывает все физические клавиши; 0 и 2 — без Shift и с Shift.
        for code in UInt16(0)...UInt16(127) {
            for modifiers in [UInt32(0), UInt32(2)] {
                guard let a = source(code, modifiers), a.count == 1,
                      let b = target(code, modifiers), b.count == 1,
                      let from = a.first, let into = b.first,
                      from != into else { continue }
                // Первое совпадение выигрывает: если один и тот же символ висит
                // на нескольких клавишах, берём тот, что раньше по скан-коду.
                if table[from] == nil { table[from] = into }
            }
        }
        self.forward = table
    }

    func convert(_ text: some StringProtocol) -> String {
        String(text.map { forward[$0] ?? $0 })
    }
}

/// Пара таблиц в обе стороны плюс выбор направления по содержимому.
struct MappingPair {
    let latinToCyrillic: Mapping
    let cyrillicToLatin: Mapping

    /// Преобладающий алфавит среди букв отрывка. По нему решаем, куда перебивать:
    /// у знаков препинания и цифр однозначного ответа нет, поэтому ориентируемся
    /// на буквы вокруг них.
    static func dominantScript(of text: some StringProtocol) -> Script {
        var latin = 0, cyrillic = 0
        for c in text {
            switch Script.of(c) {
            case .latin:    latin += 1
            case .cyrillic: cyrillic += 1
            case .other:    break
            }
        }
        if latin == 0 && cyrillic == 0 { return .other }
        return cyrillic > latin ? .cyrillic : .latin
    }

    func convert(_ text: some StringProtocol) -> String {
        switch Self.dominantScript(of: text) {
        case .cyrillic: return cyrillicToLatin.convert(text)
        case .latin:    return latinToCyrillic.convert(text)
        case .other:    return latinToCyrillic.convert(text)
        }
    }
}
