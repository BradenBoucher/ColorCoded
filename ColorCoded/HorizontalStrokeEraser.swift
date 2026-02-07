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
        let maxHalfThickness = max(1, Int((0.10 * u).rounded()))       // thickness band half-width (so 2*+1 total)
        let protectMaxFrac: Double = 0.14                              // allow more protect overlap than before
        let protectErodeR = max(1, Int((0.06 * u).rounded()))          // shrink protect just for this pass
        let staffExclusion = spacing * 0.18                            // "near staff line" distance
        
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
            // If ANY protect pixel exists within radius, treat as protected.
            // Erosion effect comes from using smaller neighborhood than your protect-dilation elsewhere.
            let r = protectErodeR
            let yy0 = max(0, y - r), yy1 = min(height - 1, y + r)
            let xx0 = max(0, x - r), xx1 = min(width - 1, x + r)
            var yy = yy0
            while yy <= yy1 {
                let row = yy * width
                var xx = xx0
                while xx <= xx1 {
                    if protectMask[row + xx] != 0 { return true }
                    xx += 1
                }
                yy += 1
            }
            return false
        }
        
        @inline(__always)
        func localVerticalInkBulk(x: Int, y: Int) -> Int {
            // Counts ink in a taller window; noteheads have much more vertical bulk than ties/beams.
            let halfH = max(2, Int((0.35 * u).rounded()))
            let yy0 = max(0, y - halfH)
            let yy1 = min(height - 1, y + halfH)
            var c = 0
            var yy = yy0
            while yy <= yy1 {
                if out[yy * width + x] != 0 { c += 1 }
                yy += 1
            }
            return c
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
                var bulkHits = 0
                
                var sx = runStart
                while sx < runEnd {
                    inkSamples += 1
                    if isProtectedEroded(x: sx, y: y) { protectHits += 1 }
                    maxT = max(maxT, maxThicknessAt(x: sx, y: y))
                    
                    // Noteheads have larger vertical ink bulk around their center columns.
                    if localVerticalInkBulk(x: sx, y: y) >= Int((0.55 * u).rounded()) {
                        bulkHits += 1
                    }
                    sx += 2
                }
                
                let protectFrac = Double(protectHits) / Double(max(1, inkSamples))
                let bulkFrac = Double(bulkHits) / Double(max(1, inkSamples))
                
                // Thinness test
                let allowedThickness = (2 * maxHalfThickness + 1)
                let isThin = maxT <= allowedThickness
                
                // If too much vertical bulk along the run, it’s likely cutting through heads (beam+head area).
                // Don’t erase those; let vertical eraser + later filtering handle.
                let looksHeadAdjacent = bulkFrac >= 0.22
                
                // Qualify: long + thin + not-too-protected + not head-adjacent
                if isThin && !looksHeadAdjacent && protectFrac <= protectMaxFrac {
                    let band = max(1, maxHalfThickness)
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
