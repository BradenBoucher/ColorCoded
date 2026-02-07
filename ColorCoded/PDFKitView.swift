import SwiftUI
import PDFKit

#if canImport(UIKit)
import UIKit

struct PDFKitView: UIViewRepresentable {
    let url: URL

    func makeUIView(context: Context) -> PDFView {
        let v = PDFView()
        v.autoScales = true
        v.displayMode = .singlePageContinuous
        v.displayDirection = .vertical
        v.document = PDFDocument(url: url)
        return v
    }

    func updateUIView(_ pdfView: PDFView, context: Context) {
        guard pdfView.document?.documentURL != url else { return }
        DispatchQueue.main.async {
            pdfView.document = PDFDocument(url: url)
        }
    }
}

#elseif canImport(AppKit)
import AppKit

struct PDFKitView: NSViewRepresentable {
    let url: URL

    func makeNSView(context: Context) -> PDFView {
        let v = PDFView()
        v.autoScales = true
        v.displayMode = .singlePageContinuous
        v.displayDirection = .vertical
        v.document = PDFDocument(url: url)
        return v
    }

    func updateNSView(_ pdfView: PDFView, context: Context) {
        guard pdfView.document?.documentURL != url else { return }
        DispatchQueue.main.async {
            pdfView.document = PDFDocument(url: url)
        }
    }
}
#endif
