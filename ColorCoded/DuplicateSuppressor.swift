import Foundation
import CoreGraphics

enum DuplicateSuppressor {
    static func suppress(_ rects: [CGRect], spacing: CGFloat) -> [CGRect] {
        guard rects.count > 1 else { return rects }
        let radius = max(2.0, spacing * 0.35)
        let sorted = rects.sorted { ($0.width * $0.height) > ($1.width * $1.height) }
        var kept: [CGRect] = []

        for rect in sorted {
            let center = CGPoint(x: rect.midX, y: rect.midY)
            var shouldKeep = true
            for existing in kept {
                let otherCenter = CGPoint(x: existing.midX, y: existing.midY)
                let dx = center.x - otherCenter.x
                let dy = center.y - otherCenter.y
                if sqrt(dx * dx + dy * dy) < radius {
                    shouldKeep = false
                    break
                }
            }
            if shouldKeep {
                kept.append(rect)
            }
        }

        return kept
    }
}
