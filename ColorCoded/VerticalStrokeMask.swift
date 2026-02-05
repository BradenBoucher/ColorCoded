import CoreGraphics
import Foundation

struct VerticalStrokeMask {
    let data: [UInt8]        // 0/1 mask in ROI coordinates
    let width: Int
    let height: Int
    let origin: CGPoint

    // Integral image (summed area table) for O(1) overlap queries.
    // Stored as Int32 to keep memory reasonable.
    // Dimensions: (width+1) * (height+1)
    private let sat: [Int32]

    /// O(1) overlap ratio using the integral image
    func overlapRatio(with rect: CGRect) -> CGFloat {
        guard width > 0, height > 0 else { return 0 }

        let localRect = CGRect(
            x: rect.minX - origin.x,
            y: rect.minY - origin.y,
            width: rect.width,
            height: rect.height
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
    private func satIndex(_ x: Int, _ y: Int) -> Int {
        // sat is (width+1) x (height+1)
        return y * (width + 1) + x
    }

    @inline(__always)
    private func satSum(x0: Int, y0: Int, x1: Int, y1: Int) -> Int32 {
        // sum over [x0, x1) x [y0, y1)
        let A = sat[satIndex(x0, y0)]
        let B = sat[satIndex(x1, y0)]
        let C = sat[satIndex(x0, y1)]
        let D = sat[satIndex(x1, y1)]
        return D - B - C + A
    }

    /// Build a vertical-run mask inside ROI from a full-page binary ink map (1=ink, 0=white).
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

        var mask = [UInt8](repeating: 0, count: roiW * roiH)

        // Allow tiny gaps (anti-aliasing / staff crossings)
        let gapMax = 2

        for x in 0..<roiW {
            var runStart = 0
            var runLength = 0
            var gapCount = 0

            @inline(__always) func commitRun(endYExclusive: Int) {
                guard runLength >= minRun else { return }
                let yStart = runStart
                let yEnd = min(endYExclusive, roiH)
                guard yEnd > yStart else { return }
                for yy in yStart..<yEnd {
                    mask[yy * roiW + x] = 1
                }
            }

            for y in 0..<roiH {
                let fullIndex = (roiY + y) * width + (roiX + x)
                if binary[fullIndex] != 0 {
                    if runLength == 0 { runStart = y }
                    runLength += 1
                    gapCount = 0
                } else if runLength > 0 {
                    gapCount += 1
                    if gapCount <= gapMax {
                        runLength += 1
                    } else {
                        let runEnd = y - gapCount + 1
                        commitRun(endYExclusive: runEnd)
                        runLength = 0
                        gapCount = 0
                    }
                }
            }

            if runLength > 0 {
                commitRun(endYExclusive: roiH)
            }
        }

        // Build summed-area table (integral image)
        let sat = buildSAT(mask: mask, w: roiW, h: roiH)

        return VerticalStrokeMask(
            data: mask,
            width: roiW,
            height: roiH,
            origin: CGPoint(x: roiX, y: roiY),
            sat: sat
        )
    }

    private static func buildSAT(mask: [UInt8], w: Int, h: Int) -> [Int32] {
        // sat dims: (w+1) x (h+1)
        var sat = [Int32](repeating: 0, count: (w + 1) * (h + 1))

        for y in 0..<h {
            var rowSum: Int32 = 0
            let srcRow = y * w
            let satRow = (y + 1) * (w + 1)
            let satPrevRow = y * (w + 1)

            // sat[(x+1,y+1)] = sat[(x+1,y)] + rowSum
            for x in 0..<w {
                rowSum += (mask[srcRow + x] != 0 ? 1 : 0)
                sat[satRow + (x + 1)] = sat[satPrevRow + (x + 1)] + rowSum
            }
        }

        return sat
    }
}
