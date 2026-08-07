import CoreGraphics
import CoreImage
import Foundation

enum TerminalQRCodeError: LocalizedError {
    case generationFailed

    var errorDescription: String? { "Could not generate the pairing QR code." }
}

enum TerminalQRCode {
    /// Produces a high-contrast QR code using two terminal cells per module so phone cameras
    /// can scan it directly from Terminal.app and standard monospace shells.
    static func render(payload: String) throws -> String {
        guard let filter = CIFilter(name: "CIQRCodeGenerator") else { throw TerminalQRCodeError.generationFailed }
        filter.setValue(Data(payload.utf8), forKey: "inputMessage")
        filter.setValue("M", forKey: "inputCorrectionLevel")
        guard let output = filter.outputImage else { throw TerminalQRCodeError.generationFailed }
        let extent = output.extent.integral
        let width = Int(extent.width)
        let moduleHeight = Int(extent.height)
        var pixels = [UInt8](repeating: 255, count: width * moduleHeight)
        let context = CIContext(options: [.workingColorSpace: NSNull()])
        guard let image = context.createCGImage(output, from: extent, format: .L8, colorSpace: CGColorSpaceCreateDeviceGray()) else {
            throw TerminalQRCodeError.generationFailed
        }
        guard let provider = image.dataProvider, let data = provider.data else { throw TerminalQRCodeError.generationFailed }
        let source = CFDataGetBytePtr(data)
        let rowBytes = image.bytesPerRow
        for row in 0..<moduleHeight {
            for column in 0..<width {
                pixels[row * width + column] = source![row * rowBytes + column]
            }
        }

        let quietZone = 2
        let blank = String(repeating: "  ", count: width + quietZone * 2)
        var lines = Array(repeating: blank, count: quietZone)
        for row in 0..<moduleHeight {
            var line = String(repeating: "  ", count: quietZone)
            for column in 0..<width {
                line += pixels[row * width + column] < 128 ? "██" : "  "
            }
            line += String(repeating: "  ", count: quietZone)
            lines.append(line)
        }
        lines.append(contentsOf: Array(repeating: blank, count: quietZone))
        return lines.joined(separator: "\n")
    }
}
