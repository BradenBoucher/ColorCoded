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

            let scored = withoutSymbols.map { ScoredHead(rect: $0) }
            let gated = StaffStepGate.filterCandidates(scored, system: system)
            let gatedRects = gated.map { $0.rect }
            let deduped = DuplicateSuppressor.suppress(gatedRects, spacing: system.spacing)
            filtered.append(contentsOf: deduped)
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
