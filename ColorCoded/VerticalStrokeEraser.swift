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

        // Tunables (single-pass run-length eraser)
        let minRun = max(6, Int((0.55 * u).rounded()))
        let maxGap = 2

        let x0 = roi.x0, y0 = roi.y0, x1 = roi.x1, y1 = roi.y1
        let roiW = roi.roiW, roiH = roi.roiH
        let roiCount = roiW * roiH

        Scratch.ensureUInt8(&scratch.strokeMask, count: roiCount)
        scratch.ensureStackCapacity(max(1024, roiW * 2))

        @inline(__always) func idx(_ x: Int, _ y: Int) -> Int { y * width + x }
        @inline(__always) func ridx(_ x: Int, _ y: Int) -> Int { (y - y0) * roiW + (x - x0) }

        let tStart = CFAbsoluteTimeGetCurrent()

        var outFull = binary
        var erased = 0
        var strokeTotal = 0

        for x in x0...x1 {
            var runStart: Int? = nil
            var lastInkY = y0
            var gapCount = 0

            func flushRun() {
                guard let ys = runStart else { return }
                let ye = lastInkY
                let runLen = ye - ys + 1
                guard runLen >= minRun else {
                    runStart = nil
                    gapCount = 0
                    return
                }

                let xLeft = max(x0, x - 1)
                let xRight = min(x1, x + 1)

                for yy in ys...ye {
                    let fullRow = yy * width
                    let roiRow = (yy - y0) * roiW
                    for xx in xLeft...xRight {
                        let iFull = fullRow + xx
                        let iROI = roiRow + (xx - x0)
                        if binary[iFull] == 0 { continue }
                        if scratch.strokeMask[iROI] == 0 {
                            scratch.strokeMask[iROI] = 1
                            strokeTotal += 1
                        }
                        if protectExpandedROI[iROI] == 0 && outFull[iFull] != 0 {
                            outFull[iFull] = 0
                            erased += 1
                        }
                    }
                }

                runStart = nil
                gapCount = 0
            }

            var y = y0
            while y <= y1 {
                let iFull = y * width + x
                if binary[iFull] != 0 {
                    if runStart == nil { runStart = y }
                    lastInkY = y
                    gapCount = 0
                } else if runStart != nil {
                    gapCount += 1
                    if gapCount > maxGap {
                        flushRun()
                    }
                }
                y += 1
            }

            if runStart != nil {
                flushRun()
            }
        }

        let tPass1 = CFAbsoluteTimeGetCurrent()

        return Result(binaryWithoutStrokes: outFull,
                      strokeMaskROI: scratch.strokeMask,
                      roiX: x0, roiY: y0, roiW: roiW, roiH: roiH,
                      erasedCount: erased,
                      totalStrokeCount: strokeTotal,
                      pass1Ms: (tPass1 - tStart) * 1000,
                      pass2Ms: 0,
                      strokeDilateMs: 0,
                      eraseLoopMs: 0)
    }
}
