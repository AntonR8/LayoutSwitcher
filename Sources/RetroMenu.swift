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
}

// MARK: - Палитра

private enum Retro {
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
    static let toggleOn = Color(red: 0.05, green: 0.15, blue: 0.75)

    static func title(_ size: CGFloat = 17) -> Font { .system(size: size, weight: .bold) }
    static let caption = Font.system(size: 13.5)
}

// MARK: - Объёмная рамка

/// Двойная рамка: светлые грани сверху-слева и тёмные снизу-справа — «выпуклая»,
/// наоборот — «вдавленная».
private struct Bevel: View {
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
private struct Etch: View {
    var body: some View {
        VStack(spacing: 0) {
            Retro.shadow.frame(height: 1)
            Retro.light.frame(height: 1)
        }
    }
}

// MARK: - Элементы

private struct RetroToggle: View {
    var isOn: Bool
    var action: () -> Void

    private let width: CGFloat = 62
    private let knob: CGFloat = 26

    var body: some View {
        Button(action: action) {
            // Ползунок едет вправо, а синяя заливка тянется за ним слева.
            let travel = width - knob
            ZStack(alignment: .leading) {
                Retro.shadow.opacity(0.35)
                Retro.toggleOn
                    .frame(width: isOn ? travel : 0)
                Retro.light
                    .frame(width: knob)
                    .overlay(Bevel(raised: true, width: 2))
                    .offset(x: isOn ? travel : 0)
            }
            .frame(width: width, height: 30, alignment: .leading)
            .clipped()
            .overlay(Bevel(raised: false, width: 2))
            .animation(.easeInOut(duration: 0.18), value: isOn)
        }
        .buttonStyle(.plain)
        .accessibilityLabel(isOn ? "Включено" : "Выключено")
    }
}

private struct RetroButtonStyle: ButtonStyle {
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

/// Строка меню: значок слева, заголовок с подписью, элемент управления справа.
private struct Row<Trailing: View>: View {
    let icon: String
    var iconBoxed = false
    let title: String
    var subtitle: String? = nil
    var plate: Plate? = nil
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
    }

    private var background: Color {
        let hot = hover && action != nil
        if let plate { return hot ? plate.hover : plate.background }
        return hot ? Retro.faceHover : Retro.face
    }

    @ViewBuilder private var iconView: some View {
        let image = Image(systemName: icon)
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

    var body: some View {
        VStack(spacing: 0) {
            Pointer()
                .fill(Retro.face)
                .overlay(Pointer().stroke(Retro.shadow, lineWidth: 1))
                .frame(width: 20, height: 9)
                .frame(maxWidth: .infinity, alignment: .leading)
                .padding(.leading, max(10, pointerX - 10))
                .offset(y: 1)
                .zIndex(1)

            VStack(spacing: 0) {
                Row(icon: "delete.left", title: "Перебить последнее слово",
                    subtitle: "Двойной Shift — слово. Ещё раз — шире.",
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
                    .help("Как пользоваться")
                }
                .overlay(Bevel(raised: false, width: 2))
                .padding(6)

                if !model.hasAccess {
                    Etch()
                    Row(icon: "exclamationmark.triangle", title: "Нет доступа к клавиатуре",
                        subtitle: "Нажмите, чтобы узнать, как его выдать.",
                        plate: .red, action: model.onExplainAccess) { EmptyView() }
                }

                Etch()
                Row(icon: "keyboard", title: "Переключать раскладку одиночным Shift",
                    subtitle: "Быстро переключать язык одним нажатием Shift.",
                    action: model.onToggleShiftTap) {
                    RetroToggle(isOn: model.shiftTap, action: model.onToggleShiftTap)
                }

                Etch()
                Row(icon: "doc.text", title: "Скопировать диагностику",
                    subtitle: "Скопировать в буфер информацию для поддержки.") {
                    Button(model.copied ? "Скопировано" : "Скопировать", action: model.onCopyDiagnostics)
                        .buttonStyle(RetroButtonStyle())
                        .frame(minWidth: 130)
                }

                Etch()
                Row(icon: "play.fill", iconBoxed: true, title: "Запускать при входе",
                    subtitle: "Автоматически запускать приложение при входе в систему.",
                    action: model.onToggleLogin) {
                    RetroToggle(isOn: model.loginEnabled, action: model.onToggleLogin)
                }

                Etch()
                Row(icon: "rectangle.portrait.and.arrow.right", title: "Выйти",
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
            if event.modifierFlags.contains(.command), event.charactersIgnoringModifiers?.lowercased() == "q"
                || event.charactersIgnoringModifiers == "й" {
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
