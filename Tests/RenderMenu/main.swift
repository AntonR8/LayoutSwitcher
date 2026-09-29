import AppKit
import SwiftUI

// Отрисовка меню без запуска приложения: для проверки вёрстки на всех языках
// и для скриншотов в README. Запуск — через Tests/render_menu.sh.
//
//   render <Resources> <язык> <out.png> [--no-access] [--a11y]
//
// --no-access  показать красную строку «Нет доступа к клавиатуре»
// --a11y       вывести дерево доступности — то, что прочитает VoiceOver

let args = CommandLine.arguments
guard args.count >= 4 else {
    print("usage: render <Resources> <lang> <out.png> [--no-access] [--a11y]")
    exit(2)
}
let resources = args[1], lang = args[2], out = args[3]
guard let bundle = Bundle(path: "\(resources)/\(lang).lproj") else {
    print("no \(lang).lproj in \(resources)")
    exit(1)
}
Localization.bundle = bundle
RetroMenuView.developerAvatar = NSImage(contentsOfFile: "\(resources)/Developer.png")

let model = MenuModel()
model.shiftTap = true
model.loginEnabled = false
model.hasAccess = !args.contains("--no-access")

let rtl = Locale.characterDirection(forLanguage: lang) == .rightToLeft
let menu = RetroMenuView(model: model, pointerX: 60)
    .environment(\.layoutDirection, rtl ? .rightToLeft : .leftToRight)

MainActor.assumeIsolated {
    let renderer = ImageRenderer(content: menu.padding(16).background(Color(red: 0.07, green: 0.2, blue: 0.2)))
    renderer.scale = 2
    guard let image = renderer.cgImage,
          let png = NSBitmapImageRep(cgImage: image).representation(using: .png, properties: [:]) else {
        print("render failed"); exit(1)
    }
    try! png.write(to: URL(fileURLWithPath: out))
    print("\(lang): \(image.width)×\(image.height) → \(out)")

    guard args.contains("--a11y") else { return }
    let nsApp = NSApplication.shared
    nsApp.setActivationPolicy(.accessory)
    nsApp.finishLaunching()
    let host = NSHostingView(rootView: menu)
    host.frame = NSRect(origin: .zero, size: host.fittingSize)
    let window = NSWindow(contentRect: host.frame, styleMask: .borderless, backing: .buffered, defer: false)
    window.contentView = host
    window.orderFrontRegardless()
    RunLoop.current.run(until: Date().addingTimeInterval(0.3))

    // Спрашиваем так же, как VoiceOver: через AXUIElement собственного процесса.
    // Иначе SwiftUI дерево доступности не строит. Нужен доступ к Универсальному
    // доступу у того, кто запускает (обычно Терминал).
    func attr(_ e: AXUIElement, _ name: String) -> AnyObject? {
        var v: AnyObject?
        return AXUIElementCopyAttributeValue(e, name as CFString, &v) == .success ? v : nil
    }
    func walk(_ e: AXUIElement, depth: Int) {
        let role = attr(e, kAXRoleAttribute) as? String ?? "?"
        let label = (attr(e, kAXDescriptionAttribute) as? String).flatMap { $0.isEmpty ? nil : $0 }
            ?? (attr(e, kAXTitleAttribute) as? String).flatMap { $0.isEmpty ? nil : $0 }
            ?? (attr(e, kAXValueAttribute) as? String) ?? ""
        var names: CFArray?
        AXUIElementCopyActionNames(e, &names)
        let actions = ((names as? [String]) ?? []).filter { !$0.hasPrefix("AXScroll") && $0 != "AXShowMenu" && $0 != "AXScrollToVisible" }
        let interesting = !label.isEmpty || role == "AXButton"
        if interesting {
            var line = String(repeating: "  ", count: depth) + "\(role) «\(label)»"
            if let value = attr(e, kAXValueAttribute) as? String, !value.isEmpty, value != label {
                line += " = \(value)"
            }
            let custom = actions.filter { !$0.hasPrefix("AX") }
            if !custom.isEmpty { line += "  + \(custom.map { $0.components(separatedBy: "\n").first ?? $0 })" }
            print(line)
        }
        for child in (attr(e, kAXChildrenAttribute) as? [AXUIElement]) ?? [] {
            walk(child, depth: interesting ? depth + 1 : depth)
        }
    }
    guard AXIsProcessTrusted() else { print("--a11y: нет доступа к Универсальному доступу у Терминала"); return }
    let app = AXUIElementCreateApplication(getpid())
    AXUIElementSetAttributeValue(app, "AXEnhancedUserInterface" as CFString, kCFBooleanTrue)
    RunLoop.current.run(until: Date().addingTimeInterval(0.5))
    let windows = (attr(app, kAXWindowsAttribute) as? [AXUIElement]) ?? []
    if windows.isEmpty { print("--a11y: окна не видны через Accessibility") }
    for w in windows { walk(w, depth: 0) }
}
