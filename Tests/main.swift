import Foundation

// Мини-харнесс: тесты запускаются как обычная программа, без XCTest.

var failures = 0
var checks = 0

func check(_ label: String, _ got: Any, _ want: Any) {
    checks += 1
    if "\(got)" != "\(want)" {
        failures += 1
        print("✗ \(label)\n    получено:  \(got)\n    ожидалось: \(want)")
    } else {
        print("✓ \(label)  \(got)")
    }
}

func starts(_ s: String) -> [Int] { Extent.starts(in: Array(s)) }

// MARK: - Границы охвата

print("--- границы ---")

check("одно слово", starts("привет"), [0])
check("два слова", starts("привет мир"), [7, 0])
check("хвостовой пробел", starts("привет мир "), [7, 0])

// "Раз. Два три" — слово с 9, предложение с 5 (пробел после точки пропущен)
check("предложение", starts("Раз. Два три"), [9, 5, 0])

// смена алфавита совпала со словом
check("смена алфавита = слово", starts("да ghjdthrf"), [3, 0])

// смена алфавита шире слова
check("смена алфавита шире слова", starts("да ghjd thrf"), [8, 3, 0])

// все четыре границы различаются
check("четыре разные границы", starts("Раз. да ghjd thrf"), [13, 8, 5, 0])

// знаки препинания не должны считаться сменой алфавита
check("запятая не рвёт алфавит", starts("привет, мир"), [8, 0])

check("пустой ввод", starts(""), [])
check("только пробелы", starts("   "), [])
check("знак в конце", starts("привет!"), [0])

// MARK: - Таблица соответствий

print("\n--- таблица соответствий ---")

// Игрушечные раскладки: четыре клавиши, без Shift и с ним. Клавиши 2 и 3 повторяют
// главную ловушку настоящих раскладок: «.» в русской и в латинской — разные клавиши.
let latinKeys: [UInt16: (String, String)] = [0: ("q", "Q"), 1: ("w", "W"), 2: (".", ">"), 3: ("/", "?")]
let cyrKeys:   [UInt16: (String, String)] = [0: ("й", "Й"), 1: ("ц", "Ц"), 2: ("ю", "Ю"), 3: (".", ",")]

func lookup(_ table: [UInt16: (String, String)]) -> (UInt16, UInt32) -> String? {
    { code, mods in
        guard let entry = table[code] else { return nil }
        return mods == 0 ? entry.0 : entry.1
    }
}

let toCyr = Mapping(from: lookup(latinKeys), to: lookup(cyrKeys))
let toLat = Mapping(from: lookup(cyrKeys), to: lookup(latinKeys))

check("латиница → кириллица", toCyr.convert("qw"), "йц")
check("с учётом регистра", toCyr.convert("QW"), "ЙЦ")
check("кириллица → латиница", toLat.convert("йц"), "qw")
check("знак препинания тоже перебивается", toCyr.convert("."), "ю")
check("незнакомый символ не трогаем", toCyr.convert("q1w"), "й1ц")

let pair = MappingPair(latinToCyrillic: toCyr, cyrillicToLatin: toLat)
check("направление по преобладанию: латиница", pair.convert("qw"), "йц")
check("направление по преобладанию: кириллица", pair.convert("йц"), "qw")
check("цифры при кириллице", pair.convert("йц1"), "qw1")

// Букв нет — направление берём из fallback (алфавит включённой раскладки).
check("одна точка на русской", pair.convert(".", fallback: .cyrillic), "/")
check("одна точка на латинской", pair.convert(".", fallback: .latin), "ю")
check("цифры со знаком на русской", pair.convert("12.", fallback: .cyrillic), "12/")
check("буквы важнее fallback", pair.convert("qw", fallback: .cyrillic), "йц")
check("fallback .other ничего не меняет", pair.convert(".", fallback: .other), ".")

// MARK: - Определение алфавита

print("\n--- алфавит ---")

check("кириллица", "\(MappingPair.dominantScript(of: "привет"))", "cyrillic")
check("латиница", "\(MappingPair.dominantScript(of: "hello"))", "latin")
check("только цифры", "\(MappingPair.dominantScript(of: "123"))", "other")
check("смесь с перевесом", "\(MappingPair.dominantScript(of: "привет hi"))", "cyrillic")

// MARK: - Итог

print(String(repeating: "-", count: 46))
if failures == 0 {
    print("все \(checks) проверок прошли")
    exit(0)
} else {
    print("провалено \(failures) из \(checks)")
    exit(1)
}
