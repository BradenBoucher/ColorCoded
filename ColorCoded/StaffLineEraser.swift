import CoreGraphics

enum StaffLineEraser {

    /// Removes staff lines by whitening only long horizontal runs near detected staff line y's.
    /// This avoids destroying noteheads that sit on lines.
    static func eraseStaffLines(in cgImage: CGImage, staff: StaffModel) -> CGImage? {
        let w = cgImage.width
        let h = cgImage.height
        guard w > 2, h > 2 else { return cgImage }

        // Pull pixels (RGBA)
        var pixels = [UInt8](repeating: 0, count: w * h * 4)
        guard let ctx = CGContext(
            data: &pixels,
            width: w,
            height: h,
            bitsPerComponent: 8,
            bytesPerRow: w * 4,
            space: CGColorSpaceCreateDeviceRGB(),
            bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue
        ) else { return nil }

        ctx.draw(cgImage, in: CGRect(x: 0, y: 0, width: w, height: h))

        // Parameters based on spacing
        let s = max(6.0, staff.lineSpacing)
        let bandHalf: Int = max(1, Int(round(s * 0.08)))      // thinner than your old 0.12
        let minRunPx: Int = max(20, Int(round(s * 10.0)))     // long horizontal run → likely staff line
        let lumThresh = 165                                   // tweak if needed

        func isInk(_ idx: Int) -> Bool {
            let r = Int(pixels[idx])
            let g = Int(pixels[idx + 1])
            let b = Int(pixels[idx + 2])
            let lum = (r + g + b) / 3
            return lum < lumThresh
        }

        // For each staff line, erase only long runs within a thin band
        for stave in staff.staves {
            for yF in stave {
                let yCenter = Int(round(yF))
                let y0 = max(0, yCenter - bandHalf)
                let y1 = min(h - 1, yCenter + bandHalf)

                for y in y0...y1 {
                    let rowStart = y * w * 4
                    var x = 0

                    while x < w {
                        let idx = rowStart + x * 4
                        if isInk(idx) {
                            // measure run length
                            let runStart = x
                            var runEnd = x
                            while runEnd < w {
                                let ii = rowStart + runEnd * 4
                                if !isInk(ii) { break }
                                runEnd += 1
                            }

                            let runLen = runEnd - runStart
                            if runLen >= minRunPx {
                                // erase this run by painting white pixels
                                for xx in runStart..<runEnd {
                                    let ii = rowStart + xx * 4
                                    pixels[ii] = 255
                                    pixels[ii + 1] = 255
                                    pixels[ii + 2] = 255
                                    pixels[ii + 3] = 255
                                }
                            }

                            x = runEnd
                        } else {
                            x += 1
                        }
                    }
                }
            }
        }

        return ctx.makeImage()
    }
}
