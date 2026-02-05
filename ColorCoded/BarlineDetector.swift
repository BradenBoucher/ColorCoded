import Foundation
import CoreGraphics

enum BarlineDetector {

    struct ScoredBarline {
        let rect: CGRect
        let score: Double
    }

    // Main API (keeps your old signature)
    static func detectBarlines(in cg: CGImage, systems: [SystemBlock]) -> [CGRect] {
        return detectBarlinesScored(in: cg, systems: systems)
            .filter { $0.score >= 0.80 }
            .map { $0.rect }
    }

    // Scored API (useful for debugging)
    static func detectBarlinesScored(in cg: CGImage, systems: [SystemBlock]) -> [ScoredBarline] {
        guard !systems.isEmpty else { return [] }

        let w = cg.width
        let h = cg.height
        guard w > 0, h > 0 else { return [] }

        // Build a fast luminance buffer
        var pixels = [UInt8](repeating: 0, count: w * h * 4)
        guard let ctx = CGContext(
            data: &pixels,
            width: w,
            height: h,
            bitsPerComponent: 8,
            bytesPerRow: w * 4,
            space: CGColorSpaceCreateDeviceRGB(),
            bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue
        ) else { return [] }

        ctx.draw(cg, in: CGRect(x: 0, y: 0, width: w, height: h))

        // Binary threshold
        let lumThreshold = 150

        func isInk(_ x: Int, _ y: Int) -> Bool {
            let idx = (y * w + x) * 4
            let lum = (Int(pixels[idx]) + Int(pixels[idx + 1]) + Int(pixels[idx + 2])) / 3
            return lum < lumThreshold
        }

        var out: [ScoredBarline] = []
        out.reserveCapacity(systems.count * 8)

        for system in systems {

            // Clamp bbox
            let sx0 = max(0, Int(floor(system.bbox.minX)))
            let sx1 = min(w - 1, Int(ceil(system.bbox.maxX)))
            let sy0 = max(0, Int(floor(system.bbox.minY)))
            let sy1 = min(h - 1, Int(ceil(system.bbox.maxY)))
            if sx1 <= sx0 || sy1 <= sy0 { continue }

            let sysH = max(1, sy1 - sy0 + 1)

            // Ignore left symbol zone (clef / key / time)
            // roughly: 30–40% of system width or ~8*spacing
            let spacing = max(6.0, system.spacing)
            let symbolW = min(CGFloat(sx1 - sx0) * 0.40, spacing * 8.0)
            let x0 = min(sx1, sx0 + Int(symbolW.rounded(.up)))
            let x1 = sx1
            if x1 <= x0 { continue }

            // If we have treble+bass lines, require spanning grand staff band
            let trebleTop = system.trebleLines.min() ?? CGFloat(sy0)
            let bassBottom = system.bassLines.max() ?? CGFloat(sy1)
            let targetMinY = max(CGFloat(sy0), trebleTop - spacing * 0.8)
            let targetMaxY = min(CGFloat(sy1), bassBottom + spacing * 0.8)

            let ty0 = max(sy0, Int(floor(targetMinY)))
            let ty1 = min(sy1, Int(ceil(targetMaxY)))
            let targetH = max(1, ty1 - ty0 + 1)

            // For each column, compute:
            // - inkCount in target band
            // - longest continuous vertical run in target band
            var colInk = [Int](repeating: 0, count: x1 - x0 + 1)
            var colMaxRun = [Int](repeating: 0, count: x1 - x0 + 1)

            for x in x0...x1 {
                var ink = 0
                var run = 0
                var bestRun = 0

                // stride 1 is important; barlines are thin
                for y in ty0...ty1 {
                    if isInk(x, y) {
                        ink += 1
                        run += 1
                        if run > bestRun { bestRun = run }
                    } else {
                        run = 0
                    }
                }

                colInk[x - x0] = ink
                colMaxRun[x - x0] = bestRun
            }

            // Smooth a bit (helps with anti-aliased PDFs)
            colInk = smooth(colInk, radius: 1)
            colMaxRun = smooth(colMaxRun, radius: 1)

            // Decide which columns look like barline columns.
            // Key discriminator: runFrac must be high.
            let minRunFrac: Double = 0.72  // stems usually fail this for grand staff
            let minInkFrac: Double = 0.20  // but allow thin lines

            var good = [Bool](repeating: false, count: colInk.count)
            for i in 0..<colInk.count {
                let runFrac = Double(colMaxRun[i]) / Double(targetH)
                let inkFrac = Double(colInk[i]) / Double(targetH)
                if runFrac >= minRunFrac && inkFrac >= minInkFrac {
                    good[i] = true
                }
            }

            // Group contiguous "good" columns into runs
            let runs = findRunsBool(good, minWidth: 1)

            for r in runs {
                let left = r.lowerBound
                let right = r.upperBound - 1

                let runWidth = right - left + 1

                // Compute average runFrac over the run
                var runFracSum = 0.0
                var inkFracSum = 0.0
                for i in left...right {
                    runFracSum += Double(colMaxRun[i]) / Double(targetH)
                    inkFracSum += Double(colInk[i]) / Double(targetH)
                }
                let n = Double(runWidth)
                let avgRunFrac = runFracSum / n
                let avgInkFrac = inkFracSum / n

                // Width sanity: barlines should be thin in image coords
                let maxPxWidth = max(2.0, spacing * 0.18)  // allow thick double barlines to be a run
                let isThinEnough = Double(runWidth) <= Double(maxPxWidth * 3.0)

                // Score: mostly runFrac, slightly inkFrac, slightly thinness
                var score = 0.0
                score += 0.75 * avgRunFrac
                score += 0.20 * min(1.0, avgInkFrac / 0.40)
                score += 0.05 * (isThinEnough ? 1.0 : 0.0)

                // Convert run to rect in full system bbox height (so overlay is visible)
                let rx0 = CGFloat(x0 + left)
                let rx1 = CGFloat(x0 + right + 1)

                // Pad slightly
                let padX = max(1.0, spacing * 0.06)
                let padY = max(1.0, spacing * 0.10)

                let rect = CGRect(
                    x: rx0 - padX,
                    y: CGFloat(sy0) - padY,
                    width: (rx1 - rx0) + 2 * padX,
                    height: CGFloat(sy1 - sy0 + 1) + 2 * padY
                )

                out.append(ScoredBarline(rect: rect, score: score))
            }
        }

        // Optional: merge barlines that are extremely close in X (double-detection)
        out = mergeNearby(out, maxGapPx: 2.0)

        return out
    }

    // MARK: - Helpers

    private static func findRunsBool(_ arr: [Bool], minWidth: Int) -> [Range<Int>] {
        var ranges: [Range<Int>] = []
        var i = 0
        while i < arr.count {
            if arr[i] {
                let start = i
                var end = i
                while end < arr.count && arr[end] { end += 1 }
                if end - start >= minWidth { ranges.append(start..<end) }
                i = end
            } else {
                i += 1
            }
        }
        return ranges
    }

    private static func smooth(_ arr: [Int], radius: Int) -> [Int] {
        guard radius > 0, arr.count > 2 else { return arr }
        var out = arr
        for i in 0..<arr.count {
            var s = 0
            var c = 0
            let a = max(0, i - radius)
            let b = min(arr.count - 1, i + radius)
            for j in a...b { s += arr[j]; c += 1 }
            out[i] = s / max(1, c)
        }
        return out
    }

    private static func mergeNearby(_ items: [ScoredBarline], maxGapPx: CGFloat) -> [ScoredBarline] {
        guard items.count >= 2 else { return items }
        let sorted = items.sorted { $0.rect.minX < $1.rect.minX }

        var out: [ScoredBarline] = []
        out.reserveCapacity(sorted.count)

        var cur = sorted[0]
        for i in 1..<sorted.count {
            let nxt = sorted[i]
            if nxt.rect.minX - cur.rect.maxX <= maxGapPx {
                // merge
                let mergedRect = cur.rect.union(nxt.rect)
                let mergedScore = max(cur.score, nxt.score)
                cur = ScoredBarline(rect: mergedRect, score: mergedScore)
            } else {
                out.append(cur)
                cur = nxt
            }
        }
        out.append(cur)
        return out
    }
}
