#if os(iOS)
import SwiftUI
import VisionKit
import PDFKit

struct DocumentScannerView: UIViewControllerRepresentable {
    typealias Completion = (URL?) -> Void
    let completion: Completion

    func makeUIViewController(context: Context) -> VNDocumentCameraViewController {
        let vc = VNDocumentCameraViewController()
        vc.delegate = context.coordinator
        return vc
    }

    func updateUIViewController(_ uiViewController: VNDocumentCameraViewController, context: Context) {}

    func makeCoordinator() -> Coordinator {
        Coordinator(completion: completion)
    }

    final class Coordinator: NSObject, VNDocumentCameraViewControllerDelegate {
        let completion: Completion
        init(completion: @escaping Completion) { self.completion = completion }

        func documentCameraViewControllerDidCancel(_ controller: VNDocumentCameraViewController) {
            completion(nil)
        }

        func documentCameraViewController(_ controller: VNDocumentCameraViewController, didFailWithError error: Error) {
            completion(nil)
        }

        func documentCameraViewController(_ controller: VNDocumentCameraViewController, didFinishWith scan: VNDocumentCameraScan) {
            let pdf = PDFDocument()
            for i in 0..<scan.pageCount {
                let img = scan.imageOfPage(at: i)
                if let page = PDFPage(image: img) {
                    pdf.insert(page, at: pdf.pageCount)
                }
            }

            let outURL = FileManager.default.temporaryDirectory
                .appendingPathComponent("scan-\(UUID().uuidString).pdf")

            pdf.write(to: outURL)
            completion(outURL)
        }
    }
}
#endif
