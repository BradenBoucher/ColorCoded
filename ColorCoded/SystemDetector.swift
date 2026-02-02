import Foundation
import PDFKit
@preconcurrency import Vision

#if canImport(UIKit)
import UIKit
#endif

enum OfflineScoreColorizer {

    enum ColorizeError: LocalizedError {
        case cannotOpenPDF
        case cannotRenderPage
        case cannotWriteOutput

        var errorDescription: String? {
            switch self {
            case .cannotOpenPDF: return "Could not open the PDF."
            case .cannotRenderPage: return "Could not render one of the pages."
            case .cannotWriteOutput: return "Could not write the output PDF."
            }
        }
    }

    static func colorizePDF(inputURL: URL) async throws -> URL {
        guard let doc = PDFDocument(url: inputURL) else { throw ColorizeError.cannotOpenPDF }

        let outDoc = PDFDocument()

        for pageIndex in 0..<doc.pageCount {
            try await withCheckedThrowingContinuation { continuation in
                autoreleasepool {
                    guard let page = doc.page(at: pageIndex) else {
                        continuation.resume(returning: ())
                        return
                    }

                    guard let image = render(page: page, scale: 2.0) else {
                        continuation.resume(throwing: ColorizeError.cannotRenderPage)
                        return
                    }

                    Task {
                        let staffModel = await StaffDetector.detectStaff(in: image)
                        let systems = SystemDetector.buildSystems(from: staffModel, imageSize: image.size)

                        // High recall note candidates
                        let detection = await NoteheadDetector.detectDebug(in: image)

                        // Barlines (still useful for symbol zone and later suppression)
                        let barlines = image.cgImageSafe.map { BarlineDetector.detectBarlines(in: $0, systems: systems) } ?? []

                        let filtered = filterNoteheadsHighRecall(
                            detection.noteRects,
                            systems: systems,
                            barlines: barlines,
                            fallbackSpacing: staffModel?.lineSpacing ?? 12.0,
                            cgImage: image.cgImageSafe
                        )

                        let colored = drawOverlays(
                            on: image,
                            staff: staffModel,
                            noteheads: filtered,
                            barlines: barlines
                        )

                        if let pdfPage = PDFPage(image: colored) {
                            outDoc.insert(pdfPage, at: outDoc.pageCount)
                        }
                        continuation.resume(returning: ())
                    }
                }
            }
        }

        let outURL = FileManager.default.temporaryDirectory
            .appendingPathComponent("colored-offline-\(UUID().uuidString).pdf")

        guard outDoc.write(to: outURL) else { throw ColorizeError.cannotWriteOutput }
        return outURL
    }

    // MARK: - Render PDF page

    private static func render(page: PDFPage, scale: CGFloat) -> PlatformImage? {
        let bounds = page.bounds(for: .mediaBox)

        let maxLongSide: CGFloat = 2200
        let baseW = bounds.width
        let baseH = bounds.height

        var s = scale
        let longSide = max(baseW, baseH) * s
        if longSide > maxLongSide {
            s *= (maxLongSide / longSide)
        }
        s = max(1.0, s)

        let size = CGSize(width: baseW * s, height: baseH * s)

        let format = UIGraphicsImageRendererFormat()
        format.opaque = true
        format.scale = 1.0

        let renderer = UIGraphicsImageRenderer(size: size, format: format)
        return renderer.image { ctx in
            UIColor.white.setFill()
            ctx.fill(CGRect(origin: .zero, size: size))

            ctx.cgContext.saveGState()
            ctx.cgContext.scaleBy(x: s, y: s)

            ctx.cgContext.translateBy(x: 0, y: bounds.height)
            ctx.cgContext.scaleBy(x: 1, y: -1)

            page.draw(with: .mediaBox, to: ctx.cgContext)
            ctx.cgContext.restoreGState()
        }
    }

    // MARK: - Filtering (high recall, noise suppression)

    private static func filterNoteheadsHighRecall(_ noteheads: [CGRect],
                                                  systems: [SystemBlock],
                                                  barlines: [CGRect],
                                                  fallbackSpacing: CGFloat,
                                                  cgImage: CGImage?) -> [CGRect] {
        guard !noteheads.isEmpty else { return [] }

        // If systems not found, only do dedupe (avoid losing notes)
        guard !systems.isEmpty else {
            return DuplicateSuppressor.suppress(noteheads, spacing: fallbackSpacing)
        }

        // Optional binary for “best-in-cluster” ranking (not hard rejection)
        let binaryPage: ([UInt8], Int, Int)? = {
            guard let cgImage else { return nil }
            return buildBinaryInkMap(from: cgImage, lumThreshold: 175)
        }()

        var out: [CGRect] = []
        var consumed = Set<Int>()

        for system in systems {
            let spacing = max(6.0, system.spacing)

            // Barlines inside system (x positions)
            let barlineXs = barlines
                .filter { $0.maxY >= system.bbox.minY && $0.minY <= system.bbox.maxY }
                .map { $0.midX }

            // Symbol zone: exclude clef/key/time region.
            // Keep this fairly wide; it reduces a lot of noise without risking misses.
            let symbolZone: CGRect = {
                let bbox = system.bbox
                let baseWidth = max(12.0, spacing * 7.5)
                var zone = CGRect(x: bbox.minX, y: bbox.minY, width: min(baseWidth, bbox.width * 0.33), height: bbox.height)

                // Expand to first barline if it exists
                let candidates = barlines.filter { br in
                    br.maxY >= bbox.minY && br.minY <= bbox.maxY && br.maxX > bbox.minX && br.minX < bbox.maxX
                }
                if let nearest = candidates.min(by: { $0.minX < $1.minX }) {
                    let clampedX = max(bbox.minX, min(nearest.minX, bbox.maxX))
                    zone.size.width = max(zone.width, clampedX - bbox.minX)
                }
                return zone
            }()

            // Grab note candidates whose centers fall in system bbox
            let systemRects: [CGRect] = noteheads.enumerated().compactMap { idx, r in
                let c = CGPoint(x: r.midX, y: r.midY)
                guard system.bbox.contains(c) else { return nil }
                consumed.insert(idx)
                return r
            }

            // Remove symbols region only (safe)
            let noSymbols = systemRects.filter { r in
                !symbolZone.contains(CGPoint(x: r.midX, y: r.midY))
            }

            // Staff step gate (keep high recall by letting it decide tolerance)
            let scored = noSymbols.map { ScoredHead(rect: $0) }
            let gated = StaffStepGate.filterCandidates(scored, system: system)
            let gatedRects = gated.map { $0.rect }

            // NEW: cluster reduce (keeps at least 1 per cluster, reduces duplicates & tails)
            let reduced = reduceClustersKeepBest(
                gatedRects,
                spacing: spacing,
                barlineXs: barlineXs,
                binaryPage: binaryPage
            )

            // Final light dedupe
            let deduped = DuplicateSuppressor.suppress(reduced, spacing: spacing)
            out.append(contentsOf: deduped)
        }

        // Remaining outside systems: do not filter hard; only dedupe
        if consumed.count < noteheads.count {
            let remaining = noteheads.enumerated().compactMap { idx, r -> CGRect? in
                guard !consumed.contains(idx) else { return nil }
                return r
            }
            out.append(contentsOf: DuplicateSuppressor.suppress(remaining, spacing: fallbackSpacing))
        }

        return out
    }

    /// Cluster candidates by proximity and keep the “best” in each cluster.
    /// This is intentionally non-destructive: it reduces duplicates/noise without dropping isolated true notes.
    private static func reduceClustersKeepBest(_ rects: [CGRect],
                                               spacing: CGFloat,
                                               barlineXs: [CGFloat],
                                               binaryPage: ([UInt8], Int, Int)?) -> [CGRect] {
        guard rects.count > 1 else { return rects }

        // Cluster radius: close candidates belong together
        let r = max(2.0, spacing * 0.40)
        let r2 = r * r

        // Simple union-find clustering
        let n = rects.count
        var parent = Array(0..<n)

        func find(_ a: Int) -> Int {
            var x = a
            while parent[x] != x {
                parent[x] = parent[parent[x]]
                x = parent[x]
            }
            return x
        }

        func union(_ a: Int, _ b: Int) {
            let ra = find(a)
            let rb = find(b)
            if ra != rb { parent[rb] = ra }
        }

        let centers = rects.map { CGPoint(x: $0.midX, y: $0.midY) }

        for i in 0..<n {
            for j in (i+1)..<n {
                let dx = centers[i].x - centers[j].x
                let dy = centers[i].y - centers[j].y
                if dx*dx + dy*dy <= r2 {
                    union(i, j)
                }
            }
        }

        // Group indices by root
        var groups: [Int: [Int]] = [:]
        groups.reserveCapacity(n)
        for i in 0..<n {
            groups[find(i), default: []].append(i)
        }

        // Pick best per group using a soft “notehead-likeness” score
        var kept: [CGRect] = []
        kept.reserveCapacity(groups.count)

        for (_, idxs) in groups {
            if idxs.count == 1 {
                kept.append(rects[idxs[0]])
                continue
            }

            var bestIdx = idxs[0]
            var bestScore = -Double.infinity

            for k in idxs {
                let rect = rects[k]
                let score = rankRect(rect, spacing: spacing, barlineXs: barlineXs, binaryPage: binaryPage)
                if score > bestScore {
                    bestScore = score
                    bestIdx = k
                }
            }

            kept.append(rects[bestIdx])
        }

        return kept
    }

    /// Ranking function: higher = more notehead-like.
    /// This NEVER hard-rejects; it only helps choose one candidate among near-duplicates.
    private static func rankRect(_ rect: CGRect,
                                 spacing: CGFloat,
                                 barlineXs: [CGFloat],
                                 binaryPage: ([UInt8], Int, Int)?) -> Double {
        let w = Double(rect.width)
        let h = Double(rect.height)

        // Prefer notehead-ish size
        let target = Double(spacing * 0.90)
        let sizeErr = abs(h - target) / max(1.0, target)
        var s = 1.0 - min(1.0, sizeErr) // 0..1

        // Prefer not-too-thin shapes
        let aspect = w / max(1e-6, h)
        let aspectCenter = 1.20
        let aspectPenalty = abs(aspect - aspectCenter) / aspectCenter
        s *= (1.0 - min(0.8, aspectPenalty))

        // Soft penalty if sitting right on a barline x
        if !barlineXs.isEmpty {
            let cx = Double(rect.midX)
            let near = barlineXs.contains { abs(Double($0) - cx) < Double(0.18 * spacing) }
            if near { s *= 0.75 }
        }

        // Extent boost if we have binary
        if let binaryPage {
            let (bin, pageW, pageH) = binaryPage
            let ext = Double(rectInkExtent(rect, bin: bin, pageW: pageW, pageH: pageH))
            // noteheads tend to be “moderately filled” — boost around ~0.35–0.65
            let extBoost = 1.0 - min(1.0, abs(ext - 0.50) / 0.35)
            s *= (0.75 + 0.25 * extBoost)
        }

        // Tiny boost for tighter boxes (often better than huge blobs)
        let area = w * h
        s *= 1.0 / (1.0 + 0.001 * area)

        return s
    }

    // MARK: - Draw overlays

    private static func drawOverlays(on image: PlatformImage,
                                     staff: StaffModel?,
                                     noteheads: [CGRect],
                                     barlines: [CGRect]) -> PlatformImage {
        let renderer = UIGraphicsImageRenderer(size: image.size)
        return renderer.image { ctx in
            image.draw(at: .zero)
            ctx.cgContext.setAlpha(0.85)

            let baseRadius = max(6.0, (staff?.lineSpacing ?? 12.0) * 0.75)

            for rect in noteheads {
                let center = CGPoint(x: rect.midX, y: rect.midY)
                let radius = baseRadius

                let pitchClass = PitchClassifier.classify(noteCenterY: center.y, staff: staff)
                let color = pitchClass.color

                ctx.cgContext.setStrokeColor(color.withAlphaComponent(0.75).cgColor)
                ctx.cgContext.setLineWidth(max(2.0, radius * 0.18))
                ctx.cgContext.strokeEllipse(in: CGRect(x: center.x - radius,
                                                       y: center.y - radius,
                                                       width: radius * 2,
                                                       height: radius * 2))

                ctx.cgContext.setFillColor(color.withAlphaComponent(0.65).cgColor)
                let dotR = max(2.5, radius * 0.20)
                ctx.cgContext.fillEllipse(in: CGRect(x: center.x - dotR,
                                                     y: center.y - dotR,
                                                     width: dotR * 2,
                                                     height: dotR * 2))
            }

            if !barlines.isEmpty {
                ctx.cgContext.setLineWidth(max(1.5, baseRadius * 0.12))
                ctx.cgContext.setStrokeColor(UIColor.systemTeal.withAlphaComponent(0.55).cgColor)
                for rect in barlines { ctx.cgContext.stroke(rect) }
            }
        }
    }

    // MARK: - Binary helpers

    private static func buildBinaryInkMap(from cg: CGImage, lumThreshold: Int) -> ([UInt8], Int, Int) {
        let w = cg.width
        let h = cg.height

        var rgba = [UInt8](repeating: 0, count: w * h * 4)
        let cs = CGColorSpaceCreateDeviceRGB()
        let bpr = w * 4

        let ctx = CGContext(
            data: &rgba,
            width: w,
            height: h,
            bitsPerComponent: 8,
            bytesPerRow: bpr,
            space: cs,
            bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue
        )!

        ctx.draw(cg, in: CGRect(x: 0, y: 0, width: w, height: h))

        var bin = [UInt8](repeating: 0, count: w * h)
        for y in 0..<h {
            let row = y * w
            let rowRGBA = y * bpr
            for x in 0..<w {
                let i = rowRGBA + x * 4
                let lum = (Int(rgba[i]) + Int(rgba[i + 1]) + Int(rgba[i + 2])) / 3
                bin[row + x] = (lum < lumThreshold) ? 1 : 0
            }
        }
        return (bin, w, h)
    }

    private static func rectInkExtent(_ rect: CGRect, bin: [UInt8], pageW: Int, pageH: Int) -> CGFloat {
        let clipped = rect.intersection(CGRect(x: 0, y: 0, width: pageW, height: pageH))
        guard clipped.width > 0, clipped.height > 0 else { return 0 }

        let x0 = max(0, Int(floor(clipped.minX)))
        let y0 = max(0, Int(floor(clipped.minY)))
        let x1 = min(pageW, Int(ceil(clipped.maxX)))
        let y1 = min(pageH, Int(ceil(clipped.maxY)))

        var ink = 0
        for y in y0..<y1 {
            let row = y * pageW
            for x in x0..<x1 {
                if bin[row + x] != 0 { ink += 1 }
            }
        }
        let area = max(1, (x1 - x0) * (y1 - y0))
        return CGFloat(ink) / CGFloat(area)
    }
}
