import CoreGraphics
import Foundation

enum ClusterSuppressor {
    static func suppress(_ candidates: [ScoredHead], spacing: CGFloat) -> [ScoredHead] {
        guard !candidates.isEmpty else { return [] }

        // Sort by best candidates first.
        // Use gateScore (more meaningful than `score` if you changed scoring logic)
        let sorted = candidates.sorted(by: { (a: ScoredHead, b: ScoredHead) -> Bool in
            a.gateScore > b.gateScore
        })

        var kept: [ScoredHead] = []
        kept.reserveCapacity(sorted.count)

        let dxThresh = spacing * 0.35
        let dyThresh = spacing * 0.35
        let chordDyThresh = spacing * 0.30

        for cand in sorted {
            let center = CGPoint(x: cand.rect.midX, y: cand.rect.midY)
            var shouldKeep = true

            for k in kept {
                let kc = CGPoint(x: k.rect.midX, y: k.rect.midY)
                let dx = abs(center.x - kc.x)
                let dy = abs(center.y - kc.y)

                guard dx < dxThresh && dy < dyThresh else { continue }

                // Suppress if same step OR almost same y (but keep chord stacks)
                let sameStep = (cand.staffStepIndex != nil && cand.staffStepIndex == k.staffStepIndex)
                let shouldSuppress = dy < chordDyThresh || sameStep

                if shouldSuppress {
                    shouldKeep = false
                    break
                }
            }

            if shouldKeep { kept.append(cand) }
        }

        return kept
    }
}
