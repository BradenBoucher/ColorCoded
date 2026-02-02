import Foundation
import CoreGraphics

enum BarlineDetector {
    static func detectBarlines(in cg: CGImage, systems: [SystemBlock]) -> [CGRect] {
        guard !systems.isEmpty else { return [] }

        let w = cg.width
        let h = cg.height
        guard w > 0, h > 0 else { return [] }

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

        var out: [CGRect] = []

        for system in systems {
            let x0 = max(0, Int(system.bbox.minX))
            let x1 = min(w - 1, Int(system.bbox.maxX))
            let y0 = max(0, Int(system.bbox.minY))
            let y1 = min(h - 1, Int(system.bbox.maxY))
            if x1 <= x0 || y1 <= y0 { continue }

            var colInk = [Int](repeating: 0, count: x1 - x0 + 1)
            let strideY = 2
            for y in stride(from: y0, through: y1, by: strideY) {
                let rowStart = y * w * 4
                for x in x0...x1 {
                    let idx = rowStart + x * 4
                    let lum = (Int(pixels[idx]) + Int(pixels[idx + 1]) + Int(pixels[idx + 2])) / 3
                    if lum < 150 {
                        colInk[x - x0] += 1
                    }
                }
            }

            colInk = smooth(colInk, radius: 2)
            let maxVal = colInk.max() ?? 0
            if maxVal == 0 { continue }
            let med = percentile(colInk, p: 0.50)
            let minVal = max(Int(Double(med) * 2.0), Int(Double(maxVal) * 0.45))
            let runs = findRuns(colInk, minVal: minVal, minWidth: 1)

            for run in runs {
                let rect = CGRect(
                    x: CGFloat(x0 + run.lowerBound) - 1,
                    y: CGFloat(y0) - 2,
                    width: CGFloat(run.upperBound - run.lowerBound + 1) + 2,
                    height: CGFloat(y1 - y0) + 4
                )
                out.append(rect)
            }
        }

        return out
    }

    private static func findRuns(_ values: [Int], minVal: Int, minWidth: Int) -> [Range<Int>] {
        var ranges: [Range<Int>] = []
        var i = 0
        while i < values.count {
            if values[i] >= minVal {
                let start = i
                var end = i
                while end < values.count && values[end] >= minVal { end += 1 }
                if end - start >= minWidth {
                    ranges.append(start..<end)
                }
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
            for j in a...b {
                s += arr[j]
                c += 1
            }
            out[i] = s / max(1, c)
        }
        return out
    }

    private static func percentile(_ arr: [Int], p: Double) -> Int {
        guard !arr.isEmpty else { return 0 }
        let sorted = arr.sorted()
        let idx = Int((Double(sorted.count - 1) * min(max(p, 0.0), 1.0)).rounded())
        return sorted[max(0, min(sorted.count - 1, idx))]
    }
}
