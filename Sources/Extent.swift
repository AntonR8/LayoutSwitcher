import Foundation

/// Чистая логика границ перебивки — без обращений к системе, чтобы её можно было тестировать.
enum Extent {

    static func isBlank(_ c: Character) -> Bool { c.isWhitespace }

    /// Возможные начала перебивки — от самого узкого к самому широкому, без повторов.
    /// Порядок и есть последовательность расширений при повторных двойных Shift.
    ///
    /// - Parameter text: текст до каретки.
    static func starts(in text: [Character]) -> [Int] {
        guard !text.isEmpty else { return [] }

        // Хвостовые пробелы не должны считаться границей.
        var contentEnd = text.count
        while contentEnd > 0, isBlank(text[contentEnd - 1]) { contentEnd -= 1 }
        guard contentEnd > 0 else { return [] }

        // Граница не должна вставать на пробел: перебивать ведущий пробел
        // бессмысленно, а охват выглядит шире, чем есть.
        func skippingBlanks(from index: Int) -> Int {
            var i = index
            while i < contentEnd, isBlank(text[i]) { i += 1 }
            return i
        }

        var result: [Int] = []

        // 1. Слово — назад до ближайшего пробела.
        var i = contentEnd - 1
        while i >= 0, !isBlank(text[i]) { i -= 1 }
        let wordStart = i + 1
        result.append(wordStart)

        // 2. Предложение — назад до завершающего знака, но не ближе начала слова.
        //    Знак внутри слова концом предложения не считается. Точка, набранная
        //    в русской раскладке, — это символ клавиши «/», а не конец фразы:
        //    граница по ней оставила бы её неперебитой («.dsdf» вместо «/dsdf»),
        //    да ещё и раньше уровня «слово» — тот шире и должен идти первым.
        let terminators: Set<Character> = [".", "!", "?", "…"]
        var sentenceStart = 0
        var j = wordStart - 1
        while j >= 0 {
            if terminators.contains(text[j]) { sentenceStart = j + 1; break }
            j -= 1
        }
        result.append(skippingBlanks(from: sentenceStart))

        // 3. Смена алфавита. Цифры и знаки препинания к алфавиту не относятся
        //    и границей не считаются — иначе «привет, world» рвалось бы по запятой.
        var lastLetter = contentEnd - 1
        var lastScript = Script.other
        while lastLetter >= 0 {
            let script = Script.of(text[lastLetter])
            if script != .other { lastScript = script; break }
            lastLetter -= 1
        }
        var scriptStart = 0
        if lastScript != .other {
            var k = lastLetter
            while k >= 0 {
                let script = Script.of(text[k])
                if script != .other && script != lastScript { scriptStart = k + 1; break }
                k -= 1
            }
        }
        result.append(skippingBlanks(from: scriptStart))

        // 4. Вся строка.
        result.append(0)

        // Граница, попавшая за последний непробельный символ, дала бы пустой охват
        // (например, точка в самом конце строки) — такой уровень бесполезен.
        var seen = Set<Int>()
        return result.sorted(by: >)
            .filter { $0 < contentEnd }
            .filter { seen.insert($0).inserted }
    }
}
