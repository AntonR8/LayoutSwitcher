import Foundation

/// Откуда берутся переводы. В приложении — его собственный бандл: macOS сама
/// выбирает язык по настройкам системы. Предпросмотр и проверки подставляют
/// сюда папку конкретного языка (`xx.lproj`), чтобы увидеть его без смены системы.
enum Localization {
    static var bundle = Bundle.main
}

/// Строка интерфейса по ключу из Localizable.strings.
func L(_ key: String) -> String {
    Localization.bundle.localizedString(forKey: key, value: nil, table: nil)
}
