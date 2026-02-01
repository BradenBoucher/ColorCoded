import CoreGraphics

#if canImport(UIKit)
import UIKit
public extension UIImage {
    var cgImageSafe: CGImage? { self.cgImage }
}
#elseif canImport(AppKit)
import AppKit
public extension NSImage {
    var cgImageSafe: CGImage? {
        var rect = CGRect(origin: .zero, size: size)
        return cgImage(forProposedRect: &rect, context: nil, hints: nil)
    }
}
#endif
