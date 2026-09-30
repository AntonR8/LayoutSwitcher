import Cocoa
import SwiftUI

// Меню значка в стиле классических интерфейсов: серые объёмные рамки,
// тёмно-синяя плашка главного действия, переключатели-«тумблеры».
// Цвета фиксированные и от светлой/тёмной темы не зависят — это часть образа.

// MARK: - Состояние

final class MenuModel: ObservableObject {
    @Published var shiftTap = true
    @Published var loginEnabled = false
    @Published var hasAccess = true
    @Published var copied = false

    var onConvert: () -> Void = {}
    var onHelp: () -> Void = {}
    var onToggleShiftTap: () -> Void = {}
    var onCopyDiagnostics: () -> Void = {}
    var onToggleLogin: () -> Void = {}
    var onExplainAccess: () -> Void = {}
    var onQuit: () -> Void = {}
    var onAboutDeveloper: () -> Void = {}
}

// MARK: - Палитра

enum Retro {
    static let face = Color(red: 0.76, green: 0.76, blue: 0.76)
    static let faceHover = Color(red: 0.83, green: 0.83, blue: 0.83)
    static let light = Color.white
    static let shadow = Color(red: 0.50, green: 0.50, blue: 0.50)
    static let dark = Color.black
    static let navy = Color(red: 0.00, green: 0.05, blue: 0.55)
    static let navySubtitle = Color(red: 0.78, green: 0.82, blue: 1.00)
    static let red = Color(red: 0.66, green: 0.00, blue: 0.00)
    static let redHover = Color(red: 0.78, green: 0.06, blue: 0.06)
    static let redSubtitle = Color(red: 1.00, green: 0.80, blue: 0.80)
    static let text = Color.black
    static let subtitle = Color(red: 0.22, green: 0.22, blue: 0.22)
    static let ledOn = Color(red: 0.13, green: 0.70, blue: 0.27)
    static let ledOff = Color(red: 0.25, green: 0.27, blue: 0.25)
    /// Зелёный для текста: светодиодный на сером фоне читается плохо.
    static let statusText = Color(red: 0.05, green: 0.42, blue: 0.14)
    static let trackOff = Color(red: 0.36, green: 0.36, blue: 0.36)

    static func title(_ size: CGFloat = 17) -> Font { .system(size: size, weight: .bold) }
    static let caption = Font.system(size: 13.5)
}

// MARK: - Объёмная рамка

/// Двойная рамка: светлые грани сверху-слева и тёмные снизу-справа — «выпуклая»,
/// наоборот — «вдавленная».
struct Bevel: View {
    var raised = true
    var width: CGFloat = 2

    var body: some View {
        GeometryReader { g in
            let w = g.size.width, h = g.size.height
            let (outerTL, outerBR, innerTL, innerBR) = raised
                ? (Retro.light, Retro.dark, Retro.faceHover, Retro.shadow)
                : (Retro.shadow, Retro.light, Retro.dark, Retro.faceHover)
            ZStack {
                edges(w, h, inset: 0, tl: outerTL, br: outerBR)
                edges(w, h, inset: width / 2 + 0.5, tl: innerTL, br: innerBR)
            }
        }
        .allowsHitTesting(false)
    }

    private func edges(_ w: CGFloat, _ h: CGFloat, inset i: CGFloat, tl: Color, br: Color) -> some View {
        let lw = width / 2 + 0.5
        return ZStack {
            Path { p in
                p.move(to: CGPoint(x: i + lw / 2, y: h - i))
                p.addLine(to: CGPoint(x: i + lw / 2, y: i + lw / 2))
                p.addLine(to: CGPoint(x: w - i, y: i + lw / 2))
            }.stroke(tl, lineWidth: lw)
            Path { p in
                p.move(to: CGPoint(x: w - i - lw / 2, y: i))
                p.addLine(to: CGPoint(x: w - i - lw / 2, y: h - i - lw / 2))
                p.addLine(to: CGPoint(x: i, y: h - i - lw / 2))
            }.stroke(br, lineWidth: lw)
        }
    }
}

/// Бороздка между строками: тёмная линия и светлая под ней.
struct Etch: View {
    var body: some View {
        VStack(spacing: 0) {
            Retro.shadow.frame(height: 1)
            Retro.light.frame(height: 1)
        }
    }
}

// MARK: - Элементы

/// Переключатель как на приборной панели 80-х: подпись прямо говорит, в каком
/// он положении, а светодиод рядом горит, пока включено. Ползунок закрывает
/// ту половину, которая сейчас не действует.
struct RetroToggle: View {
    var isOn: Bool
    var action: () -> Void

    private let width: CGFloat = 92
    private let knob: CGFloat = 38

    var body: some View {
        Button(action: action) {
            HStack(spacing: 8) {
                led
                ZStack(alignment: .leading) {
                    label(L("toggle.on"), on: true)
                    label(L("toggle.off"), on: false)
                    Retro.face
                        .frame(width: knob)
                        .overlay(grip)
                        .overlay(Bevel(raised: true, width: 2))
                        .offset(x: isOn ? width - knob : 0)
                }
                .frame(width: width, height: 30, alignment: .leading)
                .background(isOn ? Retro.ledOn : Retro.trackOff)
                .clipped()
                .overlay(Bevel(raised: false, width: 2))
            }
            .animation(.easeInOut(duration: 0.18), value: isOn)
            // Тумблер — «железка»: включено справа при любом направлении письма.
            .environment(\.layoutDirection, .leftToRight)
        }
        .buttonStyle(.plain)
        .accessibilityHidden(true)
    }

    /// Половина дорожки с подписью. Видна только та, что не закрыта ползунком.
    private func label(_ text: String, on: Bool) -> some View {
        Text(text)
            .font(.system(size: 11, weight: .heavy))
            .kerning(0.6)
            .foregroundColor(.white)
            .lineLimit(1)
            .minimumScaleFactor(0.6)
            .padding(.horizontal, 3)
            .frame(width: width - knob)
            .offset(x: on ? 0 : knob)
            .opacity(isOn == on ? 1 : 0)
    }

    /// Рифление на ползунке — три вертикальные бороздки.
    private var grip: some View {
        HStack(spacing: 3) {
            ForEach(0..<3, id: \.self) { _ in
                HStack(spacing: 0) {
                    Retro.shadow.frame(width: 1)
                    Retro.light.frame(width: 1)
                }
                .frame(height: 12)
            }
        }
    }

    private var led: some View { Led(on: isOn) }
}

struct RetroButtonStyle: ButtonStyle {
    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .font(.system(size: 13, weight: .semibold))
            .foregroundColor(Retro.text)
            .padding(.horizontal, 16)
            .frame(height: 30)
            .background(Retro.face)
            .overlay(Bevel(raised: !configuration.isPressed, width: 2))
            .offset(x: configuration.isPressed ? 1 : 0, y: configuration.isPressed ? 1 : 0)
    }
}

/// Цветная плашка под строкой: синяя — главное действие, красная — беда.
private enum Plate {
    case navy, red

    var background: Color { self == .navy ? Retro.navy : Retro.red }
    var hover: Color { self == .navy ? Retro.navy : Retro.redHover }
    var subtitle: Color { self == .navy ? Retro.navySubtitle : Retro.redSubtitle }
}

/// Строки собраны из жестов, а не из кнопок, и VoiceOver их не видел.
/// Строка с действием становится одной кнопкой: заголовок, подпись и
/// состояние тумблера читаются вместе. Строка без действия (диагностика)
/// остаётся контейнером, чтобы её кнопка «Скопировать» была доступна отдельно.
private struct RowAccessibility: ViewModifier {
    var action: (() -> Void)?

    func body(content: Content) -> some View {
        if let action {
            content
                .accessibilityElement(children: .combine)
                .accessibilityAddTraits(.isButton)
                .accessibilityAction { action() }
        } else {
            content.accessibilityElement(children: .contain)
        }
    }
}

/// Светодиод: горит зелёным, когда `on`.
struct Led: View {
    var on: Bool
    var size: CGFloat = 12

    var body: some View {
        Circle()
            .fill(on ? Retro.ledOn : Retro.ledOff)
            .overlay(Circle().fill(Color.white.opacity(on ? 0.55 : 0.15))
                        .frame(width: size / 3, height: size / 3)
                        .offset(x: -size / 6, y: -size / 6))
            .overlay(Circle().stroke(Retro.dark, lineWidth: 1))
            .frame(width: size, height: size)
            .shadow(color: on ? Retro.ledOn.opacity(0.9) : .clear, radius: size / 3)
            .accessibilityHidden(true)
    }
}

/// Бесплатное приложение — поэтому в меню есть визитка автора со ссылкой на сайт.
private struct DeveloperRow: View {
    var action: () -> Void
    @State private var hover = false

    static let name = "Anton Razguliaev"

    /// Разрядка заголовка — как на табличках 80-х. Но в связных письменностях
    /// (арабская, деванагари) она рвёт буквы, поэтому там её нет.
    static var captionKerning: CGFloat {
        let joined = L("menu.developer.caption").unicodeScalars.contains {
            (0x0600...0x06FF).contains($0.value) || (0x0900...0x097F).contains($0.value)
        }
        return joined ? 0 : 1.6
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            Text(L("menu.developer.caption").uppercased())
                .font(.system(size: 11, weight: .heavy))
                .kerning(Self.captionKerning)
                .foregroundColor(Retro.shadow)
                .padding(.horizontal, 12)
                .padding(.top, 8)

            HStack(spacing: 14) {
                avatar
                    .frame(width: 44, height: 44)
                VStack(alignment: .leading, spacing: 3) {
                    Text(Self.name)
                        .font(Retro.title())
                        .kerning(0.4)
                        .foregroundColor(Retro.navy)
                    HStack(spacing: 6) {
                        Text(L("menu.developer.role"))
                            .foregroundColor(Retro.subtitle)
                        Text("·").foregroundColor(Retro.shadow).accessibilityHidden(true)
                        Led(on: true, size: 9)
                        Text(L("menu.developer.status"))
                            .foregroundColor(Retro.statusText)
                    }
                    .font(Retro.caption)
                }
                Spacer(minLength: 12)
                Button(L("menu.developer.about"), action: action)
                    .buttonStyle(RetroButtonStyle())
            }
            .padding(.horizontal, 12)
            .padding(.vertical, 10)
        }
        .background(hover ? Retro.faceHover : Retro.face)
        .contentShape(Rectangle())
        .onHover { hover = $0 }
        .onTapGesture(perform: action)
        .modifier(RowAccessibility(action: action))
    }

    @ViewBuilder private var avatar: some View {
        if let image = RetroMenuView.developerAvatar {
            Image(nsImage: image)
                .resizable()
                .interpolation(.high)
                .clipShape(Circle())
                .accessibilityHidden(true)
        } else {
            Image(systemName: "person.crop.circle.fill")
                .font(.system(size: 36))
                .foregroundColor(Retro.text)
        }
    }
}

/// Строка меню: значок слева, заголовок с подписью, элемент управления справа.
private struct Row<Trailing: View>: View {
    let icon: String
    var iconBoxed = false
    let title: String
    var subtitle: String? = nil
    var plate: Plate? = nil
    /// Что VoiceOver прочитает как состояние строки — у тумблеров «вкл/выкл».
    var accessibilityValue: String? = nil
    var action: (() -> Void)? = nil
    @ViewBuilder var trailing: () -> Trailing

    @State private var hover = false

    var body: some View {
        HStack(spacing: 14) {
            iconView
                .frame(width: 44, height: 40)
            VStack(alignment: .leading, spacing: 3) {
                Text(title)
                    .font(Retro.title())
                    .kerning(0.4)
                    .foregroundColor(plate != nil ? .white : Retro.text)
                if let subtitle {
                    Text(subtitle)
                        .font(Retro.caption)
                        .kerning(0.2)
                        .foregroundColor(plate?.subtitle ?? Retro.subtitle)
                }
            }
            .fixedSize(horizontal: false, vertical: true)
            Spacer(minLength: 12)
            trailing()
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 10)
        .frame(minHeight: subtitle == nil ? 50 : 64)
        .background(background)
        .contentShape(Rectangle())
        .onHover { hover = $0 }
        .onTapGesture { action?() }
        .modifier(RowAccessibility(action: action))
        .accessibilityValue(accessibilityValue ?? "")
    }

    private var background: Color {
        let hot = hover && action != nil
        if let plate { return hot ? plate.hover : plate.background }
        return hot ? Retro.faceHover : Retro.face
    }

    @ViewBuilder private var iconView: some View {
        let image = Image(systemName: icon)
            .accessibilityHidden(true)
            .font(.system(size: iconBoxed ? 20 : 26, weight: .semibold))
            .foregroundColor(plate != nil ? .white : Retro.text)
        if iconBoxed {
            image
                .frame(width: 40, height: 36)
                .background(Retro.face)
                .overlay(Bevel(raised: true, width: 2))
        } else {
            image
        }
    }
}

// MARK: - Панель целиком

struct RetroMenuView: View {
    @ObservedObject var model: MenuModel
    /// Где по горизонтали стоит «носик», указывающий на значок в строке меню.
    var pointerX: CGFloat

    static let width: CGFloat = 690
    /// Логотип автора (Resources/Developer.png). Предпросмотр подставляет его сам.
    static var developerAvatar: NSImage? = NSImage(named: "Developer")

    var body: some View {
        VStack(spacing: 0) {
            Pointer()
                .fill(Retro.face)
                .overlay(Pointer().stroke(Retro.shadow, lineWidth: 1))
                .frame(width: 20, height: 9)
                .frame(maxWidth: .infinity, alignment: .leading)
                .padding(.leading, max(10, pointerX - 10))
                // Носик указывает на значок в строке меню — это экранная
                // координата, при письме справа налево её зеркалить нельзя.
                .environment(\.layoutDirection, .leftToRight)
                .offset(y: 1)
                .zIndex(1)

            VStack(spacing: 0) {
                Row(icon: "delete.left", title: L("menu.convert.title"),
                    subtitle: L("menu.convert.subtitle"),
                    plate: .navy, action: model.onConvert) {
                    Button(action: model.onHelp) {
                        Text("?")
                            .font(.system(size: 17, weight: .heavy))
                            .foregroundColor(Retro.text)
                            .frame(width: 32, height: 32)
                            .background(Retro.face)
                            .overlay(Bevel(raised: true, width: 2))
                    }
                    .buttonStyle(.plain)
                    .help(L("menu.help"))
                    .accessibilityHidden(true)
                }
                .accessibilityAction(named: Text(L("menu.help")), model.onHelp)
                .overlay(Bevel(raised: false, width: 2))
                .padding(6)

                if !model.hasAccess {
                    Etch()
                    Row(icon: "exclamationmark.triangle", title: L("menu.access.title"),
                        subtitle: L("menu.access.subtitle"),
                        plate: .red, action: model.onExplainAccess) { EmptyView() }
                }

                Etch()
                Row(icon: "keyboard", title: L("menu.shiftTap.title"),
                    subtitle: L("menu.shiftTap.subtitle"),
                    accessibilityValue: model.shiftTap ? L("toggle.a11y.on") : L("toggle.a11y.off"),
                    action: model.onToggleShiftTap) {
                    RetroToggle(isOn: model.shiftTap, action: model.onToggleShiftTap)
                }

                Etch()
                Row(icon: "doc.text", title: L("menu.diagnostics.title"),
                    subtitle: L("menu.diagnostics.subtitle")) {
                    Button(model.copied ? L("menu.diagnostics.copied") : L("menu.diagnostics.copy"), action: model.onCopyDiagnostics)
                        .buttonStyle(RetroButtonStyle())
                        .frame(minWidth: 130)
                }

                Etch()
                Row(icon: "play.fill", iconBoxed: true, title: L("menu.login.title"),
                    subtitle: L("menu.login.subtitle"),
                    accessibilityValue: model.loginEnabled ? L("toggle.a11y.on") : L("toggle.a11y.off"),
                    action: model.onToggleLogin) {
                    RetroToggle(isOn: model.loginEnabled, action: model.onToggleLogin)
                }

                Etch()
                DeveloperRow(action: model.onAboutDeveloper)

                Etch()
                Row(icon: "rectangle.portrait.and.arrow.right", title: L("menu.quit"),
                    action: model.onQuit) {
                    Text("⌘  Q")
                        .font(.system(size: 14, weight: .bold))
                        .foregroundColor(Retro.text)
                        .frame(width: 70, height: 30)
                        .overlay(Rectangle().stroke(Retro.dark, lineWidth: 1))
                }
            }
            .overlay(Bevel(raised: false, width: 2))
            .padding(6)
            .background(Retro.face)
            .overlay(Bevel(raised: true, width: 3))
        }
        .frame(width: Self.width)
        .environment(\.colorScheme, .light)
    }
}

/// Треугольный «носик» над панелью.
private struct Pointer: Shape {
    func path(in r: CGRect) -> Path {
        Path { p in
            p.move(to: CGPoint(x: r.minX, y: r.maxY))
            p.addLine(to: CGPoint(x: r.midX, y: r.minY))
            p.addLine(to: CGPoint(x: r.maxX, y: r.maxY))
        }
    }
}

// MARK: - Окно

/// Панель без рамки, которая не активирует приложение: фокус остаётся в том
/// поле, где человек печатал, и «Перебить последнее слово» работает прямо отсюда.
private final class RetroPanel: NSPanel {
    override var canBecomeKey: Bool { true }
}

final class RetroMenuController {
    let model = MenuModel()
    private var panel: NSPanel?
    private var monitors: [Any] = []
    var onClose: () -> Void = {}

    var isShown: Bool { panel != nil }

    func show(below button: NSStatusBarButton) {
        guard panel == nil,
              let buttonWindow = button.window,
              let screen = buttonWindow.screen ?? NSScreen.main else { return }

        let buttonFrame = buttonWindow.convertToScreen(button.convert(button.bounds, to: nil))
        let width = RetroMenuView.width
        let visible = screen.visibleFrame

        // Панель стоит так, чтобы носик был под значком, но не вылезает за экран.
        let preferredLeft = buttonFrame.midX - 60
        let left = min(max(preferredLeft, visible.minX + 6), visible.maxX - width - 6)

        let host = NSHostingView(rootView: RetroMenuView(model: model, pointerX: buttonFrame.midX - left))
        let size = host.fittingSize
        host.frame = NSRect(origin: .zero, size: size)

        let panel = RetroPanel(contentRect: NSRect(x: left, y: buttonFrame.minY - size.height - 2,
                                                   width: size.width, height: size.height),
                               styleMask: [.borderless, .nonactivatingPanel],
                               backing: .buffered, defer: false)
        panel.isOpaque = false
        panel.backgroundColor = .clear
        panel.hasShadow = true
        panel.level = .popUpMenu
        panel.collectionBehavior = [.canJoinAllSpaces, .transient]
        panel.contentView = host
        panel.orderFrontRegardless()
        panel.makeKey()
        self.panel = panel

        // Клик мимо панели закрывает её, как обычное меню.
        if let m = NSEvent.addGlobalMonitorForEvents(matching: [.leftMouseDown, .rightMouseDown], handler: { [weak self] _ in
            self?.close()
        }) { monitors.append(m) }

        if let m = NSEvent.addLocalMonitorForEvents(matching: .keyDown, handler: { [weak self] event in
            guard let self, event.window === self.panel else { return event }
            if event.keyCode == 53 {                               // Esc
                self.close()
                return nil
            }
            if event.modifierFlags.contains(.command), event.keyCode == 12 {   // Q в любой раскладке
                self.model.onQuit()
                return nil
            }
            return event
        }) { monitors.append(m) }
    }

    func close() {
        guard let panel else { return }
        monitors.forEach(NSEvent.removeMonitor)
        monitors.removeAll()
        panel.orderOut(nil)
        self.panel = nil
        onClose()
    }
}
