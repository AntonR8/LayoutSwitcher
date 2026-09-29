import Foundation

/// Распознаёт одиночное и двойное нажатие Shift по событиям нажатия и отпускания.
/// Без зависимостей от CGEvent — чтобы логику можно было гонять в тестах.
struct ShiftTap {

    enum Result: Equatable {
        case none
        case single
        case double
    }

    /// Дольше этого Shift держали — это не нажатие, а удержание.
    var maxTapDuration: Double = 0.5
    /// Пауза между двумя нажатиями, при которой они считаются двойным.
    var doubleTapWindow: Double = 0.4

    private var downAt: Double?
    private var interrupted = false
    private var lastTapAt: Double?

    /// Shift нажат. `otherModifiers` — уже зажаты Cmd/Ctrl/Option: тогда это
    /// начало сочетания, а не нажатие.
    mutating func down(at t: Double, otherModifiers: Bool = false) {
        if downAt != nil {
            // Второй Shift, пока первый ещё зажат.
            interrupted = true
            return
        }
        downAt = t
        interrupted = otherModifiers
    }

    /// Пока Shift зажат, нажали что-то ещё: клавишу, другой модификатор, кнопку мыши.
    mutating func interrupt() {
        if downAt != nil { interrupted = true }
    }

    mutating func up(at t: Double) -> Result {
        guard let start = downAt else { return .none }
        downAt = nil

        if interrupted || t - start > maxTapDuration {
            lastTapAt = nil
            return .none
        }
        if let last = lastTapAt, start - last < doubleTapWindow {
            lastTapAt = nil
            return .double
        }
        lastTapAt = t
        return .single
    }
}
