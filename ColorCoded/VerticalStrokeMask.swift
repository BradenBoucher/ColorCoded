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

        let x0 = max(0, Int(clipped.minX.rounded(.down)))
        let y0 = max(0, Int(clipped.minY.rounded(.down)))
        let x1 = min(width, Int(clipped.maxX.rounded(.up)))
        let y1 = min(height, Int(clipped.maxY.rounded(.up)))

        var count = 0
        for y in y0..<y1 {
            let row = y * width
            for x in x0..<x1 {
                if data[row + x] != 0 { count += 1 }
            }
        }

        let area = max(1, Int(rect.width * rect.height))
        return CGFloat(count) / CGFloat(area)
    }

    static func build(from binary: [UInt8],
                      width: Int,
                      height: Int,
                      roi: CGRect,
                      minRun: Int) -> VerticalStrokeMask? {
        guard width > 0, height > 0, minRun > 1 else { return nil }
        let clipped = roi.intersection(CGRect(x: 0, y: 0, width: width, height: height))
        guard clipped.width > 0, clipped.height > 0 else { return nil }

        let roiX = max(0, Int(clipped.minX.rounded(.down)))
        let roiY = max(0, Int(clipped.minY.rounded(.down)))
        let roiW = min(width - roiX, Int(clipped.width.rounded(.down)))
        let roiH = min(height - roiY, Int(clipped.height.rounded(.down)))
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

        return VerticalStrokeMask(data: mask, width: roiW, height: roiH, origin: CGPoint(x: roiX, y: roiY))
    }
}
