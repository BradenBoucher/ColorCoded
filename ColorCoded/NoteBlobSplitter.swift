import CoreGraphics

enum NoteBlobSplitter {

    /// Split a wide candidate rect into multiple rects if multiple "ink peaks" exist.
    /// - Parameters:
    ///   - rect: candidate note region in IMAGE coordinates
    ///   - cg: preprocessed CGImage (ideally staff-erased + high-contrast)
    ///   - maxSplits: max number of noteheads to split into (usually 3-4 for chords)
    static func splitIfNeeded(rect: CGRect, cg: CGImage, maxSplits: Int = 4) -> [CGRect] {
        let imgW = CGFloat(cg.width)
        let imgH = CGFloat(cg.height)
        let croppedRect = rect.intersection(CGRect(x: 0, y: 0, width: imgW, height: imgH))
        guard croppedRect.width >= 8, croppedRect.height >= 8 else { return [rect] }

        if croppedRect.width < croppedRect.height * 1.35 {
            return [croppedRect]
        }

        guard let crop = cg.cropping(to: croppedRect.integral) else { return [croppedRect] }

        let w = crop.width
        let h = crop.height
        guard w > 0, h > 0 else { return [croppedRect] }

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

        var colInk = [Int](repeating: 0, count: w)
        let threshold = 150

        for y in 0..<h {
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

        let smoothed = smooth(colInk, radius: 2)
        let maxVal = smoothed.max() ?? 0
        guard maxVal > 0 else { return [croppedRect] }

        let peakMin = max(3, Int(Double(maxVal) * 0.45))

        var peaks: [Int] = []
        var x = 1
        while x < w - 1 {
            if smoothed[x] >= peakMin,
               smoothed[x] >= smoothed[x - 1],
               smoothed[x] >= smoothed[x + 1] {

                var best = x
                var j = x
                while j + 1 < w && smoothed[j + 1] == smoothed[x] {
                    best = j + 1
                    j += 1
                }

                peaks.append(best)
                x = j + 1
            } else {
                x += 1
            }
        }

        peaks = dedupePeaks(peaks, minDistance: max(6, Int(Double(w) * 0.12)))
        if peaks.count <= 1 { return [croppedRect] }

        if peaks.count > maxSplits {
            peaks = Array(peaks.prefix(maxSplits))
        }

        let estW = max(10.0, min(croppedRect.height * 0.9, croppedRect.width / CGFloat(peaks.count)))

        var out: [CGRect] = []
        for p in peaks {
            let cx = croppedRect.minX + CGFloat(p) + 0.5
            let newRect = CGRect(
                x: cx - estW / 2.0,
                y: croppedRect.minY,
                width: estW,
                height: croppedRect.height
            ).intersection(croppedRect)

            if newRect.width >= 6 && newRect.height >= 6 {
                out.append(newRect)
            }
        }

        return out.isEmpty ? [croppedRect] : out
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
        var out: [Int] = []
        for p in peaks {
            if let last = out.last, abs(p - last) < minDistance {
                continue
            }
            out.append(p)
        }
        return out
    }
}
