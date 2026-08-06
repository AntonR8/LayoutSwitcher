import Foundation

/// Чистая логика границ перебивки — без обращений к системе, чтобы её можно было тестировать.
enum Extent {

    static func isBlank(_ s: String) -> Bool {
        s.trimmingCharacters(in: .whitespaces).isEmpty
    }

    /// Возможные начала перебивки — от самого узкого к самому широкому, без повторов.
    /// Порядок и есть последовательность расширений при повторных двойных Shift.
    ///
    /// - Parameters:
    ///   - shown: что сейчас на экране для каждого нажатия.
    ///   - sourceIDs: раскладка, в которой нажатие было набрано.
    static func starts(shown: [String], sourceIDs: [String]) -> [Int] {
        guard !shown.isEmpty, shown.count == sourceIDs.count else { return [] }

        // Хвостовые пробелы не должны считаться границей.
        var contentEnd = shown.count
        while contentEnd > 0, isBlank(shown[contentEnd - 1]) { contentEnd -= 1 }
        guard contentEnd > 0 else { return [] }

        var result: [Int] = []

        // 1. Слово — назад до ближайшего пробела.
        var i = contentEnd - 1
        while i >= 0, !isBlank(shown[i]) { i -= 1 }
        result.append(i + 1)

        // 2. Предложение — назад до завершающего знака.
        let terminators: Set<Character> = [".", "!", "?", "…"]
        var sentenceStart = 0
        var j = contentEnd - 1
        while j >= 0 {
            if let c = shown[j].first, terminators.contains(c) { sentenceStart = j + 1; break }
            j -= 1
        }
        result.append(sentenceStart)

        // 3. С последней смены раскладки.
        let lastID = sourceIDs[contentEnd - 1]
        var langStart = 0
        var k = contentEnd - 1
        while k >= 0 {
            if sourceIDs[k] != lastID { langStart = k + 1; break }
            k -= 1
        }
        result.append(langStart)

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
