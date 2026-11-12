import AppKit
import CoreGraphics
import DictaCore

/// Escucha el teclado globalmente con un CGEventTap (solo escucha, no bloquea teclas),
/// la misma técnica que usan Wispr Flow y Typeless (`CGEventTapCreate`).
/// Requiere el permiso «Monitorización de entrada».
@MainActor
final class HotkeyMonitor {
    struct Event {
        let action: HotkeyAction
        let shiftHeld: Bool // Mayús + atajo = modo edición
    }

    var onAction: ((Event) -> Void)?
    var onEscape: (() -> Void)?

    private(set) var machine = HotkeyStateMachine()
    private var tap: CFMachPort?
    private var source: CFRunLoopSource?
    private var triggerDown = false
    private var shiftAtStart = false
    private var retryTimer: Timer?
    var trigger: TriggerKey = .rightOption

    var isTriggerDown: Bool { triggerDown }
    var isActive: Bool { tap != nil }

    func configure(trigger: TriggerKey, holdMs: Double, doubleTapMs: Double) {
        self.trigger = trigger
        machine.holdThreshold = holdMs / 1000
        machine.doubleTapWindow = doubleTapMs / 1000
    }

    func start() {
        guard tap == nil else { return }
        let mask: CGEventMask = (1 << CGEventType.flagsChanged.rawValue) | (1 << CGEventType.keyDown.rawValue)
        let refcon = Unmanaged.passUnretained(self).toOpaque()
        let callback: CGEventTapCallBack = { _, type, event, refcon in
            guard let refcon else { return Unmanaged.passUnretained(event) }
            let monitor = Unmanaged<HotkeyMonitor>.fromOpaque(refcon).takeUnretainedValue()
            let keyCode = event.getIntegerValueField(.keyboardEventKeycode)
            let flags = event.flags.rawValue
            let isRepeat = event.getIntegerValueField(.keyboardEventAutorepeat) != 0
            MainActor.assumeIsolated {
                monitor.handle(type: type, keyCode: keyCode, flags: flags, isRepeat: isRepeat)
            }
            return Unmanaged.passUnretained(event)
        }
        guard let port = CGEvent.tapCreate(tap: .cgSessionEventTap, place: .headInsertEventTap,
                                           options: .listenOnly, eventsOfInterest: mask,
                                           callback: callback, userInfo: refcon) else {
            // Sin permiso de Monitorización de entrada: reintentar hasta que se conceda.
            if retryTimer == nil {
                retryTimer = Timer.scheduledTimer(withTimeInterval: 2, repeats: true) { [weak self] _ in
                    MainActor.assumeIsolated { self?.start() }
                }
            }
            return
        }
        retryTimer?.invalidate(); retryTimer = nil
        tap = port
        source = CFMachPortCreateRunLoopSource(kCFAllocatorDefault, port, 0)
        CFRunLoopAddSource(CFRunLoopGetMain(), source, .commonModes)
        CGEvent.tapEnable(tap: port, enable: true)
    }

    private func now() -> TimeInterval { ProcessInfo.processInfo.systemUptime }

    private func handle(type: CGEventType, keyCode: Int64, flags: UInt64, isRepeat: Bool) {
        switch type {
        case .tapDisabledByTimeout, .tapDisabledByUserInput:
            if let tap { CGEvent.tapEnable(tap: tap, enable: true) }
        case .flagsChanged:
            guard keyCode == trigger.keyCode else {
                // Otra modificadora mientras se mantiene el atajo: no la tratamos como combo
                // (Mayús se usa para el modo edición).
                return
            }
            let down = (flags & trigger.deviceMask) != 0
            guard down != triggerDown else { return }
            triggerDown = down
            if down {
                shiftAtStart = (flags & CGEventFlags.maskShift.rawValue) != 0
                emit(machine.keyDown(at: now()))
                scheduleTick()
            } else {
                emit(machine.keyUp(at: now()))
                scheduleTick()
            }
        case .keyDown:
            if keyCode == 53 { // Esc
                if machine.isRecording { machine.reset(); onEscape?() }
                return
            }
            if triggerDown, !isRepeat {
                // ⌥ + tecla (p. ej. «@» = ⌥2 en teclado español): no es un dictado.
                emit(machine.otherKeyPressed())
            }
        default:
            break
        }
    }

    private func scheduleTick() {
        let delay = machine.doubleTapWindow + 0.02
        DispatchQueue.main.asyncAfter(deadline: .now() + delay) { [weak self] in
            MainActor.assumeIsolated {
                guard let self else { return }
                self.emit(self.machine.tick(at: self.now()))
            }
        }
    }

    private func emit(_ actions: [HotkeyAction]) {
        for a in actions { onAction?(Event(action: a, shiftHeld: shiftAtStart)) }
    }

    /// Para iniciar desde el menú o el botón «Re-dictar».
    func forceHandsFree() { machine.forceHandsFree() }
    func reset() { machine.reset() }

    /// Espera (como máximo `timeout`) a que se suelte el atajo antes de pegar,
    /// para que ⌥ no se mezcle con ⌘V.
    func waitForRelease(timeout: TimeInterval = 1.0) async {
        let start = Date()
        while triggerDown, Date().timeIntervalSince(start) < timeout {
            try? await Task.sleep(nanoseconds: 20_000_000)
        }
    }
}
