import CoreGraphics
import Foundation

struct VerticalStrokeMask {
    let data: [UInt8]        // 0/1 mask in *mask grid* coordinates (may be downsampled)
    let width: Int
    let height: Int
    let origin: CGPoint      // origin in FULL-RES image coords
    let scale: Int           // 1 = full-res, 4 = mask grid is 1/4 resolution

    // Integral image (summed area table) for O(1) overlap queries.
    // Dimensions: (width+1) * (height+1)
    private let sat: [Int32]

    /// O(1) overlap ratio using the integral image.
    /// rect is in FULL-RES image coordinates.
    func overlapRatio(with rect: CGRect) -> CGFloat {
        guard width > 0, height > 0 else { return 0 }
        let s = CGFloat(scale)

        // Convert rect into mask-grid coordinates (downsampled if scale>1)
        let localRect = CGRect(
            x: (rect.minX - origin.x) / s,
            y: (rect.minY - origin.y) / s,
            width: rect.width / s,
            height: rect.height / s
        )

        let clipped = localRect.intersection(CGRect(x: 0, y: 0, width: width, height: height))
        guard clipped.width > 0, clipped.height > 0 else { return 0 }

        let x0 = max(0, Int(floor(clipped.minX)))
        let y0 = max(0, Int(floor(clipped.minY)))
        let x1 = min(width, Int(ceil(clipped.maxX)))
        let y1 = min(height, Int(ceil(clipped.maxY)))
        if x1 <= x0 || y1 <= y0 { return 0 }

        let sum = satSum(x0: x0, y0: y0, x1: x1, y1: y1)
        let area = max(1, (x1 - x0) * (y1 - y0))
        return CGFloat(sum) / CGFloat(area)
    }

    @inline(__always)
    private func satIndex(_ x: Int, _ y: Int) -> Int { y * (width + 1) + x }

    @inline(__always)
    private func satSum(x0: Int, y0: Int, x1: Int, y1: Int) -> Int32 {
        let A = sat[satIndex(x0, y0)]
        let B = sat[satIndex(x1, y0)]
        let C = sat[satIndex(x0, y1)]
        let D = sat[satIndex(x1, y1)]
        return D - B - C + A
    }

    /// Build a vertical-run mask inside ROI from a full-page binary ink map (1=ink, 0=white).
    /// This implementation AUTO-DOWNSAMPLES for large ROIs to avoid multi-second full-page scans.
    static func build(from binary: [UInt8],
                      width: Int,
                      height: Int,
                      roi: CGRect,
                      minRun: Int) -> VerticalStrokeMask? {
        guard width > 0, height > 0, minRun > 1 else { return nil }
        guard binary.count == width * height else { return nil }

        let clipped = roi.intersection(CGRect(x: 0, y: 0, width: width, height: height))
        guard clipped.width > 1, clipped.height > 1 else { return nil }

        let roiX = max(0, Int(floor(clipped.minX)))
        let roiY = max(0, Int(floor(clipped.minY)))
        let roiW = min(width - roiX, Int(ceil(clipped.width)))
        let roiH = min(height - roiY, Int(ceil(clipped.height)))
        guard roiW > 1, roiH > 1 else { return nil }

        // ---- AUTO SCALE CHOICE ----
        // Full-page at ~2976x~4000 is too expensive at scale=1.
        // Pick scale based on ROI area (tune thresholds as you like).
        let area = roiW * roiH
        let scale: Int
        if area >= 2_000_000 {        // big: full page or near it
            scale = 4
        } else if area >= 900_000 {   // medium
            scale = 3
        } else {
            scale = 1
        }

        // Adjust thresholds for downsampled grid
        let minRunLow = max(2, Int(round(Double(minRun) / Double(scale))))
        let gapMaxLow: Int = (scale == 1) ? 2 : 1  // smaller grid => fewer “fake gaps”

        let wL = max(1, roiW / scale)
        let hL = max(1, roiH / scale)
        guard wL > 1, hL > 1 else { return nil }

        var mask = [UInt8](repeating: 0, count: wL * hL)

        // Helper: does this low-res cell contain any ink in its full-res block?
        @inline(__always)
        func cellHasInk(xL: Int, yL: Int) -> Bool {
            let x0 = roiX + xL * scale
            let y0 = roiY + yL * scale
            let x1 = min(roiX + roiW, x0 + scale)
            let y1 = min(roiY + roiH, y0 + scale)

            var yy = y0
            while yy < y1 {
                let rowBase = yy * width
                var xx = x0
                while xx < x1 {
                    if binary[rowBase + xx] != 0 { return true }
                    xx += 1
                }
                yy += 1
            }
            return false
        }

        // Vertical run-length scan in LOW-RES columns
        for x in 0..<wL {
            var runStart = 0
            var runLength = 0
            var gapCount = 0

            @inline(__always)
            func commitRun(endYExclusive: Int) {
                guard runLength >= minRunLow else { return }
                let yStart = runStart
                let yEnd = min(endYExclusive, hL)
                guard yEnd > yStart else { return }
                for yy in yStart..<yEnd {
                    mask[yy * wL + x] = 1
                }
            }

            for y in 0..<hL {
                if cellHasInk(xL: x, yL: y) {
                    if runLength == 0 { runStart = y }
                    runLength += 1
                    gapCount = 0
                } else if runLength > 0 {
                    gapCount += 1
                    if gapCount <= gapMaxLow {
                        runLength += 1
                    } else {
                        let runEnd = y - gapCount + 1
                        commitRun(endYExclusive: runEnd)
                        runLength = 0
                        gapCount = 0
                    }
                }
            }
            if runLength > 0 { commitRun(endYExclusive: hL) }
        }

        let sat = buildSAT(mask: mask, w: wL, h: hL)

        return VerticalStrokeMask(
            data: mask,
            width: wL,
            height: hL,
            origin: CGPoint(x: roiX, y: roiY),
            scale: scale,
            sat: sat
        )
    }

    private static func buildSAT(mask: [UInt8], w: Int, h: Int) -> [Int32] {
        var sat = [Int32](repeating: 0, count: (w + 1) * (h + 1))
        for y in 0..<h {
            var rowSum: Int32 = 0
            let srcRow = y * w
            let satRow = (y + 1) * (w + 1)
            let satPrevRow = y * (w + 1)
            for x in 0..<w {
                rowSum += (mask[srcRow + x] != 0 ? 1 : 0)
                sat[satRow + (x + 1)] = sat[satPrevRow + (x + 1)] + rowSum
            }
        }
        return sat
    }
}
