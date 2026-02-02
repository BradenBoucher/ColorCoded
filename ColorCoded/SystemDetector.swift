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
            let treble = sortedStaves[i].sorted()
            let bass = sortedStaves[i + 1].sorted()

            let trebleBottom = treble.max() ?? 0
            let bassTop = bass.min() ?? trebleBottom
            let gap = bassTop - trebleBottom

            // Grand staff gap sanity
            if gap >= spacing * 2.0 && gap <= spacing * 12.0 {

                // ✅ tighter padding than your previous *4.0
                let topPad = spacing * 2.5
                let botPad = spacing * 2.5

                let top = (treble.min() ?? 0) - topPad
                let bottom = (bass.max() ?? 0) + botPad

                let y0 = max(0, top)
                let y1 = min(imageSize.height, bottom)
                let h = max(1, y1 - y0)

                // Still full width here (SystemDetector has no pixels),
                // but the vertical tightening reduces title/lyrics hits massively.
                let bbox = CGRect(x: 0, y: y0, width: imageSize.width, height: h)

                systems.append(SystemBlock(
                    trebleLines: treble,
                    bassLines: bass,
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

    private static func avg(_ ys: [CGFloat]) -> CGFloat {
        guard !ys.isEmpty else { return 0 }
        return ys.reduce(0, +) / CGFloat(ys.count)
    }
}
