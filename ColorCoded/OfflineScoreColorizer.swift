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
            guard let page = doc.page(at: pageIndex) else { continue }

            guard let image = render(page: page, scale: 3.0) else {
                throw ColorizeError.cannotRenderPage
            }

            // Detect staff model + noteheads
            let staffModel = await StaffDetector.detectStaff(in: image)
            let noteheads = await NoteheadDetector.detectNoteheads(in: image)

            // Draw overlays
            let colored = drawOverlays(on: image, staff: staffModel, noteheads: noteheads)

            if let pdfPage = PDFPage(image: colored) {
                outDoc.insert(pdfPage, at: outDoc.pageCount)
            }
        }

        let outURL = FileManager.default.temporaryDirectory
            .appendingPathComponent("colored-offline-\(UUID().uuidString).pdf")

        guard outDoc.write(to: outURL) else { throw ColorizeError.cannotWriteOutput }
        return outURL
    }

    // MARK: - Render PDF page to UIImage

    private static func render(page: PDFPage, scale: CGFloat) -> UIImage? {
        let bounds = page.bounds(for: .mediaBox)
        let size = CGSize(width: bounds.width * scale, height: bounds.height * scale)

        let renderer = UIGraphicsImageRenderer(size: size)
        return renderer.image { ctx in
            UIColor.white.setFill()
            ctx.fill(CGRect(origin: .zero, size: size))

            ctx.cgContext.saveGState()
            ctx.cgContext.scaleBy(x: scale, y: scale)

            // PDFKit uses a flipped coordinate system; adjust
            ctx.cgContext.translateBy(x: 0, y: bounds.height)
            ctx.cgContext.scaleBy(x: 1, y: -1)

            page.draw(with: .mediaBox, to: ctx.cgContext)
            ctx.cgContext.restoreGState()
        }
    }

    // MARK: - Draw overlays

    private static func drawOverlays(on image: UIImage,
                                     staff: StaffModel?,
                                     noteheads: [CGRect]) -> UIImage {
        let renderer = UIGraphicsImageRenderer(size: image.size)
        return renderer.image { ctx in
            image.draw(at: .zero)

            // Slightly transparent so we still see the note glyph
            ctx.cgContext.setAlpha(0.85)

            for rect in noteheads {
                let center = CGPoint(x: rect.midX, y: rect.midY)
                let radius = max(rect.width, rect.height) * 0.85

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
        }
    }
}
