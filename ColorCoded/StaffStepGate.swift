import Foundation
import CoreGraphics

enum ClefKind {
    case treble
    case bass
}

struct ScoredHead {
    let rect: CGRect
    var score: CGFloat
    var clef: ClefKind?
    var staffStepIndex: Int?
    var staffStepError: CGFloat?

    init(rect: CGRect, score: CGFloat = 1.0) {
        self.rect = rect
        self.score = score
    }
}

enum StaffStepGate {
    struct StepSnap {
        let rawSteps: CGFloat
        let stepIndex: Int
        let stepError: CGFloat
    }

    static func snapToSteps(y: CGFloat, staffLines: [CGFloat], spacing: CGFloat) -> StepSnap? {
        guard staffLines.count == 5 else { return nil }
        let stepSize = spacing / 2.0
        guard stepSize > 0 else { return nil }

        let sortedLines = staffLines.sorted()
        let refY = sortedLines[4]
        let rawSteps = (refY - y) / stepSize
        let stepIndex = Int(rawSteps.rounded())
        let stepError = abs(rawSteps - CGFloat(stepIndex))
        return StepSnap(rawSteps: rawSteps, stepIndex: stepIndex, stepError: stepError)
    }

    static func bestClefAndStep(y: CGFloat,
                                trebleLines: [CGFloat],
                                bassLines: [CGFloat],
                                spacing: CGFloat,
                                tolerance: CGFloat,
                                maxSteps: Int) -> (clef: ClefKind, snap: StepSnap)? {
        let trebleSnap = snapToSteps(y: y, staffLines: trebleLines, spacing: spacing)
        let bassSnap = snapToSteps(y: y, staffLines: bassLines, spacing: spacing)

        let best: (ClefKind, StepSnap)?
        switch (trebleSnap, bassSnap) {
        case let (t?, b?):
            best = (t.stepError <= b.stepError) ? (.treble, t) : (.bass, b)
        case let (t?, nil):
            best = (.treble, t)
        case let (nil, b?):
            best = (.bass, b)
        case (nil, nil):
            best = nil
        }

        guard let chosen = best else { return nil }
        guard abs(chosen.1.stepIndex) <= maxSteps else { return nil }
        guard chosen.1.stepError <= tolerance else { return nil }
        return (clef: chosen.0, snap: chosen.1)
    }

    static func filterCandidates(_ candidates: [ScoredHead],
                                 system: SystemBlock,
                                 tolerance: CGFloat = 0.35,
                                 maxSteps: Int = 18) -> [ScoredHead] {
        guard !candidates.isEmpty else { return [] }

        var out: [ScoredHead] = []
        out.reserveCapacity(candidates.count)

        for var candidate in candidates {
            let centerY = candidate.rect.midY
            guard let match = bestClefAndStep(
                y: centerY,
                trebleLines: system.trebleLines,
                bassLines: system.bassLines,
                spacing: system.spacing,
                tolerance: tolerance,
                maxSteps: maxSteps
            ) else { continue }

            candidate.clef = match.clef
            candidate.staffStepIndex = match.snap.stepIndex
            candidate.staffStepError = match.snap.stepError
            out.append(candidate)
        }

        return out
    }
}
