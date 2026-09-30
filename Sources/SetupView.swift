import Cocoa
import SwiftUI

// Окно настройки: ведёт от первого запуска до работающей перебивки.
//
// Строка меню у программы — единственное, что видно после запуска, и без
// подсказок человек не знает, что делать дальше: системный запрос доступа
// macOS показывает не всегда, а куда нажать в настройках, неочевидно.
// Здесь каждый шаг — строка с понятным действием и лампочкой, которая
// загорается сама, как только шаг выполнен.

// MARK: - Состояние

/// ObservableObject, а не @Observable: программа поддерживает macOS 13,
/// а Observation появился в macOS 14. Так же устроено и меню.
final class SetupModel: ObservableObject {
    @Published var installed = true
    @Published var hasAccess = false
    /// Запрос доступа уже отправляли — показываем запасной путь через настройки.
    @Published var accessRequested = false
    @Published var hasLayoutPair = true
    @Published var tested = false
    @Published var loginEnabled = false
    @Published var trial = ""
    var example: (typed: String, result: String)?
    /// У экрана есть вырез под камеру — он может закрыть значок в строке меню.
    var screenHasNotch = false

    var onInstall: () -> Void = {}
    var onRequestAccess: () -> Void = {}
    var onOpenAccessSettings: () -> Void = {}
    var onOpenKeyboardSettings: () -> Void = {}
    var onToggleLogin: () -> Void = {}
    var onHelp: () -> Void = {}
    var onDone: () -> Void = {}
}

// MARK: - Вид

private enum StepState {
    case done, current, locked
}

/// Шаг настройки: номер или горящая лампочка, заголовок, пояснение, действие.
private struct StepRow<Content: View, Trailing: View>: View {
    let number: Int
    let state: StepState
    let title: String
    let text: String
    @ViewBuilder var content: () -> Content
    @ViewBuilder var trailing: () -> Trailing

    var body: some View {
        HStack(alignment: .top, spacing: 14) {
            badge
                .frame(width: 34, height: 34)
            VStack(alignment: .leading, spacing: 6) {
                Text(title)
                    .font(Retro.title(16))
                    .kerning(0.3)
                    .foregroundColor(Retro.text)
                Text(text)
                    .font(Retro.caption)
                    .foregroundColor(state == .done ? Retro.statusText : Retro.subtitle)
                    .fixedSize(horizontal: false, vertical: true)
                content()
            }
            Spacer(minLength: 8)
            trailing()
        }
        .padding(.horizontal, 14)
        .padding(.vertical, 12)
        .opacity(state == .locked ? 0.45 : 1)
        .disabled(state == .locked)
        .accessibilityElement(children: .contain)
    }

    @ViewBuilder private var badge: some View {
        if state == .done {
            Led(on: true, size: 16)
                .frame(width: 34, height: 34)
                .accessibilityLabel(Text(L("toggle.a11y.on")))
        } else {
            Text("\(number)")
                .font(.system(size: 16, weight: .heavy))
                .foregroundColor(state == .current ? .white : Retro.text)
                .frame(width: 34, height: 34)
                .background(state == .current ? Retro.navy : Retro.face)
                .overlay(Bevel(raised: true, width: 2))
                .accessibilityHidden(true)
        }
    }
}

struct SetupView: View {
    @ObservedObject var model: SetupModel
    @FocusState private var trialFocused: Bool

    static let width: CGFloat = 600

    private var installState: StepState { model.installed ? .done : .current }
    private var accessState: StepState {
        model.hasAccess ? .done : (model.installed ? .current : .locked)
    }
    private var tryState: StepState {
        model.tested ? .done : (model.hasAccess ? .current : .locked)
    }

    var body: some View {
        VStack(spacing: 0) {
            header
                .overlay(Bevel(raised: false, width: 2))
                .padding(6)

            VStack(spacing: 0) {
                installStep
                Etch()
                accessStep
                Etch()
                tryStep
                Etch()
                loginStep
            }
            .background(Retro.face)
            .overlay(Bevel(raised: false, width: 2))
            .padding(.horizontal, 6)

            footer
                .padding(.horizontal, 14)
                .padding(.vertical, 12)
        }
        .padding(.bottom, 2)
        .background(Retro.face)
        .frame(width: Self.width)
        .environment(\.colorScheme, .light)
        .onChange(of: model.hasAccess) { granted in
            if granted { trialFocused = true }
        }
    }

    private var header: some View {
        VStack(alignment: .leading, spacing: 3) {
            Text(L("setup.title"))
                .font(Retro.title(20))
                .kerning(0.4)
                .foregroundColor(.white)
            Text(L("setup.subtitle"))
                .font(Retro.caption)
                .foregroundColor(Retro.navySubtitle)
        }
        .padding(.horizontal, 14)
        .padding(.vertical, 12)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(Retro.navy)
    }

    private var installStep: some View {
        StepRow(number: 1, state: installState, title: L("setup.install.title"),
                text: model.installed ? L("setup.install.done") : L("setup.install.todo")) {
            EmptyView()
        } trailing: {
            if !model.installed {
                Button(L("setup.install.button"), action: model.onInstall)
                    .buttonStyle(RetroButtonStyle())
            }
        }
    }

    private var accessStep: some View {
        StepRow(number: 2, state: accessState, title: L("setup.access.title"),
                text: model.hasAccess ? L("setup.access.done") : L("setup.access.todo")) {
            if model.accessRequested && !model.hasAccess {
                Text(L("setup.access.fallback"))
                    .font(Retro.caption)
                    .foregroundColor(Retro.subtitle)
                    .fixedSize(horizontal: false, vertical: true)
                    .padding(.top, 2)
            }
        } trailing: {
            if !model.hasAccess {
                VStack(alignment: .trailing, spacing: 10) {
                    Button(L("setup.access.button"), action: model.onRequestAccess)
                        .buttonStyle(RetroButtonStyle())
                    if model.accessRequested {
                        Button(L("setup.openSettings"), action: model.onOpenAccessSettings)
                            .buttonStyle(RetroButtonStyle())
                    }
                }
                .fixedSize()
            }
        }
    }

    private var tryText: String {
        if model.tested { return L("setup.try.done") }
        if !model.hasAccess { return L("setup.try.locked") }
        if !model.hasLayoutPair { return L("setup.try.noPair") }
        if let example = model.example {
            return String(format: L("setup.try.example"), example.typed, example.result)
        }
        return L("setup.try.generic")
    }

    private var tryStep: some View {
        StepRow(number: 3, state: tryState, title: L("setup.try.title"), text: tryText) {
            if model.hasAccess && model.hasLayoutPair {
                TextField(L("setup.try.placeholder"), text: $model.trial)
                    .textFieldStyle(.plain)
                    .font(.system(size: 15))
                    .foregroundColor(Retro.text)
                    .focused($trialFocused)
                    .padding(.horizontal, 8)
                    .frame(height: 30)
                    .background(Color.white)
                    .overlay(Bevel(raised: false, width: 2))
                    .padding(.top, 2)
            }
        } trailing: {
            if model.hasAccess && !model.hasLayoutPair {
                Button(L("setup.openSettings"), action: model.onOpenKeyboardSettings)
                    .buttonStyle(RetroButtonStyle())
            }
        }
    }

    private var loginStep: some View {
        StepRow(number: 4, state: model.installed ? (model.loginEnabled ? .done : .current) : .locked,
                title: L("menu.login.title"), text: L("setup.login.text")) {
            EmptyView()
        } trailing: {
            RetroToggle(isOn: model.loginEnabled, action: model.onToggleLogin)
        }
        .accessibilityElement(children: .combine)
        .accessibilityAddTraits(.isButton)
        .accessibilityValue(model.loginEnabled ? L("toggle.a11y.on") : L("toggle.a11y.off"))
        .accessibilityAction { model.onToggleLogin() }
    }

    private var footer: some View {
        VStack(alignment: .leading, spacing: 12) {
            VStack(alignment: .leading, spacing: 4) {
                Text(L("setup.footer"))
                if model.screenHasNotch {
                    Text(L("setup.notch"))
                }
            }
            .font(Retro.caption)
            .foregroundColor(Retro.subtitle)
            .fixedSize(horizontal: false, vertical: true)
            HStack(spacing: 12) {
                Spacer()
                Button(L("menu.help"), action: model.onHelp)
                    .buttonStyle(RetroButtonStyle())
                    .fixedSize()
                Button(L("setup.done"), action: model.onDone)
                    .buttonStyle(RetroButtonStyle())
                    .fixedSize()
                    .keyboardShortcut(.defaultAction)
            }
        }
    }
}
