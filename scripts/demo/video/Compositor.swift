import AppKit
import CoreImage
import CoreImage.CIFilterBuiltins

// Core Image finishing: world background, perspective, depth of field, glow,
// shockwaves, chromatic split, grade and dithered grain. Screen points are y-down;
// Core Image is y-up, so conversions happen here.

struct Tilt {
    var pitch = 0.0, yaw = 0.0

    /// Rotates the image plane about the frame center and projects it with a pinhole camera.
    func project(_ p: V2, width: Double = 1920, height: Double = 1080) -> V2 {
        let c = V2(width / 2, height / 2)
        var x = p.x - c.x, y = p.y - c.y, z = 0.0
        let yaw = degrees(self.yaw), pitch = degrees(self.pitch)
        (x, z) = (x * cos(yaw) + z * sin(yaw), -x * sin(yaw) + z * cos(yaw))
        (y, z) = (y * cos(pitch) - z * sin(pitch), y * sin(pitch) + z * cos(pitch))
        let focal = 2100.0
        let s = focal / (focal + z)
        return c + V2(x, y) * s
    }

    var isFlat: Bool { abs(pitch) < 0.01 && abs(yaw) < 0.01 }
}

final class Compositor {
    let width: Int, height: Int
    let context: CIContext
    let sRGB = CGColorSpace(name: CGColorSpace.sRGB)!
    private var gridImage: CIImage
    private let noise: CIImage
    private let starCanvas: Canvas

    init(width: Int, height: Int) {
        self.width = width
        self.height = height
        context = CIContext(options: [.cacheIntermediates: false, .highQualityDownsample: true,
                                      .workingFormat: CIFormat.RGBAh])
        noise = CIFilter.randomGenerator().outputImage!
        starCanvas = Canvas(width: width, height: height)
        gridImage = CIImage.empty()
        gridImage = makeGrid()
    }

    var extent: CGRect { CGRect(x: 0, y: 0, width: width, height: height) }
    func ci(_ p: V2) -> CGPoint { CGPoint(x: p.x, y: Double(height) - p.y) }

    private func makeGrid() -> CIImage {
        let canvas = Canvas(width: width + 192, height: height + 192)
        canvas.draw { cg in
            for (index, x) in stride(from: 0.0, through: Double(canvas.width), by: 48).enumerated() {
                cg.line(V2(x, 0), V2(x, Double(canvas.height)), Palette.grid.alpha(index % 4 == 0 ? 0.085 : 0.045), width: 1, cap: .butt)
            }
            for (index, y) in stride(from: 0.0, through: Double(canvas.height), by: 48).enumerated() {
                cg.line(V2(0, y), V2(Double(canvas.width), y), Palette.grid.alpha(index % 4 == 0 ? 0.085 : 0.045), width: 1, cap: .butt)
            }
        }
        return CIImage(cgImage: canvas.image())
    }

    // MARK: World

    func background(t: Double, dawn: Double, brand: Double, parallax: V2, stars: Double, freeze: Bool) -> CIImage {
        let time = freeze ? 0 : t
        let top = Palette.ink.mixed(RGBA(0x0B2547), dawn).mixed(RGBA(0x061226), brand)
        let bottom = Palette.night.mixed(RGBA(0x2B2752), dawn).mixed(RGBA(0x0A1F3D), brand)
        let gradient = CIFilter.linearGradient()
        gradient.point0 = CGPoint(x: 0, y: height)
        gradient.point1 = CGPoint(x: 0, y: 0)
        gradient.color0 = CIColor(cgColor: top.cg)
        gradient.color1 = CIColor(cgColor: bottom.cg)
        var image = gradient.outputImage!.cropped(to: extent)

        func glow(_ center: V2, _ radius: Double, _ color: RGBA) -> CIImage {
            let f = CIFilter.radialGradient()
            f.center = ci(center)
            f.radius0 = 0
            f.radius1 = Float(radius)
            f.color0 = CIColor(cgColor: color.cg)
            f.color1 = CIColor(red: 0, green: 0, blue: 0, alpha: 0)
            // A fully transparent gradient has no output image.
            return f.outputImage?.cropped(to: extent) ?? CIImage.empty()
        }
        let drift = V2(sin(time * 0.21) * 60, cos(time * 0.17) * 40)
        let glows = [
            glow(V2(860, 640) + drift, 980, RGBA(0x123A6B, 0.75 * (1 - brand * 0.4))),
            glow(V2(1500, 260) - drift * 0.7, 760, RGBA(0x1B6FB8, 0.22 + 0.08 * dawn)),
            glow(V2(300, 900) + drift * 0.5, 700, RGBA(0x0F5C7A, 0.2 * (1 - dawn))),
            glow(V2(960, 1260), 1150, RGBA(0xFF9C6B, 0.3 * dawn * (1 - brand))),
            glow(V2(960, 420), 820, RGBA(0x2A7FE0, 0.42 * brand)),
        ]
        for layer in glows { image = layer.composited(over: image) }

        // Blueprint grid with slight parallax, fading toward the edges.
        let offset = V2(parallax.x.truncatingRemainder(dividingBy: 192), parallax.y.truncatingRemainder(dividingBy: 192))
        let grid = gridImage.transformed(by: CGAffineTransform(translationX: -96 - offset.x, y: -96 + offset.y)).cropped(to: extent)
        let mask = CIFilter.radialGradient()
        mask.center = CGPoint(x: Double(width) / 2, y: Double(height) * 0.45)
        mask.radius0 = 200
        mask.radius1 = 1150
        mask.color0 = CIColor(red: 1, green: 1, blue: 1, alpha: 1)
        mask.color1 = CIColor(red: 0, green: 0, blue: 0, alpha: 0)
        let blend = CIFilter.blendWithAlphaMask()
        blend.inputImage = grid
        blend.backgroundImage = CIImage(color: .clear).cropped(to: extent)
        blend.maskImage = mask.outputImage!.cropped(to: extent)
        image = blend.outputImage!.composited(over: image)

        if stars > 0.001 {
            let canvas = starCanvas
            canvas.clear()
            canvas.draw { cg in
                for i in 0..<90 {
                    let x = hashNoise(i * 3) * Double(width), y = pow(hashNoise(i * 3 + 1), 1.4) * Double(height) * 0.7
                    let twinkle = freeze ? 0.8 : 0.55 + 0.45 * sin(time * (0.8 + hashNoise(i * 7) * 1.6) + hashNoise(i * 11) * 6)
                    let r = 0.6 + hashNoise(i * 3 + 2) * 1.1
                    cg.circle(V2(x, y) - parallax * 0.3, r, fill: RGBA(0xDDEBFF, (0.1 + 0.3 * hashNoise(i * 5)) * twinkle * stars))
                }
            }
            image = CIImage(cgImage: canvas.image()).composited(over: image)
        }
        return image
    }

    // MARK: Layers

    func image(_ canvas: Canvas) -> CIImage { CIImage(cgImage: canvas.image()) }

    func perspective(_ image: CIImage, _ tilt: Tilt) -> CIImage {
        guard !tilt.isFlat else { return image }
        let w = Double(width), h = Double(height)
        let f = CIFilter.perspectiveTransform()
        f.inputImage = image
        f.topLeft = ci(tilt.project(V2(0, 0)))
        f.topRight = ci(tilt.project(V2(w, 0)))
        f.bottomRight = ci(tilt.project(V2(w, h)))
        f.bottomLeft = ci(tilt.project(V2(0, h)))
        return f.outputImage!
    }

    func blur(_ image: CIImage, _ radius: Double) -> CIImage {
        guard radius > 0.2 else { return image }
        return image.clampedToExtent().applyingGaussianBlur(sigma: radius).cropped(to: image.extent.intersection(extent))
    }

    func dim(_ image: CIImage, _ amount: Double) -> CIImage {
        guard amount < 0.999 else { return image }
        let v = CGFloat(amount)
        return image.applyingFilter("CIColorMatrix", parameters: [
            "inputRVector": CIVector(x: v, y: 0, z: 0, w: 0), "inputGVector": CIVector(x: 0, y: v, z: 0, w: 0),
            "inputBVector": CIVector(x: 0, y: 0, z: v, w: 0), "inputAVector": CIVector(x: 0, y: 0, z: 0, w: 1),
        ])
    }

    func fade(_ image: CIImage, _ alpha: Double) -> CIImage {
        guard alpha < 0.999 else { return image }
        let a = CGFloat(max(0, alpha))
        return image.applyingFilter("CIColorMatrix", parameters: [
            "inputRVector": CIVector(x: a, y: 0, z: 0, w: 0), "inputGVector": CIVector(x: 0, y: a, z: 0, w: 0),
            "inputBVector": CIVector(x: 0, y: 0, z: a, w: 0), "inputAVector": CIVector(x: 0, y: 0, z: 0, w: a),
        ])
    }

    /// A soft contact shadow under a transparent layer.
    func shadow(of image: CIImage, offset: V2, radius: Double, opacity: Double) -> CIImage {
        let black = image.applyingFilter("CIColorMatrix", parameters: [
            "inputRVector": CIVector(x: 0, y: 0, z: 0, w: 0), "inputGVector": CIVector(x: 0, y: 0, z: 0, w: 0),
            "inputBVector": CIVector(x: 0, y: 0, z: 0, w: 0), "inputAVector": CIVector(x: 0, y: 0, z: 0, w: CGFloat(opacity)),
        ])
        return blur(black.transformed(by: CGAffineTransform(translationX: offset.x, y: -offset.y)), radius)
    }

    func average(_ images: [CIImage]) -> CIImage {
        guard images.count > 1 else { return images.first ?? CIImage.empty() }
        var sum = images[0]
        for image in images.dropFirst() {
            sum = image.applyingFilter("CIAdditionCompositing", parameters: [kCIInputBackgroundImageKey: sum])
        }
        return fade(sum, 1 / Double(images.count))
    }

    func add(_ top: CIImage, over base: CIImage) -> CIImage {
        top.applyingFilter("CIAdditionCompositing", parameters: [kCIInputBackgroundImageKey: base])
    }

    /// Two-radius glow from an emissive layer.
    func glow(_ emissive: CIImage, strength: Double) -> CIImage {
        let near = fade(blur(emissive, 7), 0.9 * strength)
        let far = fade(blur(emissive, 26), 0.75 * strength)
        return add(near, over: far)
    }

    func shockwave(_ image: CIImage, center: V2, radius: Double, width: Double, refraction: Double) -> CIImage {
        guard refraction > 0.01 else { return image }
        let f = CIFilter.torusLensDistortion()
        f.inputImage = image.clampedToExtent()
        f.center = ci(center)
        f.radius = Float(radius)
        f.width = Float(width)
        f.refraction = Float(refraction)
        return f.outputImage!.cropped(to: extent)
    }

    func chromatic(_ image: CIImage, center: V2, amount: Double) -> CIImage {
        guard amount > 0.05 else { return image }
        // Each channel keeps full alpha; a per-channel maximum then reassembles the opaque frame.
        func channel(_ r: CGFloat, _ g: CGFloat, _ b: CGFloat, scale: Double) -> CIImage {
            let c = ci(center)
            let s = CGFloat(scale)
            let transform = CGAffineTransform(translationX: c.x, y: c.y).scaledBy(x: s, y: s).translatedBy(x: -c.x, y: -c.y)
            return image.clampedToExtent().transformed(by: transform).applyingFilter("CIColorMatrix", parameters: [
                "inputRVector": CIVector(x: r, y: 0, z: 0, w: 0), "inputGVector": CIVector(x: 0, y: g, z: 0, w: 0),
                "inputBVector": CIVector(x: 0, y: 0, z: b, w: 0), "inputAVector": CIVector(x: 0, y: 0, z: 0, w: 1),
            ]).cropped(to: extent)
        }
        let k = amount / 900
        let red = channel(1, 0, 0, scale: 1 + k)
        let green = channel(0, 1, 0, scale: 1)
        let blue = channel(0, 0, 1, scale: 1 - k)
        let maximum = { (a: CIImage, b: CIImage) in a.applyingFilter("CIMaximumCompositing", parameters: [kCIInputBackgroundImageKey: b]) }
        return maximum(blue, maximum(red, green))
    }

    func zoomBlur(_ image: CIImage, center: V2, amount: Double) -> CIImage {
        guard amount > 0.2 else { return image }
        let f = CIFilter.zoomBlur()
        f.inputImage = image.clampedToExtent()
        f.center = ci(center)
        f.amount = Float(amount)
        return f.outputImage!.cropped(to: extent)
    }

    func motionBlur(_ image: CIImage, velocity: V2) -> CIImage {
        let length = velocity.length
        guard length > 1.5 else { return image }
        let f = CIFilter.motionBlur()
        f.inputImage = image.clampedToExtent()
        f.radius = Float(min(60, length))
        f.angle = Float(atan2(-velocity.y, velocity.x))
        return f.outputImage!.cropped(to: extent)
    }

    // MARK: Finish

    func finish(_ image: CIImage, exposure: Double, vignette: Double, grain: Double, frame: Int) -> CIImage {
        var out = image
        if abs(exposure) > 0.001 {
            out = out.applyingFilter("CIExposureAdjust", parameters: [kCIInputEVKey: exposure])
        }
        out = out.applyingFilter("CIColorControls", parameters: [kCIInputSaturationKey: 1.06, kCIInputContrastKey: 1.02])
        let v = CIFilter.vignetteEffect()
        v.inputImage = out
        v.center = CGPoint(x: Double(width) / 2, y: Double(height) * 0.52)
        v.radius = Float(Double(width) * 0.62)
        v.intensity = Float(vignette)
        v.falloff = 0.55
        out = v.outputImage!.cropped(to: extent)
        if grain > 0 {
            // Dither in display space so dark gradients do not band after 8-bit encoding.
            let offset = CGAffineTransform(translationX: CGFloat(hashNoise(frame) * 4000), y: CGFloat(hashNoise(frame + 77) * 4000))
            // Opaque mid-gray noise; linear light adds 2 × (noise − 0.5) to the frame.
            let amplitude = CGFloat(grain / 255) / 2
            let speckle = noise.transformed(by: offset).cropped(to: extent).settingAlphaOne(in: extent).applyingFilter("CIColorMatrix", parameters: [
                "inputRVector": CIVector(x: amplitude, y: 0, z: 0, w: 0), "inputGVector": CIVector(x: amplitude, y: 0, z: 0, w: 0),
                "inputBVector": CIVector(x: amplitude, y: 0, z: 0, w: 0), "inputAVector": CIVector(x: 0, y: 0, z: 0, w: 0),
                "inputBiasVector": CIVector(x: 0.5 - amplitude / 2, y: 0.5 - amplitude / 2, z: 0.5 - amplitude / 2, w: 1),
            ])
            let display = out.applyingFilter("CILinearToSRGBToneCurve")
            out = speckle.applyingFilter("CILinearLightBlendMode", parameters: [kCIInputBackgroundImageKey: display])
                .applyingFilter("CISRGBToneCurveToLinear")
        }
        return out.cropped(to: extent)
    }

    func render(_ image: CIImage, into buffer: UnsafeMutableRawPointer) {
        context.render(image, toBitmap: buffer, rowBytes: width * 4, bounds: extent, format: .BGRA8, colorSpace: sRGB)
    }

    func cgImage(_ image: CIImage) -> CGImage {
        context.createCGImage(image, from: extent, format: .RGBA8, colorSpace: sRGB)!
    }
}
