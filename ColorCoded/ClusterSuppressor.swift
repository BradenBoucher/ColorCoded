import CoreGraphics
import Foundation

enum ClusterSuppressor {

    static func suppress(_ candidates: [ScoredHead], spacing: CGFloat) -> [ScoredHead] {
        guard !candidates.isEmpty else { return [] }

        // Prefer best overall (staff-fit + shape), not just gate.
        let sorted = candidates.sorted { a, b in
            if a.compositeScore != b.compositeScore { return a.compositeScore > b.compositeScore }
            // deterministic tie-breakers reduce "identical rows treated differently"
            if a.rect.midX != b.rect.midX { return a.rect.midX < b.rect.midX }
            return a.rect.midY < b.rect.midY
        }

        var kept: [ScoredHead] = []
        kept.reserveCapacity(sorted.count)

        // Close-in-X = same "time slice"
        let dxThresh = spacing * 0.42

        // Very tight Y = truly duplicate, not a chord
        let dupDyThresh = spacing * 0.12

        // If step indices exist, allow chords: stacked notes differ by >= 2 steps typically
        let minChordStepDiff = 2

        for cand in sorted {
            let cx = cand.rect.midX
            let cy = cand.rect.midY

            var keep = true
            for k in kept {
                let kx = k.rect.midX
                let ky = k.rect.midY

                let dx = abs(cx - kx)
                if dx > dxThresh { continue }

                let dy = abs(cy - ky)

                // If both have step indices, only suppress when they represent the SAME step
                if let s1 = cand.staffStepIndex, let s2 = k.staffStepIndex {
                    if s1 == s2 {
                        keep = false
                        break
                    }
                    // If they're different steps enough, it's probably a chord stack -> keep
                    if abs(s1 - s2) >= minChordStepDiff {
                        continue
                    }
                    // Small step diff (0 or 1) can still be a duplicate or a tight cluster.
                    // Use very-tight dy to suppress only true duplicates.
                    if dy < dupDyThresh {
                        keep = false
                        break
                    }
                } else {
                    // No step info: suppress only if extremely close in Y (duplicate), not just "near"
                    if dy < dupDyThresh {
                        keep = false
                        break
                    }
                }
            }

            if keep { kept.append(cand) }
        }

        return kept
    }
}
