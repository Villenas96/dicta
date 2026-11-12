import AppKit
import DictaCore
import SwiftUI

@MainActor
final class OverlayModel: ObservableObject {
    enum Phase: Equatable {
        case hidden
        case listening(handsFree: Bool, edit: Bool)
        case processing
        case done(String)
        case message(String, icon: String)
    }
    @Published var phase: Phase = .hidden
    @Published var levels: [Float] = Array(repeating: 0, count: 18)
    @Published var partial = ""
    @Published var triggerSymbol = "⌥"
    @Published var showPreview = true
    @Published var engineName = ""
    @Published var anchorTop = false
    @Published var lastError: String?

    var onRedictate: (() -> Void)?
    var onUndo: (() -> Void)?
    var onCopy: (() -> Void)?
    var onStop: (() -> Void)?
    var onCancel: (() -> Void)?

    func push(level: Float) {
        levels.removeFirst()
        levels.append(level)
    }
}

/// Panel flotante que no roba el foco (para no sacar al usuario de su casilla).
final class OverlayPanel: NSPanel {
    override var canBecomeKey: Bool { false }
    override var canBecomeMain: Bool { false }
}

@MainActor
final class OverlayController {
    let model = OverlayModel()
    private var panel: OverlayPanel!
    private var hideWork: DispatchWorkItem?

    init() {
        panel = OverlayPanel(contentRect: NSRect(x: 0, y: 0, width: 460, height: 120),
                             styleMask: [.nonactivatingPanel, .borderless], backing: .buffered, defer: true)
        panel.isOpaque = false
        panel.backgroundColor = .clear
        panel.hasShadow = false
        panel.level = .statusBar
        panel.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary, .stationary, .ignoresCycle]
        panel.hidesOnDeactivate = false
        let host = NSHostingView(rootView: OverlayView(model: model))
        host.frame = panel.contentRect(forFrameRect: panel.frame)
        panel.contentView = host
    }

    /// Zona que no se debe tapar (cursor o casilla activa).
    private var avoid: CGRect?

    func setAvoid(_ rect: CGRect?) {
        avoid = rect
        if panel.isVisible { position() }
    }

    private func position() {
        // Pantalla de la casilla (o del ratón si no se sabe).
        let ref = avoid.map { CGPoint(x: $0.midX, y: $0.midY) } ?? NSEvent.mouseLocation
        let screen = NSScreen.screens.first { $0.frame.contains(ref) } ?? NSScreen.main
        guard let vf = screen?.visibleFrame else { return }
        let r = OverlayPlacement.choose(screen: vf, panel: panel.frame.size, avoid: avoid)
        model.anchorTop = r.anchorTop
        panel.setFrameOrigin(r.origin)
    }

    func show(_ phase: OverlayModel.Phase, autoHide: TimeInterval? = nil) {
        hideWork?.cancel()
        model.phase = phase
        if case .listening = phase { model.partial = "" }
        // Solo acepta clics cuando hay botones.
        switch phase {
        case .done, .listening(handsFree: true, _): panel.ignoresMouseEvents = false
        default: panel.ignoresMouseEvents = true
        }
        if !panel.isVisible { position(); panel.orderFrontRegardless() }
        if let autoHide {
            let work = DispatchWorkItem { [weak self] in self?.hide() }
            hideWork = work
            DispatchQueue.main.asyncAfter(deadline: .now() + autoHide, execute: work)
        }
    }

    func hide() {
        hideWork?.cancel()
        model.phase = .hidden
        panel.orderOut(nil)
    }
}

// MARK: - Vista

struct OverlayView: View {
    @ObservedObject var model: OverlayModel

    var body: some View {
        VStack(spacing: 6) {
            if model.anchorTop {
                pill
                preview
                Spacer(minLength: 0)
            } else {
                Spacer(minLength: 0)
                preview
                pill
            }
        }
        .frame(width: 460, height: 120, alignment: model.anchorTop ? .top : .bottom)
        .animation(.easeOut(duration: 0.15), value: model.phase)
    }

    /// Transcripción en directo (solo mientras escucha).
    @ViewBuilder private var preview: some View {
        if model.showPreview, case .listening = model.phase, !model.partial.isEmpty {
            Text(model.partial.suffix(140))
                .font(.system(size: 12))
                .foregroundStyle(.white.opacity(0.9))
                .lineLimit(2)
                .padding(.horizontal, 12).padding(.vertical, 6)
                .background(.black.opacity(0.72), in: RoundedRectangle(cornerRadius: 10))
                .frame(maxWidth: 440)
                .transition(.opacity)
        }
    }

    @ViewBuilder private var pill: some View {
        HStack(spacing: 10) {
            switch model.phase {
            case .hidden:
                EmptyView()
            case .listening(let handsFree, let edit):
                Image(systemName: handsFree ? "lock.fill" : "mic.fill")
                    .foregroundStyle(edit ? Color.orange : Color.red)
                    .symbolEffect(.pulse, options: .repeating)
                Waveform(levels: model.levels, color: edit ? .orange : .white)
                if edit { Text("Editar").font(.system(size: 11, weight: .semibold)).foregroundStyle(.orange) }
                if handsFree {
                    Button { model.onStop?() } label: {
                        Image(systemName: "stop.circle.fill").foregroundStyle(.white)
                    }.buttonStyle(.plain).help("Parar (o pulsa \(model.triggerSymbol))")
                    Button { model.onCancel?() } label: {
                        Image(systemName: "xmark.circle.fill").foregroundStyle(.white.opacity(0.6))
                    }.buttonStyle(.plain).help("Cancelar (Esc)")
                }
            case .processing:
                ProgressView().controlSize(.small).tint(.white)
                Text(model.engineName.isEmpty ? "Corrigiendo…" : "Corrigiendo con \(model.engineName)…")
                    .font(.system(size: 12, weight: .medium)).foregroundStyle(.white).lineLimit(1)
            case .done:
                // Sin el texto en medio: solo confirmación y botones.
                Image(systemName: "checkmark.circle.fill").foregroundStyle(.green)
                pillButton("arrow.counterclockwise", "Re-dictar") { model.onRedictate?() }
                pillButton("arrow.uturn.backward", "Deshacer") { model.onUndo?() }
                pillButton("doc.on.doc", "Copiar") { model.onCopy?() }
            case .message(let text, let icon):
                Image(systemName: icon).foregroundStyle(.yellow)
                Text(text).font(.system(size: 12, weight: .medium)).foregroundStyle(.white).lineLimit(2)
            }
        }
        .padding(.horizontal, 14).padding(.vertical, 9)
        .background(Capsule().fill(.black.opacity(0.85)))
        .overlay(Capsule().strokeBorder(.white.opacity(0.12)))
        .opacity(model.phase == .hidden ? 0 : 1)
    }

    private func pillButton(_ icon: String, _ help: String, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            Label(help, systemImage: icon).labelStyle(.iconOnly).foregroundStyle(.white)
                .frame(width: 22, height: 22)
                .background(Circle().fill(.white.opacity(0.14)))
        }.buttonStyle(.plain).help(help)
    }
}

struct Waveform: View {
    let levels: [Float]
    var color: Color = .white
    var body: some View {
        HStack(alignment: .center, spacing: 2.5) {
            ForEach(levels.indices, id: \.self) { i in
                Capsule().fill(color.opacity(0.9))
                    .frame(width: 3, height: 4 + CGFloat(levels[i]) * 20)
            }
        }
        .frame(height: 24)
        .animation(.linear(duration: 0.08), value: levels)
    }
}
