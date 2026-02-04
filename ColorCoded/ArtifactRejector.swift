import Foundation
import CoreGraphics

enum ArtifactRejector {
    private struct BinarySampler {
        let width: Int
        let height: Int
        let data: [UInt8]

        init?(cg: CGImage) {
            let w = cg.width
            let h = cg.height
            guard w > 0, h > 0 else { return nil }

            var rgba = [UInt8](repeating: 0, count: w * h * 4)
            let cs = CGColorSpaceCreateDeviceRGB()
            guard let ctx = CGContext(
                data: &rgba,
                width: w,
                height: h,
                bitsPerComponent: 8,
                bytesPerRow: w * 4,
                space: cs,
                bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue
            ) else { return nil }

            ctx.draw(cg, in: CGRect(x: 0, y: 0, width: w, height: h))

            var lum = [UInt8](repeating: 0, count: w * h)
            for y in 0..<h {
                let rowRGBA = y * w * 4
                let row = y * w
                for x in 0..<w {
                    let idx = rowRGBA + x * 4
                    let l = (Int(rgba[idx]) + Int(rgba[idx + 1]) + Int(rgba[idx + 2])) / 3
                    lum[row + x] = UInt8(l)
                }
            }

            self.width = w
            self.height = h
            self.data = lum
        }

        func isInk(x: Int, y: Int, threshold: UInt8 = 128) -> Bool {
            guard x >= 0, y >= 0, x < width, y < height else { return false }
            return data[y * width + x] < threshold
        }
    }

    static func rejectArtifacts(_ rects: [CGRect],
                                cg: CGImage,
                                spacing: CGFloat,
                                barlines: [CGRect]) -> [CGRect] {
        guard !rects.isEmpty else { return [] }
        guard let sampler = BinarySampler(cg: cg) else { return rects }

        let expandedBarlines = barlines.map {
            $0.insetBy(dx: -0.5 * spacing, dy: -0.5 * spacing)
        }

        return rects.filter { rect in
            let clipped = rect.intersection(CGRect(x: 0, y: 0, width: sampler.width, height: sampler.height))
            guard clipped.width > 1, clipped.height > 1 else { return false }

            let aspect = clipped.width / max(1.0, clipped.height)
            let extremeAspect = max(aspect, 1.0 / max(0.001, aspect)) > 3.0

            let tallSkinny = clipped.height > spacing * 2.3 && clipped.width < spacing * 0.55
            if tallSkinny { return false }

            let longHorizontal = clipped.width > spacing * 3.5 && clipped.height < spacing * 0.55
            if longHorizontal { return false }

            let inkRatio = sampleInkRatio(rect: clipped, sampler: sampler, grid: 8)
            if inkRatio < 0.08 { return false }
            if inkRatio > 0.85 && extremeAspect { return false }

            if maxIoU(rect: clipped, others: expandedBarlines) > 0.25 { return false }

            let (vPeaks, hPeaks) = projectionPeaks(rect: clipped, sampler: sampler, grid: 12)
            let dominant = max(vPeaks, hPeaks)
            let weaker = max(1, min(vPeaks, hPeaks))
            if Double(dominant) / Double(weaker) > 4.0 && extremeAspect { return false }

            return true
        }
    }

    private static func sampleInkRatio(rect: CGRect, sampler: BinarySampler, grid: Int) -> Double {
        let cols = max(2, grid)
        let rows = max(2, grid)
        var ink = 0
        var total = 0

        for row in 0..<rows {
            let y = rect.minY + (CGFloat(row) + 0.5) * rect.height / CGFloat(rows)
            let iy = Int(y.rounded())
            for col in 0..<cols {
                let x = rect.minX + (CGFloat(col) + 0.5) * rect.width / CGFloat(cols)
                let ix = Int(x.rounded())
                total += 1
                if sampler.isInk(x: ix, y: iy) { ink += 1 }
            }
        }

        return total > 0 ? Double(ink) / Double(total) : 0
    }

    private static func projectionPeaks(rect: CGRect, sampler: BinarySampler, grid: Int) -> (Int, Int) {
        let cols = max(4, grid)
        let rows = max(4, grid)
        var verticalPeaks = 0
        var horizontalPeaks = 0

        for col in 0..<cols {
            let x = rect.minX + (CGFloat(col) + 0.5) * rect.width / CGFloat(cols)
            let ix = Int(x.rounded())
            var inkCount = 0
            for row in 0..<rows {
                let y = rect.minY + (CGFloat(row) + 0.5) * rect.height / CGFloat(rows)
                let iy = Int(y.rounded())
                if sampler.isInk(x: ix, y: iy) { inkCount += 1 }
            }
            if inkCount >= rows / 2 { verticalPeaks += 1 }
        }

        for row in 0..<rows {
            let y = rect.minY + (CGFloat(row) + 0.5) * rect.height / CGFloat(rows)
            let iy = Int(y.rounded())
            var inkCount = 0
            for col in 0..<cols {
                let x = rect.minX + (CGFloat(col) + 0.5) * rect.width / CGFloat(cols)
                let ix = Int(x.rounded())
                if sampler.isInk(x: ix, y: iy) { inkCount += 1 }
            }
            if inkCount >= cols / 2 { horizontalPeaks += 1 }
        }

        return (verticalPeaks, horizontalPeaks)
    }

    private static func maxIoU(rect: CGRect, others: [CGRect]) -> CGFloat {
        var best: CGFloat = 0
        for other in others {
            let inter = rect.intersection(other)
            if inter.isNull { continue }
            let interArea = inter.width * inter.height
            let unionArea = rect.width * rect.height + other.width * other.height - interArea
            if unionArea > 0 {
                best = max(best, interArea / unionArea)
            }
        }
        return best
    }
}
