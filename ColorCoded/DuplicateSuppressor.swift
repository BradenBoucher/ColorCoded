import Foundation
import CoreGraphics

enum DuplicateSuppressor {

    /// Simple rect-only suppression (no staff-step info).
    /// Keeps tighter boxes by sorting by area ASC (more notehead-like).
    static func suppress(_ rects: [CGRect], spacing: CGFloat) -> [CGRect] {
        guard rects.count > 1 else { return rects }

        let r = max(2.0, spacing * 0.35)

        // ✅ keep smaller/tighter boxes first (often better notehead localization)
        let sorted = rects.sorted { ($0.width * $0.height) < ($1.width * $1.height) }
        var kept: [CGRect] = []
        kept.reserveCapacity(sorted.count)

        for rect in sorted {
            let c = CGPoint(x: rect.midX, y: rect.midY)
            var ok = true
            for k in kept {
                let kc = CGPoint(x: k.midX, y: k.midY)
                let dx = c.x - kc.x
                let dy = c.y - kc.y
                if sqrt(dx*dx + dy*dy) < r {
                    ok = false
                    break
                }
            }
            if ok { kept.append(rect) }
        }
        return kept
    }
}
