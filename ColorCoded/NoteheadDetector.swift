import Foundation
@preconcurrency import Vision
import CoreGraphics

enum NoteheadDetector {

    static func detectNoteheads(in image: PlatformImage) async -> [CGRect] {
        guard let cg = image.cgImageSafe else { return [] }

        // Use CGImage dimensions so we don't depend on UIKit/AppKit .size
        let imageSize = CGSize(width: cg.width, height: cg.height)

        return await withCheckedContinuation { continuation in
            DispatchQueue.global(qos: .userInitiated).async {
                do {
                    let request = VNDetectContoursRequest { req, err in
                        guard err == nil else {
                            continuation.resume(returning: [])
                            return
                        }

                        guard let obs = req.results?.first as? VNContoursObservation else {
                            continuation.resume(returning: [])
                            return
                        }

                        let boxes = extractCandidateBoxes(from: obs, imageSize: imageSize)

                        // Split merged blobs
                        let split = splitMergedBoxes(boxes, cgImage: cg)

                        // NMS to reduce duplicates (keep close notes)
                        let out = nonMaxSuppression(split, iouThreshold: 0.85)

                        continuation.resume(returning: out)
                    }

                    request.contrastAdjustment = 1.2
                    request.detectsDarkOnLight = true

                    let handler = VNImageRequestHandler(cgImage: cg, orientation: .up, options: [:])
                    try handler.perform([request])
                } catch {
                    continuation.resume(returning: [])
                }
            }
        }
    }

    /// Very recall-heavy candidate extraction.
    /// We let splitter + NMS handle cleanup.
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
            if box.width > 140 || box.height > 140 { continue }

            // Allow broad aspect ratio (merged blobs can be wide)
            let ar = box.width / max(1, box.height)
            if ar < 0.25 || ar > 6.0 { continue }

            // Inflate slightly
            box = box.insetBy(dx: -2, dy: -2)

            out.append(box)
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
                if iou(b, k) > iouThreshold {
                    shouldKeep = false
                    break
                }
            }
            if shouldKeep { kept.append(b) }
        }
        return kept
    }

    private static func iou(_ a: CGRect, _ b: CGRect) -> CGFloat {
        let inter = a.intersection(b)
        if inter.isNull { return 0 }
        let interArea = inter.width * inter.height
        let unionArea = a.width * a.height + b.width * b.height - interArea
        return interArea / max(1, unionArea)
    }

    private static func splitMergedBoxes(_ boxes: [CGRect], cgImage: CGImage) -> [CGRect] {
        guard !boxes.isEmpty else { return [] }
        var out: [CGRect] = []
        out.reserveCapacity(boxes.count * 2)

        for box in boxes {
            out.append(contentsOf: NoteBlobSplitter.splitIfNeeded(rect: box, cg: cgImage, maxSplits: 6))
        }

        return out
    }
}
