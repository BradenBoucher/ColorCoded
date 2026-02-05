import Foundation
import CoreGraphics

/// Detect + erase thin stroke-like ink (stems/tails/slurs/ties fragments) from a binary ink map.
/// - binary: 1 = ink, 0 = white
enum VerticalStrokeEraser {

    struct Result {
        let binaryWithoutStrokes: [UInt8]
        let strokeMaskROI: [UInt8]       // 1 where we consider pixels "stroke" (ROI only)
        let roiX: Int
        let roiY: Int
        let roiW: Int
        let roiH: Int
        let erasedCount: Int             // number of pixels cleared (not protected)
        let totalStrokeCount: Int        // total stroke pixels (including protected zones)
        let pass1Ms: Double
        let pass2Ms: Double
        let strokeDilateMs: Double
        let eraseLoopMs: Double
    }

    struct QuantizedROI {
        let x0: Int
        let y0: Int
        let x1: Int
        let y1: Int
        let roiW: Int
        let roiH: Int
    }

    struct Scratch {
        // ROI-sized buffers
        var strokeMask: [UInt8] = []
        var thin: [UInt8] = []
        var visited: [UInt8] = []
        var temp: [UInt8] = []
        var out: [UInt8] = []

        // Caller expects these (buildStrokeCleaned was using them)
        var protectROI: [UInt8] = []
        var protectExpandedROI: [UInt8] = []

        // Stacks / scratch lists
        var stackX: [Int] = []
        var stackY: [Int] = []
        var runPixelsX: [Int] = []
        var runPixelsY: [Int] = []
        var compPixels: [Int] = []

        /// IMPORTANT: static (NOT mutating) to avoid overlapping access to `scratch`
        static func ensureUInt8(_ array: inout [UInt8], count: Int) {
            if array.count != count {
                array = [UInt8](repeating: 0, count: count)
            } else {
                array.withUnsafeMutableBufferPointer { buf in
                    guard let base = buf.baseAddress else { return }
                    base.initialize(repeating: 0, count: count)
                }
            }
        }

        mutating func ensureStackCapacity(_ capacity: Int) {
            if stackX.capacity < capacity { stackX.reserveCapacity(capacity) }
            if stackY.capacity < capacity { stackY.reserveCapacity(capacity) }
            if runPixelsX.capacity < capacity { runPixelsX.reserveCapacity(capacity) }
            if runPixelsY.capacity < capacity { runPixelsY.reserveCapacity(capacity) }
            if compPixels.capacity < capacity { compPixels.reserveCapacity(capacity) }
        }
    }

    static func quantize(systemRect: CGRect, width: Int, height: Int) -> QuantizedROI? {
        let roi = systemRect.intersection(CGRect(x: 0, y: 0, width: width, height: height))
        if roi.width < 2 || roi.height < 2 { return nil }
        let x0 = max(0, Int(floor(roi.minX)))
        let y0 = max(0, Int(floor(roi.minY)))
        let x1 = min(width - 1, Int(ceil(roi.maxX)))
        let y1 = min(height - 1, Int(ceil(roi.maxY)))
        let roiW = max(0, x1 - x0 + 1)
        let roiH = max(0, y1 - y0 + 1)
        guard roiW > 0, roiH > 0 else { return nil }
        return QuantizedROI(x0: x0, y0: y0, x1: x1, y1: y1, roiW: roiW, roiH: roiH)
    }

    /// Simple ROI-only box dilation (naive; fast enough for ROI sizes you’re using)
    static func boxDilateROI(maskROI: inout [UInt8],
                             tempROI: inout [UInt8],
                             outROI: inout [UInt8],
                             roiW: Int,
                             roiH: Int,
                             radiusX: Int,
                             radiusY: Int) {
        let count = roiW * roiH
        guard count > 0,
              maskROI.count == count,
              tempROI.count == count,
              outROI.count == count else { return }

        // Clear temp/out (memset-fast)
        tempROI.withUnsafeMutableBufferPointer { buf in
            guard let base = buf.baseAddress else { return }
            base.initialize(repeating: 0, count: count)
        }
        outROI.withUnsafeMutableBufferPointer { buf in
            guard let base = buf.baseAddress else { return }
            base.initialize(repeating: 0, count: count)
        }

        // If no dilation needed, do nothing
        guard radiusX > 0 || radiusY > 0 else { return }

        // --- Pass A: vertical dilation into tempROI (sliding window sum) ---
        if radiusY > 0 {
            for x in 0..<roiW {
                var sum = 0

                // initialize window [0 ... radiusY]
                let initEnd = min(roiH - 1, radiusY)
                if initEnd >= 0 {
                    for y in 0...initEnd {
                        if maskROI[y * roiW + x] != 0 { sum += 1 }
                    }
                }

                for y in 0..<roiH {
                    if sum > 0 { tempROI[y * roiW + x] = 1 }

                    // remove y - radiusY
                    let yRemove = y - radiusY
                    if yRemove >= 0 {
                        if maskROI[yRemove * roiW + x] != 0 { sum -= 1 }
                    }

                    // add y + radiusY + 1
                    let yAdd = y + radiusY + 1
                    if yAdd < roiH {
                        if maskROI[yAdd * roiW + x] != 0 { sum += 1 }
                    }
                }
            }
        } else {
            // No vertical dilation => tempROI = maskROI
            tempROI.withUnsafeMutableBufferPointer { dst in
                maskROI.withUnsafeBufferPointer { src in
                    guard let d = dst.baseAddress, let s = src.baseAddress else { return }
                    d.assign(from: s, count: count)
                }
            }
        }

        // --- Pass B: horizontal dilation into outROI (sliding window sum) ---
        if radiusX > 0 {
            for y in 0..<roiH {
                let row = y * roiW
                var sum = 0

                // initialize window [0 ... radiusX]
                let initEnd = min(roiW - 1, radiusX)
                if initEnd >= 0 {
                    for x in 0...initEnd {
                        if tempROI[row + x] != 0 { sum += 1 }
                    }
                }

                for x in 0..<roiW {
                    if sum > 0 { outROI[row + x] = 1 }

                    // remove x - radiusX
                    let xRemove = x - radiusX
                    if xRemove >= 0 {
                        if tempROI[row + xRemove] != 0 { sum -= 1 }
                    }

                    // add x + radiusX + 1
                    let xAdd = x + radiusX + 1
                    if xAdd < roiW {
                        if tempROI[row + xAdd] != 0 { sum += 1 }
                    }
                }
            }
        } else {
            // No horizontal dilation => outROI = tempROI
            outROI.withUnsafeMutableBufferPointer { dst in
                tempROI.withUnsafeBufferPointer { src in
                    guard let d = dst.baseAddress, let s = src.baseAddress else { return }
                    d.assign(from: s, count: count)
                }
            }
        }

        // result back into maskROI
        swap(&maskROI, &outROI)
    }


    static func eraseStrokes(binary: [UInt8],
                             width: Int,
                             height: Int,
                             roi: QuantizedROI,
                             spacing: CGFloat,
                             protectExpandedROI: [UInt8],
                             scratch: inout Scratch) -> Result {

        guard binary.count == width * height,
              protectExpandedROI.count == roi.roiW * roi.roiH else {
            return Result(binaryWithoutStrokes: binary,
                          strokeMaskROI: [],
                          roiX: roi.x0, roiY: roi.y0, roiW: roi.roiW, roiH: roi.roiH,
                          erasedCount: 0, totalStrokeCount: 0,
                          pass1Ms: 0, pass2Ms: 0, strokeDilateMs: 0, eraseLoopMs: 0)
        }

        let u = max(6.0, spacing)

        // Tunables
        let minRun = max(10, Int((2.2 * u).rounded()))
        let maxGap = max(1, Int((0.12 * u).rounded()))
        let maxWidth = max(2, Int((0.15 * u).rounded()))
        let longRunThreshold = Int((3.2 * u).rounded())
        let maxWidthLong = max(4, Int((0.22 * u).rounded()))
        let dilateR = max(1, Int((0.06 * u).rounded()))

        let thinWidth = max(2, Int((0.12 * u).rounded()))
        let compLongSideMin = max(10, Int((1.15 * u).rounded()))
        let compShortSideMax = max(3, Int((0.28 * u).rounded()))
        let compMinPixels = max(18, Int((0.45 * u).rounded()))

        let x0 = roi.x0, y0 = roi.y0, x1 = roi.x1, y1 = roi.y1
        let roiW = roi.roiW, roiH = roi.roiH
        let roiCount = roiW * roiH

        Scratch.ensureUInt8(&scratch.strokeMask, count: roiCount)
        Scratch.ensureUInt8(&scratch.thin, count: roiCount)
        Scratch.ensureUInt8(&scratch.visited, count: roiCount)
        Scratch.ensureUInt8(&scratch.temp, count: roiCount)
        Scratch.ensureUInt8(&scratch.out, count: roiCount)
        scratch.ensureStackCapacity(max(1024, roiW * 2))

        @inline(__always) func idx(_ x: Int, _ y: Int) -> Int { y * width + x }
        @inline(__always) func ridx(_ x: Int, _ y: Int) -> Int { (y - y0) * roiW + (x - x0) }
        @inline(__always) func ink(_ x: Int, _ y: Int) -> Bool { binary[idx(x, y)] != 0 }

        @inline(__always) func findInkNeighborX(_ baseX: Int, _ y: Int) -> Int? {
            if ink(baseX, y) { return baseX }
            if baseX > 0 && ink(baseX - 1, y) { return baseX - 1 }
            if baseX + 1 < width && ink(baseX + 1, y) { return baseX + 1 }
            return nil
        }

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

        let tStart = CFAbsoluteTimeGetCurrent()

        // PASS 1
        for x in x0...x1 {
            var runStart: Int? = nil
            var runInkCount = 0
            var runWidthSum = 0
            var gapCount = 0
            scratch.runPixelsX.removeAll(keepingCapacity: true)
            scratch.runPixelsY.removeAll(keepingCapacity: true)

            func flushRun(at yEndExclusive: Int) {
                guard let ys = runStart else { return }
                let ye = yEndExclusive
                let runLen = ye - ys
                if runLen >= minRun && runInkCount > 0 {
                    let avgW = Double(runWidthSum) / Double(runInkCount)
                    let widthLimit = runLen >= longRunThreshold ? Double(maxWidthLong) : Double(maxWidth)
                    if avgW <= widthLimit {
                        for i in 0..<scratch.runPixelsX.count {
                            scratch.strokeMask[ridx(scratch.runPixelsX[i], scratch.runPixelsY[i])] = 1
                        }
                    }
                }
                runStart = nil
                runInkCount = 0
                runWidthSum = 0
                gapCount = 0
            }

            for y in y0...y1 {
                if let nx = (runStart != nil ? findInkNeighborX(x, y) : (ink(x, y) ? x : nil)) {
                    if runStart == nil { runStart = y }
                    runInkCount += 1
                    runWidthSum += localWidthAt(nx, y)
                    gapCount = 0
                    scratch.runPixelsX.append(nx)
                    scratch.runPixelsY.append(y)
                } else if runStart != nil {
                    gapCount += 1
                    if gapCount > maxGap {
                        flushRun(at: y - gapCount + 1)
                    }
                }
            }

            if runStart != nil { flushRun(at: y1 + 1) }
        }

        let tPass1 = CFAbsoluteTimeGetCurrent()

        // PASS 2
        for y in y0...y1 {
            for x in x0...x1 {
                if ink(x, y) && localWidthAt(x, y) <= thinWidth {
                    scratch.thin[ridx(x, y)] = 1
                }
            }
        }

        let neighbor8 = [(-1,-1),(0,-1),(1,-1),
                         (-1, 0),       (1, 0),
                         (-1, 1),(0, 1),(1, 1)]

        for y in y0...y1 {
            for x in x0...x1 {
                let ri0 = ridx(x, y)
                if scratch.thin[ri0] == 0 || scratch.visited[ri0] != 0 { continue }

                scratch.visited[ri0] = 1
                scratch.stackX.removeAll(keepingCapacity: true)
                scratch.stackY.removeAll(keepingCapacity: true)
                scratch.stackX.append(x)
                scratch.stackY.append(y)

                var minX = x, maxX = x, minY = y, maxY = y
                var pixels = 0
                var compPixelCount = 0

                while let cx = scratch.stackX.popLast(), let cy = scratch.stackY.popLast() {
                    pixels += 1
                    minX = min(minX, cx); maxX = max(maxX, cx)
                    minY = min(minY, cy); maxY = max(maxY, cy)

                    let ri = ridx(cx, cy)
                    if compPixelCount < scratch.compPixels.count {
                        scratch.compPixels[compPixelCount] = ri
                    } else {
                        scratch.compPixels.append(ri)
                    }
                    compPixelCount += 1

                    for (dx, dy) in neighbor8 {
                        let nx = cx + dx
                        let ny = cy + dy
                        if nx < x0 || nx > x1 || ny < y0 || ny > y1 { continue }
                        let ni = ridx(nx, ny)
                        if scratch.thin[ni] != 0 && scratch.visited[ni] == 0 {
                            scratch.visited[ni] = 1
                            scratch.stackX.append(nx)
                            scratch.stackY.append(ny)
                        }
                    }
                }

                if pixels < compMinPixels { continue }

                let bboxW = maxX - minX + 1
                let bboxH = maxY - minY + 1
                let longSide = max(bboxW, bboxH)
                let shortSide = min(bboxW, bboxH)

                if longSide >= compLongSideMin && shortSide <= compShortSideMax {
                    for i in 0..<compPixelCount {
                        scratch.strokeMask[scratch.compPixels[i]] = 1
                    }
                }
            }
        }

        let tPass2 = CFAbsoluteTimeGetCurrent()

        // Dilate stroke mask (ROI)
        if dilateR > 0 {
            boxDilateROI(maskROI: &scratch.strokeMask,
                         tempROI: &scratch.temp,
                         outROI: &scratch.out,
                         roiW: roiW,
                         roiH: roiH,
                         radiusX: 1,
                         radiusY: dilateR + 1)
        }

        let tDilate = CFAbsoluteTimeGetCurrent()

        // Apply erase
        var outFull = binary
        var erased = 0
        var strokeTotal = 0

        for y in y0...y1 {
            let row = y * width
            for x in x0...x1 {
                let iFull = row + x
                let iROI = ridx(x, y)
                if scratch.strokeMask[iROI] != 0 {
                    strokeTotal += 1
                    if protectExpandedROI[iROI] == 0 && outFull[iFull] != 0 {
                        outFull[iFull] = 0
                        erased += 1
                    }
                }
            }
        }

        let tErase = CFAbsoluteTimeGetCurrent()

        return Result(binaryWithoutStrokes: outFull,
                      strokeMaskROI: scratch.strokeMask,
                      roiX: x0, roiY: y0, roiW: roiW, roiH: roiH,
                      erasedCount: erased,
                      totalStrokeCount: strokeTotal,
                      pass1Ms: (tPass1 - tStart) * 1000,
                      pass2Ms: (tPass2 - tPass1) * 1000,
                      strokeDilateMs: (tDilate - tPass2) * 1000,
                      eraseLoopMs: (tErase - tDilate) * 1000)
    }
}
