import Foundation

enum FileImportHelper {

    enum ImportError: LocalizedError {
        case noAccess
        case copyFailed

        var errorDescription: String? {
            switch self {
            case .noAccess: return "No permission to access that file."
            case .copyFailed: return "Failed to copy PDF into app storage."
            }
        }
    }

    /// Copies a picked file URL into the app's sandbox (temporary directory) and returns the new URL.
    static func copyToSandbox(_ url: URL) throws -> URL {
        let needsSecurity = url.startAccessingSecurityScopedResource()
        defer {
            if needsSecurity { url.stopAccessingSecurityScopedResource() }
        }

        guard FileManager.default.isReadableFile(atPath: url.path) else {
            throw ImportError.noAccess
        }

        let fileName = url.lastPathComponent.isEmpty ? "import.pdf" : url.lastPathComponent
        let dest = FileManager.default.temporaryDirectory
            .appendingPathComponent("imported-\(UUID().uuidString)-\(fileName)")

        do {
            if FileManager.default.fileExists(atPath: dest.path) {
                try FileManager.default.removeItem(at: dest)
            }
            try FileManager.default.copyItem(at: url, to: dest)
            return dest
        } catch {
            do {
                let data = try Data(contentsOf: url)
                try data.write(to: dest, options: .atomic)
                return dest
            } catch {
                throw ImportError.copyFailed
            }
        }
    }
}
