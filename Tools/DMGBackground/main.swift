import AppKit
import SwiftUI

// Фон окна DMG в стиле меню: серые объёмные рамки, синяя плашка, стрелка
// «перетащи сюда». Рисуется в 1x и 2x и склеивается в один TIFF — Finder
// берёт нужное разрешение сам.
//
//   Tools/make_dmg_background.sh   →   Assets/dmg/background.tiff
//
// Координаты гнёзд должны совпадать с позициями значков в build.sh
// (ICON_APP_X / ICON_APPS_X / ICON_Y): Finder ставит значок центром в точку.

let W: CGFloat = 640, H: CGFloat = 400
/// Холст выше окна: высоту заголовка Finder не сообщает, и если окно
/// окажется чуть выше, снизу должен быть тот же серый, а не белая полоса.
let canvasH: CGFloat = H + 40
let appX: CGFloat = 160, appsX: CGFloat = 480, iconY: CGFloat = 215

let cFace = Color(red: 0.76, green: 0.76, blue: 0.76)
let cFaceLight = Color(red: 0.83, green: 0.83, blue: 0.83)
let cShadow = Color(red: 0.50, green: 0.50, blue: 0.50)
let cNavy = Color(red: 0.00, green: 0.05, blue: 0.55)
let cNavySubtitle = Color(red: 0.78, green: 0.82, blue: 1.00)

/// Двойная рамка: выпуклая — светлое сверху-слева, вдавленная — наоборот.
struct Bevel: View {
    var raised = true
    var width: CGFloat = 2
    var body: some View {
        GeometryReader { g in
            let w = g.size.width, h = g.size.height
            let (a, b, c, d) = raised ? (Color.white, Color.black, cFaceLight, cShadow)
                                      : (cShadow, Color.white, Color.black, cFaceLight)
            ZStack {
                edges(w, h, 0, a, b)
                edges(w, h, width / 2 + 0.5, c, d)
            }
        }
    }
    func edges(_ w: CGFloat, _ h: CGFloat, _ i: CGFloat, _ tl: Color, _ br: Color) -> some View {
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

/// Толстая стрелка вправо.
struct Arrow: Shape {
    func path(in r: CGRect) -> Path {
        let shaft = r.height * 0.38, head = r.width * 0.42
        return Path { p in
            p.move(to: CGPoint(x: r.minX, y: r.midY - shaft / 2))
            p.addLine(to: CGPoint(x: r.maxX - head, y: r.midY - shaft / 2))
            p.addLine(to: CGPoint(x: r.maxX - head, y: r.minY))
            p.addLine(to: CGPoint(x: r.maxX, y: r.midY))
            p.addLine(to: CGPoint(x: r.maxX - head, y: r.maxY))
            p.addLine(to: CGPoint(x: r.maxX - head, y: r.midY + shaft / 2))
            p.addLine(to: CGPoint(x: r.minX, y: r.midY + shaft / 2))
            p.closeSubpath()
        }
    }
}

/// Вдавленное гнездо под значок с подписью Finder.
func slot(x: CGFloat) -> some View {
    cFace.frame(width: 176, height: 184)
        .overlay(Bevel(raised: false, width: 2))
        .position(x: x, y: iconY + 16)
}

let background = ZStack(alignment: .topLeading) {
    cFace
    // Шапка
    VStack(alignment: .leading, spacing: 3) {
        Text("LayoutSwitcher")
            .font(.system(size: 22, weight: .bold))
            .kerning(0.5)
            .foregroundColor(.white)
        Text("Drag the app to Applications to install")
            .font(.system(size: 13))
            .foregroundColor(cNavySubtitle)
    }
    .padding(.horizontal, 20)
    .frame(width: W - 20, height: 64, alignment: .leading)
    .background(cNavy)
    .overlay(Bevel(raised: false, width: 2))
    .offset(x: 10, y: 10)

    slot(x: appX)
    slot(x: appsX)

    // Стрелка: тень, тело, светлая кромка — как объёмная кнопка.
    ZStack {
        Arrow().fill(Color.black.opacity(0.35)).offset(x: 3, y: 3)
        Arrow().fill(cNavy)
        Arrow().stroke(Color.white.opacity(0.55), lineWidth: 1.5)
    }
    .frame(width: 100, height: 64)
    .position(x: (appX + appsX) / 2, y: iconY)

    Text("Перетащите LayoutSwitcher в папку «Программы»")
        .font(.system(size: 12))
        .foregroundColor(cShadow)
        .frame(width: W)
        .position(x: W / 2, y: H - 30)
}
.frame(width: W, height: canvasH, alignment: .top)
.environment(\.colorScheme, .light)

let out = CommandLine.arguments.count > 1 ? CommandLine.arguments[1] : "background.tiff"
MainActor.assumeIsolated {
    var reps: [NSBitmapImageRep] = []
    for scale in [1.0, 2.0] {
        let r = ImageRenderer(content: background)
        r.scale = scale
        let rep = NSBitmapImageRep(cgImage: r.cgImage!)
        rep.size = NSSize(width: W, height: canvasH)     // 72 dpi и 144 dpi — Finder различает по этому
        reps.append(rep)
    }
    let image = NSImage(size: NSSize(width: W, height: canvasH))
    reps.forEach(image.addRepresentation)
    try! image.tiffRepresentation(using: .lzw, factor: 1)!.write(to: URL(fileURLWithPath: out))
    try! reps[1].representation(using: .png, properties: [:])!
        .write(to: URL(fileURLWithPath: out.replacingOccurrences(of: ".tiff", with: "@2x-preview.png")))
    print("фон DMG: \(out)")
}
