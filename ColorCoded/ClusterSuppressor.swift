import Foundation
import CoreGraphics

/// Suppresses tiny clustered detections (common around stems/tails/beam junk).
/// Provides overloads for both CGRect and ScoredHead, so call sites can stay unchanged.
enum ClusterSuppressor {

    // MARK: - Public (CGRect)

    static func suppress(_ rects: [CGRect], spacing: CGFloat) -> [CGRect] {
        guard rects.count > 1 else { return rects }
        let s = max(6.0, spacing)

        let tinyAreaMax = (s * s) * 0.18
        let clusterRadius = max(6.0, s * 0.85)
        let minNeighborsToKill = 3

        var tiny: [CGRect] = []
        var big: [CGRect] = []
        tiny.reserveCapacity(rects.count)
        big.reserveCapacity(rects.count)

        for r in rects {
            let a = r.width * r.height
            if a <= tinyAreaMax { tiny.append(r) } else { big.append(r) }
        }

        guard !tiny.isEmpty else { return rects }

        var kill = [Bool](repeating: false, count: tiny.count)

        for i in 0..<tiny.count {
            let ci = CGPoint(x: tiny[i].midX, y: tiny[i].midY)
            var neighbors = 0
            for j in 0..<tiny.count where j != i {
                let cj = CGPoint(x: tiny[j].midX, y: tiny[j].midY)
                let dx = ci.x - cj.x
                let dy = ci.y - cj.y
                if (dx*dx + dy*dy) <= clusterRadius * clusterRadius {
                    neighbors += 1
                    if neighbors >= minNeighborsToKill { break }
                }
            }
            if neighbors >= minNeighborsToKill { kill[i] = true }
        }

        var keptTiny: [CGRect] = []
        keptTiny.reserveCapacity(tiny.count)
        for i in 0..<tiny.count where !kill[i] { keptTiny.append(tiny[i]) }

        return big + keptTiny
    }

    // MARK: - Public (ScoredHead)

    /// Cluster-kill tiny detections, but keep ONE best element per dense neighborhood.
    static func suppress(_ heads: [ScoredHead], spacing: CGFloat) -> [ScoredHead] {
        guard heads.count > 1 else { return heads }
        let s = max(6.0, spacing)

        let tinyAreaMax = (s * s) * 0.18
        let clusterRadius = max(6.0, s * 0.85)
        let minNeighborsToKill = 3

        var tiny: [ScoredHead] = []
        var big: [ScoredHead] = []
        tiny.reserveCapacity(heads.count)
        big.reserveCapacity(heads.count)

        for h in heads {
            let r = h.rect
            let a = r.width * r.height
            if a <= tinyAreaMax { tiny.append(h) } else { big.append(h) }
        }

        guard !tiny.isEmpty else { return heads }

        // Identify dense tiny clusters. Keep best score in each local neighborhood.
        var kill = [Bool](repeating: false, count: tiny.count)

        for i in 0..<tiny.count {
            let ri = tiny[i].rect
            let ci = CGPoint(x: ri.midX, y: ri.midY)

            var neighborIdxs: [Int] = []
            neighborIdxs.reserveCapacity(8)

            for j in 0..<tiny.count where j != i {
                let rj = tiny[j].rect
                let cj = CGPoint(x: rj.midX, y: rj.midY)
                let dx = ci.x - cj.x
                let dy = ci.y - cj.y
                if (dx*dx + dy*dy) <= clusterRadius * clusterRadius {
                    neighborIdxs.append(j)
                }
            }

            if neighborIdxs.count >= minNeighborsToKill {
                // best among i + neighbors
                var bestIndex = i
                var bestScore = tiny[i].compositeScore
                for j in neighborIdxs {
                    let sc = tiny[j].compositeScore
                    if sc > bestScore {
                        bestScore = sc
                        bestIndex = j
                    }
                }
                if bestIndex != i { kill[i] = true }
            }
        }

        var keptTiny: [ScoredHead] = []
        keptTiny.reserveCapacity(tiny.count)
        for i in 0..<tiny.count where !kill[i] { keptTiny.append(tiny[i]) }

        // NOTE: stable output order: big first, then tiny
        return big + keptTiny
    }
}
