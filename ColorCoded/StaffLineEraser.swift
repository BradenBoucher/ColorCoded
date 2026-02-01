import CoreGraphics

enum StaffLineEraser {
    /// Removes staff lines by painting thin white bands along detected staff lines.
    static func eraseStaffLines(in cgImage: CGImage, staff: StaffModel) -> CGImage? {
        let w = cgImage.width
        let h = cgImage.height

        let colorSpace = CGColorSpaceCreateDeviceRGB()
        guard let ctx = CGContext(
            data: nil,
            width: w,
            height: h,
            bitsPerComponent: 8,
            bytesPerRow: w * 4,
            space: colorSpace,
            bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue
        ) else { return nil }

        ctx.draw(cgImage, in: CGRect(x: 0, y: 0, width: w, height: h))
        ctx.setFillColor(CGColor(red: 1, green: 1, blue: 1, alpha: 1))

        let bandHalfThickness: CGFloat = max(1.0, staff.lineSpacing * 0.12)

        for lines in staff.staves {
            for y in lines {
                let rect = CGRect(
                    x: 0,
                    y: y - bandHalfThickness,
                    width: CGFloat(w),
                    height: bandHalfThickness * 2
                )
                ctx.fill(rect)
            }
        }

        return ctx.makeImage()
    }
}
