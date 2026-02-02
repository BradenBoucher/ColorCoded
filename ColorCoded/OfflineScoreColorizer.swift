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
        print("Opening PDF at:", inputURL.path)
        print("Exists:", FileManager.default.fileExists(atPath: inputURL.path))
        print("Readable:", FileManager.default.isReadableFile(atPath: inputURL.path))
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
                        let detection = await NoteheadDetector.detectDebug(in: image)
                        let systems = SystemDetector.buildSystems(from: staffModel, imageSize: image.size)
                        let barlines = image.cgImageSafe.map { BarlineDetector.detectBarlines(in: $0, systems: systems) } ?? []

                        let filtered = filterNoteheads(
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

    // MARK: - Render PDF page to UIImage

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

            // PDFKit uses a flipped coordinate system; adjust
            ctx.cgContext.translateBy(x: 0, y: bounds.height)
            ctx.cgContext.scaleBy(x: 1, y: -1)

            page.draw(with: .mediaBox, to: ctx.cgContext)
            ctx.cgContext.restoreGState()
        }
    }

    // MARK: - Draw overlays

    private static func filterNoteheads(_ noteheads: [CGRect],
                                        systems: [SystemBlock],
                                        barlines: [CGRect],
                                        fallbackSpacing: CGFloat,
                                        cgImage: CGImage?) -> [CGRect] {
        guard !noteheads.isEmpty else { return [] }
        guard !systems.isEmpty else {
            return DuplicateSuppressor.suppress(noteheads, spacing: fallbackSpacing)
        }

        let binary = cgImage.flatMap { BinaryImage(from: $0, threshold: 180) }

        var filtered: [CGRect] = []
        var consumed = Set<Int>()

        for system in systems {
            let barlineXs = barlines
                .filter { $0.maxY >= system.bbox.minY && $0.minY <= system.bbox.maxY }
                .map { $0.midX }

            // Derive a symbol zone within this system to exclude clefs, key/time signatures, etc.
            // We approximate by taking a strip from the left side of the system's bbox and extending to any nearby barlines.
            let systemZone: CGRect = {
                let bbox = system.bbox
                // Base zone: a fraction of the system width from the left (e.g., 18% of width)
                let baseWidth = max(12.0, bbox.width * 0.18)
                var zone = CGRect(x: bbox.minX, y: bbox.minY, width: baseWidth, height: bbox.height)

                // If there are barlines inside this system, expand the zone up to the first barline (closest to the left)
                if !barlines.isEmpty {
                    // Consider barlines that intersect vertically with the system bbox and lie within the bbox horizontally
                    let candidates = barlines.filter { br in
                        br.maxY >= bbox.minY && br.minY <= bbox.maxY && br.maxX > bbox.minX && br.minX < bbox.maxX
                    }
                    if let nearest = candidates.min(by: { $0.minX < $1.minX }) {
                        let clampedX = max(bbox.minX, min(nearest.minX, bbox.maxX))
                        let newWidth = max(zone.width, clampedX - bbox.minX)
                        zone.size.width = newWidth
                    }
                }
                return zone
            }()

            let systemNotes = noteheads.enumerated().compactMap { index, rect -> CGRect? in
                guard system.bbox.contains(CGPoint(x: rect.midX, y: rect.midY)) else { return nil }
                consumed.insert(index)
                return rect
            }

            let withoutSymbols = systemNotes.filter { rect in
                let center = CGPoint(x: rect.midX, y: rect.midY)
                return !systemZone.contains(center)
            }

            let verticalMask = binary.flatMap {
                VerticalStrokeMask.build(
                    from: $0.data,
                    width: $0.width,
                    height: $0.height,
                    roi: system.bbox,
                    minRun: max(2, Int((system.spacing * 3.5).rounded(.up)))
                )
            }

            let scored = withoutSymbols.compactMap { rect -> ScoredHead? in
                guard rect.width > 0, rect.height > 0 else { return nil }
                let extent = binary.map { $0.extent(in: rect) } ?? 0.0
                let isStemLike = rect.height > system.spacing * 1.8 && rect.width < system.spacing * 0.6
                let isTieLike = rect.width > system.spacing * 1.8 && rect.height < system.spacing * 0.45
                guard extent >= 0.25, !isStemLike, !isTieLike else { return nil }

                let overlap = verticalMask?.overlapRatio(with: rect) ?? 0.0
                if overlap > 0.22 { return nil }

                var score = max(0, min(1, (extent - 0.18) / 0.40))
                if overlap > 0.10 {
                    score = max(0, score - 0.7)
                }

                let noteheadLike = rect.width >= system.spacing * 0.6 && rect.width <= system.spacing * 1.6
                let nearBarline = barlineXs.contains { abs($0 - rect.midX) <= system.spacing * 0.20 }
                if nearBarline && (!noteheadLike || score < 0.85) {
                    return nil
                }

                return ScoredHead(rect: rect, score: score)
            }

            let gated = StaffStepGate.filterCandidates(scored, system: system)
            let deduped = ClusterSuppressor.suppress(gated, spacing: system.spacing)
            filtered.append(contentsOf: deduped.map { $0.rect })
        }

        if consumed.count < noteheads.count {
            let remaining = noteheads.enumerated().compactMap { index, rect -> CGRect? in
                guard !consumed.contains(index) else { return nil }
                return rect
            }
            filtered.append(contentsOf: DuplicateSuppressor.suppress(remaining, spacing: fallbackSpacing))
        }

        return filtered
    }

    private static func drawOverlays(on image: PlatformImage,
                                     staff: StaffModel?,
                                     noteheads: [CGRect],
                                     barlines: [CGRect]) -> PlatformImage {
        let renderer = UIGraphicsImageRenderer(size: image.size)
        return renderer.image { ctx in
            image.draw(at: .zero)

            // Slightly transparent so we still see the note glyph
            ctx.cgContext.setAlpha(0.85)

            let baseRadius = max(6.0, (staff?.lineSpacing ?? 12.0) * 0.75)

            for rect in noteheads {
                let center = CGPoint(x: rect.midX, y: rect.midY)
                let radius = baseRadius

                let pitchClass = PitchClassifier.classify(noteCenterY: center.y,
                                                          staff: staff)
                let color = pitchClass.color

                // Glow ring
                ctx.cgContext.setStrokeColor(color.withAlphaComponent(0.75).cgColor)
                ctx.cgContext.setLineWidth(max(2.0, radius * 0.18))
                ctx.cgContext.strokeEllipse(in: CGRect(x: center.x - radius,
                                                       y: center.y - radius,
                                                       width: radius * 2,
                                                       height: radius * 2))

                // Small filled dot
                ctx.cgContext.setFillColor(color.withAlphaComponent(0.65).cgColor)
                let dotR = max(2.5, radius * 0.20)
                ctx.cgContext.fillEllipse(in: CGRect(x: center.x - dotR,
                                                     y: center.y - dotR,
                                                     width: dotR * 2,
                                                     height: dotR * 2))
            }

            if !barlines.isEmpty {
                ctx.cgContext.setLineWidth(max(1.5, baseRadius * 0.12))
                ctx.cgContext.setStrokeColor(UIColor.systemTeal.withAlphaComponent(0.65).cgColor)
                for rect in barlines {
                    ctx.cgContext.stroke(rect)
                }
            }
        }
    }
}

private struct BinaryImage {
    let data: [UInt8]
    let width: Int
    let height: Int

    init?(from cgImage: CGImage, threshold: Int) {
        let w = cgImage.width
        let h = cgImage.height
        guard w > 0, h > 0 else { return nil }

        var pixels = [UInt8](repeating: 0, count: w * h * 4)
        guard let ctx = CGContext(
            data: &pixels,
            width: w,
            height: h,
            bitsPerComponent: 8,
            bytesPerRow: w * 4,
            space: CGColorSpaceCreateDeviceRGB(),
            bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue
        ) else { return nil }

        ctx.draw(cgImage, in: CGRect(x: 0, y: 0, width: w, height: h))

        var out = [UInt8](repeating: 0, count: w * h)
        for y in 0..<h {
            for x in 0..<w {
                let i = (y * w + x) * 4
                let lum = (Int(pixels[i]) + Int(pixels[i + 1]) + Int(pixels[i + 2])) / 3
                if lum < threshold { out[y * w + x] = 1 }
            }
        }

        self.data = out
        self.width = w
        self.height = h
    }

    func extent(in rect: CGRect) -> CGFloat {
        let clipped = rect.intersection(CGRect(x: 0, y: 0, width: width, height: height))
        guard clipped.width > 0, clipped.height > 0 else { return 0 }

        let x0 = max(0, Int(clipped.minX.rounded(.down)))
        let y0 = max(0, Int(clipped.minY.rounded(.down)))
        let x1 = min(width, Int(clipped.maxX.rounded(.up)))
        let y1 = min(height, Int(clipped.maxY.rounded(.up)))

        var count = 0
        for y in y0..<y1 {
            let row = y * width
            for x in x0..<x1 {
                if data[row + x] != 0 { count += 1 }
            }
        }

        let area = max(1, Int(rect.width * rect.height))
        return CGFloat(count) / CGFloat(area)
    }
}
