import CoreGraphics
import Foundation

enum ClusterSuppressor {

    static func suppress(_ candidates: [ScoredHead], spacing: CGFloat) -> [ScoredHead] {
        guard !candidates.isEmpty else { return [] }

        let sorted = candidates.sorted { $0.score > $1.score }
        var kept: [ScoredHead] = []
        kept.reserveCapacity(sorted.count)

        let dxThresh = spacing * 0.35
        let dyThresh = spacing * 0.35
        let chordDyThresh = spacing * 0.30

        // ✅ hard duplicate window (very tight)
        let hardDx = spacing * 0.22
        let hardDy = spacing * 0.22

        for cand in sorted {
            let c = CGPoint(x: cand.rect.midX, y: cand.rect.midY)
            var keep = true

            for k in kept {
                let kc = CGPoint(x: k.rect.midX, y: k.rect.midY)
                let dx = abs(c.x - kc.x)
                let dy = abs(c.y - kc.y)

                // Hard duplicates: always suppress
                if dx < hardDx && dy < hardDy {
                    keep = false
                    break
                }

                // Soft duplicates: suppress if near and same step (or nearly same y)
                guard dx < dxThresh && dy < dyThresh else { continue }
                let sameStep = (cand.staffStepIndex == k.staffStepIndex)
                let shouldSuppress = (dy < chordDyThresh) || sameStep
                if shouldSuppress {
                    keep = false
                    break
                }
            }

            if keep { kept.append(cand) }
        }

        return kept
    }
}
