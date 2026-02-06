import Foundation
@preconcurrency import Vision
import CoreGraphics

enum NoteheadDetector {

    // MARK: - Public

    /// Production: just notehead rects
    static func detectNoteheads(
        in image: PlatformImage,
        contoursBinaryOverride: ([UInt8], Int, Int)? = nil
    ) async -> [CGRect] {
        let result = await detectDebug(in: image, contoursBinaryOverride: contoursBinaryOverride)
        return result.noteRects
    }

    /// Debug: noteheads + staff rectangles (treble/bass systems).
    static func detectDebug(
        in image: PlatformImage,
        contoursBinaryOverride: ([UInt8], Int, Int)? = nil
    ) async -> (noteRects: [CGRect], staffRects: [CGRect]) {

        // Use override if provided; otherwise use the original image CG
        let baseCG: CGImage? =
            contoursBinaryOverride.flatMap { cgImageFromBinary($0) }
            ?? image.cgImageSafe

        guard let cg = baseCG else { return ([], []) }

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

                        // Split merged blobs
                        let split = splitMergedBoxes(boxes, cgImage: cg)

                        // Reduce duplicates, but keep close stacked notes
                        let notes = nonMaxSuppression(split, iouThreshold: 0.78)

                        // Staff debug rectangles (optional)
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

    // MARK: - Binary -> CGImage helper

    private static func cgImageFromBinary(_ binary: ([UInt8], Int, Int)) -> CGImage? {
        let (pixels, width, height) = binary
        guard width > 0, height > 0, pixels.count >= width * height else { return nil }

        let bytesPerRow = width
        let colorSpace = CGColorSpaceCreateDeviceGray()

        return pixels.withUnsafeBytes { ptr in
            guard let base = ptr.baseAddress else { return nil }
            guard let provider = CGDataProvider(data: NSData(bytes: base, length: pixels.count)) else { return nil }

            return CGImage(
                width: width,
                height: height,
                bitsPerComponent: 8,
                bitsPerPixel: 8,
                bytesPerRow: bytesPerRow,
                space: colorSpace,
                bitmapInfo: CGBitmapInfo(rawValue: CGImageAlphaInfo.none.rawValue),
                provider: provider,
                decode: nil,
                shouldInterpolate: false,
                intent: .defaultIntent
            )
        }
    }

    // MARK: - Candidate extraction

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

            if box.width < 3 || box.height < 3 { continue }
            //if box.width > 180 || box.height > 220 { continue }
            // OLD:
            // if box.width > 180 || box.height > 220 { continue }

            // NEW (recall-first): allow big merged blobs so the splitter can do its job
            if box.width > imageSize.width * 0.85 { continue }     // only reject absurd full-page blobs
            if box.height > imageSize.height * 0.85 { continue }


            let ar = box.width / max(1, box.height)
            if ar < 0.15 || ar > 7.0 { continue }

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

    // MARK: - Staff debug detection (unchanged, keep yours)

    private static func detectStaffRects(inCG cg: CGImage) -> [CGRect] {
        // Keep your existing implementation here.
        // (I’m leaving it as-is to avoid breaking your debug path.)
        return []
    }
}
