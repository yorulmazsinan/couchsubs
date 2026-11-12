// SPDX-License-Identifier: AGPL-3.0-only
// design/logo.svg'den uygulama simgelerini üretir (macOS uygulaması ve TV uygulaması).
// Kullanım: swift scripts/make-icons.swift   (depo kökünden)

import AppKit

func render(_ svg: NSImage, size: Int, to path: String) {
    let rep = NSBitmapImageRep(bitmapDataPlanes: nil, pixelsWide: size, pixelsHigh: size, bitsPerSample: 8, samplesPerPixel: 4,
                               hasAlpha: true, isPlanar: false, colorSpaceName: .deviceRGB, bytesPerRow: 0, bitsPerPixel: 0)!
    NSGraphicsContext.saveGraphicsState()
    NSGraphicsContext.current = NSGraphicsContext(bitmapImageRep: rep)
    NSGraphicsContext.current?.imageInterpolation = .high
    svg.draw(in: NSRect(x: 0, y: 0, width: size, height: size))
    NSGraphicsContext.restoreGraphicsState()
    try! rep.representation(using: .png, properties: [:])!.write(to: URL(fileURLWithPath: path))
}

guard let logo = NSImage(contentsOfFile: "design/logo.svg") else { fatalError("design/logo.svg okunamadı") }

// macOS: 16–512 pt, 1x ve 2x.
let iconSet = "mac/CouchSubs/Resources/Assets.xcassets/AppIcon.appiconset"
try! FileManager.default.createDirectory(atPath: iconSet, withIntermediateDirectories: true)
var images: [[String: String]] = []
for points in [16, 32, 128, 256, 512] {
    for scale in [1, 2] {
        let name = "icon_\(points)x\(points)\(scale == 2 ? "@2x" : "").png"
        render(logo, size: points * scale, to: "\(iconSet)/\(name)")
        images.append(["idiom": "mac", "size": "\(points)x\(points)", "scale": "\(scale)x", "filename": name])
    }
}
let contents: [String: Any] = ["images": images, "info": ["author": "xcode", "version": 1]]
try! JSONSerialization.data(withJSONObject: contents, options: [.prettyPrinted, .sortedKeys]).write(to: URL(fileURLWithPath: "\(iconSet)/Contents.json"))

// Uygulama içindeki logo (vektör olarak kalır).
let logoSet = "mac/CouchSubs/Resources/Assets.xcassets/Logo.imageset/logo.svg"
try? FileManager.default.removeItem(atPath: logoSet)
try! FileManager.default.copyItem(atPath: "design/logo.svg", toPath: logoSet)

// TV (webOS): 80 ve 130 piksel.
render(logo, size: 80, to: "tv-webos/icon.png")
render(logo, size: 130, to: "tv-webos/largeIcon.png")
// Windows: çok boyutlu .ico (PNG girdili) ve uygulama içi logo (kenar boşluğu kırpılmış kare).
func png(_ svg: NSImage, size: Int, crop: Bool = false) -> Data {
    let rep = NSBitmapImageRep(bitmapDataPlanes: nil, pixelsWide: size, pixelsHigh: size, bitsPerSample: 8, samplesPerPixel: 4,
                               hasAlpha: true, isPlanar: false, colorSpaceName: .deviceRGB, bytesPerRow: 0, bitsPerPixel: 0)!
    NSGraphicsContext.saveGraphicsState()
    NSGraphicsContext.current = NSGraphicsContext(bitmapImageRep: rep)
    NSGraphicsContext.current?.imageInterpolation = .high
    // Kırpılmış sürümde 1024'lük tuvalin ortasındaki 824'lük kare tüm alanı kaplar.
    let scale = crop ? Double(size) * 1024 / 824 : Double(size)
    let offset = crop ? -Double(size) * 100 / 824 : 0
    svg.draw(in: NSRect(x: offset, y: offset, width: scale, height: scale))
    NSGraphicsContext.restoreGraphicsState()
    return rep.representation(using: .png, properties: [:])!
}
let windowsAssets = "windows/src/CouchSubs.App/Assets"
try! FileManager.default.createDirectory(atPath: windowsAssets, withIntermediateDirectories: true)
let icoSizes = [16, 24, 32, 48, 64, 128, 256]
// Windows simgesinde macOS ızgarasının kenar boşluğu gereksiz; kare simgenin tamamı kullanılır.
let icoImages = icoSizes.map { png(logo, size: $0, crop: true) }
var ico = Data([0, 0, 1, 0, UInt8(icoSizes.count), 0])
var offset = 6 + 16 * icoSizes.count
for (size, image) in zip(icoSizes, icoImages) {
    let side = UInt8(size == 256 ? 0 : size)
    ico += [side, side, 0, 0, 1, 0, 32, 0]
    ico += withUnsafeBytes(of: UInt32(image.count).littleEndian) { Data($0) }
    ico += withUnsafeBytes(of: UInt32(offset).littleEndian) { Data($0) }
    offset += image.count
}
icoImages.forEach { ico += $0 }
try! ico.write(to: URL(fileURLWithPath: "\(windowsAssets)/CouchSubs.ico"))
try! png(logo, size: 512, crop: true).write(to: URL(fileURLWithPath: "\(windowsAssets)/logo.png"))

// iPhone/iPad: App Store simgesi saydamlık (alfa kanalı) içeremez ve köşeleri iOS yuvarlar. macOS ızgarasının kenar
// boşluğu kırpılır, köşeler logonun zemin geçişiyle doldurulur; PNG alfa kanalsız yazılır.
func opaqueIcon(_ svg: NSImage, size: Int, to path: String) {
    let context = CGContext(data: nil, width: size, height: size, bitsPerComponent: 8, bytesPerRow: 0,
                            space: CGColorSpace(name: CGColorSpace.sRGB)!, bitmapInfo: CGImageAlphaInfo.noneSkipLast.rawValue)!
    // design/logo.svg'deki "zemin" geçişi: üstte #2B2D33, altta #141518.
    let colors = [CGColor(srgbRed: 0x2B / 255, green: 0x2D / 255, blue: 0x33 / 255, alpha: 1),
                  CGColor(srgbRed: 0x14 / 255, green: 0x15 / 255, blue: 0x18 / 255, alpha: 1)] as CFArray
    let gradient = CGGradient(colorsSpace: CGColorSpace(name: CGColorSpace.sRGB)!, colors: colors, locations: [0, 1])!
    context.drawLinearGradient(gradient, start: CGPoint(x: 0, y: size), end: .zero, options: [])
    NSGraphicsContext.saveGraphicsState()
    NSGraphicsContext.current = NSGraphicsContext(cgContext: context, flipped: false)
    let scale = Double(size) * 1024 / 824
    let offset = -Double(size) * 100 / 824
    svg.draw(in: NSRect(x: offset, y: offset, width: scale, height: scale))
    NSGraphicsContext.restoreGraphicsState()
    let destination = CGImageDestinationCreateWithURL(URL(fileURLWithPath: path) as CFURL, "public.png" as CFString, 1, nil)!
    CGImageDestinationAddImage(destination, context.makeImage()!, nil)
    precondition(CGImageDestinationFinalize(destination), "\(path) yazılamadı")
}
opaqueIcon(logo, size: 1024, to: "couchsubs-ios/CouchSubs/Assets.xcassets/AppIcon.appiconset/icon-1024.png")

// Belgeler ve mağaza görselleri için büyük kopya.
render(logo, size: 1024, to: "design/logo-1024.png")
print("Simgeler üretildi.")
