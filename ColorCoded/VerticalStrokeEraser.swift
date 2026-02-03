import Foundation
import CoreGraphics

/// Detect + erase thin vertical strokes (stems/tails/barline fragments) from a binary ink map.
/// binary: 1 = ink, 0 = white
enum VerticalStrokeEraser {

    struct Result {
        let binaryWithoutStrokes: [UInt8]
        let strokeMask: [UInt8]     // full-page mask, 1 where stroke detected
        let erasedCount: Int
        let strokeCount: Int
    }

    /// binary: 1=ink, 0=white
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
                          strokeCount: 0)
        }

        let u = max(6.0, spacing)

        // Tunables (these are intentionally aggressive to show visible change)
        let minRun = max(8, Int((spacing * 1.8).rounded())) // stems/tails are long
        let gapMax = 2                                      // bridge tiny gaps
        let maxWidth3px = max(2, Int((0.16 * u).rounded())) // thin stroke test (2–3 px)
        let dilateR = max(1, Int((0.06 * u).rounded()))     // 1–2 px

        let roi = systemRect.intersection(CGRect(x: 0, y: 0, width: width, height: height))
        if roi.width < 2 || roi.height < 2 {
            return Result(binaryWithoutStrokes: binary,
                          strokeMask: [UInt8](repeating: 0, count: width * height),
                          erasedCount: 0,
                          strokeCount: 0)
        }

        let x0 = max(0, Int(floor(roi.minX)))
        let y0 = max(0, Int(floor(roi.minY)))
        let x1 = min(width - 1, Int(ceil(roi.maxX)))
        let y1 = min(height - 1, Int(ceil(roi.maxY)))

        @inline(__always) func isInk(_ x: Int, _ y: Int) -> Bool {
            binary[y * width + x] != 0
        }

        // quick local width estimate around a point (helps avoid marking noteheads/beams)
        @inline(__always) func localWidth(_ x: Int, _ y: Int) -> Int {
            var c = 0
            if x > 0 && isInk(x - 1, y) { c += 1 }
            if isInk(x, y) { c += 1 }
            if x + 1 < width && isInk(x + 1, y) { c += 1 }
            return c
        }

        var strokeMask = [UInt8](repeating: 0, count: width * height)

        // 1) Detect thin vertical runs per column
        for x in x0...x1 {
            var runStart: Int? = nil
            var runLen = 0
            var gap = 0
            var inkCount = 0
            var widthSum = 0

            func commit(endYExclusive: Int) {
                guard let ys = runStart else { return }
                let ye = endYExclusive
                if runLen >= minRun && inkCount > 0 {
                    let avgW = Double(widthSum) / Double(inkCount)
                    if avgW <= Double(maxWidth3px) {
                        for yy in ys..<ye {
                            if isInk(x, yy) { strokeMask[yy * width + x] = 1 }
                        }
                    }
                }
                runStart = nil
                runLen = 0
                gap = 0
                inkCount = 0
                widthSum = 0
            }

            for y in y0...y1 {
                if isInk(x, y) {
                    if runStart == nil { runStart = y }
                    runLen += 1
                    inkCount += 1
                    widthSum += localWidth(x, y)
                    gap = 0
                } else if runStart != nil {
                    gap += 1
                    if gap <= gapMax {
                        runLen += 1 // keep run alive
                    } else {
                        commit(endYExclusive: y - gap + 1)
                    }
                }
            }
            if runStart != nil { commit(endYExclusive: y1 + 1) }
        }

        // 2) Dilate stroke mask slightly so anti-aliased edges don’t survive
        if dilateR > 0 {
            var dilated = strokeMask
            for y in y0...y1 {
                for x in x0...x1 where strokeMask[y * width + x] != 0 {
                    let xx0 = max(x0, x - dilateR)
                    let xx1 = min(x1, x + dilateR)
                    let yy0 = max(y0, y - dilateR)
                    let yy1 = min(y1, y + dilateR)
                    for yy in yy0...yy1 {
                        let row = yy * width
                        for xx in xx0...xx1 { dilated[row + xx] = 1 }
                    }
                }
            }
            strokeMask = dilated
        }

        // 3) Erase: clear stroke pixels unless protected
        var out = binary
        var erased = 0
        var strokeCount = 0

        for y in y0...y1 {
            let row = y * width
            for x in x0...x1 {
                let idx = row + x
                if strokeMask[idx] != 0 {
                    strokeCount += 1
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
                      strokeCount: strokeCount)
    }
}
