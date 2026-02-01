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

        // Build a horizontal "ink" projection by counting dark pixels per row.
        guard let rows = small.horizontalInkProjection() else { return nil }

        // Find peaks (rows with lots of dark pixels)
        let peaks = findPeaks(rows, minDistance: 3, thresholdFracOfMax: 0.55)
        if peaks.count < 5 { return nil }

        // Convert peak indices back to original-image coordinates
        let ys = peaks.map { CGFloat($0) / scale }

        // Group into staves of 5 lines
        let grouped = groupIntoStaves(ys: ys)

        // Estimate spacing from first staff if possible
        let spacing: CGFloat
        if let first = grouped.first, first.count == 5 {
            let diffs = zip(first.dropFirst(), first).map { $0 - $1 }
            spacing = diffs.sorted()[diffs.count / 2]
        } else {
            spacing = 12
        }

        return StaffModel(staves: grouped, lineSpacing: max(6, spacing))
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
        // Greedy grouping into chunks of 5 with roughly consistent spacing
        let sorted = ys.sorted()
        var staves: [[CGFloat]] = []
        var current: [CGFloat] = []

        for y in sorted {
            if current.isEmpty {
                current = [y]
                continue
            }

            // Accept if it's not ridiculously far from previous line
            let dy = y - current.last!
            if dy < 80 { // heuristic
                current.append(y)
                if current.count == 5 {
                    staves.append(current)
                    current = []
                }
            } else {
                // reset
                current = [y]
            }
        }

        // If leftover lines, ignore.
        return staves
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

    func horizontalInkProjection() -> [Int]? {
        let w = self.width
        let h = self.height

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
                if lum < 80 { count += 1 } // dark threshold
            }
            rows[y] = count
        }

        return rows
    }
}
