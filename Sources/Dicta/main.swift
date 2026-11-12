import AppKit
import SwiftUI

@MainActor
final class AppDelegate: NSObject, NSApplicationDelegate, NSMenuDelegate {
    private var statusItem: NSStatusItem!
    private let controller = DictationController()
    private let windows = WindowManager()
    private let settings = AppSettings.shared

    func applicationDidFinishLaunching(_ notification: Notification) {
        NSApp.setActivationPolicy(.accessory)
        statusItem = NSStatusBar.system.statusItem(withLength: NSStatusItem.variableLength)
        updateIcon(.idle)
        let menu = NSMenu()
        menu.delegate = self
        statusItem.menu = menu

        controller.onStateChange = { [weak self] s in self?.updateIcon(s) }
        controller.start()

        if !Permissions.allGranted { showPermissions() }
        if Permissions.microphone == false { Permissions.requestMicrophone() }
    }

    private func updateIcon(_ s: DictationController.State) {
        let name: String
        switch s {
        case .idle: name = "waveform"
        case .recording: name = "mic.fill"
        case .processing: name = "ellipsis.circle"
        }
        let img = NSImage(systemSymbolName: name, accessibilityDescription: "Dicta")
        img?.isTemplate = s != .recording
        statusItem.button?.image = s == .recording
            ? img?.withSymbolConfiguration(.init(paletteColors: [.systemRed]))
            : img
    }

    // Menú reconstruido cada vez que se abre (estado y permisos al día).
    func menuNeedsUpdate(_ menu: NSMenu) {
        menu.removeAllItems()
        let k = settings.trigger.symbol
        let header = NSMenuItem(title: "Mantén \(k) para dictar · doble toque: manos libres", action: nil, keyEquivalent: "")
        header.isEnabled = false
        menu.addItem(header)
        switch controller.voiceModel {
        case .preparing:
            let i = NSMenuItem(title: "⏳ Preparando el modelo de voz en español…", action: nil, keyEquivalent: "")
            i.isEnabled = false; menu.addItem(i)
        case .failed(let why):
            menu.addItem(item("⚠️ \(why) Reintentar", #selector(retryVoiceModel)))
        case .ready: break
        }
        let engine = NSMenuItem(title: CleanerFactory.describe(), action: nil, keyEquivalent: "")
        engine.isEnabled = false
        menu.addItem(engine)
        if !Permissions.allGranted {
            menu.addItem(item("⚠️ Faltan permisos…", #selector(showPermissions)))
        }
        menu.addItem(.separator())
        menu.addItem(item(controller.state == .recording ? "Parar dictado" : "Empezar dictado (manos libres)",
                          #selector(toggleDictation)))
        menu.addItem(item("Re-dictar / editar lo último", #selector(redictate)))
        menu.addItem(item("Pegar último dictado", #selector(pasteLast)))
        menu.addItem(item("Copiar último dictado", #selector(copyLast)))
        menu.addItem(.separator())
        menu.addItem(item("Historial…", #selector(showHistory), "h"))
        menu.addItem(item("Diccionario…", #selector(showDictionary), "d"))
        menu.addItem(item("Ajustes…", #selector(showSettings), ","))
        menu.addItem(item("Permisos…", #selector(showPermissions)))
        menu.addItem(.separator())
        menu.addItem(item("Salir de Dicta", #selector(quit), "q"))
    }

    private func item(_ title: String, _ sel: Selector, _ key: String = "") -> NSMenuItem {
        let i = NSMenuItem(title: title, action: sel, keyEquivalent: key)
        i.target = self
        return i
    }

    @objc private func retryVoiceModel() { Task { await controller.warmUp() } }
    @objc private func toggleDictation() { controller.startFromMenu() }
    @objc private func redictate() { controller.redictateLast() }
    @objc private func pasteLast() { controller.pasteLast() }
    @objc private func copyLast() {
        if let t = HistoryStore.shared.last?.text { TextInserter.copyToClipboard(t) }
    }
    @objc private func showHistory() { windows.show("history", title: "Historial de dictados") { HistoryView() } }
    @objc private func showDictionary() { windows.show("dictionary", title: "Diccionario personal") { DictionaryView() } }
    @objc private func showSettings() {
        windows.show("settings", title: "Ajustes de Dicta") {
            SettingsView(onChange: { [weak self] in self?.controller.applySettings() })
        }
    }
    @objc private func showPermissions() { windows.show("permissions", title: "Permisos") { PermissionsView() } }
    @objc private func quit() { NSApp.terminate(nil) }
}

let cliArgs = CommandLine.arguments
if let i = cliArgs.firstIndex(of: "--selftest") {
    let rest = Array(cliArgs[(i + 1)...])
    let sem = DispatchSemaphore(value: 0)
    var code: Int32 = 0
    Task.detached { code = await SelfTest.run(rest); sem.signal() }
    while sem.wait(timeout: .now() + 0.05) == .timedOut {
        RunLoop.main.run(until: Date().addingTimeInterval(0.05))
    }
    exit(code)
}

MainActor.assumeIsolated {
    let app = NSApplication.shared
    let delegate = AppDelegate()
    app.delegate = delegate
    withExtendedLifetime(delegate) { app.run() }
}
