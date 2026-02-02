import CoreGraphics
import Foundation

/// VerticalStrokeMask marks pixels that belong to long vertical runs (stems, barlines).
/// `data` is 0/1 in ROI coordinates.
struct VerticalStrokeMask {
    let data: [UInt8]
    let width: Int
    let height: Int
    let origin: CGPoint

    /// Returns the fraction of pixels inside `rect` that are marked as vertical stroke.
    /// IMPORTANT: Uses the CLIPPED rect area (not the original rect).
    func overlapRatio(with rect: CGRect) -> CGFloat {
        guard width > 0, height > 0 else { return 0 }

        let localRect = CGRect(
            x: rect.minX - origin.x,
            y: rect.minY - origin.y,
            width: rect.width,
            height: rect.height
        )

        let bounds = CGRect(x: 0, y: 0, width: width, height: height)
        let clipped = localRect.intersection(bounds)
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

        // ✅ denominator must be the area we actually sampled
        let sampleArea = max(1, (x1 - x0) * (y1 - y0))
        return CGFloat(count) / CGFloat(sampleArea)
    }

    /// Stronger version: checks overlap only on a center window of the rect.
    /// This avoids over-penalizing legitimate noteheads that touch a stem on one side.
    func overlapRatioCenterWindow(with rect: CGRect, insetFraction: CGFloat = 0.20) -> CGFloat {
        let insetX = rect.width * insetFraction
        let insetY = rect.height * insetFraction
        let inner = rect.insetBy(dx: insetX, dy: insetY)
        return overlapRatio(with: inner)
    }

    /// Build a vertical stroke mask from a full-page binary image (0/1 or 0/255).
    /// Pixels are considered "ink" if `binary[idx] != 0`.
    static func build(from binary: [UInt8],
                      width: Int,
                      height: Int,
                      roi: CGRect,
                      minRun: Int) -> VerticalStrokeMask? {
        guard width > 0, height > 0, minRun > 1 else { return nil }

        let bounds = CGRect(x: 0, y: 0, width: width, height: height)
        let clipped = roi.intersection(bounds)
        guard clipped.width > 0, clipped.height > 0 else { return nil }

        let roiX = max(0, Int(floor(clipped.minX)))
        let roiY = max(0, Int(floor(clipped.minY)))
        let roiW = max(1, min(width - roiX, Int(floor(clipped.width))))
        let roiH = max(1, min(height - roiY, Int(floor(clipped.height))))
        guard roiW > 0, roiH > 0 else { return nil }

        var mask = [UInt8](repeating: 0, count: roiW * roiH)

        for x in 0..<roiW {
            var runStart = 0
            var runLength = 0

            for y in 0..<roiH {
                let fullIndex = (roiY + y) * width + (roiX + x)
                if binary[fullIndex] != 0 {
                    if runLength == 0 { runStart = y }
                    runLength += 1
                } else if runLength > 0 {
                    if runLength >= minRun {
                        for yy in runStart..<(runStart + runLength) {
                            mask[yy * roiW + x] = 1
                        }
                    }
                    runLength = 0
                }
            }

            if runLength >= minRun {
                for yy in runStart..<(runStart + runLength) {
                    mask[yy * roiW + x] = 1
                }
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
