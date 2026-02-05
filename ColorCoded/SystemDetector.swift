import Foundation
import CoreGraphics

struct SystemBlock {
    let trebleLines: [CGFloat]
    let bassLines: [CGFloat]
    let spacing: CGFloat
    let bbox: CGRect
}

enum SystemDetector {

    static func buildSystems(from staff: StaffModel?, imageSize: CGSize) -> [SystemBlock] {
        guard let staff else { return [] }
        let spacing = max(6.0, staff.lineSpacing)

        let sortedStaves = staff.staves.sorted { avg($0) < avg($1) }
        guard !sortedStaves.isEmpty else { return [] }

        var systems: [SystemBlock] = []
        var i = 0

        if sortedStaves.count == 1 {
            return [buildSingleStaffSystem(staffLines: sortedStaves[0], spacing: spacing, imageSize: imageSize)]
        }

        var unpaired: [[CGFloat]] = []

        while i + 1 < sortedStaves.count {
            let treble = sortedStaves[i].sorted()
            let bass = sortedStaves[i + 1].sorted()

            let trebleBottom = treble.max() ?? 0
            let bassTop = bass.min() ?? trebleBottom
            let gap = bassTop - trebleBottom

            // Grand staff gap sanity
            if gap >= spacing * 2.0 && gap <= spacing * 12.0 {
                systems.append(buildSystem(treble: treble, bass: bass, spacing: spacing, imageSize: imageSize))
                i += 2
            } else {
                unpaired.append(treble)
                i += 1
            }
        }

        if i < sortedStaves.count {
            unpaired.append(sortedStaves[i])
        }

        if sortedStaves.count >= 5 && systems.isEmpty {
            return clusterSystems(from: sortedStaves, spacing: spacing, imageSize: imageSize)
        }

        for staffLines in unpaired {
            systems.append(buildSingleStaffSystem(staffLines: staffLines, spacing: spacing, imageSize: imageSize))
        }

        return systems
    }

    private static func buildSystem(treble: [CGFloat],
                                    bass: [CGFloat],
                                    spacing: CGFloat,
                                    imageSize: CGSize) -> SystemBlock {
        let topPad = spacing * 2.5
        let botPad = spacing * 2.5

        let top = (treble.min() ?? 0) - topPad
        let bottom = (bass.max() ?? 0) + botPad

        let y0 = max(0, top)
        let y1 = min(imageSize.height, bottom)
        let h = max(1, y1 - y0)

        let bbox = CGRect(x: 0, y: y0, width: imageSize.width, height: h)

        return SystemBlock(
            trebleLines: treble,
            bassLines: bass,
            spacing: spacing,
            bbox: bbox
        )
    }

    private static func buildSingleStaffSystem(staffLines: [CGFloat],
                                               spacing: CGFloat,
                                               imageSize: CGSize) -> SystemBlock {
        let topPad = spacing * 2.2
        let botPad = spacing * 2.2
        let top = (staffLines.min() ?? 0) - topPad
        let bottom = (staffLines.max() ?? 0) + botPad
        let y0 = max(0, top)
        let y1 = min(imageSize.height, bottom)
        let h = max(1, y1 - y0)
        let bbox = CGRect(x: 0, y: y0, width: imageSize.width, height: h)

        return SystemBlock(
            trebleLines: staffLines.sorted(),
            bassLines: [],
            spacing: spacing,
            bbox: bbox
        )
    }

    private static func clusterSystems(from staves: [[CGFloat]],
                                       spacing: CGFloat,
                                       imageSize: CGSize) -> [SystemBlock] {
        let sorted = staves.sorted { avg($0) < avg($1) }
        let maxGap = spacing * 6.5
        var clusters: [[[CGFloat]]] = []
        var current: [[CGFloat]] = []

        for staffLines in sorted {
            if let last = current.last {
                let gap = (staffLines.min() ?? 0) - (last.max() ?? 0)
                if gap > maxGap {
                    if !current.isEmpty { clusters.append(current) }
                    current = [staffLines]
                } else {
                    current.append(staffLines)
                }
            } else {
                current = [staffLines]
            }
        }

        if !current.isEmpty { clusters.append(current) }

        return clusters.map { cluster in
            let topLines = cluster.first ?? []
            let bottomLines = cluster.count > 1 ? (cluster.last ?? []) : []
            let allLines = cluster.flatMap { $0 }
            let topPad = spacing * 2.4
            let botPad = spacing * 2.4
            let top = (allLines.min() ?? 0) - topPad
            let bottom = (allLines.max() ?? 0) + botPad
            let y0 = max(0, top)
            let y1 = min(imageSize.height, bottom)
            let h = max(1, y1 - y0)
            let bbox = CGRect(x: 0, y: y0, width: imageSize.width, height: h)

            return SystemBlock(
                trebleLines: topLines.sorted(),
                bassLines: bottomLines.sorted(),
                spacing: spacing,
                bbox: bbox
            )
        }
    }

    private static func avg(_ ys: [CGFloat]) -> CGFloat {
        guard !ys.isEmpty else { return 0 }
        return ys.reduce(0, +) / CGFloat(ys.count)
    }
}
