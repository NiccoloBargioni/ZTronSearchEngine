import CoreGraphics
import Foundation
import ImageIO
import UniformTypeIdentifiers

/// A bitmap of 8-bit sRGB pixels, four bytes each (red, green, blue, alpha).
public struct PixelImage: Sendable, Equatable {
    public let width: Int
    public let height: Int
    public private(set) var bytes: [UInt8]

    public init(width: Int, height: Int, bytes: [UInt8]) {
        precondition(bytes.count == width * height * 4, "four bytes per pixel")
        self.width = width
        self.height = height
        self.bytes = bytes
    }

    /// A solid image, for tests.
    public init(width: Int, height: Int, red: UInt8, green: UInt8, blue: UInt8) {
        var bytes = [UInt8](repeating: 255, count: width * height * 4)
        for index in 0..<(width * height) {
            bytes[index * 4] = red
            bytes[index * 4 + 1] = green
            bytes[index * 4 + 2] = blue
        }
        self.init(width: width, height: height, bytes: bytes)
    }

    /// Converts any image to 8-bit sRGB without resampling.
    public init?(_ image: CGImage) {
        let width = image.width, height = image.height
        guard width > 0, height > 0, let space = CGColorSpace(name: CGColorSpace.sRGB) else { return nil }
        var bytes = [UInt8](repeating: 0, count: width * height * 4)
        let drawn = bytes.withUnsafeMutableBytes { buffer -> Bool in
            guard let context = CGContext(
                data: buffer.baseAddress, width: width, height: height, bitsPerComponent: 8, bytesPerRow: width * 4,
                space: space, bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue
            ) else { return false }
            context.interpolationQuality = .none
            context.draw(image, in: CGRect(x: 0, y: 0, width: width, height: height))
            return true
        }
        guard drawn else { return nil }
        self.init(width: width, height: height, bytes: bytes)
    }

    public subscript(x: Int, y: Int) -> (red: UInt8, green: UInt8, blue: UInt8) {
        get {
            let offset = (y * width + x) * 4
            return (bytes[offset], bytes[offset + 1], bytes[offset + 2])
        }
        set {
            let offset = (y * width + x) * 4
            bytes[offset] = newValue.red
            bytes[offset + 1] = newValue.green
            bytes[offset + 2] = newValue.blue
            bytes[offset + 3] = 255
        }
    }

    /// The part of the image inside a pixel rectangle, clamped to the image.
    public func cropped(to rect: PixelRect) -> PixelImage {
        let x0 = max(0, rect.x), y0 = max(0, rect.y)
        let x1 = min(width, rect.x + rect.width), y1 = min(height, rect.y + rect.height)
        guard x1 > x0, y1 > y0 else { return PixelImage(width: 0, height: 0, bytes: []) }
        var cropped = [UInt8]()
        cropped.reserveCapacity((x1 - x0) * (y1 - y0) * 4)
        for y in y0..<y1 {
            cropped.append(contentsOf: bytes[((y * width + x0) * 4)..<((y * width + x1) * 4)])
        }
        return PixelImage(width: x1 - x0, height: y1 - y0, bytes: cropped)
    }

    public var cgImage: CGImage? {
        guard width > 0, height > 0, let space = CGColorSpace(name: CGColorSpace.sRGB),
              let provider = CGDataProvider(data: Data(bytes) as CFData) else { return nil }
        return CGImage(
            width: width, height: height, bitsPerComponent: 8, bitsPerPixel: 32, bytesPerRow: width * 4, space: space,
            bitmapInfo: CGBitmapInfo(rawValue: CGImageAlphaInfo.premultipliedLast.rawValue), provider: provider,
            decode: nil, shouldInterpolate: false, intent: .defaultIntent
        )
    }

    public func pngData() -> Data? {
        guard let image = cgImage else { return nil }
        let data = NSMutableData()
        guard let destination = CGImageDestinationCreateWithData(data, UTType.png.identifier as CFString, 1, nil) else { return nil }
        CGImageDestinationAddImage(destination, image, nil)
        guard CGImageDestinationFinalize(destination) else { return nil }
        return data as Data
    }
}

/// A rectangle of whole pixels.
public struct PixelRect: Codable, Hashable, Sendable {
    public var x: Int
    public var y: Int
    public var width: Int
    public var height: Int

    public init(x: Int, y: Int, width: Int, height: Int) {
        self.x = x
        self.y = y
        self.width = width
        self.height = height
    }

    /// The pixels a rectangle in points touches at a scale, grown by `margin` pixels.
    public init(_ rect: CGRect, scale: CGFloat, margin: Int = 0) {
        let x0 = Int((rect.minX * scale).rounded(.down)) - margin
        let y0 = Int((rect.minY * scale).rounded(.down)) - margin
        let x1 = Int((rect.maxX * scale).rounded(.up)) + margin
        let y1 = Int((rect.maxY * scale).rounded(.up)) + margin
        self.init(x: x0, y: y0, width: max(0, x1 - x0), height: max(0, y1 - y0))
    }

    func contains(_ px: Int, _ py: Int) -> Bool {
        px >= x && px < x + width && py >= y && py < y + height
    }
}

/// The outcome of comparing two snapshots (specification section 15.7).
public struct PixelComparison: Codable, Sendable {
    public var width: Int
    public var height: Int
    /// Pixels taken out of the comparison (the caret, above all).
    public var maskedPixels: Int
    public var comparedPixels: Int
    /// Pixels whose 8-bit sRGB value is not identical in the two snapshots.
    public var differingPixels: Int
    public var differingPercent: Double
    /// Largest CIEDE2000 distance of any differing pixel; 0 when none differs.
    public var maxDeltaE: Double
    /// The same pixel population measured with CIE76, for reference.
    public var maxDeltaE76: Double
    /// Differing pixels whose CIEDE2000 distance exceeds the threshold.
    public var pixelsOverThreshold: Int
    /// Where the largest distance was found, in pixels.
    public var worstX: Int?
    public var worstY: Int?
    /// Set when the two snapshots are not the same size, so no pixel was compared.
    public var sizeMismatch: String?
    public var passes: Bool
}

/// Pixel snapshot comparison: at most 0.5% of the pixels differ, and no differing pixel
/// exceeds a colour distance of ΔE 2 (CIEDE2000, see ``ColorDifference``).
///
/// A pixel differs when its 8-bit sRGB value is not byte-for-byte the reference's: the count
/// is of every difference, however faint, and the ΔE bound then limits how strong any of them
/// may be. Both conditions must hold.
public enum PixelComparator {
    public static let maximumDifferingPercent = 0.5
    public static let maximumDeltaE = 2.0

    /// - Parameter masks: pixel rectangles left out of the comparison in both snapshots.
    /// - Returns: the numbers, and an image that marks every differing pixel: red above the
    ///   ΔE threshold, orange below it, blue where masked, over a faded copy of the reference.
    public static func compare(reference: PixelImage, clone: PixelImage, masks: [PixelRect] = []) -> (comparison: PixelComparison, difference: PixelImage?) {
        guard reference.width == clone.width, reference.height == clone.height else {
            let comparison = PixelComparison(
                width: reference.width, height: reference.height, maskedPixels: 0, comparedPixels: 0, differingPixels: 0,
                differingPercent: 100, maxDeltaE: .infinity, maxDeltaE76: .infinity, pixelsOverThreshold: 0, worstX: nil, worstY: nil,
                sizeMismatch: "reference \(reference.width)x\(reference.height), clone \(clone.width)x\(clone.height)", passes: false
            )
            return (comparison, nil)
        }
        let width = reference.width, height = reference.height
        var difference = PixelImage(width: width, height: height, red: 255, green: 255, blue: 255)
        var masked = 0, differing = 0, over = 0
        var maxDeltaE = 0.0, maxDeltaE76 = 0.0
        var worst: (x: Int, y: Int)?
        var labCache: [UInt32: LabColor] = [:]
        func lab(_ pixel: (red: UInt8, green: UInt8, blue: UInt8)) -> LabColor {
            let key = UInt32(pixel.red) << 16 | UInt32(pixel.green) << 8 | UInt32(pixel.blue)
            if let cached = labCache[key] { return cached }
            let color = LabColor(red: pixel.red, green: pixel.green, blue: pixel.blue)
            labCache[key] = color
            return color
        }
        for y in 0..<height {
            for x in 0..<width {
                let a = reference[x, y]
                if masks.contains(where: { $0.contains(x, y) }) {
                    masked += 1
                    difference[x, y] = (90, 140, 255)
                    continue
                }
                let b = clone[x, y]
                if a == b {
                    // A faded copy of the reference, so the marks can be located.
                    difference[x, y] = (fade(a.red), fade(a.green), fade(a.blue))
                    continue
                }
                differing += 1
                let first = lab(a), second = lab(b)
                let deltaE = ColorDifference.ciede2000(first, second)
                maxDeltaE76 = max(maxDeltaE76, ColorDifference.cie76(first, second))
                if deltaE > maxDeltaE {
                    maxDeltaE = deltaE
                    worst = (x, y)
                }
                if deltaE > maximumDeltaE {
                    over += 1
                    difference[x, y] = (230, 30, 30)
                } else {
                    difference[x, y] = (255, 170, 40)
                }
            }
        }
        let compared = width * height - masked
        let percent = compared > 0 ? Double(differing) / Double(compared) * 100 : 0
        let comparison = PixelComparison(
            width: width, height: height, maskedPixels: masked, comparedPixels: compared, differingPixels: differing,
            differingPercent: percent, maxDeltaE: maxDeltaE, maxDeltaE76: maxDeltaE76, pixelsOverThreshold: over,
            worstX: worst?.x, worstY: worst?.y, sizeMismatch: nil,
            passes: percent <= maximumDifferingPercent && maxDeltaE <= maximumDeltaE
        )
        return (comparison, difference)
    }

    private static func fade(_ component: UInt8) -> UInt8 {
        UInt8(255 - (255 - Int(component)) / 4)
    }
}
