import CoreGraphics

enum NoteBlobSplitter {

    /// Split a candidate rect into multiple rects if multiple "ink peaks" exist.
    /// Works best on a preprocessed (high contrast + staff-erased) CGImage,
    /// but should still behave reasonably on raw images.
    static func splitIfNeeded(rect: CGRect, cg: CGImage, maxSplits: Int = 6) -> [CGRect] {

        let imgW = CGFloat(cg.width)
        let imgH = CGFloat(cg.height)
        let croppedRect = rect.intersection(CGRect(x: 0, y: 0, width: imgW, height: imgH))
        guard croppedRect.width >= 8, croppedRect.height >= 8 else { return [croppedRect] }

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

        // NOTE:
        // - Triads are often "TALL blobs" (multiple noteheads stacked in Y)
        // - Chords can also be "WIDE blobs" (multiple noteheads in X)
        //
        // We'll attempt BOTH:
        //   1) Wide split via column projection (existing idea)
        //   2) Tall split via row projection (NEW — fixes triads)

        let threshold = 180 // slightly high; works for filled + hollow heads
        let wideResult = trySplitWide(
            croppedRect: croppedRect,
            pixels: pixels,
            w: w,
            h: h,
            threshold: threshold,
            maxSplits: maxSplits
        )

        if wideResult.count >= 2 { return wideResult }

        let tallResult = trySplitTall(
            croppedRect: croppedRect,
            pixels: pixels,
            w: w,
            h: h,
            threshold: threshold,
            maxSplits: maxSplits
        )

        if tallResult.count >= 2 { return tallResult }

        // Fallback: force split if geometry strongly suggests multiple noteheads
        // (works for cases where projections are weak due to blur/light gray ink)
        let ar = croppedRect.width / max(1, croppedRect.height)

        // Estimate "single head size" ~ minDim * 0.9
        let minDim = min(croppedRect.width, croppedRect.height)
        let estSingle = max(10.0, minDim * 0.9)

        if ar >= 1.25 {
            let expected = Int((croppedRect.width / estSingle).rounded())
            if expected >= 2 {
                let n = min(maxSplits, expected)
                let forcedCenters = (0..<n).map { i in
                    Int((Double(w) * (Double(i) + 0.5) / Double(n)).rounded())
                }
                return splitRectsWide(from: forcedCenters, in: croppedRect, cropWidth: w)
            }
        } else if ar <= 0.80 {
            let expected = Int((croppedRect.height / estSingle).rounded())
            if expected >= 2 {
                let n = min(maxSplits, expected)
                let forcedCenters = (0..<n).map { i in
                    Int((Double(h) * (Double(i) + 0.5) / Double(n)).rounded())
                }
                return splitRectsTall(from: forcedCenters, in: croppedRect, cropHeight: h)
            }
        }

        return [croppedRect]
    }

    // MARK: - Wide split (X)

    private static func trySplitWide(
        croppedRect: CGRect,
        pixels: [UInt8],
        w: Int,
        h: Int,
        threshold: Int,
        maxSplits: Int
    ) -> [CGRect] {

        // Only attempt if it's plausibly wide or at least not extremely tall
        if croppedRect.width < croppedRect.height * 1.10 { return [croppedRect] }

        var rowInk = [Int](repeating: 0, count: h)
        for y in 0..<h {
            var s = 0
            for x in 0..<w {
                let i = (y * w + x) * 4
                let lum = (Int(pixels[i]) + Int(pixels[i + 1]) + Int(pixels[i + 2])) / 3
                if lum < threshold { s += 1 }
            }
            rowInk[y] = s
        }

        rowInk = smooth(rowInk, radius: 2)
        let rowMax = rowInk.max() ?? 0
        let beamRowMin = Int(Double(rowMax) * 0.80)

        // Widen the band to keep noteheads while still suppressing beams.
        let y0 = Int(Double(h) * 0.06)
        let y1 = Int(Double(h) * 0.94)

        var colInk = [Int](repeating: 0, count: w)
        for y in y0..<y1 {
            if rowInk[y] >= beamRowMin { continue }
            for x in 0..<w {
                let i = (y * w + x) * 4
                let lum = (Int(pixels[i]) + Int(pixels[i + 1]) + Int(pixels[i + 2])) / 3
                if lum < threshold { colInk[x] += 1 }
            }
        }

        var sm = smooth(colInk, radius: 3)
        let baseline = percentile(sm, p: 0.20)
        if baseline > 0 {
            for i in 0..<sm.count { sm[i] = max(0, sm[i] - baseline) }
        }

        let maxVal = sm.max() ?? 0
        if maxVal <= 0 { return [croppedRect] }

        let med = percentile(sm, p: 0.50)
        let peakMin = max(2, Int(max(Double(med) * 1.15, Double(maxVal) * 0.18)))

        var peaks = findPeaks(sm, peakMin: peakMin, length: w)
        // Dedupe LESS aggressively to keep close noteheads distinct
        peaks = dedupePeaks(peaks, minDistance: max(2, Int(Double(w) * 0.045)))

        if peaks.count >= 2 {
            peaks = Array(peaks.prefix(maxSplits))
            return splitRectsWide(from: peaks, in: croppedRect, cropWidth: w)
        }

        return [croppedRect]
    }

    private static func splitRectsWide(from peakCols: [Int], in rect: CGRect, cropWidth: Int) -> [CGRect] {
        guard !peakCols.isEmpty else { return [rect] }

        // width per head ~ rect.height * 0.95 (clamped)
        let estW = max(10.0, min(rect.height * 0.98, rect.width / CGFloat(peakCols.count)))

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

        return quickNMS(out, iouThreshold: 0.50)
    }

    // MARK: - Tall split (Y)  ✅ fixes triads / stacked heads

    private static func trySplitTall(
        croppedRect: CGRect,
        pixels: [UInt8],
        w: Int,
        h: Int,
        threshold: Int,
        maxSplits: Int
    ) -> [CGRect] {

        // Only attempt if it's plausibly tall
        if croppedRect.height < croppedRect.width * 1.15 { return [croppedRect] }

        // Ignore left/right band to reduce stems / barlines influence
        let x0 = Int(Double(w) * 0.20)
        let x1 = Int(Double(w) * 0.80)

        var rowInk = [Int](repeating: 0, count: h)
        for y in 0..<h {
            var s = 0
            for x in x0..<x1 {
                let i = (y * w + x) * 4
                let lum = (Int(pixels[i]) + Int(pixels[i + 1]) + Int(pixels[i + 2])) / 3
                if lum < threshold { s += 1 }
            }
            rowInk[y] = s
        }

        var sm = smooth(rowInk, radius: 3)
        let baseline = percentile(sm, p: 0.20)
        if baseline > 0 {
            for i in 0..<sm.count { sm[i] = max(0, sm[i] - baseline) }
        }

        let maxVal = sm.max() ?? 0
        if maxVal <= 0 { return [croppedRect] }

        let med = percentile(sm, p: 0.50)
        let peakMin = max(2, Int(max(Double(med) * 1.25, Double(maxVal) * 0.22)))

        var peaks = findPeaks(sm, peakMin: peakMin, length: h)
        peaks = dedupePeaks(peaks, minDistance: max(2, Int(Double(h) * 0.055)))

        if peaks.count >= 2 {
            peaks = Array(peaks.prefix(maxSplits))
            return splitRectsTall(from: peaks, in: croppedRect, cropHeight: h)
        }

        return [croppedRect]
    }

    private static func splitRectsTall(from peakRows: [Int], in rect: CGRect, cropHeight: Int) -> [CGRect] {
        guard !peakRows.isEmpty else { return [rect] }

        // height per head ~ rect.width * 0.95 (clamped)
        let estH = max(10.0, min(rect.width * 1.05, rect.height / CGFloat(peakRows.count)))

        var out: [CGRect] = []
        out.reserveCapacity(peakRows.count)

        for p in peakRows {
            let cy = rect.minY + CGFloat(p) * (rect.height / CGFloat(max(1, cropHeight))) + 0.5
            let newRect = CGRect(
                x: rect.minX,
                y: cy - estH / 2.0,
                width: rect.width,
                height: estH
            ).intersection(rect)

            if newRect.width >= 6 && newRect.height >= 6 {
                out.append(newRect)
            }
        }

        return quickNMS(out, iouThreshold: 0.50)
    }

    // MARK: - Peak finding

    private static func findPeaks(_ arr: [Int], peakMin: Int, length: Int) -> [Int] {
        guard length >= 3 else { return [] }
        var peaks: [Int] = []
        var i = 1
        while i < length - 1 {
            if arr[i] >= peakMin, arr[i] >= arr[i - 1], arr[i] >= arr[i + 1] {

                // plateau -> choose center
                var l = i
                var r = i
                while l - 1 >= 0 && arr[l - 1] == arr[i] { l -= 1 }
                while r + 1 < length && arr[r + 1] == arr[i] { r += 1 }
                peaks.append((l + r) / 2)
                i = r + 1
            } else {
                i += 1
            }
        }
        return peaks
    }

    // MARK: - NMS / IoU

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
