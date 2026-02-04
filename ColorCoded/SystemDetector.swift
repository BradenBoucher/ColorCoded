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

        let sortedStaves = staff.staves.sorted { avg($0) < avg($1) }
        guard !sortedStaves.isEmpty else { return [] }

        var systems: [SystemBlock] = []
        var i = 0
        let lookahead = 4
        let minGap = spacing * 1.0
        let maxGap = spacing * 18.0
        let targetGap = spacing * 6.0

        while i + 1 < sortedStaves.count {
            let treble = sortedStaves[i].sorted()
            let trebleBottom = treble.max() ?? 0

            var bestIndex: Int?
            var bestGap = CGFloat.greatestFiniteMagnitude
            let upper = min(sortedStaves.count - 1, i + lookahead)
            if i + 1 <= upper {
                for j in (i + 1)...upper {
                    let bass = sortedStaves[j].sorted()
                    let bassTop = bass.min() ?? trebleBottom
                    let gap = bassTop - trebleBottom
                    guard gap > 0 else { continue }
                    let score = abs(gap - targetGap)
                    if score < bestGap {
                        bestGap = score
                        bestIndex = j
                    }
                }
            }

            if let bestIndex {
                let bass = sortedStaves[bestIndex].sorted()
                let bassTop = bass.min() ?? trebleBottom
                let gap = bassTop - trebleBottom
                if gap >= minGap && gap <= maxGap {
                    if let system = buildSystem(treble: treble,
                                                bass: bass,
                                                spacing: spacing,
                                                imageSize: imageSize,
                                                isFallback: false) {
                        systems.append(system)
                        i = bestIndex + 1
                        continue
                    }
                }
            }

            i += 1
        }

        if systems.isEmpty {
            let allLines = sortedStaves.flatMap { $0 }.sorted()
            if let topLine = allLines.first, let bottomLine = allLines.last {
                let top = topLine - spacing * 3.0
                let bottom = bottomLine + spacing * 3.0

                var y0 = max(0, top)
                var y1 = min(imageSize.height, bottom)
                if (y1 - y0) < imageSize.height * 0.55 {
                    y0 = 0
                    y1 = imageSize.height
                }
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

        return systems
    }

    private static func buildSystem(treble: [CGFloat],
                                    bass: [CGFloat],
                                    spacing: CGFloat,
                                    imageSize: CGSize,
                                    isFallback: Bool) -> SystemBlock? {
        let topPad = spacing * 2.5
        let botPad = spacing * 2.5

        let top = (treble.min() ?? bass.min() ?? 0) - topPad
        let bottom = (bass.max() ?? treble.max() ?? 0) + botPad

        let y0 = max(0, top)
        let y1 = min(imageSize.height, bottom)
        let h = max(1, y1 - y0)
        guard h > 1 else { return nil }

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
