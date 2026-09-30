import Cocoa
import SwiftUI
import ServiceManagement

// Окно настройки: показывает SetupView и следит за шагами, которые
// выполняются вне программы, — в Системных настройках и в Finder.

final class SetupWindowController: NSObject, NSWindowDelegate {
    let model = SetupModel()
    private var window: NSWindow?
    private var timer: Timer?
    private var observer: NSObjectProtocol?

    /// Вызывается, когда в окне включают или выключают автозапуск.
    var onToggleLogin: () -> Void = {}

    override init() {
        super.init()
        model.screenHasNotch = (NSScreen.main?.safeAreaInsets.top ?? 0) > 0
        model.onInstall = { Installer.install() }
        model.onRequestAccess = { [weak self] in
            Installer.requestAccess()
            self?.model.accessRequested = true
        }
        model.onOpenAccessSettings = {
            Self.open("x-apple.systempreferences:com.apple.preference.security?Privacy_Accessibility")
        }
        model.onOpenKeyboardSettings = {
            Self.open("x-apple.systempreferences:com.apple.Keyboard-Settings.extension")
        }
        model.onToggleLogin = { [weak self] in
            self?.onToggleLogin()
            self?.refresh()
        }
        model.onHelp = { Self.open("https://github.com/AntonR8/LayoutSwitcher#readme") }
        model.onDone = { [weak self] in self?.window?.close() }
    }

    func show() {
        refresh()
        if window == nil {
            let host = NSHostingView(rootView: SetupView(model: model))
            host.frame.size = host.fittingSize
            let window = NSWindow(contentRect: NSRect(origin: .zero, size: host.fittingSize),
                                  styleMask: [.titled, .closable],
                                  backing: .buffered, defer: false)
            window.title = "LayoutSwitcher"
            window.contentView = host
            window.isReleasedWhenClosed = false
            window.delegate = self
            window.center()
            self.window = window
        }
        startWatching()
        NSApp.activate(ignoringOtherApps: true)
        window?.makeKeyAndOrderFront(nil)
    }

    /// Пока окно открыто, следим за шагами: доступ выдают в Системных
    /// настройках, раскладку добавляют там же — сообщить нам об этом некому.
    private func startWatching() {
        guard timer == nil else { return }
        timer = Timer.scheduledTimer(withTimeInterval: 1.0, repeats: true) { [weak self] _ in
            self?.refresh()
        }
        observer = NotificationCenter.default.addObserver(forName: Engine.didConvert, object: nil, queue: .main) { [weak self] _ in
            // Засчитываем перебивку, сделанную именно в поле проверки.
            guard let self, self.window?.isKeyWindow == true else { return }
            self.model.tested = true
        }
    }

    private func refresh() {
        let granted = AXIsProcessTrusted()
        if granted && !model.hasAccess {
            // Доступ выдали в Системных настройках — возвращаем окно вперёд,
            // чтобы следующий шаг был перед глазами.
            NSApp.activate(ignoringOtherApps: true)
            window?.makeKeyAndOrderFront(nil)
        }
        if model.hasAccess != granted { model.hasAccess = granted }
        let installed = Installer.isInApplications
        if model.installed != installed { model.installed = installed }
        let pair = Engine.shared.hasLayoutPair
        if model.hasLayoutPair != pair { model.hasLayoutPair = pair }
        if pair && model.example == nil { model.example = Engine.shared.example() }
        let login = SMAppService.mainApp.status == .enabled
        if model.loginEnabled != login { model.loginEnabled = login }
        resize()
    }

    /// Высота окна зависит от текста шагов — подгоняем, когда он меняется.
    private func resize() {
        guard let window, let host = window.contentView else { return }
        let size = host.fittingSize
        guard size != window.contentLayoutRect.size else { return }
        var frame = window.frameRect(forContentRect: NSRect(origin: .zero, size: size))
        frame.origin = NSPoint(x: window.frame.minX, y: window.frame.maxY - frame.height)
        window.setFrame(frame, display: true, animate: false)
    }

    func windowWillClose(_ notification: Notification) {
        timer?.invalidate()
        timer = nil
        if let observer { NotificationCenter.default.removeObserver(observer) }
        observer = nil
    }

    private static func open(_ link: String) {
        if let url = URL(string: link) { NSWorkspace.shared.open(url) }
    }
}
