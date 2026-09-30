import AppKit
import SwiftUI

// Отрисовка окна настройки без запуска приложения — для проверки вёрстки
// на всех языках и во всех состояниях. Запуск — через Tests/render_setup.sh.
//
//   render <Resources> <язык> <out.png> <состояние>
//
// Состояния: moved — программа не в «Программах»; access — ждём доступа
// (запрос уже отправлен); try — доступ есть, ждём проверки; done — всё готово.

let args = CommandLine.arguments
guard args.count >= 5 else {
    print("usage: render <Resources> <lang> <out.png> <moved|access|try|done>")
    exit(2)
}
let resources = args[1], lang = args[2], out = args[3], state = args[4]
guard let bundle = Bundle(path: "\(resources)/\(lang).lproj") else {
    print("no \(lang).lproj in \(resources)")
    exit(1)
}
Localization.bundle = bundle

let model = SetupModel()
model.installed = state != "moved"
model.hasAccess = state == "try" || state == "done"
model.accessRequested = state == "access"
model.tested = state == "done"
model.loginEnabled = state == "done"
model.example = ("ghbdtn", "привет")
model.screenHasNotch = true
if state == "try" { model.trial = "ghbdtn" }

let rtl = Locale.characterDirection(forLanguage: lang) == .rightToLeft
let view = SetupView(model: model)
    .environment(\.layoutDirection, rtl ? .rightToLeft : .leftToRight)

MainActor.assumeIsolated {
    let renderer = ImageRenderer(content: view.padding(16).background(Color(red: 0.07, green: 0.2, blue: 0.2)))
    renderer.scale = 2
    guard let image = renderer.cgImage,
          let png = NSBitmapImageRep(cgImage: image).representation(using: .png, properties: [:]) else {
        print("render failed"); exit(1)
    }
    try! png.write(to: URL(fileURLWithPath: out))
    print("\(lang) \(state): \(image.width)×\(image.height) → \(out)")
}
