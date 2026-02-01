import Foundation
import PDFKit
import Vision

#if canImport(UIKit)
import UIKit
public typealias PlatformImage = UIImage
public typealias PlatformColor = UIColor
#elseif canImport(AppKit)
import AppKit
public typealias PlatformImage = NSImage
public typealias PlatformColor = NSColor
#endif


enum NoteheadDetector {

    static func detectNoteheads(in image: UIImage) async -> [CGRect] {
        guard let cg = image.cgImage else { return [] }

        return await withCheckedContinuation { continuation in
            let request = VNDetectContoursRequest { req, err in
                guard err == nil else {
                    continuation.resume(returning: [])
                    return
                }

                guard let obs = req.results?.first as? VNContoursObservation else {
                    continuation.resume(returning: [])
                    return
                }

                let boxes = extractEllipseLikeBoxes(from: obs, imageSize: image.size)
                continuation.resume(returning: nonMaxSuppression(boxes, iouThreshold: 0.35))
            }

            request.contrastAdjustment = 1.0
            request.detectsDarkOnLight = true

            let handler = VNImageRequestHandler(cgImage: cg, orientation: .up, options: [:])
            DispatchQueue.global(qos: .userInitiated).async {
                do {
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
        let all = (0..<obs.contourCount).compactMap { obs.contour(at: $0) }

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

            // Heuristics: notehead-ish size
            if box.width < 6 || box.height < 6 { continue }
            if box.width > 60 || box.height > 60 { continue }

            // Heuristic: ellipse-ish aspect ratio (noteheads are oval)
            let ar = box.width / max(1, box.height)
            if ar < 0.55 || ar > 2.2 { continue }

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
}
