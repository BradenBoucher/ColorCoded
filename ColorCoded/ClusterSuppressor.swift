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

        for candidate in sorted {
            let center = CGPoint(x: candidate.rect.midX, y: candidate.rect.midY)
            var shouldKeep = true

            for keptCandidate in kept {
                let keptCenter = CGPoint(x: keptCandidate.rect.midX, y: keptCandidate.rect.midY)
                let dx = abs(center.x - keptCenter.x)
                let dy = abs(center.y - keptCenter.y)

                guard dx < dxThresh && dy < dyThresh else { continue }

                let sameStep = candidate.staffStepIndex == keptCandidate.staffStepIndex
                let shouldSuppress = dy < chordDyThresh || sameStep
                if shouldSuppress {
                    shouldKeep = false
                    break
                }
            }

            if shouldKeep {
                kept.append(candidate)
            }
        }

        return kept
    }
}
