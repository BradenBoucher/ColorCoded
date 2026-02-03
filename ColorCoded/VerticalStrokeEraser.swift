import Foundation
import CoreGraphics

/// Detect + erase thin stroke-like ink (stems/tails/slurs/ties fragments) from a binary ink map.
/// - binary: 1 = ink, 0 = white
enum VerticalStrokeEraser {

    struct Result {
        let binaryWithoutStrokes: [UInt8]
        let strokeMask: [UInt8]          // 1 where we consider pixels "stroke"
        let erasedCount: Int             // number of pixels cleared (not protected)
        let totalStrokeCount: Int        // total stroke pixels (including protected zones)
    }

    static func eraseStrokes(binary: [UInt8],
                             width: Int,
                             height: Int,
                             systemRect: CGRect,
                             spacing: CGFloat,
                             protectMask: [UInt8]) -> Result {

        guard binary.count == width * height,
              protectMask.count == width * height else {
            return Result(binaryWithoutStrokes: binary,
                          strokeMask: [UInt8](repeating: 0, count: max(0, width * height)),
                          erasedCount: 0,
                          totalStrokeCount: 0)
        }

        let u = max(6.0, spacing)

        // --- Tunables ---
        let minRun = max(10, Int((2.2 * u).rounded()))
        let maxGap = max(1, Int((0.12 * u).rounded()))
        let maxWidth = max(2, Int((0.15 * u).rounded()))
        let dilateR = max(1, Int((0.06 * u).rounded()))

        // Extra pass: diagonal/curved thin components (tails/slurs)
        let thinWidth = max(2, Int((0.12 * u).rounded()))
        let compLongSideMin = max(10, Int((1.15 * u).rounded()))
        let compShortSideMax = max(3, Int((0.28 * u).rounded()))
        let compMinPixels = max(18, Int((0.45 * u).rounded()))

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

        var strokeMask = [UInt8](repeating: 0, count: width * height)

        @inline(__always) func idx(_ x: Int, _ y: Int) -> Int { y * width + x }
        @inline(__always) func ink(_ x: Int, _ y: Int) -> Bool { binary[idx(x, y)] != 0 }

        @inline(__always) func localWidthAt(_ x: Int, _ y: Int) -> Int {
            if thinWidth <= 2 {
                var w = 0
                if x > 0 && ink(x - 1, y) { w += 1 }
                if ink(x, y) { w += 1 }
                if x + 1 < width && ink(x + 1, y) { w += 1 }
                return w
            } else {
                let r = min(2, thinWidth)
                var w = 0
                for xx in max(0, x - r)...min(width - 1, x + r) {
                    if ink(xx, y) { w += 1 }
                }
                return w
            }
        }

        // ------------------------------------------------------------
        // PASS 1: long thin vertical runs
        // ------------------------------------------------------------
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
                        for yy in ys..<ye {
                            if yy >= y0 && yy <= y1, ink(x, yy) {
                                strokeMask[idx(x, yy)] = 1
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
                    gapCount += 1
                    if gapCount > maxGap {
                        flushRun(at: y - gapCount + 1)
                    }
                }
            }

            if runStart != nil {
                flushRun(at: y1 + 1)
            }
        }

        // ------------------------------------------------------------
        // PASS 2: thin diagonal/curved components (tails/slurs/ties)
        // ------------------------------------------------------------
        let roiW = x1 - x0 + 1
        let roiH = y1 - y0 + 1
        var thin = [UInt8](repeating: 0, count: roiW * roiH)
        var visited = [UInt8](repeating: 0, count: roiW * roiH)

        @inline(__always) func ridx(_ x: Int, _ y: Int) -> Int { (y - y0) * roiW + (x - x0) }

        for y in y0...y1 {
            for x in x0...x1 {
                if ink(x, y) && localWidthAt(x, y) <= thinWidth {
                    thin[ridx(x, y)] = 1
                }
            }
        }

        let neighbor8 = [(-1,-1),(0,-1),(1,-1),
                         (-1, 0),       (1, 0),
                         (-1, 1),(0, 1),(1, 1)]

        var stackX: [Int] = []
        var stackY: [Int] = []
        stackX.reserveCapacity(2048)
        stackY.reserveCapacity(2048)

        for y in y0...y1 {
            for x in x0...x1 {
                let ri = ridx(x, y)
                if thin[ri] == 0 || visited[ri] != 0 { continue }

                visited[ri] = 1
                stackX.removeAll(keepingCapacity: true)
                stackY.removeAll(keepingCapacity: true)
                stackX.append(x)
                stackY.append(y)

                var minX = x, maxX = x, minY = y, maxY = y
                var pixels = 0

                while let cx = stackX.popLast(), let cy = stackY.popLast() {
                    pixels += 1
                    minX = min(minX, cx); maxX = max(maxX, cx)
                    minY = min(minY, cy); maxY = max(maxY, cy)

                    for (dx, dy) in neighbor8 {
                        let nx = cx + dx
                        let ny = cy + dy
                        if nx < x0 || nx > x1 || ny < y0 || ny > y1 { continue }
                        let ni = ridx(nx, ny)
                        if thin[ni] != 0 && visited[ni] == 0 {
                            visited[ni] = 1
                            stackX.append(nx)
                            stackY.append(ny)
                        }
                    }
                }

                if pixels < compMinPixels { continue }

                let bboxW = maxX - minX + 1
                let bboxH = maxY - minY + 1
                let longSide = max(bboxW, bboxH)
                let shortSide = min(bboxW, bboxH)

                if longSide >= compLongSideMin && shortSide <= compShortSideMax {
                    for yy in minY...maxY {
                        for xx in minX...maxX {
                            if ink(xx, yy) {
                                strokeMask[idx(xx, yy)] = 1
                            }
                        }
                    }
                }
            }
        }

        // ------------------------------------------------------------
        // Dilate stroke mask (inside ROI)
        // ------------------------------------------------------------
        if dilateR > 0 {
            var dilated = strokeMask
            for y in y0...y1 {
                for x in x0...x1 {
                    if strokeMask[idx(x, y)] == 0 { continue }
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

        // ------------------------------------------------------------
        // Apply erase (respect protectMask)
        // ------------------------------------------------------------
        var out = binary
        var erased = 0
        var strokeTotal = 0

        for y in y0...y1 {
            let row = y * width
            for x in x0...x1 {
                let i = row + x
                if strokeMask[i] != 0 {
                    strokeTotal += 1
                    if protectMask[i] == 0 && out[i] != 0 {
                        out[i] = 0
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
