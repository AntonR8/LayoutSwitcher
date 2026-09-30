import Cocoa

/// Установка в «Программы» самой программой.
///
/// Перетаскивание в «Программы» Finder делает молча: образу никто не сообщает,
/// что копия готова, поэтому ни подсказать, что делать дальше, ни закрыть окно
/// установщика нельзя. Если же программу открыли прямо из образа, она ставит
/// себя сама: копирует в /Applications, запускает эту копию и завершается,
/// а копия извлекает образ (окно Finder закрывается вместе с ним) и открывает
/// окно настройки. Тем же путём окно настройки переносит программу,
/// запущенную из «Загрузок» или другой папки.
enum Installer {
    static let destination = URL(fileURLWithPath: "/Applications/LayoutSwitcher.app")

    /// Аргументы запуска новой копии: откуда её поставили.
    private static let installedFromFlag = "--installed-from"

    /// Запущена ли программа из «Программ». Из любого другого места macOS
    /// либо запускает временную копию (App Translocation), и доступ к клавиатуре
    /// слетает при каждом запуске, либо программа потеряется при уборке папки.
    static var isInApplications: Bool {
        let path = Bundle.main.bundlePath
        return path.hasPrefix("/Applications/")
            || path.hasPrefix(FileManager.default.homeDirectoryForCurrentUser.path + "/Applications/")
    }

    // MARK: Экземпляр не из «Программ»

    /// Открыли прямо из окна DMG — ставимся сразу, без вопросов.
    /// true — копия в «Программах» уже запускается, этому экземпляру пора завершиться.
    static func installFromDiskImageIfNeeded() -> Bool {
        let source = originalBundleURL()
        guard diskImageVolume(of: source) != nil else { return false }
        return install()
    }

    /// Скопировать себя в «Программы» и перезапуститься оттуда.
    /// true — копия уже запускается, этому экземпляру пора завершиться.
    @discardableResult
    static func install() -> Bool {
        let source = originalBundleURL()
        let volume = diskImageVolume(of: source)
        do {
            quitOtherInstances()
            try copy(source)
        } catch {
            NSLog("install: \(error)")
            let alert = NSAlert()
            alert.messageText = L("alert.installFailed.title")
            alert.informativeText = L("alert.installFailed.body")
            alert.addButton(withTitle: L("alert.ok"))
            NSApp.activate(ignoringOtherApps: true)
            alert.runModal()
            return false
        }

        let config = NSWorkspace.OpenConfiguration()
        config.createsNewApplicationInstance = true
        config.arguments = [installedFromFlag, volume?.path ?? "", source.path]
        NSWorkspace.shared.openApplication(at: destination, configuration: config) { _, error in
            if let error { NSLog("install: не запустилась копия из «Программ»: \(error)") }
            DispatchQueue.main.async { NSApp.terminate(nil) }
        }
        return true
    }

    /// Где лежит запущенная программа на самом деле. Скачанный образ помечен
    /// карантином, и Gatekeeper запускает не саму программу, а её зеркало
    /// в AppTranslocation — по его пути образ не узнать.
    /// Функция из Security.framework закрытая, поэтому ищем её через dlsym;
    /// не нашлась — считаем, что запущены не из образа.
    private static func originalBundleURL() -> URL {
        let url = Bundle.main.bundleURL
        guard url.path.contains("/AppTranslocation/"),
              let security = dlopen("/System/Library/Frameworks/Security.framework/Security", RTLD_LAZY),
              let symbol = dlsym(security, "SecTranslocateCreateOriginalPathForURL") else { return url }
        typealias OriginalPath = @convention(c) (CFURL, UnsafeMutablePointer<Unmanaged<CFError>?>?) -> Unmanaged<CFURL>?
        let originalPath = unsafeBitCast(symbol, to: OriginalPath.self)
        return originalPath(url as CFURL, nil)?.takeRetainedValue() as URL? ?? url
    }

    /// Том образа, из которого запущена программа. Том только для чтения —
    /// чтобы не принять за установщик флешку и не извлечь её.
    private static func diskImageVolume(of app: URL) -> URL? {
        let parts = app.standardizedFileURL.pathComponents   // "/", "Volumes", том, …
        guard parts.count > 3, parts[1] == "Volumes" else { return nil }
        let volume = URL(fileURLWithPath: "/Volumes", isDirectory: true).appendingPathComponent(parts[2], isDirectory: true)
        let readOnly = (try? volume.resourceValues(forKeys: [.volumeIsReadOnlyKey]))?.volumeIsReadOnly ?? false
        return readOnly ? volume : nil
    }

    /// Старую версию, запущенную из «Программ», закрываем: пока она работает,
    /// заменить её нельзя, а новая запустится рядом второй копией.
    private static func quitOtherInstances() {
        let me = ProcessInfo.processInfo.processIdentifier
        let others = NSRunningApplication.runningApplications(withBundleIdentifier: Bundle.main.bundleIdentifier ?? "")
            .filter { $0.processIdentifier != me }
        guard !others.isEmpty else { return }
        others.forEach { $0.terminate() }
        let deadline = Date().addingTimeInterval(5)
        while others.contains(where: { !$0.isTerminated }), Date() < deadline {
            RunLoop.current.run(until: Date().addingTimeInterval(0.1))
        }
        others.filter { !$0.isTerminated }.forEach { $0.forceTerminate() }
    }

    /// Копируем во временную папку на том же диске и уже потом подменяем:
    /// если копирование сорвётся, прежняя версия в «Программах» останется целой.
    private static func copy(_ source: URL) throws {
        let fm = FileManager.default
        let temp = try fm.url(for: .itemReplacementDirectory, in: .userDomainMask,
                              appropriateFor: destination, create: true)
        defer { try? fm.removeItem(at: temp) }
        let staged = temp.appendingPathComponent(destination.lastPathComponent)
        try fm.copyItem(at: source, to: staged)
        // Карантин снимаем: запуск этой программы человек уже подтвердил.
        // С карантином Gatekeeper спросил бы ещё раз и снова запустил бы её
        // из временного зеркала, где слетает доступ к клавиатуре.
        run("/usr/bin/xattr", "-dr", "com.apple.quarantine", staged.path)
        if fm.fileExists(atPath: destination.path) {
            _ = try fm.replaceItemAt(destination, withItemAt: staged)
        } else {
            try fm.moveItem(at: staged, to: destination)
        }
    }

    // MARK: Копия в «Программах»

    /// Первый запуск после установки: убрать то, откуда ставили.
    /// true — программу только что установили.
    static func finishInstallIfNeeded() -> Bool {
        let args = CommandLine.arguments
        guard let i = args.firstIndex(of: installedFromFlag), i + 2 < args.count else { return false }
        let volume = args[i + 1]
        let oldApp = URL(fileURLWithPath: args[i + 2])
        DispatchQueue.global(qos: .utility).async { cleanUp(volume: volume, oldApp: oldApp) }
        return true
    }

    private static func cleanUp(volume: String, oldApp: URL) {
        if volume.isEmpty {
            // Ставили из обычной папки («Загрузки» и т. п.) — старая копия больше
            // не нужна, а оставшись, она давала бы второй значок в Launchpad.
            // Кладём в Корзину, а не удаляем: вдруг человеку она зачем-то нужна.
            if oldApp.standardizedFileURL != destination.standardizedFileURL {
                try? FileManager.default.trashItem(at: oldApp, resultingItemURL: nil)
            }
        } else {
            eject(URL(fileURLWithPath: volume, isDirectory: true))
        }
        // Launch Services помнит старую копию и после её удаления —
        // без этого в Launchpad остаётся второй значок LayoutSwitcher.
        run("/System/Library/Frameworks/CoreServices.framework/Frameworks/LaunchServices.framework/Support/lsregister",
            "-u", oldApp.path)
    }

    /// Экземпляр из образа ещё завершается, а пока он работает, том занят —
    /// поэтому пробуем несколько раз.
    private static func eject(_ volume: URL) {
        for _ in 0..<20 {
            if (try? NSWorkspace.shared.unmountAndEjectDevice(at: volume)) != nil { return }
            Thread.sleep(forTimeInterval: 0.5)
        }
        // Мешать может зеркало AppTranslocation, которое система убирает не сразу.
        // Образ только для чтения, так что принудительное извлечение ничего не портит.
        run("/usr/bin/hdiutil", "detach", "-force", volume.path)
    }

    // MARK: Доступ к клавиатуре

    /// Системный запрос доступа macOS показывает, только пока программы нет
    /// в списке «Универсального доступа». Если она там уже есть — выключенной,
    /// после отказа или с подписью прошлой сборки, — запрос молчит, а переключатель
    /// может даже стоять включённым и не действовать. Поэтому перед запросом
    /// запись сбрасываем: раз доступа нет, терять нечего, а запрос появится наверняка.
    static func requestAccess() {
        if let id = Bundle.main.bundleIdentifier {
            run("/usr/bin/tccutil", "reset", "Accessibility", id)
        }
        let options = [kAXTrustedCheckOptionPrompt.takeUnretainedValue() as String: true] as CFDictionary
        _ = AXIsProcessTrustedWithOptions(options)
    }

    static func run(_ tool: String, _ arguments: String...) {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: tool)
        process.arguments = arguments
        process.standardOutput = FileHandle.nullDevice
        process.standardError = FileHandle.nullDevice
        do {
            try process.run()
            process.waitUntilExit()
        } catch {
            NSLog("install: \(tool): \(error)")
        }
    }
}
