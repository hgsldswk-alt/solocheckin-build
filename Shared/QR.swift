import CoreImage
import CoreImage.CIFilterBuiltins
import Foundation

enum QR {
    static func image(_ value: String, scale: Int = 5) -> CIImage? {
        let filter = CIFilter.qrCodeGenerator()
        filter.message = Data(value.utf8)
        filter.correctionLevel = "M"
        return filter.outputImage?.transformed(by: CGAffineTransform(scaleX: CGFloat(scale), y: CGFloat(scale)))
    }
}
