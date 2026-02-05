import CoreImage
import CoreImage.CIFilterBuiltins

enum ImagePreprocessor {

    // Reuse a single CIContext (creating these repeatedly is expensive).
    // If you ever need different options, make a second cached context.
    private static let ctx: CIContext = {
        CIContext(options: [
            .useSoftwareRenderer: false
        ])
    }()

    static func preprocessForContours(_ image: CGImage) -> CGImage? {
        let ci = CIImage(cgImage: image)

        let controls = CIFilter.colorControls()
        controls.inputImage = ci
        controls.contrast = 1.4
        controls.brightness = 0.0
        controls.saturation = 0.0

        let exposure = CIFilter.exposureAdjust()
        exposure.inputImage = controls.outputImage
        exposure.ev = 0.4

        let sharpen = CIFilter.sharpenLuminance()
        sharpen.inputImage = exposure.outputImage
        sharpen.sharpness = 0.6

        guard let out = sharpen.outputImage else { return nil }
        return ctx.createCGImage(out, from: out.extent)
    }
}
