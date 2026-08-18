import CoreGraphics
import CoreImage
import Foundation

enum TerminalQRCodeError: LocalizedError {
    case generationFailed

    var errorDescription: String? { "Could not generate the pairing QR code." }
}

enum TerminalQRCode {
    /// Packs two module rows into each terminal row. A terminal cell is roughly twice as tall
    /// as it is wide, so the half-block characters keep modules square without doubling width.
    static func render(payload: String) throws -> String {
        guard let filter = CIFilter(name: "CIQRCodeGenerator") else { throw TerminalQRCodeError.generationFailed }
        filter.setValue(Data(payload.utf8), forKey: "inputMessage")
        filter.setValue("L", forKey: "inputCorrectionLevel")
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

        let quietZone = 4
        let totalWidth = width + quietZone * 2
        let blank = String(repeating: " ", count: totalWidth)
        var lines = Array(repeating: blank, count: quietZone / 2)
        for row in stride(from: 0, to: moduleHeight, by: 2) {
            var line = String(repeating: " ", count: quietZone)
            for column in 0..<width {
                let upperIsDark = pixels[row * width + column] < 128
                let lowerIsDark = row + 1 < moduleHeight && pixels[(row + 1) * width + column] < 128
                switch (upperIsDark, lowerIsDark) {
                case (true, true): line += "█"
                case (true, false): line += "▀"
                case (false, true): line += "▄"
                case (false, false): line += " "
                }
            }
            line += String(repeating: " ", count: quietZone)
            lines.append(line)
        }
        lines.append(contentsOf: Array(repeating: blank, count: quietZone / 2))
        return lines.joined(separator: "\n")
    }
}
