import SwiftUI
import UniformTypeIdentifiers
import PDFKit

struct ContentView: View {
    @State private var showImporter = false
    @State private var pickedPDFURL: URL?
    @State private var coloredPDFURL: URL?
    @State private var status: String = "Import a PDF (or scan on iOS)."
    @State private var isProcessing = false

    @State private var showScanner = false

    var body: some View {
        NavigationStack {
            ZStack(alignment: .bottomTrailing) {
                VStack(spacing: 14) {

                    Text(status)
                        .font(.headline)
                        .frame(maxWidth: .infinity, alignment: .leading)

                    if let url = coloredPDFURL {
                        VStack(alignment: .leading, spacing: 8) {
                            Text("Colored output (offline)")
                                .font(.subheadline)
                                .foregroundStyle(.secondary)
                            PDFKitView(url: url)
                                .frame(maxWidth: CGFloat.infinity, maxHeight: 420)
                                .cornerRadius(12)
                        }
                    } else if let url = pickedPDFURL {
                        VStack(alignment: .leading, spacing: 8) {
                            Text("Input")
                                .font(.subheadline)
                                .foregroundStyle(.secondary)
                            PDFKitView(url: url)
                                .frame(maxWidth: CGFloat.infinity, maxHeight: 420)
                                .cornerRadius(12)
                        }
                    } else {
                        ZStack {
                            RoundedRectangle(cornerRadius: 14)
                                .strokeBorder(.secondary.opacity(0.35), lineWidth: 1)
                                .frame(height: 220)
                            VStack(spacing: 10) {
                                Image(systemName: "music.note.list")
                                    .font(.system(size: 44))
                                    .foregroundStyle(.tint)
                                Text("No PDF selected")
                                    .foregroundStyle(.secondary)
                            }
                        }
                    }

                    HStack(spacing: 10) {
                        Button {
                            showImporter = true
                        } label: {
                            Label("Import PDF", systemImage: "doc")
                        }
                        .buttonStyle(.borderedProminent)

#if os(iOS)
                        Button {
                            showScanner = true
                        } label: {
                            Label("Scan", systemImage: "camera.viewfinder")
                        }
                        .buttonStyle(.bordered)
#endif
                    }

                    Button {
                        Task { await runOfflineColorize() }
                    } label: {
                        Label(isProcessing ? "Colorizing…" : "Colorize Notes (Offline)", systemImage: "paintpalette")
                            .frame(maxWidth: .infinity)
                    }
                    .buttonStyle(.borderedProminent)
                    .disabled(pickedPDFURL == nil || isProcessing)

                    if let coloredPDFURL {
                        ShareLink(item: coloredPDFURL) {
                            Label("Share Colored PDF", systemImage: "square.and.arrow.up")
                                .frame(maxWidth: .infinity)
                        }
                        .buttonStyle(.bordered)
                    }

                    Spacer(minLength: 6)
                }
                .padding()

                Text("z")
                    .font(.caption2)
                    .foregroundStyle(.secondary)
                    .padding([.trailing, .bottom], 8)
            }
            .navigationTitle("ColorCoded")
        }
        .fileImporter(
            isPresented: $showImporter,
            allowedContentTypes: [.pdf],
            allowsMultipleSelection: false
        ) { result in
            switch result {
            case .success(let urls):
                guard let url = urls.first else { return }
                do {
                    let localURL = try FileImportHelper.copyToSandbox(url)
                    pickedPDFURL = localURL
                    coloredPDFURL = nil
                    status = "Loaded PDF. Ready to colorize offline."
                } catch {
                    status = "Failed: \(error.localizedDescription)"
                }
            case .failure(let error):
                status = "Import failed: \(error.localizedDescription)"
            }
        }
#if os(iOS)
        .sheet(isPresented: $showScanner) {
            DocumentScannerView { scannedPDFURL in
                if let scannedPDFURL {
                    pickedPDFURL = scannedPDFURL
                    coloredPDFURL = nil
                    status = "Scanned PDF ready. Ready to colorize offline."
                } else {
                    status = "Scan cancelled."
                }
                showScanner = false
            }
        }
#endif
    }

    private func runOfflineColorize() async {
        guard let input = pickedPDFURL else { return }
        isProcessing = true
        status = "Processing pages on-device…"

        do {
            let outURL = try await OfflineScoreColorizer.colorizePDF(inputURL: input)
            coloredPDFURL = outURL
            status = "Done ✅ (offline)"
        } catch {
            status = "Failed: \(error.localizedDescription)"
        }

        isProcessing = false
    }
}
