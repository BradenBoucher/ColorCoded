import CoreImage
import CoreImage.CIFilterBuiltins

enum ImagePreprocessor {
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

        let ctx = CIContext(options: [.useSoftwareRenderer: false])
        guard let out = sharpen.outputImage else { return nil }
        return ctx.createCGImage(out, from: out.extent)
    }
}
