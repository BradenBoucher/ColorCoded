import Foundation
import CoreGraphics

struct SystemBlock {
    let trebleLines: [CGFloat]
    let bassLines: [CGFloat]
    let spacing: CGFloat
    let bbox: CGRect
    let isFallback: Bool

    init(trebleLines: [CGFloat],
         bassLines: [CGFloat],
         spacing: CGFloat,
         bbox: CGRect,
         isFallback: Bool = false) {
        self.trebleLines = trebleLines
        self.bassLines = bassLines
        self.spacing = spacing
        self.bbox = bbox
        self.isFallback = isFallback
    }
}

enum SystemDetector {

    static func buildSystems(from staff: StaffModel?, imageSize: CGSize) -> [SystemBlock] {
        guard let staff else { return [] }

        let spacing = max(6.0, staff.lineSpacing)
        let staves = staff.staves
            .map { $0.sorted() }
            .filter { !$0.isEmpty }
            .sorted { avg($0) < avg($1) }

        guard !staves.isEmpty else { return [] }

        // --- 1) Split into "bands" (systems) by large vertical gaps between staves
        // If the distance between staff centers is huge, it's probably a new system line.
        let splitGap = spacing * 10.0

        var bands: [[[CGFloat]]] = []
        var cur: [[CGFloat]] = []
        cur.reserveCapacity(4)

        var lastCenter: CGFloat? = nil
        for s in staves {
            let c = avg(s)
            if let lc = lastCenter, (c - lc) > splitGap, !cur.isEmpty {
                bands.append(cur)
                cur = []
            }
            cur.append(s)
            lastCenter = c
        }
        if !cur.isEmpty { bands.append(cur) }

        // --- 2) For each band, pair treble+bass when plausible, else single staff
        var systems: [SystemBlock] = []
        systems.reserveCapacity(bands.count * 2)

        for band in bands {
            var i = 0
            while i < band.count {
                if i + 1 < band.count {
                    // Decide if these two staves are a "grand staff" pair
                    let treble = band[i]
                    let bass = band[i + 1]

                    let trebleBottom = treble.max() ?? 0
                    let bassTop = bass.min() ?? trebleBottom
                    let gap = bassTop - trebleBottom

                    // Typical grand-staff gap: not too small, not insanely large
                    let minGap = spacing * 1.0
                    let maxGap = spacing * 18.0

                    if gap > minGap && gap < maxGap {
                        if let sys = buildSystem(
                            treble: treble,
                            bass: bass,
                            spacing: spacing,
                            imageSize: imageSize,
                            isFallback: false
                        ) {
                            systems.append(sys)
                            i += 2
                            continue
                        }
                    }
                }

                // Single-staff fallback
                let trebleOnly = band[i]
                if let sys = buildSystem(
                    treble: trebleOnly,
                    bass: [],
                    spacing: spacing,
                    imageSize: imageSize,
                    isFallback: true
                ) {
                    systems.append(sys)
                }
                i += 1
            }
        }

        // If somehow we built nothing, fall back to per-staff blocks
        if systems.isEmpty {
            let allLines = sortedStaves.flatMap { $0 }.sorted()
            if let topLine = allLines.first, let bottomLine = allLines.last {
                let top = topLine - spacing * 3.0
                let bottom = bottomLine + spacing * 3.0

                let y0 = max(0, top)
                let y1 = min(imageSize.height, bottom)
                let h = max(1, y1 - y0)
                if h > 1 {
                    let bbox = CGRect(x: 0, y: y0, width: imageSize.width, height: h)
                    let trebleLines = sortedStaves.first?.sorted() ?? []
                    let bassLines = sortedStaves.dropFirst().first?.sorted() ?? []
                    systems.append(SystemBlock(trebleLines: trebleLines,
                                               bassLines: bassLines,
                                               spacing: spacing,
                                               bbox: bbox,
                                               isFallback: true))
                }
            }
        }

        // Debug (optional)
        // print("[systems] built=\(systems.count) bands=\(bands.count) staves=\(staves.count) spacing=\(spacing)")

        return systems
    }

    private static func buildSystem(treble: [CGFloat],
                                    bass: [CGFloat],
                                    spacing: CGFloat,
                                    imageSize: CGSize,
                                    isFallback: Bool) -> SystemBlock? {

        // Pads matter a lot: too big -> bbox eats blank page -> barline garbage near bottom
        let topPad = spacing * 1.8
        let botPad = spacing * 2.2

        let topLine = min(treble.min() ?? .greatestFiniteMagnitude,
                          bass.min() ?? .greatestFiniteMagnitude)
        let botLine = max(treble.max() ?? 0,
                          bass.max() ?? 0)

        var y0 = topLine - topPad
        var y1 = botLine + botPad

        y0 = max(0, y0)
        y1 = min(imageSize.height, y1)

        let h = max(1, y1 - y0)
        guard h > 2 else { return nil }

        let bbox = CGRect(x: 0, y: y0, width: imageSize.width, height: h)

        return SystemBlock(
            trebleLines: treble,
            bassLines: bass,
            spacing: spacing,
            bbox: bbox,
            isFallback: isFallback
        )
    }

    private static func avg(_ ys: [CGFloat]) -> CGFloat {
        guard !ys.isEmpty else { return 0 }
        return ys.reduce(0, +) / CGFloat(ys.count)
    }
}
