import Foundation

// Мини-харнесс: тесты запускаются как обычная программа, без XCTest.

var failures = 0
var checks = 0

let RU = "com.apple.keylayout.RussianWin"
let EN = "com.apple.keylayout.ABC"

/// Собирает вход из строки. Раскладка задаётся посимвольно вторым аргументом,
/// где каждый символ — 'r' или 'e'; если он короче, хвост считается той же раскладкой.
func input(_ text: String, _ langs: String) -> ([String], [String]) {
    let shown = text.map { String($0) }
    var ids: [String] = []
    let marks = Array(langs)
    for i in 0..<shown.count {
        let m = i < marks.count ? marks[i] : (marks.last ?? "r")
        ids.append(m == "e" ? EN : RU)
    }
    return (shown, ids)
}

func expect(_ label: String, _ got: [Int], _ want: [Int]) {
    checks += 1
    if got != want {
        failures += 1
        print("✗ \(label)\n    получено: \(got)\n    ожидалось: \(want)")
    } else {
        print("✓ \(label)  \(got)")
    }
}

// MARK: - Одно слово

do {
    let (s, l) = input("привет", "r")
    // всё слово — оно же предложение, оно же строка: границы схлопываются в одну
    expect("одно слово", Extent.starts(shown: s, sourceIDs: l), [0])
}

// MARK: - Два слова

do {
    let (s, l) = input("привет мир", "r")
    // слово -> вся строка
    expect("два слова", Extent.starts(shown: s, sourceIDs: l), [7, 0])
}

// MARK: - Хвостовой пробел не должен съедать границу

do {
    let (s, l) = input("привет мир ", "r")
    expect("хвостовой пробел", Extent.starts(shown: s, sourceIDs: l), [7, 0])
}

// MARK: - Предложение

do {
    let (s, l) = input("Раз. Два три", "r")
    //                  0123456789..
    // слово = "три" (9), предложение = после точки (4), строка = 0
    expect("предложение", Extent.starts(shown: s, sourceIDs: l), [9, 4, 0])
}

// MARK: - Смена раскладки

do {
    // "да " по-русски, дальше латиница
    let (s, l) = input("да ghjdthrf", "rrreeeeeeee")
    // слово = 3, смена языка = 3 (совпадает, схлопнется), строка = 0
    expect("смена раскладки совпала со словом",
           Extent.starts(shown: s, sourceIDs: l), [3, 0])
}

do {
    // по-русски "да ", затем два латинских слова
    let (s, l) = input("да ghjd thrf", "rrreeeeeeeee")
    // слово = 8, смена языка = 3, строка = 0
    expect("смена раскладки шире слова",
           Extent.starts(shown: s, sourceIDs: l), [8, 3, 0])
}

// MARK: - Все четыре границы различаются

do {
    let (s, l) = input("Раз. да ghjd thrf", "rrrrrrrreeeeeeeee")
    //                  01234567890123456
    // слово = 13, смена языка = 8, предложение = 4, строка = 0
    expect("четыре разные границы",
           Extent.starts(shown: s, sourceIDs: l), [13, 8, 4, 0])
}

// MARK: - Вырожденные случаи

do {
    expect("пустой ввод", Extent.starts(shown: [], sourceIDs: []), [])
}

do {
    let (s, l) = input("   ", "r")
    expect("только пробелы", Extent.starts(shown: s, sourceIDs: l), [])
}

do {
    let (s, l) = input("привет!", "r")
    // терминатор в самом конце: contentEnd указывает на него,
    // поэтому предложение = вся строка
    expect("знак в конце", Extent.starts(shown: s, sourceIDs: l), [0])
}

// MARK: - Итог

print(String(repeating: "-", count: 46))
if failures == 0 {
    print("все \(checks) проверок прошли")
    exit(0)
} else {
    print("провалено \(failures) из \(checks)")
    exit(1)
}
