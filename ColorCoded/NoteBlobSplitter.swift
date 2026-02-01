import CoreGraphics

enum NoteBlobSplitter {

    /// Split a wide candidate rect into multiple rects if multiple "ink peaks" exist.
    /// Works best on a preprocessed (high contrast + staff-erased) CGImage.
    static func splitIfNeeded(rect: CGRect, cg: CGImage, maxSplits: Int = 4) -> [CGRect] {

        let imgW = CGFloat(cg.width)
        let imgH = CGFloat(cg.height)
        let croppedRect = rect.intersection(CGRect(x: 0, y: 0, width: imgW, height: imgH))
        guard croppedRect.width >= 8, croppedRect.height >= 8 else { return [rect] }

        // Only split if it looks "wide enough" to contain >1 notehead
        if croppedRect.width < croppedRect.height * 1.25 {
            return [croppedRect]
        }

        guard let crop = cg.cropping(to: croppedRect.integral) else { return [croppedRect] }

        let w = crop.width
        let h = crop.height
        guard w > 0, h > 0 else { return [croppedRect] }

        // Read pixels (RGBA)
        var pixels = [UInt8](repeating: 0, count: w * h * 4)
        guard let ctx = CGContext(
            data: &pixels,
            width: w,
            height: h,
            bitsPerComponent: 8,
            bytesPerRow: w * 4,
            space: CGColorSpaceCreateDeviceRGB(),
            bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue
        ) else { return [croppedRect] }

        ctx.draw(crop, in: CGRect(x: 0, y: 0, width: w, height: h))

        // ---- Vertical ink projection (count dark pixels per column) ----
        var colInk = [Int](repeating: 0, count: w)

        // Slightly higher threshold catches hollow noteheads too
        let threshold = 175

        // Ignore top/bottom band to reduce stems/beams influence
        let y0 = Int(Double(h) * 0.12)
        let y1 = Int(Double(h) * 0.88)

        for y in y0..<y1 {
            for x in 0..<w {
                let i = (y * w + x) * 4
                let r = Int(pixels[i])
                let g = Int(pixels[i + 1])
                let b = Int(pixels[i + 2])
                let lum = (r + g + b) / 3
                if lum < threshold {
                    colInk[x] += 1
                }
            }
        }

        // Smooth projection
        var smoothed = smooth(colInk, radius: 3)

        // Normalize small noise: subtract a small baseline (helps hollow noteheads)
        let baseline = percentile(smoothed, p: 0.20)
        if baseline > 0 {
            for i in 0..<smoothed.count { smoothed[i] = max(0, smoothed[i] - baseline) }
        }

        let maxVal = smoothed.max() ?? 0
        if maxVal <= 0 { return [croppedRect] }

        // Adaptive threshold: based on median/max, not just max
        let med = percentile(smoothed, p: 0.50)
        let peakMin = max(2, Int(max(Double(med) * 1.4, Double(maxVal) * 0.28)))

        // Find peaks
        var peaks: [Int] = []
        var x = 1
        while x < w - 1 {
            if smoothed[x] >= peakMin,
               smoothed[x] >= smoothed[x - 1],
               smoothed[x] >= smoothed[x + 1] {

                // Walk across plateau and pick center
                var left = x
                var right = x
                while left - 1 >= 0 && smoothed[left - 1] == smoothed[x] { left -= 1 }
                while right + 1 < w && smoothed[right + 1] == smoothed[x] { right += 1 }
                let best = (left + right) / 2

                peaks.append(best)
                x = right + 1
            } else {
                x += 1
            }
        }

        // Dedupe peaks less aggressively so close noteheads don't merge
        peaks = dedupePeaks(peaks, minDistance: max(3, Int(Double(w) * 0.05)))

        // If we found 2+ peaks, split using peaks
        if peaks.count >= 2 {
            peaks = Array(peaks.prefix(maxSplits))
            return splitRects(from: peaks, in: croppedRect, cropWidth: w)
        }

        // ---- Fallback: force split based on width if it strongly suggests multiple noteheads ----
        // Estimate "single notehead width" ~ height*0.85 (vector render tends to match this)
        let estSingle = max(10.0, croppedRect.height * 0.85)
        let expectedCount = Int((croppedRect.width / estSingle).rounded())

        // If it looks like 3 noteheads wide, force 3-way split even if peaks were weak
        if expectedCount >= 3 {
            let n = min(maxSplits, expectedCount)
            let forcedCenters = (0..<n).map { i in
                Int((Double(w) * (Double(i) + 0.5) / Double(n)).rounded())
            }
            return splitRects(from: forcedCenters, in: croppedRect, cropWidth: w)
        }

        // Otherwise keep as-is
        return [croppedRect]
    }

    // MARK: - Splitting

    private static func splitRects(from peakCols: [Int], in rect: CGRect, cropWidth: Int) -> [CGRect] {
        guard !peakCols.isEmpty else { return [rect] }

        // Estimate width per notehead as rect.height * 0.9, but clamp to reasonable
        let estW = max(10.0, min(rect.height * 0.95, rect.width / CGFloat(peakCols.count)))

        var out: [CGRect] = []
        out.reserveCapacity(peakCols.count)

        for p in peakCols {
            let cx = rect.minX + CGFloat(p) * (rect.width / CGFloat(max(1, cropWidth))) + 0.5
            let newRect = CGRect(
                x: cx - estW / 2.0,
                y: rect.minY,
                width: estW,
                height: rect.height
            ).intersection(rect)

            if newRect.width >= 6 && newRect.height >= 6 {
                out.append(newRect)
            }
        }

        // If we accidentally produced overlapping duplicates, lightly NMS them here
        return quickNMS(out, iouThreshold: 0.55)
    }

    private static func quickNMS(_ boxes: [CGRect], iouThreshold: CGFloat) -> [CGRect] {
        let sorted = boxes.sorted { ($0.width * $0.height) > ($1.width * $1.height) }
        var kept: [CGRect] = []
        for b in sorted {
            var keep = true
            for k in kept {
                if iou(b, k) > iouThreshold { keep = false; break }
            }
            if keep { kept.append(b) }
        }
        return kept
    }

    private static func iou(_ a: CGRect, _ b: CGRect) -> CGFloat {
        let inter = a.intersection(b)
        if inter.isNull { return 0 }
        let ia = inter.width * inter.height
        let ua = a.width * a.height + b.width * b.height - ia
        return ia / max(1, ua)
    }

    // MARK: - Helpers

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

    private static func dedupePeaks(_ peaks: [Int], minDistance: Int) -> [Int] {
        guard !peaks.isEmpty else { return peaks }
        let sorted = peaks.sorted()
        var out: [Int] = []
        for p in sorted {
            if let last = out.last, abs(p - last) < minDistance {
                continue
            }
            out.append(p)
        }
        return out
    }

    /// p in [0,1]
    private static func percentile(_ arr: [Int], p: Double) -> Int {
        guard !arr.isEmpty else { return 0 }
        let sorted = arr.sorted()
        let idx = Int((Double(sorted.count - 1) * min(max(p, 0.0), 1.0)).rounded())
        return sorted[max(0, min(sorted.count - 1, idx))]
    }
}
