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

enum PitchClass: CaseIterable {
    case A, B, C, D, E, F, G

    var color: UIColor {
        switch self {
        case .A: return UIColor(red: 1.0, green: 0.0, blue: 0.0, alpha: 1.0)        // red
        case .B: return UIColor(red: 1.0, green: 0.5, blue: 0.0, alpha: 1.0)        // orange
        case .C: return UIColor(red: 1.0, green: 0.9, blue: 0.0, alpha: 1.0)        // yellow
        case .D: return UIColor(red: 0.0, green: 0.85, blue: 0.2, alpha: 1.0)       // green
        case .E: return UIColor(red: 0.0, green: 0.4, blue: 1.0, alpha: 1.0)        // blue
        case .F: return UIColor(red: 0.29, green: 0.0, blue: 0.51, alpha: 1.0)      // indigo
        case .G: return UIColor(red: 0.55, green: 0.0, blue: 1.0, alpha: 1.0)       // violet
        }
    }
}

enum PitchClassifier {

    static func classify(noteCenterY: CGFloat, staff: StaffModel?) -> PitchClass {
        guard let staff, let closest = closestStaff(to: noteCenterY, staves: staff.staves) else {
            // Fallback: stable cycling by vertical position
            let idx = Int((noteCenterY / 20).rounded(.down)) % PitchClass.allCases.count
            return PitchClass.allCases[abs(idx)]
        }

        // Treble-clef approximation:
        // Use the middle line (3rd line in 5) as reference: B4.
        let lines = closest.sorted() // 5 y positions top->bottom (image coords)
        if lines.count != 5 {
            let idx = Int((noteCenterY / 20).rounded(.down)) % PitchClass.allCases.count
            return PitchClass.allCases[abs(idx)]
        }

        let spacing = max(6, staff.lineSpacing)
        let middleLineY = lines[2]

        // Each "step" is half a line spacing (line<->space).
        let stepsFromB = Int(((middleLineY - noteCenterY) / (spacing / 2)).rounded())

        // B is index 1 in A,B,C,... but we want pitch class modulo 7
        // Sequence upward from B: B,C,D,E,F,G,A,B...
        let order: [PitchClass] = [.B, .C, .D, .E, .F, .G, .A]
        let idx = mod(stepsFromB, 7)
        return order[idx]
    }

    private static func closestStaff(to y: CGFloat, staves: [[CGFloat]]) -> [CGFloat]? {
        guard !staves.isEmpty else { return nil }
        var best: ([CGFloat], CGFloat)? = nil
        for staff in staves {
            guard let center = staff.sorted().dropFirst().dropLast().first else { continue }
            let dist = abs(center - y)
            if best == nil || dist < best!.1 {
                best = (staff, dist)
            }
        }
        return best?.0
    }

    private static func mod(_ a: Int, _ n: Int) -> Int {
        let r = a % n
        return r >= 0 ? r : r + n
    }
}
