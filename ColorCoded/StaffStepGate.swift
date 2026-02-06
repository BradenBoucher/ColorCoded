import Foundation
import CoreGraphics

enum ClefKind {
    case treble
    case bass
}

/// Why a candidate survived or was rejected (debuggable + extendable)
enum HeadDecision: String {
    case kept
    case rejectedHardStep
    case rejectedMaxSteps
    case rejectedEmpty
}

/// Richer candidate container:
/// - gateScore = staff-step fit (context)
/// - shapeScore = notehead-likeness (geometry + ink + vertical-stroke penalty)
/// - compositeScore = what we rank/suppress on
struct ScoredHead {
    var rect: CGRect

    // Staff-fit metadata
    var clef: ClefKind?
    var staffStepIndex: Int?
    var staffStepError: CGFloat?

    // Shape metrics (computed in OfflineScoreColorizer where binary/vMask exist)
    var inkExtent: CGFloat?          // 0..1
    var strokeOverlap: CGFloat?      // 0..1 (vertical runs)
    var shapeScore: CGFloat = 0      // 0..1
    var isHeadLike: Bool = false

    // Optional debug state
    var decision: HeadDecision = .kept

    /// Gate score only (0..1). Closer to a staff step = higher.
    var gateScore: CGFloat {
        guard let staffStepError else { return 0 }
        // staffStepError is in "step units" (0 is perfect, 0.5 is halfway)
        let s = 1.0 - min(1.0, staffStepError / 0.5)
        return max(0, min(1, s))
    }

    /// Final ranking score (0..~2.5 depending on weights).
    /// This is the score we should sort/suppress/consolidate by.
    var compositeScore: CGFloat {
        // Keep recall: gate matters, but shape prevents stems/ties from winning.
        // strokeOverlap is already baked into shapeScore, so don't double-penalize.
        return (gateScore * 1.55) + (shapeScore * 1.15)
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
        let refY = sortedLines[4] // bottom line
        let rawSteps = (refY - y) / stepSize
        let stepIndex = Int(rawSteps.rounded())
        let stepError = abs(rawSteps - CGFloat(stepIndex))
        return StepSnap(rawSteps: rawSteps, stepIndex: stepIndex, stepError: stepError)
    }

    /// Returns best clef + snap, WITHOUT hard-rejecting by tolerance.
    static func bestClefAndStepSoft(
        y: CGFloat,
        trebleLines: [CGFloat],
        bassLines: [CGFloat],
        spacing: CGFloat,
        maxSteps: Int,
        preferBassInGap: Bool
    ) -> (clef: ClefKind, snap: StepSnap)? {

        let t = snapToSteps(y: y, staffLines: trebleLines, spacing: spacing)
        let b = snapToSteps(y: y, staffLines: bassLines, spacing: spacing)
        guard t != nil || b != nil else { return nil }

        let gapBias: CGFloat = preferBassInGap ? 0.03 : 0.0

        var inGap = false
        if trebleLines.count == 5, bassLines.count == 5 {
            let trebleSorted = trebleLines.sorted()
            let bassSorted = bassLines.sorted()
            let trebleBottom = trebleSorted[4]
            let bassTop = bassSorted[0]
            if y > trebleBottom && y < bassTop { inGap = true }
        }

        func effectiveError(_ clef: ClefKind, _ snap: StepSnap) -> CGFloat {
            guard preferBassInGap, inGap else { return snap.stepError }
            if clef == .bass { return max(0, snap.stepError - gapBias) }
            return snap.stepError
        }

        let chosen: (ClefKind, StepSnap)
        switch (t, b) {
        case let (tt?, bb?):
            let te = effectiveError(.treble, tt)
            let be = effectiveError(.bass, bb)
            chosen = (te <= be) ? (.treble, tt) : (.bass, bb)
        case let (tt?, nil):
            chosen = (.treble, tt)
        case let (nil, bb?):
            chosen = (.bass, bb)
        default:
            return nil
        }

        guard abs(chosen.1.stepIndex) <= maxSteps else { return nil }
        return (clef: chosen.0, snap: chosen.1)
    }

    /// Two-tier step gate:
    /// - hardTolerance: strong reject
    /// - softTolerance: keep, but low gateScore
    static func filterCandidates(
        _ candidates: [ScoredHead],
        system: SystemBlock,
        softTolerance: CGFloat = 0.45,
        hardTolerance: CGFloat = 0.60,
        maxSteps: Int = 22,
        preferBassInGap: Bool = true
    ) -> [ScoredHead] {
        guard !candidates.isEmpty else { return [] }

        var out: [ScoredHead] = []
        out.reserveCapacity(candidates.count)

        for var candidate in candidates {
            let centerY = candidate.rect.midY

            guard let match = bestClefAndStepSoft(
                y: centerY,
                trebleLines: system.trebleLines,
                bassLines: system.bassLines,
                spacing: system.spacing,
                maxSteps: maxSteps,
                preferBassInGap: preferBassInGap
            ) else { continue }

            if abs(match.snap.stepIndex) > maxSteps {
                candidate.decision = .rejectedMaxSteps
                continue
            }

            if match.snap.stepError > hardTolerance {
                candidate.decision = .rejectedHardStep
                continue
            }

            candidate.clef = match.clef
            candidate.staffStepIndex = match.snap.stepIndex
            candidate.staffStepError = match.snap.stepError

            // still keep above softTolerance (high recall); it just ranks lower later
            _ = softTolerance // kept for readability; gateScore handles this
            out.append(candidate)
        }

        return out
    }
}
