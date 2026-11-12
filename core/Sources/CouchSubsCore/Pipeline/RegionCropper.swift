// SPDX-License-Identifier: AGPL-3.0-only

import CoreGraphics

/// Görüntüde altyazının arandığı bölge, kenarlara oranla (0–1, üstten ve soldan).
public struct CropRegion: Codable, Equatable {
    public var top = 0.62
    public var bottom = 0.97
    public var left = 0.14
    public var right = 0.86

    public init(top: Double = 0.62, bottom: Double = 0.97, left: Double = 0.14, right: Double = 0.86) {
        self.top = top
        self.bottom = bottom
        self.left = left
        self.right = right
    }
}

public enum RegionCropper {
    public static func crop(_ image: CGImage, to region: CropRegion) -> CGImage {
        let width = Double(image.width), height = Double(image.height)
        let rect = CGRect(x: width * region.left, y: height * region.top,
                          width: width * (region.right - region.left), height: height * (region.bottom - region.top))
        return image.cropping(to: rect.integral) ?? image
    }

    /// Bölgenin küçültülmüş gri kopyası: iki kareyi yazı tanımaya gerek kalmadan karşılaştırmaya yeter.
    public static func signature(of image: CGImage) -> [UInt8] {
        let width = 64, height = 12
        var pixels = [UInt8](repeating: 0, count: width * height)
        pixels.withUnsafeMutableBytes { buffer in
            guard let context = CGContext(data: buffer.baseAddress, width: width, height: height, bitsPerComponent: 8, bytesPerRow: width,
                                          space: CGColorSpaceCreateDeviceGray(), bitmapInfo: CGImageAlphaInfo.none.rawValue) else { return }
            context.interpolationQuality = .low
            context.draw(image, in: CGRect(x: 0, y: 0, width: width, height: height))
        }
        return pixels
    }
}
