import Foundation

/// Acciones que produce la máquina de estados del atajo.
public enum HotkeyAction: Equatable, Sendable {
    /// Empieza a grabar en cuanto se pulsa (para no perder la primera sílaba).
    case startRecording
    /// Segundo toque rápido: la grabación queda bloqueada (manos libres).
    case lockHandsFree
    /// Termina la grabación y procesa el texto.
    case stopAndProcess
    /// Descarta la grabación (toque suelto accidental, combinación con otra tecla…).
    case cancel
}

/// Máquina de estados del atajo, inspirada en `holdThresholdMs` / `doubleTapWindowMs`
/// de Wispr Flow y `ShortcutDetector.allowedCounts` de Typeless.
///
/// - Mantener pulsado ≥ `holdThreshold` y soltar → pulsar-para-hablar.
/// - Dos toques dentro de `doubleTapWindow` → manos libres; otro toque lo para.
/// - Un toque corto suelto → se descarta.
public struct HotkeyStateMachine: Sendable {
    public enum State: Equatable, Sendable {
        case idle
        /// Tecla pulsada por primera vez; aún no sabemos si es mantener o toque.
        case firstDown(at: TimeInterval)
        /// Primer toque corto soltado; esperando un segundo toque.
        case waitingSecondTap(deadline: TimeInterval)
        /// Segundo toque pulsado (aún sin soltar) → manos libres.
        case handsFreeArming
        /// Grabando en manos libres.
        case handsFree
        /// Se pulsó para parar; esperando a que se suelte la tecla.
        case stoppingWaitRelease
    }

    public var holdThreshold: TimeInterval
    public var doubleTapWindow: TimeInterval
    public private(set) var state: State = .idle

    public init(holdThreshold: TimeInterval = 0.30, doubleTapWindow: TimeInterval = 0.40) {
        self.holdThreshold = holdThreshold
        self.doubleTapWindow = doubleTapWindow
    }

    public var isRecording: Bool {
        switch state {
        case .idle, .stoppingWaitRelease: return false
        default: return true
        }
    }

    public mutating func keyDown(at t: TimeInterval) -> [HotkeyAction] {
        switch state {
        case .idle:
            state = .firstDown(at: t)
            return [.startRecording]
        case .waitingSecondTap(let deadline):
            if t <= deadline {
                state = .handsFreeArming
                return [.lockHandsFree]
            }
            // Llegó tarde: la grabación anterior ya debía descartarse; empezamos otra.
            state = .firstDown(at: t)
            return [.cancel, .startRecording]
        case .handsFree:
            state = .stoppingWaitRelease
            return [.stopAndProcess]
        case .firstDown, .handsFreeArming, .stoppingWaitRelease:
            return [] // autorepetición de la tecla
        }
    }

    public mutating func keyUp(at t: TimeInterval) -> [HotkeyAction] {
        switch state {
        case .firstDown(let downAt):
            if t - downAt >= holdThreshold {
                state = .idle
                return [.stopAndProcess]
            }
            state = .waitingSecondTap(deadline: t + doubleTapWindow)
            return []
        case .handsFreeArming:
            state = .handsFree
            return []
        case .stoppingWaitRelease:
            state = .idle
            return []
        case .idle, .waitingSecondTap, .handsFree:
            return []
        }
    }

    /// Llamar periódicamente (o tras `doubleTapWindow`) para caducar el primer toque.
    public mutating func tick(at t: TimeInterval) -> [HotkeyAction] {
        if case .waitingSecondTap(let deadline) = state, t > deadline {
            state = .idle
            return [.cancel]
        }
        return []
    }

    /// Se pulsó otra tecla mientras el atajo estaba abajo (p. ej. ⌥2 para escribir «@»):
    /// no era un dictado, se descarta.
    public mutating func otherKeyPressed() -> [HotkeyAction] {
        switch state {
        case .firstDown, .waitingSecondTap:
            state = .idle
            return [.cancel]
        default:
            return []
        }
    }

    /// Fuerza el inicio en manos libres (menú / botón «Re-dictar»).
    public mutating func forceHandsFree() { state = .handsFree }

    public mutating func reset() { state = .idle }
}
