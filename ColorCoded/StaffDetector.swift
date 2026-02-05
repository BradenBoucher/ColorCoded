import Foundation
import PDFKit
@preconcurrency import Vision


struct StaffModel {
    /// Approx y positions of staff lines (in image coordinates), grouped into staves of 5.
    let staves: [[CGFloat]]
    /// Estimated line spacing (distance between adjacent staff lines)
    let lineSpacing: CGFloat
}

enum StaffDetector {

    static func detectStaff(in image: PlatformImage) async -> StaffModel? {
        guard let cg = image.cgImageSafe else { return nil }

        // Downscale for speed
        let targetW = 900
        let scale = CGFloat(targetW) / CGFloat(cg.width)
        let targetH = Int(CGFloat(cg.height) * scale)

        guard let small = cg.resized(width: targetW, height: targetH) else { return nil }

        let thresholds = [80, 120]
        var bestModel: StaffModel?
        var bestScore = -1

        for threshold in thresholds {
            guard let rows = small.horizontalInkProjection(lumThreshold: threshold) else { continue }

            let peaks = findPeaks(rows, minDistance: 3, thresholdFracOfMax: 0.55)
            if peaks.count < 5 { continue }

            let ys = peaks.map { CGFloat($0) / scale }
            var grouped = groupIntoStaves(ys: ys)

            if grouped.isEmpty, let fallback = bestSingleStaff(from: ys) {
                grouped = [fallback]
            }

            guard !grouped.isEmpty else { continue }

            let spacing = estimateSpacing(from: grouped)
            let model = StaffModel(staves: grouped, lineSpacing: max(6, spacing))

            let score = grouped.count * 10 + peaks.count
            if score > bestScore {
                bestScore = score
                bestModel = model
            }
        }

        return bestModel
    }

    private static func findPeaks(_ rows: [Int], minDistance: Int, thresholdFracOfMax: Double) -> [Int] {
        guard let maxV = rows.max(), maxV > 0 else { return [] }
        let thresh = Int(Double(maxV) * thresholdFracOfMax)

        var candidates: [Int] = []
        for i in 1..<(rows.count - 1) {
            if rows[i] >= thresh && rows[i] >= rows[i-1] && rows[i] >= rows[i+1] {
                candidates.append(i)
            }
        }

        // Non-maximum suppression by minDistance
        var picked: [Int] = []
        for c in candidates {
            if picked.last.map({ abs(c - $0) >= minDistance }) ?? true {
                picked.append(c)
            }
        }
        return picked
    }

    private static func groupIntoStaves(ys: [CGFloat]) -> [[CGFloat]] {
        let sorted = ys.sorted()
        var staves: [[CGFloat]] = []

        var i = 0
        while i + 4 < sorted.count {
            let candidate = Array(sorted[i...(i + 4)])

            let diffs = zip(candidate.dropFirst(), candidate).map { $0 - $1 }
            let med = diffs.sorted()[diffs.count / 2]
            let tolerance = max(2.0, med * 0.20)
            let ok = diffs.allSatisfy { abs($0 - med) < tolerance }

            if ok {
                staves.append(candidate)
                i += 5
            } else {
                i += 1
            }
        }

        return staves
    }

    private static func estimateSpacing(from grouped: [[CGFloat]]) -> CGFloat {
        if let first = grouped.first, first.count == 5 {
            let diffs = zip(first.dropFirst(), first).map { $0 - $1 }
            return diffs.sorted()[diffs.count / 2]
        }
        return 12
    }

    private static func bestSingleStaff(from ys: [CGFloat]) -> [CGFloat]? {
        let sorted = ys.sorted()
        guard sorted.count >= 5 else { return nil }
        var best: [CGFloat]?
        var bestScore = Double.greatestFiniteMagnitude
        for i in 0...(sorted.count - 5) {
            let candidate = Array(sorted[i..<(i + 5)])
            let diffs = zip(candidate.dropFirst(), candidate).map { $0 - $1 }
            let mean = diffs.reduce(0, +) / CGFloat(diffs.count)
            let variance = diffs.reduce(0.0) { acc, val in
                let delta = Double(val - mean)
                return acc + (delta * delta)
            } / Double(diffs.count)
            if variance < bestScore {
                bestScore = variance
                best = candidate
            }
        }
        return best
    }
}

// MARK: - CGImage helpers

private extension CGImage {
    func resized(width: Int, height: Int) -> CGImage? {
        let colorSpace = CGColorSpaceCreateDeviceRGB()
        guard let ctx = CGContext(
            data: nil,
            width: width,
            height: height,
            bitsPerComponent: 8,
            bytesPerRow: width * 4,
            space: colorSpace,
            bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue
        ) else { return nil }

        ctx.interpolationQuality = .low
        ctx.draw(self, in: CGRect(x: 0, y: 0, width: width, height: height))
        return ctx.makeImage()
    }

    func horizontalInkProjection(lumThreshold: Int) -> [Int]? {
        let w = self.width
        let h = self.height
        let pixelCount = w * h
        if pixelCount > 8_000_000 {
            return nil
        }

        let colorSpace = CGColorSpaceCreateDeviceRGB()
        var data = [UInt8](repeating: 0, count: w * h * 4)

        guard let ctx = CGContext(
            data: &data,
            width: w,
            height: h,
            bitsPerComponent: 8,
            bytesPerRow: w * 4,
            space: colorSpace,
            bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue
        ) else { return nil }

        ctx.draw(self, in: CGRect(x: 0, y: 0, width: w, height: h))

        var rows = [Int](repeating: 0, count: h)

        // Count "dark" pixels per row
        for y in 0..<h {
            var count = 0
            let rowStart = y * w * 4
            for x in 0..<w {
                let idx = rowStart + x * 4
                let r = Int(data[idx])
                let g = Int(data[idx + 1])
                let b = Int(data[idx + 2])
                let lum = (r + g + b) / 3
                if lum < lumThreshold { count += 1 } // dark threshold
            }
            rows[y] = count
        }

        return rows
    }
}
