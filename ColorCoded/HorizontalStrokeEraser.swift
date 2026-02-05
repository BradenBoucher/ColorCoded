import CoreGraphics
import os

enum HorizontalStrokeEraser {
    private static let log = Logger(subsystem: "ColorCoded", category: "HorizontalStrokeEraser")

    struct Result {
        let binaryWithoutHorizontals: [UInt8]
        let horizMask: [UInt8]   // 1 where we erased
        let erasedCount: Int
    }

    /// Remove long thin horizontal runs (beams, ties, leftover staff/ledger fragments),
    /// while respecting protectMask (notehead neighborhoods).
    static func eraseHorizontalRuns(
        binary: [UInt8],
        width: Int,
        height: Int,
        roi: CGRect,
        spacing: CGFloat,
        protectMask: [UInt8],
        staffLinesY: [CGFloat]
    ) -> Result {
        log.notice("eraseHorizontalRuns enter roi=\(String(describing: roi), privacy: .public)")

        var out = binary
        var mask = [UInt8](repeating: 0, count: width * height)

        let u = max(7.0, spacing)

        // Tunables (safe defaults)
        let minRun = max(16, Int((1.8 * u).rounded()))           // "long"
        let minCurveRun = max(12, Int((1.2 * u).rounded()))      // allow mild curvature
        let maxThickness = max(1, Int((0.18 * u).rounded()))     // "thin band"
        let protectMaxFrac: Double = 0.08                        // don't erase if too protected
        let tieBand = max(1, Int((0.12 * u).rounded()))
        let staffExclusion = spacing * 0.18

        let clipped = roi.intersection(CGRect(x: 0, y: 0, width: width, height: height))
        guard clipped.width > 2, clipped.height > 2 else {
            return Result(binaryWithoutHorizontals: out, horizMask: mask, erasedCount: 0)
        }

        let x0 = max(0, Int(floor(clipped.minX)))
        let y0 = max(0, Int(floor(clipped.minY)))
        let x1 = min(width, Int(ceil(clipped.maxX)))
        let y1 = min(height, Int(ceil(clipped.maxY)))

        var erased = 0

        @inline(__always)
        func distanceToNearestStaffLine(y: Int) -> CGFloat {
            guard !staffLinesY.isEmpty else { return .greatestFiniteMagnitude }
            let yFloat = CGFloat(y)
            var best = CGFloat.greatestFiniteMagnitude
            for ly in staffLinesY {
                best = min(best, abs(ly - yFloat))
            }
            return best
        }

        @inline(__always)
        func columnThicknessAt(x: Int, y: Int) -> Int {
            var t = 0
            for dy in -maxThickness...maxThickness {
                let yy = y + dy
                if yy < 0 || yy >= height { continue }
                if out[yy * width + x] != 0 { t += 1 }
            }
            return t
        }

        for y in y0..<y1 {
            if distanceToNearestStaffLine(y: y) < staffExclusion {
                continue
            }
            var x = x0
            while x < x1 {
                // find run start
                while x < x1 && out[y * width + x] == 0 { x += 1 }
                if x >= x1 { break }
                let runStart = x

                // find run end
                while x < x1 && out[y * width + x] != 0 { x += 1 }
                let runEnd = x
                let runLen = runEnd - runStart

                if runLen < minRun { continue }

                // measure protect overlap and thickness
                var protectHits = 0
                var inkSamples = 0
                var maxT = 0

                var sx = runStart
                while sx < runEnd {
                    inkSamples += 1
                    if protectMask[y * width + sx] != 0 { protectHits += 1 }
                    maxT = max(maxT, columnThicknessAt(x: sx, y: y))
                    sx += 2
                }

                let protectFrac = Double(protectHits) / Double(max(1, inkSamples))

                let isThin = maxT <= (2 * maxThickness + 1)

                var isCurvedBand = false
                if runLen >= minCurveRun && isThin {
                    var bandHits = 0
                    var bandSamples = 0
                    var sx = runStart
                    while sx < runEnd {
                        bandSamples += 1
                        var found = false
                        for dy in -tieBand...tieBand {
                            let yy = y + dy
                            if yy < 0 || yy >= height { continue }
                            if out[yy * width + sx] != 0 {
                                found = true
                                break
                            }
                        }
                        if found { bandHits += 1 }
                        sx += 2
                    }
                    let bandFrac = Double(bandHits) / Double(max(1, bandSamples))
                    isCurvedBand = bandFrac >= 0.65
                }

                let qualifies = runLen >= minRun || isCurvedBand

                // Erase if thin and not protected (extra guard near staff lines)
                if qualifies && isThin && protectFrac <= protectMaxFrac {
                    let band = max(1, maxThickness)
                    for yy in max(0, y - band)...min(height - 1, y + band) {
                        let row = yy * width
                        for xx in runStart..<runEnd {
                            if protectMask[row + xx] != 0 { continue }
                            if out[row + xx] != 0 {
                                out[row + xx] = 0
                                mask[row + xx] = 1
                                erased += 1
                            }
                        }
                    }
                }
            }
        }

        let roiArea = max(1.0, Double((x1 - x0) * (y1 - y0)))
        let erasedFrac = Double(erased) / roiArea
        if erasedFrac > 0.06 {
            log.warning("eraseHorizontalRuns clamp triggered roi=\(String(describing: roi), privacy: .public) erasedFrac=\(erasedFrac, privacy: .public)")
            return Result(binaryWithoutHorizontals: binary, horizMask: [UInt8](repeating: 0, count: width * height), erasedCount: 0)
        }

        log.notice("eraseHorizontalRuns done erasedPixels=\(erased, privacy: .public)")
        return Result(binaryWithoutHorizontals: out, horizMask: mask, erasedCount: erased)
    }
}
