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
        guard sortedStaves.count >= 2 else { return [] }

        var systems: [SystemBlock] = []
        var i = 0
        while i + 1 < sortedStaves.count {
            let treble = sortedStaves[i]
            let bass = sortedStaves[i + 1]
            let trebleBottom = treble.max() ?? 0
            let bassTop = bass.min() ?? trebleBottom
            let gap = bassTop - trebleBottom

            if gap >= spacing * 2.0 && gap <= spacing * 12.0 {
                let top = (treble.min() ?? 0) - spacing * 4.0
                let bottom = (bass.max() ?? 0) + spacing * 4.0
                let bbox = CGRect(
                    x: 0,
                    y: max(0, top),
                    width: imageSize.width,
                    height: min(imageSize.height, bottom) - max(0, top)
                )
                systems.append(SystemBlock(
                    trebleLines: treble.sorted(),
                    bassLines: bass.sorted(),
                    spacing: spacing,
                    bbox: bbox
                ))
                i += 2
            } else {
                i += 1
            }
        }

        return systems
    }

    static func symbolZone(for system: SystemBlock, barlines: [CGRect]) -> CGRect {
        let defaultWidth = system.spacing * 7.0
        let systemBars = barlines
            .filter { $0.intersects(system.bbox) }
            .sorted { $0.minX < $1.minX }
        if let first = systemBars.first {
            let width = min(first.minX - system.bbox.minX, defaultWidth)
            return CGRect(x: system.bbox.minX,
                          y: system.bbox.minY,
                          width: max(0, width),
                          height: system.bbox.height)
        }
        return CGRect(x: system.bbox.minX,
                      y: system.bbox.minY,
                      width: defaultWidth,
                      height: system.bbox.height)
    }

    private static func avg(_ ys: [CGFloat]) -> CGFloat {
        guard !ys.isEmpty else { return 0 }
        let total = ys.reduce(0, +)
        return total / CGFloat(ys.count)
    }
}
