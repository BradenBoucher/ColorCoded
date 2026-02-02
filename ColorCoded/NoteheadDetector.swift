import Foundation
@preconcurrency import Vision
import CoreGraphics

enum NoteheadDetector {

    // MARK: - Public

    /// Production: just notehead rects
    static func detectNoteheads(in image: PlatformImage) async -> [CGRect] {
        let result = await detectDebug(in: image)
        return result.noteRects
    }

    /// Debug: noteheads + staff rectangles (treble/bass systems).
    static func detectDebug(in image: PlatformImage) async -> (noteRects: [CGRect], staffRects: [CGRect]) {
        guard let cg = image.cgImageSafe else { return ([], []) }

        let imageSize = CGSize(width: cg.width, height: cg.height)

        return await withCheckedContinuation { continuation in
            DispatchQueue.global(qos: .userInitiated).async {
                do {
                    let request = VNDetectContoursRequest { req, err in
                        guard err == nil else {
                            continuation.resume(returning: ([], []))
                            return
                        }

                        guard let obs = req.results?.first as? VNContoursObservation else {
                            continuation.resume(returning: ([], []))
                            return
                        }

                        // High-recall candidates
                        let boxes = extractCandidateBoxes(from: obs, imageSize: imageSize)

                        // Split merged blobs (NOW handles wide + tall stacks)
                        let split = splitMergedBoxes(boxes, cgImage: cg)

                        // Reduce duplicates, but keep close stacked notes
                        let notes = nonMaxSuppression(split, iouThreshold: 0.78)

                        // Staff debug rectangles
                        let staffRects = detectStaffRects(inCG: cg)

                        continuation.resume(returning: (notes, staffRects))
                    }

                    request.contrastAdjustment = 1.2
                    request.detectsDarkOnLight = true

                    let handler = VNImageRequestHandler(cgImage: cg, orientation: .up, options: [:])
                    try handler.perform([request])
                } catch {
                    continuation.resume(returning: ([], []))
                }
            }
        }
    }

    // MARK: - Candidate extraction

    /// Very recall-heavy candidate extraction.
    /// Let splitter + NMS handle cleanup.
    private static func extractCandidateBoxes(from obs: VNContoursObservation,
                                             imageSize: CGSize) -> [CGRect] {
        var out: [CGRect] = []
        out.reserveCapacity(obs.contourCount)

        let all = (0..<obs.contourCount).compactMap { try? obs.contour(at: $0) }

        for c in all {
            let boxN = c.normalizedPath.boundingBox

            // Vision origin is lower-left; convert to image coords (top-left origin)
            var box = CGRect(
                x: boxN.origin.x * imageSize.width,
                y: (1 - boxN.origin.y - boxN.size.height) * imageSize.height,
                width: boxN.size.width * imageSize.width,
                height: boxN.size.height * imageSize.height
            )

            // Basic sanity
            if box.width < 3 || box.height < 3 { continue }
            if box.width > 180 || box.height > 220 { continue } // allow tall merged triads

            // Allow broad aspect ratio (merged blobs can be wide or tall)
            let ar = box.width / max(1, box.height)
            if ar < 0.15 || ar > 7.0 { continue }

            // Inflate slightly
            box = box.insetBy(dx: -2, dy: -2)

            out.append(box)
        }

        return out
    }

    // MARK: - Split merged

    private static func splitMergedBoxes(_ boxes: [CGRect], cgImage: CGImage) -> [CGRect] {
        guard !boxes.isEmpty else { return [] }
        var out: [CGRect] = []
        out.reserveCapacity(boxes.count * 2)

        for box in boxes {
            out.append(contentsOf: NoteBlobSplitter.splitIfNeeded(rect: box, cg: cgImage, maxSplits: 6))
        }

        return out
    }

    // MARK: - NMS

    private static func nonMaxSuppression(_ boxes: [CGRect], iouThreshold: CGFloat) -> [CGRect] {
        let sorted = boxes.sorted { ($0.width * $0.height) > ($1.width * $1.height) }
        var kept: [CGRect] = []

        for b in sorted {
            var shouldKeep = true
            for k in kept {
                // Only suppress if they *really* overlap and centers are extremely close
                if iou(b, k) > iouThreshold && centersAreVeryNear(b, k) {
                    shouldKeep = false
                    break
                }
            }
            if shouldKeep { kept.append(b) }
        }
        return kept
    }

    private static func centersAreVeryNear(_ a: CGRect, _ b: CGRect) -> Bool {
        let dx = a.midX - b.midX
        let dy = a.midY - b.midY
        let dist = sqrt(dx * dx + dy * dy)
        let minDim = min(min(a.width, a.height), min(b.width, b.height))
        return dist < max(1.5, minDim * 0.25)
    }

    private static func iou(_ a: CGRect, _ b: CGRect) -> CGFloat {
        let inter = a.intersection(b)
        if inter.isNull { return 0 }
        let interArea = inter.width * inter.height
        let unionArea = a.width * a.height + b.width * b.height - interArea
        return interArea / max(1, unionArea)
    }

    // MARK: - Staff debug detection (rectangles)

    /// Returns rectangles around each staff band (treble/bass systems).
    /// This is intentionally "debug-focused" and favors recall.
    private static func detectStaffRects(inCG cg: CGImage) -> [CGRect] {
        let w = cg.width
        let h = cg.height
        guard w > 0, h > 0 else { return [] }

        // Read pixels
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

        let threshold = 175

        // 1) Find "staff system bands" by horizontal projection
        //    (rows with lots of dark pixels)
        var rowInk = [Int](repeating: 0, count: h)
        for y in 0..<h {
            var s = 0
            // sample every 2px for speed
            var x = 0
            while x < w {
                let i = (y * w + x) * 4
                let lum = (Int(pixels[i]) + Int(pixels[i + 1]) + Int(pixels[i + 2])) / 3
                if lum < threshold { s += 1 }
                x += 2
            }
            rowInk[y] = s
        }

        rowInk = smooth(rowInk, radius: 6)

        // band threshold: keep rows with ink above median (favor recall for debug)
        let med = percentile(rowInk, p: 0.50)
        let bandMin = max(4, Int(Double(med) * 1.2))

        var bands = findBands(rowInk, minVal: bandMin, minHeight: max(24, h / 24))
        let usingFallbackBand = bands.isEmpty
        if usingFallbackBand {
            bands = [(0, max(1, h - 1))]
        }

        var out: [CGRect] = []
        out.reserveCapacity(staffBands.count)

        for (y0, y1) in staffBands {
            let bandH = y1 - y0
            if bandH <= 0 { continue }

            var colInk = [Int](repeating: 0, count: w)

            // sample every 2px vertically for speed
            var y = y0
            while y < y1 {
                var x = 0
                while x < w {
                    let i = (y * w + x) * 4
                    let lum = (Int(pixels[i]) + Int(pixels[i + 1]) + Int(pixels[i + 2])) / 3
                    if lum < threshold { colInk[x] += 1 }
                    x += 1
                }
                y += 2
            }

            colInk = smooth(colInk, radius: 2)

            let maxVal = colInk.max() ?? 0
            if maxVal <= 0 { continue }

            // Barline columns tend to be very strong vertically
            let colMed = percentile(colInk, p: 0.50)
            let barMinMultiplier = usingFallbackBand ? 1.8 : 2.2
            let barMaxFrac = usingFallbackBand ? 0.40 : 0.48
            let barMin = max(Int(Double(colMed) * barMinMultiplier), Int(Double(maxVal) * barMaxFrac))

            // Find contiguous "hot" column runs
            let runs = findRuns(colInk, minVal: barMin, minWidth: 2)

            for r in runs {
                let x0 = CGFloat(r.lowerBound)
                let x1 = CGFloat(r.upperBound)
                let rect = CGRect(
                    x: x0 - 1,
                    y: CGFloat(y0) - 2,
                    width: (x1 - x0) + 2,
                    height: CGFloat((y1 - y0) + 4)
                )
                out.append(rect)
            }
        }

        return out
    }

    // MARK: - Band helpers

    private static func findBands(_ rowInk: [Int], minVal: Int, minHeight: Int) -> [(Int, Int)] {
        var bands: [(Int, Int)] = []
        var i = 0
        while i < rowInk.count {
            if rowInk[i] >= minVal {
                let start = i
                var end = i
                while end < rowInk.count && rowInk[end] >= minVal { end += 1 }
                if end - start >= minHeight {
                    bands.append((max(0, start - 6), min(rowInk.count - 1, end + 6)))
                }
                i = end
            } else {
                i += 1
            }
        }
        return bands
    }

    private static func mergeBands(_ bands: [(Int, Int)], gap: Int) -> [(Int, Int)] {
        guard !bands.isEmpty else { return [] }
        let sorted = bands.sorted { $0.0 < $1.0 }
        var out: [(Int, Int)] = [sorted[0]]

        for b in sorted.dropFirst() {
            var last = out.removeLast()
            if b.0 <= last.1 + gap {
                last.1 = max(last.1, b.1)
                out.append(last)
            } else {
                out.append(last)
                out.append(b)
            }
        }
        return out
    }

    // MARK: - Shared small helpers

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

    /// p in [0,1]
    private static func percentile(_ arr: [Int], p: Double) -> Int {
        guard !arr.isEmpty else { return 0 }
        let sorted = arr.sorted()
        let idx = Int((Double(sorted.count - 1) * min(max(p, 0.0), 1.0)).rounded())
        return sorted[max(0, min(sorted.count - 1, idx))]
    }
}
