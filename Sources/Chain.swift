import Foundation

/// Что делает очередной двойной Shift, когда предыдущая перебивка ещё на экране.
enum ChainAction {
    /// Расширить охват: слово → предложение → дальше.
    case expand
    /// Вернуть как было.
    case undo
    /// Начать заново от того, что сейчас в поле.
    case fresh
}

extension ChainAction {

    /// - Parameters:
    ///   - untouched: в поле ровно то, что мы записали в прошлый раз, и с тех пор
    ///     человек ничего не набирал и никуда не переставлял каретку.
    ///   - expanding: вызов с клавиатуры (двойной Shift), а не из меню.
    ///   - elapsed: сколько прошло с прошлой перебивки.
    ///   - window: окно, внутри которого нажатия считаются одной цепочкой.
    ///
    /// Отдельный `undo` нужен потому, что перебивка знаков препинания не обратима:
    /// «.» и «/» лежат на разных клавишах, и второй проход даёт не исходное «.»,
    /// а следующий символ в цепочке — «|». У букв обратимость есть, поэтому там
    /// возврат и повторная перебивка — одно и то же.
    static func decide(untouched: Bool, expanding: Bool,
                       elapsed: TimeInterval, window: TimeInterval) -> ChainAction {
        guard expanding, untouched else { return .fresh }
        return elapsed < window ? .expand : .undo
    }
}
