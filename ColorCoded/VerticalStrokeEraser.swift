import CoreGraphics

enum VerticalStrokeEraser {
    struct Result {
        let strokeMask: [UInt8]
        let binaryWithoutStrokes: [UInt8]
    }

    static func eraseStrokes(binary: [UInt8],
                             width: Int,
                             height: Int,
                             systemRect: CGRect,
                             spacing: CGFloat,
                             protectMask: [UInt8]) -> Result {
        guard width > 0, height > 0, binary.count == width * height else {
            return Result(strokeMask: [], binaryWithoutStrokes: binary)
        }

        let clipped = systemRect.intersection(CGRect(x: 0, y: 0, width: width, height: height))
        guard clipped.width > 1, clipped.height > 1 else {
            return Result(strokeMask: [], binaryWithoutStrokes: binary)
        }

        let x0 = max(0, Int(floor(clipped.minX)))
        let y0 = max(0, Int(floor(clipped.minY)))
        let x1 = min(width, Int(ceil(clipped.maxX)))
        let y1 = min(height, Int(ceil(clipped.maxY)))

        let minRun = max(4, Int(round(spacing * 2.8)))
        let maxWidth = max(2, Int(round(spacing * 0.10)))

        var strokeMask = [UInt8](repeating: 0, count: width * height)

        for x in x0..<x1 {
            var runStart = y0
            var runLength = 0

            func commitRun(endYExclusive: Int) {
                guard runLength >= minRun else { return }
                var thinCount = 0
                for y in runStart..<endYExclusive {
                    let row = y * width
                    var widthCount = 0
                    for xx in max(x - 1, x0)..<min(x + 2, x1) {
                        if binary[row + xx] != 0 { widthCount += 1 }
                    }
                    if widthCount <= maxWidth { thinCount += 1 }
                }
                let thinFrac = Double(thinCount) / Double(max(1, runLength))
                guard thinFrac > 0.60 else { return }
                for y in runStart..<endYExclusive {
                    strokeMask[y * width + x] = 1
                }
            }

            for y in y0..<y1 {
                let idx = y * width + x
                if binary[idx] != 0 {
                    if runLength == 0 { runStart = y }
                    runLength += 1
                } else if runLength > 0 {
                    commitRun(endYExclusive: y)
                    runLength = 0
                }
            }
            if runLength > 0 {
                commitRun(endYExclusive: y1)
            }
        }

        let dilated = dilate(mask: strokeMask,
                             width: width,
                             height: height,
                             rect: clipped,
                             radius: max(1, Int(round(spacing * 0.06))))

        var cleaned = binary
        for y in y0..<y1 {
            let row = y * width
            for x in x0..<x1 {
                let idx = row + x
                if dilated[idx] != 0 && protectMask[idx] == 0 {
                    cleaned[idx] = 0
                }
            }
        }

        return Result(strokeMask: dilated, binaryWithoutStrokes: cleaned)
    }

    private static func dilate(mask: [UInt8],
                               width: Int,
                               height: Int,
                               rect: CGRect,
                               radius: Int) -> [UInt8] {
        guard radius > 0 else { return mask }
        var out = mask

        let x0 = max(0, Int(floor(rect.minX)))
        let y0 = max(0, Int(floor(rect.minY)))
        let x1 = min(width, Int(ceil(rect.maxX)))
        let y1 = min(height, Int(ceil(rect.maxY)))

        for y in y0..<y1 {
            for x in x0..<x1 {
                guard mask[y * width + x] != 0 else { continue }
                for yy in max(y - radius, y0)..<min(y + radius + 1, y1) {
                    let row = yy * width
                    for xx in max(x - radius, x0)..<min(x + radius + 1, x1) {
                        out[row + xx] = 1
                    }
                }
            }
        }

        return out
    }
}
