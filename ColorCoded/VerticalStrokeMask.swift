import CoreGraphics
import Foundation

struct VerticalStrokeMask {
    let data: [UInt8]
    let width: Int
    let height: Int
    let origin: CGPoint

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

        var count = 0
        for y in y0..<y1 {
            let row = y * width
            for x in x0..<x1 {
                if data[row + x] != 0 { count += 1 }
            }
        }

        let area = max(1, (x1 - x0) * (y1 - y0))
        return CGFloat(count) / CGFloat(area)
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

        return VerticalStrokeMask(
            data: mask,
            width: roiW,
            height: roiH,
            origin: CGPoint(x: roiX, y: roiY)
        )
    }
}
