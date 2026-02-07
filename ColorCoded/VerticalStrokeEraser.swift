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
        let erasedCount: Int
        let totalStrokeCount: Int
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
        var strokeMask: [UInt8] = []
        var thin: [UInt8] = []
        var visited: [UInt8] = []
        var temp: [UInt8] = []
        var out: [UInt8] = []

        // Caller expects these
        var protectROI: [UInt8] = []
        var protectExpandedROI: [UInt8] = []

        var stackX: [Int] = []
        var stackY: [Int] = []
        var runPixelsX: [Int] = []
        var runPixelsY: [Int] = []
        var compPixels: [Int] = []

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

        // ✅ LESS AGGRESSIVE than before:
        // - require a LONGER run to qualify as a stroke
        // - allow fewer "bridged gaps"
        let minRun = max(12, Int((0.90 * u).rounded()))  // was ~0.55*u
        let maxGap = 1                                   // was 2

        let x0 = roi.x0, y0 = roi.y0, x1 = roi.x1, y1 = roi.y1
        let roiW = roi.roiW, roiH = roi.roiH
        let roiCount = roiW * roiH

        Scratch.ensureUInt8(&scratch.strokeMask, count: roiCount)
        scratch.ensureStackCapacity(max(1024, roiW * 2))

        @inline(__always) func ridx(_ x: Int, _ y: Int) -> Int { (y - y0) * roiW + (x - x0) }

        let tStart = CFAbsoluteTimeGetCurrent()

        var outFull = binary
        var erased = 0
        var strokeTotal = 0

        // Scan vertical runs column-by-column
        for x in x0...x1 {
            var runStart: Int? = nil
            var lastInkY = y0
            var gapCount = 0

            @inline(__always)
            func flushRun() {
                guard let ys = runStart else { return }
                let ye = lastInkY
                let runLen = ye - ys + 1

                guard runLen >= minRun else {
                    runStart = nil
                    gapCount = 0
                    return
                }

                // ✅ Even less destructive: erase ONLY this x (no x±1)
                let xx = x

                for yy in ys...ye {
                    let iFull = yy * width + xx
                    if binary[iFull] == 0 { continue }

                    let iROI = ridx(xx, yy)
                    if scratch.strokeMask[iROI] == 0 {
                        scratch.strokeMask[iROI] = 1
                        strokeTotal += 1
                    }

                    // Never erase inside protectExpandedROI
                    if protectExpandedROI[iROI] == 0 && outFull[iFull] != 0 {
                        outFull[iFull] = 0
                        erased += 1
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
