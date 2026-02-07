import Foundation
@preconcurrency import Vision
import CoreGraphics
import OSLog

enum NoteheadDetector {
    private static let log = Logger(subsystem: "ColorCoded", category: "NoteheadDetector")

    // MARK: - Public

    /// Production: just notehead rects
    static func detectNoteheads(
        in image: PlatformImage,
        contoursBinaryOverride: ([UInt8], Int, Int)? = nil,
        systems: [SystemBlock]? = nil
    ) async -> [CGRect] {
        let result = await detectDebug(
            in: image,
            contoursBinaryOverride: contoursBinaryOverride,
            systems: systems
        )
        return result.noteRects
    }

    /// Debug: noteheads + staff rectangles (optional – you can keep returning empty staffRects)
    static func detectDebug(
        in image: PlatformImage,
        contoursBinaryOverride: ([UInt8], Int, Int)? = nil,
        systems: [SystemBlock]? = nil
    ) async -> (noteRects: [CGRect], staffRects: [CGRect]) {

        // ------------------------------------------------------------
        // PATH A: caller provides a binary ink map (recommended)
        // ------------------------------------------------------------
        if let (binary, width, height) = contoursBinaryOverride {

            let imgRect = CGRect(x: 0, y: 0, width: width, height: height)
            let sysBlocks = systems ?? []

            // Build ROIs (system bbox expanded a bit)
            let rois: [(system: SystemBlock?, roi: CGRect, spacing: CGFloat)] = {
                if sysBlocks.isEmpty {
                    return [(nil, imgRect, 12.0)]
                } else {
                    return sysBlocks.map { s in
                        let expand = max(6.0, s.spacing * 1.5)
                        let roi = s.bbox.insetBy(dx: -expand, dy: -expand).intersection(imgRect)
                        return (s, roi, max(6.0, s.spacing))
                    }
                }
            }()

            let barlines: [CGRect] = [] // binary-only path keeps empty for now

            // Connected components inside each ROI
            let cclStart = CFAbsoluteTimeGetCurrent()
            var scratch = BinaryConnectedComponents.Scratch()
            var components: [BinaryConnectedComponents.Component] = []
            components.reserveCapacity(1024)

            for (_, roi, _) in rois {
                let roiComponents = BinaryConnectedComponents.label(
                    binary: binary,
                    width: width,
                    height: height,
                    roi: roi,
                    scratch: &scratch
                )
                components.append(contentsOf: roiComponents)
            }

            let cclMs = (CFAbsoluteTimeGetCurrent() - cclStart) * 1000.0
            log.notice("PERF cclMs=\(String(format: "%.1f", cclMs), privacy: .public) comps=\(components.count, privacy: .public)")

            // Convert components -> boxes (slight pad for safety)
            var boxes = components.map { $0.rect.insetBy(dx: -2, dy: -2) }
            boxes = boxes.map { $0.intersection(imgRect) }.filter { !$0.isNull && $0.width >= 3 && $0.height >= 3 }

            // Split merged blobs (chords)
            let splitStart = CFAbsoluteTimeGetCurrent()
            let split = splitMergedBoxes(boxes, binary: binary, width: width, height: height)
            let splitMs = (CFAbsoluteTimeGetCurrent() - splitStart) * 1000.0
            log.notice("PERF splitMs=\(String(format: "%.1f", splitMs), privacy: .public) split=\(split.count, privacy: .public)")

            // Score + gate per-system if systems exist, else do global scoring
            let scoreStart = CFAbsoluteTimeGetCurrent()
            var scoredAll: [ScoredHead] = []
            scoredAll.reserveCapacity(split.count)

            if sysBlocks.isEmpty {
                let spacingGuess: CGFloat = 12.0
                let roi = imgRect

                let minRun = max(6, Int((0.55 * spacingGuess).rounded()))
                let vMask = VerticalStrokeMask.build(
                    from: binary,
                    width: width,
                    height: height,
                    roi: roi,
                    minRun: minRun
                )

                var local: [ScoredHead] = []
                local.reserveCapacity(split.count)

                for r in split {
                    var s = ScoredHead(rect: r)
                    computeShapeMetrics(&s, binary: binary, width: width, height: height, strokeMask: vMask)
                    if hardRejectTailOrStem(s, spacing: spacingGuess) { continue }
                    if overlapsAny(r, barlines, minIoU: 0.20) { continue }
                    local.append(s)
                }

                // ✅ actually suppress tiny clusters
                local = ClusterSuppressor.suppress(local, spacing: spacingGuess)
                scoredAll.append(contentsOf: local)

            } else {
                // Systems path: build stroke mask per ROI + staff-step gate
                for (sysOpt, roi, spacing) in rois {
                    guard let system = sysOpt else { continue }

                    let minRun = max(6, Int((0.55 * spacing).rounded()))
                    let vMask = VerticalStrokeMask.build(
                        from: binary,
                        width: width,
                        height: height,
                        roi: roi,
                        minRun: minRun
                    )

                    let localRects = split.filter { $0.intersects(roi) }
                    if localRects.isEmpty { continue }

                    var candidates: [ScoredHead] = localRects.map { ScoredHead(rect: $0) }

                    candidates = StaffStepGate.filterCandidates(
                        candidates,
                        system: system,
                        softTolerance: 0.50,
                        hardTolerance: 0.68,
                        maxSteps: 28,
                        preferBassInGap: true
                    )

                    var kept: [ScoredHead] = []
                    kept.reserveCapacity(candidates.count)

                    for var c in candidates {
                        computeShapeMetrics(&c, binary: binary, width: width, height: height, strokeMask: vMask)

                        if overlapsAny(c.rect, barlines, minIoU: 0.20) { continue }
                        if hardRejectTailOrStem(c, spacing: spacing) { continue }

                        kept.append(c)
                    }

                    // ✅ suppress tiny clusters per-system
                    kept = ClusterSuppressor.suppress(kept, spacing: spacing)
                    scoredAll.append(contentsOf: kept)
                }
            }

            let scoreMs = (CFAbsoluteTimeGetCurrent() - scoreStart) * 1000.0
            log.notice("PERF scoreMs=\(String(format: "%.1f", scoreMs), privacy: .public) scored=\(scoredAll.count, privacy: .public)")

            // Final suppression based on compositeScore (not area)
            let nmsStart = CFAbsoluteTimeGetCurrent()
            let final = scoredNMS(scoredAll, iouThreshold: 0.72)
            let nmsMs = (CFAbsoluteTimeGetCurrent() - nmsStart) * 1000.0
            log.notice("PERF nmsMs=\(String(format: "%.1f", nmsMs), privacy: .public) final=\(final.count, privacy: .public)")

            // Deterministic ordering (helps downstream if someone assumes order)
            let rects = final.map { $0.rect }.sorted {
                if $0.midY != $1.midY { return $0.midY < $1.midY }
                return $0.midX < $1.midX
            }

            return (rects, [])
        }

        // ------------------------------------------------------------
        // PATH B: Vision-contours-only fallback
        // ------------------------------------------------------------
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

                        let boxes = extractCandidateBoxes(from: obs, imageSize: imageSize)
                        let split = splitMergedBoxes(boxes, cgImage: cg)
                        let notes = nonMaxSuppression(split, iouThreshold: 0.78)

                        let sorted = notes.sorted {
                            if $0.midY != $1.midY { return $0.midY < $1.midY }
                            return $0.midX < $1.midX
                        }

                        continuation.resume(returning: (sorted, []))
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

    // MARK: - Candidate extraction (Vision path)

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
            if box.width > imageSize.width * 0.85 { continue }
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

    private static func splitMergedBoxes(
        _ boxes: [CGRect],
        binary: [UInt8],
        width: Int,
        height: Int
    ) -> [CGRect] {
        guard !boxes.isEmpty else { return [] }
        var out: [CGRect] = []
        out.reserveCapacity(boxes.count * 2)

        for box in boxes {
            out.append(
                contentsOf: NoteBlobSplitter.splitIfNeeded(
                    rect: box,
                    binary: binary,
                    width: width,
                    height: height,
                    maxSplits: 6
                )
            )
        }
        return out
    }

    // MARK: - Shape metrics + hard reject

    private static func computeShapeMetrics(
        _ head: inout ScoredHead,
        binary: [UInt8],
        width: Int,
        height: Int,
        strokeMask: VerticalStrokeMask?
    ) {
        let imgRect = CGRect(x: 0, y: 0, width: width, height: height)
        let r = head.rect.intersection(imgRect).integral
        guard r.width >= 2, r.height >= 2 else {
            head.shapeScore = 0
            head.isHeadLike = false
            head.inkExtent = 0
            head.strokeOverlap = 0
            return
        }

        let x0 = max(0, Int(r.minX))
        let y0 = max(0, Int(r.minY))
        let x1 = min(width - 1, Int(r.maxX))
        let y1 = min(height - 1, Int(r.maxY))

        let area = max(1, (x1 - x0 + 1) * (y1 - y0 + 1))

        var ink = 0
        var yy = y0
        while yy <= y1 {
            let row = yy * width
            var xx = x0
            while xx <= x1 {
                if binary[row + xx] != 0 { ink += 1 }
                xx += 1
            }
            yy += 1
        }

        let inkFrac = CGFloat(ink) / CGFloat(area)
        head.inkExtent = inkFrac

        let strokeOv: CGFloat = {
            guard let strokeMask else { return 0 }
            return strokeMask.overlapRatio(with: r)
        }()
        head.strokeOverlap = strokeOv

        let w = CGFloat(r.width)
        let h = CGFloat(r.height)
        let ar = w / max(1, h)

        let arScore: CGFloat = {
            if ar < 0.35 { return 0.0 }
            if ar > 2.70 { return 0.0 }
            let d = abs(ar - 1.10)
            return max(0, 1.0 - d / 1.35)
        }()

        let fillScore: CGFloat = {
            if inkFrac < 0.03 { return 0.0 }
            if inkFrac > 0.85 { return 0.10 }
            if inkFrac <= 0.50 {
                return max(0, (inkFrac - 0.03) / 0.47)
            } else {
                return max(0, 1.0 - (inkFrac - 0.50) / 0.35)
            }
        }()

        let strokePenalty = min(1.0, strokeOv / 0.55)
        let strokeScore = max(0, 1.0 - strokePenalty)

        let shape = (arScore * 0.45) + (fillScore * 0.35) + (strokeScore * 0.20)
        head.shapeScore = max(0, min(1, shape))
        head.isHeadLike = head.shapeScore >= 0.30
    }

    private static func hardRejectTailOrStem(_ h: ScoredHead, spacing: CGFloat) -> Bool {
        let w = h.rect.width
        let hh = h.rect.height
        let ar = w / max(1, hh)

        let stroke = h.strokeOverlap ?? 0
        let ink = h.inkExtent ?? 0

        if stroke >= 0.65 && ar < 0.60 { return true }
        if ar < 0.38 && ink < 0.18 { return true }

        let area = w * hh
        if area < max(12.0, spacing * spacing * 0.06), ink < 0.30, stroke > 0.12 {
            return true
        }

        return false
    }

    // MARK: - Scored NMS

    private static func scoredNMS(_ heads: [ScoredHead], iouThreshold: CGFloat) -> [ScoredHead] {
        guard heads.count > 1 else { return heads }

        let sorted = heads.sorted { $0.compositeScore > $1.compositeScore }
        var kept: [ScoredHead] = []
        kept.reserveCapacity(sorted.count)

        for h in sorted {
            var ok = true
            for k in kept {
                if iou(h.rect, k.rect) > iouThreshold && centersAreNear(h.rect, k.rect) {
                    ok = false
                    break
                }
            }
            if ok { kept.append(h) }
        }
        return kept
    }

    private static func centersAreNear(_ a: CGRect, _ b: CGRect) -> Bool {
        let dx = a.midX - b.midX
        let dy = a.midY - b.midY
        let dist = sqrt(dx * dx + dy * dy)
        let minDim = min(min(a.width, a.height), min(b.width, b.height))
        return dist < max(2.0, minDim * 0.35)
    }

    private static func overlapsAny(_ rect: CGRect, _ others: [CGRect], minIoU: CGFloat) -> Bool {
        guard !others.isEmpty else { return false }
        for o in others {
            if iou(rect, o) >= minIoU { return true }
        }
        return false
    }

    private static func iou(_ a: CGRect, _ b: CGRect) -> CGFloat {
        let inter = a.intersection(b)
        if inter.isNull { return 0 }
        let ia = inter.width * inter.height
        let ua = a.width * a.height + b.width * b.height - ia
        return ia / max(1, ua)
    }

    // MARK: - Old NMS fallback (Vision path)

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
}
