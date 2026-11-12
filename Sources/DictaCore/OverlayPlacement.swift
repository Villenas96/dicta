import CoreGraphics

/// Dónde colocar la píldora flotante para no tapar la casilla en la que escribes.
/// Coordenadas de AppKit (origen abajo-izquierda).
public enum OverlayPlacement {
    public struct Result: Equatable, Sendable {
        public let origin: CGPoint
        /// true si la píldora va arriba (el contenido se alinea arriba del panel).
        public let anchorTop: Bool
    }

    public static func choose(screen vf: CGRect, panel size: CGSize, avoid: CGRect?) -> Result {
        let m: CGFloat = 24
        let candidates: [Result] = [
            Result(origin: CGPoint(x: vf.midX - size.width / 2, y: vf.minY + m), anchorTop: false),   // abajo centro
            Result(origin: CGPoint(x: vf.maxX - size.width - m, y: vf.minY + m), anchorTop: false),   // abajo derecha
            Result(origin: CGPoint(x: vf.minX + m, y: vf.minY + m), anchorTop: false),                // abajo izquierda
            Result(origin: CGPoint(x: vf.midX - size.width / 2, y: vf.maxY - size.height - 12), anchorTop: true), // arriba centro
            Result(origin: CGPoint(x: vf.maxX - size.width - m, y: vf.maxY - size.height - 12), anchorTop: true), // arriba derecha
        ]
        guard let avoid, !avoid.isNull, !avoid.isEmpty else { return candidates[0] }
        func overlap(_ r: Result) -> CGFloat {
            let i = CGRect(origin: r.origin, size: size).intersection(avoid)
            return i.isNull ? 0 : i.width * i.height
        }
        return candidates.first { overlap($0) == 0 } ?? candidates.min { overlap($0) < overlap($1) }!
    }
}
