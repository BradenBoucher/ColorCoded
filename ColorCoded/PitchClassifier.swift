import CoreGraphics

enum PitchClass: CaseIterable {
    case A, B, C, D, E, F, G

    // A red, then rainbow order onward
    var color: PlatformColor {
        switch self {
        case .A: return PlatformColor(red: 1.0, green: 0.0, blue: 0.0, alpha: 1.0)        // red
        case .B: return PlatformColor(red: 1.0, green: 0.5, blue: 0.0, alpha: 1.0)        // orange
        case .C: return PlatformColor(red: 1.0, green: 0.9, blue: 0.0, alpha: 1.0)        // yellow
        case .D: return PlatformColor(red: 0.0, green: 0.85, blue: 0.2, alpha: 1.0)       // green
        case .E: return PlatformColor(red: 0.0, green: 0.4, blue: 1.0, alpha: 1.0)        // blue
        case .F: return PlatformColor(red: 0.29, green: 0.0, blue: 0.51, alpha: 1.0)      // indigo
        case .G: return PlatformColor(red: 0.55, green: 0.0, blue: 1.0, alpha: 1.0)       // violet
        }
    }
}

enum PitchClassifier {

    /// Classify by staff + clef anchor.
    /// - Treble: bottom line = E
    /// - Bass: bottom line = G
    static func classify(noteCenterY: CGFloat, staff: StaffModel?) -> PitchClass {
        guard let staff, !staff.staves.isEmpty else {
            let idx = Int((noteCenterY / 18).rounded(.down)) % PitchClass.allCases.count
            return PitchClass.allCases[abs(idx)]
        }

        guard let (lines, staffIndex) = closestStaff(to: noteCenterY, staves: staff.staves) else {
            let idx = Int((noteCenterY / 18).rounded(.down)) % PitchClass.allCases.count
            return PitchClass.allCases[abs(idx)]
        }

        let sortedLines = lines.sorted() // y positions top->bottom in image coords
        guard sortedLines.count == 5 else {
            let idx = Int((noteCenterY / 18).rounded(.down)) % PitchClass.allCases.count
            return PitchClass.allCases[abs(idx)]
        }

        let spacing = max(6, staff.lineSpacing)
        let halfStep = spacing / 2.0

        // Anchor at bottom line (line 5)
        let bottomLineY = sortedLines[4]

        let stepsUp = Int(((bottomLineY - noteCenterY) / halfStep).rounded())

        let clef: Clef = {
            if staff.staves.count >= 2 {
                return (staffIndex == 0) ? .treble : .bass
            } else {
                return .treble
            }
        }()

        return pitchFromBottomLine(stepsUp: stepsUp, clef: clef)
    }

    // MARK: - Internals

    private enum Clef { case treble, bass }

    /// Treble bottom line is E; Bass bottom line is G.
    private static func pitchFromBottomLine(stepsUp: Int, clef: Clef) -> PitchClass {
        let trebleSequence: [PitchClass] = [.E, .F, .G, .A, .B, .C, .D]
        let bassSequence: [PitchClass] = [.G, .A, .B, .C, .D, .E, .F]

        let seq = (clef == .treble) ? trebleSequence : bassSequence
        let idx = mod(stepsUp, 7)
        return seq[idx]
    }

    private static func closestStaff(to y: CGFloat, staves: [[CGFloat]]) -> ([CGFloat], Int)? {
        var bestIndex: Int?
        var bestDist: CGFloat = .greatestFiniteMagnitude

        for (i, staffLines) in staves.enumerated() {
            let sorted = staffLines.sorted()
            guard sorted.count == 5 else { continue }
            let centerY = (sorted.first! + sorted.last!) / 2.0
            let d = abs(centerY - y)
            if d < bestDist {
                bestDist = d
                bestIndex = i
            }
        }

        guard let idx = bestIndex else { return nil }
        return (staves[idx], idx)
    }

    private static func mod(_ a: Int, _ n: Int) -> Int {
        let r = a % n
        return r >= 0 ? r : r + n
    }
}
