import Foundation
import PDFKit
@preconcurrency import Vision


enum NoteheadDetector {

    static func detectNoteheads(in image: PlatformImage) async -> [CGRect] {
        guard let cg = image.cgImageSafe else { return [] }
        let imageSize = image.size
        let processed = ImagePreprocessor.preprocessForContours(cg) ?? cg

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

                        let boxes = extractEllipseLikeBoxes(from: obs, imageSize: imageSize)
                        let split = splitMergedBoxes(boxes, cgImage: cg)
                        continuation.resume(returning: nonMaxSuppression(split, iouThreshold: 0.35))
                    }

                    request.contrastAdjustment = 1.0
                    request.detectsDarkOnLight = true

                    let handler = VNImageRequestHandler(cgImage: processed, orientation: .up, options: [:])
                    try handler.perform([request])
                } catch {
                    continuation.resume(returning: [])
                }
            }
        }
    }

    private static func extractEllipseLikeBoxes(from obs: VNContoursObservation,
                                               imageSize: CGSize) -> [CGRect] {
        var out: [CGRect] = []

        // Pull top-level contours and child contours; noteheads often appear as small closed shapes.
        let all = (0..<obs.contourCount).compactMap { try? obs.contour(at: $0) }

        for c in all {
            // VNContour points are normalized (0..1). Convert to image coords.
            let boxN = c.normalizedPath.boundingBox

            // Convert to UIKit coords (Vision origin is lower-left)
            let box = CGRect(
                x: boxN.origin.x * imageSize.width,
                y: (1 - boxN.origin.y - boxN.size.height) * imageSize.height,
                width: boxN.size.width * imageSize.width,
                height: boxN.size.height * imageSize.height
            )

            // Heuristics: notehead-ish size (looser to keep recall high)
            if box.width < 4 || box.height < 4 { continue }
            if box.width > 90 || box.height > 90 { continue }

            // Heuristic: oval-ish aspect ratio, but allow wider for merged noteheads
            let ar = box.width / max(1, box.height)
            if ar < 0.4 || ar > 3.5 { continue }

            out.append(box.insetBy(dx: -1, dy: -1))
        }

        return out
    }

    // MARK: - NMS

    private static func nonMaxSuppression(_ boxes: [CGRect], iouThreshold: CGFloat) -> [CGRect] {
        // simple: keep larger boxes first
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
        out.reserveCapacity(boxes.count)

        for box in boxes {
            out.append(contentsOf: NoteBlobSplitter.splitIfNeeded(rect: box, cg: cgImage))
        }

        return out
    }
}
