import Foundation
import CoreGraphics

/// Detect + erase thin vertical strokes (stems/tails/barline fragments) from a binary ink map.
/// binary: 1 = ink, 0 = white
enum VerticalStrokeEraser {

    struct Result {
        let binaryWithoutStrokes: [UInt8]
        let strokeMask: [UInt8]          // 1 where we consider pixels "stroke"
        let erasedCount: Int             // number of pixels cleared (not protected)
        let totalStrokeCount: Int        // total stroke pixels (including protected zones)
    }

    /// Main entry point.
    /// - Parameters:
    ///   - binary: full page binary (w*h)
    ///   - width/height: page dims
    ///   - systemRect: ROI in *pixel coords* (same coord space as binary)
    ///   - spacing: staff spacing in pixels (approx)
    ///   - protectMask: full page mask (1=protected, 0=erasable)
    static func eraseStrokes(binary: [UInt8],
                             width: Int,
                             height: Int,
                             systemRect: CGRect,
                             spacing: CGFloat,
                             protectMask: [UInt8]) -> Result {

        guard binary.count == width * height,
              protectMask.count == width * height else {
            return Result(binaryWithoutStrokes: binary,
                          strokeMask: [UInt8](repeating: 0, count: width * height),
                          erasedCount: 0,
                          totalStrokeCount: 0)
        }

        // --- Tunables (these matter) ---
        let u = max(6.0, spacing)

        // Minimum height of vertical run to count as a "stroke"
        // (stems are typically multiple spacings tall)
        let minRun = max(10, Int((2.4 * u).rounded()))

        // Allow small gaps because anti-aliasing often breaks runs
        let maxGap = max(1, Int((0.10 * u).rounded()))   // typically 1–2 px

        // Must be "thin": average width across run <= maxWidth
        let maxWidth = max(2, Int((0.14 * u).rounded())) // typically 2–3 px

        // Dilate stroke mask so edges don't survive as micro-contours
        let dilateR = max(1, Int((0.06 * u).rounded()))  // typically 1–2 px

        // Clip ROI
        let roi = systemRect.intersection(CGRect(x: 0, y: 0, width: width, height: height))
        if roi.width < 2 || roi.height < 2 {
            return Result(binaryWithoutStrokes: binary,
                          strokeMask: [UInt8](repeating: 0, count: width * height),
                          erasedCount: 0,
                          totalStrokeCount: 0)
        }

        let x0 = max(0, Int(floor(roi.minX)))
        let y0 = max(0, Int(floor(roi.minY)))
        let x1 = min(width - 1, Int(ceil(roi.maxX)))
        let y1 = min(height - 1, Int(ceil(roi.maxY)))

        // --- Build stroke mask ---
        var strokeMask = [UInt8](repeating: 0, count: width * height)

        // Helper to read ink
        @inline(__always) func ink(_ x: Int, _ y: Int) -> Bool {
            binary[y * width + x] != 0
        }

        // Estimate local "thickness" at a pixel by checking a small horizontal neighborhood
        // Returns 1..3ish (for stems), bigger for noteheads/beams
        @inline(__always) func localWidthAt(_ x: Int, _ y: Int) -> Int {
            var w = 0
            if x > 0 && ink(x - 1, y) { w += 1 }
            if ink(x, y) { w += 1 }
            if x + 1 < width && ink(x + 1, y) { w += 1 }
            return w
        }

        // Scan each column in ROI to find long vertical runs, with gap-bridging.
        for x in x0...x1 {
            var runStart: Int? = nil
            var runInkCount = 0
            var runWidthSum = 0
            var gapCount = 0

            func flushRun(at yEndExclusive: Int) {
                guard let ys = runStart else { return }
                let ye = yEndExclusive
                let runLen = ye - ys
                if runLen >= minRun && runInkCount > 0 {
                    let avgW = Double(runWidthSum) / Double(runInkCount)
                    if avgW <= Double(maxWidth) {
                        // Mark as stroke
                        for yy in ys..<ye {
                            if ink(x, yy) { // only mark actual ink pixels
                                strokeMask[yy * width + x] = 1
                            }
                        }
                    }
                }
                runStart = nil
                runInkCount = 0
                runWidthSum = 0
                gapCount = 0
            }

            for y in y0...y1 {
                if ink(x, y) {
                    if runStart == nil { runStart = y }
                    runInkCount += 1
                    runWidthSum += localWidthAt(x, y)
                    gapCount = 0
                } else if runStart != nil {
                    // white pixel inside a run: allow small gaps
                    gapCount += 1
                    if gapCount > maxGap {
                        flushRun(at: y - gapCount + 1)
                    }
                }
            }
            // Flush at end
            if runStart != nil {
                flushRun(at: y1 + 1)
            }
        }

        // Dilate stroke mask inside ROI (simple square dilation)
        if dilateR > 0 {
            var dilated = strokeMask
            for y in y0...y1 {
                for x in x0...x1 {
                    let idx = y * width + x
                    if strokeMask[idx] == 0 { continue }
                    let xx0 = max(x0, x - dilateR)
                    let xx1 = min(x1, x + dilateR)
                    let yy0 = max(y0, y - dilateR)
                    let yy1 = min(y1, y + dilateR)
                    for yy in yy0...yy1 {
                        let row = yy * width
                        for xx in xx0...xx1 {
                            dilated[row + xx] = 1
                        }
                    }
                }
            }
            strokeMask = dilated
        }

        // --- Apply erasing (but do not erase protected pixels) ---
        var out = binary
        var erased = 0
        var strokeTotal = 0

        for y in y0...y1 {
            let row = y * width
            for x in x0...x1 {
                let idx = row + x
                if strokeMask[idx] != 0 {
                    strokeTotal += 1
                    if protectMask[idx] == 0 && out[idx] != 0 {
                        out[idx] = 0
                        erased += 1
                    }
                }
            }
        }

        return Result(binaryWithoutStrokes: out,
                      strokeMask: strokeMask,
                      erasedCount: erased,
                      totalStrokeCount: strokeTotal)
    }
}
