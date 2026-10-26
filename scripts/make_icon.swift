import CoreGraphics
import Foundation
import ImageIO
import UniformTypeIdentifiers

let destination = URL(fileURLWithPath: CommandLine.arguments[1], isDirectory: true)
let sourceURL = URL(fileURLWithPath: CommandLine.arguments[2])
guard let source = CGImageSourceCreateWithURL(sourceURL as CFURL, nil),
      let artwork = CGImageSourceCreateImageAtIndex(source, 0, nil),
      artwork.width == artwork.height else {
    fatalError("App icon artwork must be a readable square image: \(sourceURL.path)")
}
let colorSpace = CGColorSpace(name: CGColorSpace.sRGB)!

func writeIcon(size: Int, name: String) {
    let context = CGContext(data: nil, width: size, height: size, bitsPerComponent: 8,
                            bytesPerRow: size * 4, space: colorSpace,
                            bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue)!
    // Normalize the generated art to a clean macOS icon silhouette during
    // export. The source artwork and its generation metadata stay intact.
    let edge = CGFloat(size)
    let tile = CGRect(x: edge * 0.055, y: edge * 0.055,
                      width: edge * 0.89, height: edge * 0.89)
    context.addPath(CGPath(roundedRect: tile, cornerWidth: edge * 0.17,
                           cornerHeight: edge * 0.17, transform: nil))
    context.clip()
    // IconServices adds a gray backplate when the tile is translucent.
    // Keep the classic rounded silhouette, but make its interior opaque.
    context.setFillColor(CGColor(red: 0.02, green: 0.48, blue: 0.96, alpha: 1))
    context.fill(tile)
    context.interpolationQuality = .high
    context.draw(artwork, in: CGRect(x: 0, y: 0, width: size, height: size))
    let file = destination.appendingPathComponent(name)
    let image = context.makeImage()!
    let writer = CGImageDestinationCreateWithURL(file as CFURL, UTType.png.identifier as CFString, 1, nil)!
    CGImageDestinationAddImage(writer, image, nil)
    precondition(CGImageDestinationFinalize(writer))
}

for size in [16, 32, 128, 256, 512] {
    writeIcon(size: size, name: "icon_\(size)x\(size).png")
    writeIcon(size: size * 2, name: "icon_\(size)x\(size)@2x.png")
}
