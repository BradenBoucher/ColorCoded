import CoreGraphics
import os

enum HorizontalStrokeEraser {
    private static let log = Logger(subsystem: "ColorCoded", category: "HorizontalStrokeEraser")
    
    struct Result {
        let binaryWithoutHorizontals: [UInt8]
        let horizMask: [UInt8]   // 1 where we erased
        let erasedCount: Int
    }
    
    /// Remove long thin horizontal runs (beams, ties, leftover staff/ledger fragments),
    /// while respecting protectMask (notehead neighborhoods).
    static func eraseHorizontalRuns(
        binary: [UInt8],
        width: Int,
        height: Int,
        roi: CGRect,
        spacing: CGFloat,
        protectMask: [UInt8],
        staffLinesY: [CGFloat]
    ) -> Result {
        log.notice("eraseHorizontalRuns enter roi=\(String(describing: roi), privacy: .public)")
        
        let u = max(7.0, spacing)
        
        // Tunables (high-recall, protect-aware)
        let minRun = max(14, Int((3.8 * u).rounded()))                 // long enough to be a stroke/beam/tie fragment
        let minStaffRun = max(18, Int((6.0 * u).rounded()))            // extra-long straight lines (staff leftovers)
        let minCurveRun = minRun
        let maxHalfThickness = max(1, Int((0.10 * u).rounded()))       // thickness band half-width (so 2*+1 total)
        let protectMaxFrac: Double = 0.14                              // allow more protect overlap than before
        let protectErodeR = max(1, Int((0.06 * u).rounded()))          // shrink protect just for this pass
        let staffExclusion = spacing * 0.18                            // "near staff line" distance
        let tieBand = maxHalfThickness

        let beamMinRun = max(14, Int((3.0 * u).rounded()))
        let beamStaffDist = spacing * 0.10              // was 0.35
        let beamProtectMaxFrac: Double = 0.20           // was 0.05
        let beamMaxThickness = max(2, Int((0.22 * u).rounded())) // was 0.14*u

        
        let clipped = roi.intersection(CGRect(x: 0, y: 0, width: width, height: height))
        guard clipped.width > 2, clipped.height > 2 else {
            return Result(binaryWithoutHorizontals: binary, horizMask: [], erasedCount: 0)
        }
        
        let x0 = max(0, Int(floor(clipped.minX)))
        let y0 = max(0, Int(floor(clipped.minY)))
        let x1 = min(width, Int(ceil(clipped.maxX)))
        let y1 = min(height, Int(ceil(clipped.maxY)))
        
        var out = binary
        var mask = [UInt8](repeating: 0, count: width * height)
        
        @inline(__always)
        func distanceToNearestStaffLine(y: Int) -> CGFloat {
            guard !staffLinesY.isEmpty else { return .greatestFiniteMagnitude }
            let yf = CGFloat(y)
            var best = CGFloat.greatestFiniteMagnitude
            for ly in staffLinesY { best = min(best, abs(ly - yf)) }
            return best
        }
        
        // Erode protect for THIS horizontal pass only (reduces over-protection blocking staff removal)
        // Simple circular-ish neighborhood check with small radius; cheap because we only read protect.
        @inline(__always)
        func isProtectedEroded(x: Int, y: Int) -> Bool {
            // Erode: require the *entire* neighborhood to be protected.
            // If there is ANY gap in protectMask nearby, treat as NOT protected.
            let r = protectErodeR
            let yy0 = max(0, y - r), yy1 = min(height - 1, y + r)
            let xx0 = max(0, x - r), xx1 = min(width - 1, x + r)

            var yy = yy0
            while yy <= yy1 {
                let row = yy * width
                var xx = xx0
                while xx <= xx1 {
                    if protectMask[row + xx] == 0 { return false }
                    xx += 1
                }
                yy += 1
            }
            return true
        }

        
        @inline(__always)
        func maxThicknessAt(x: Int, y: Int) -> Int {
            // Measure thickness in a tight band around y (ties/beams should be thin)
            var t = 0
            let yy0 = max(0, y - maxHalfThickness)
            let yy1 = min(height - 1, y + maxHalfThickness)
            var yy = yy0
            while yy <= yy1 {
                if out[yy * width + x] != 0 { t += 1 }
                yy += 1
            }
            return t
        }

        @inline(__always)
        func isStraightRun(runStart: Int, runEnd: Int, y: Int) -> Bool {
            var minOffset = Int.max
            var maxOffset = Int.min
            var samples = 0
            var sx = runStart
            while sx < runEnd {
                var sum = 0
                var count = 0
                for dy in -tieBand...tieBand {
                    let yy = y + dy
                    if yy < 0 || yy >= height { continue }
                    if out[yy * width + sx] != 0 {
                        sum += dy
                        count += 1
                    }
                }
                if count > 0 {
                    let avgOffset = Int(round(Double(sum) / Double(count)))
                    minOffset = min(minOffset, avgOffset)
                    maxOffset = max(maxOffset, avgOffset)
                    samples += 1
                }
                sx += 2
            }
            if samples < 3 { return true }
            return (maxOffset - minOffset) <= 1
        }
        
        // Fast gate: scan a few rows for a run >= minRun
        // (Your old sampleStep=4 + run+=sampleStep can miss thin strokes; keep stride but measure correctly.)
        var foundRun = false
        let gateYStep = 3
        let gateXStep = 3
        if (x1 - x0) > 0 && (y1 - y0) > 0 {
            var y = y0
            while y < y1 && !foundRun {
                var x = x0
                var run = 0
                while x < x1 {
                    if binary[y * width + x] != 0 {
                        run += gateXStep
                        if run >= minRun { foundRun = true; break }
                    } else {
                        run = 0
                    }
                    x += gateXStep
                }
                y += gateYStep
            }
        }
        
        if !foundRun {
            log.notice("eraseHorizontalRuns skipped roi=\(String(describing: roi), privacy: .public)")
            return Result(binaryWithoutHorizontals: binary,
                          horizMask: [UInt8](repeating: 0, count: width * height),
                          erasedCount: 0)
        }
        
        var erased = 0
        
        // Main scan (row-by-row inside ROI)
        for y in y0..<y1 {
            
            // We DO still allow erasing near staff lines, but we require longer runs there.
            let nearStaff = distanceToNearestStaffLine(y: y) < staffExclusion
            let requiredRun = nearStaff ? minStaffRun : minRun
            
            var x = x0
            while x < x1 {
                // find run start
                while x < x1 && out[y * width + x] == 0 { x += 1 }
                if x >= x1 { break }
                let runStart = x
                
                // find run end
                while x < x1 && out[y * width + x] != 0 { x += 1 }
                let runEnd = x
                let runLen = runEnd - runStart
                if runLen < requiredRun { continue }
                
                // Measure protect overlap + thickness + "notehead bulk" heuristics
                var protectHits = 0
                var inkSamples = 0
                var maxT = 0
                var sx = runStart
                while sx < runEnd {
                    inkSamples += 1
                    if isProtectedEroded(x: sx, y: y) { protectHits += 1 }
                    maxT = max(maxT, maxThicknessAt(x: sx, y: y))
                    sx += 2
                }
                
                let protectFrac = Double(protectHits) / Double(max(1, inkSamples))
                
                let isStraight = isStraightRun(runStart: runStart, runEnd: runEnd, y: y)

                // Two thickness interpretations:
                // - tie/slur: very thin
                let isThinTie = maxT <= (2 * maxHalfThickness + 1)

                // - beam: can be thicker
                let isThinBeam = maxT <= (2 * beamMaxThickness + 1)

                // Qualify as a curved band (ties/slurs)
                var isCurvedBand = false
                if runLen >= minCurveRun && isThinTie {
                    var bandHits = 0
                    var bandSamples = 0
                    var sx = runStart
                    while sx < runEnd {
                        bandSamples += 1
                        var found = false
                        for dy in -tieBand...tieBand {
                            let yy = y + dy
                            if yy < 0 || yy >= height { continue }
                            if out[yy * width + sx] != 0 { found = true; break }
                        }
                        if found { bandHits += 1 }
                        sx += 2
                    }
                    let bandFrac = Double(bandHits) / Double(max(1, bandSamples))
                    isCurvedBand = bandFrac >= 0.65
                }

                // NEW: qualify straight “beam-like” runs too
                let distToStaff = distanceToNearestStaffLine(y: y)
                let qualifiesTie = isCurvedBand && protectFrac <= protectMaxFrac && isThinTie

                let qualifiesBeam =
                    isStraight &&
                    runLen >= beamMinRun &&
                    distToStaff >= beamStaffDist &&
                    isThinBeam &&
                    protectFrac <= beamProtectMaxFrac

                if (qualifiesTie || qualifiesBeam) {
                    let band = max(1, qualifiesBeam ? beamMaxThickness : maxHalfThickness)
                    let yy0 = max(0, y - band)
                    let yy1 = min(height - 1, y + band)
                    var yy = yy0
                    while yy <= yy1 {
                        let row = yy * width
                        for xx in runStart..<runEnd {
                            if isProtectedEroded(x: xx, y: yy) { continue }
                            if out[row + xx] != 0 {
                                out[row + xx] = 0
                                mask[row + xx] = 1
                                erased += 1
                            }
                        }
                        yy += 1
                    }
                }
            }
        }
        
        // Clamp (keep your safety net, but slightly higher tolerance since ROI is system-tight)
        let roiArea = max(1.0, Double((x1 - x0) * (y1 - y0)))
        let erasedFrac = Double(erased) / roiArea
        if erasedFrac > 0.10 {
            log.warning("eraseHorizontalRuns clamp triggered roi=\(String(describing: roi), privacy: .public) erasedFrac=\(erasedFrac, privacy: .public)")
            return Result(binaryWithoutHorizontals: binary,
                          horizMask: [UInt8](repeating: 0, count: width * height),
                          erasedCount: 0)
        }
        
        log.notice("eraseHorizontalRuns done erasedPixels=\(erased, privacy: .public)")
        return Result(binaryWithoutHorizontals: out, horizMask: mask, erasedCount: erased)
    }
    
}
