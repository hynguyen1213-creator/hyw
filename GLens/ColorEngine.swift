import UIKit
import CoreImage
import ImageIO
import CoreImage.CIFilterBuiltins

struct Look: Identifiable, Equatable, Codable {
    let id: String
    let name: String
    let subtitle: String
    let saturation: Float
    let contrast: Float
    let warmth: Float
    let lift: Float
    static let all: [Look] = [
        .init(id: "authentic", name: "Authentic", subtitle: "NATURAL COLOR", saturation: 0.88, contrast: 1.12, warmth: 0.025, lift: 0),
        .init(id: "vibrant", name: "Vibrant", subtitle: "A LITTLE MORE LIFE", saturation: 1.24, contrast: 1.06, warmth: 0.012, lift: 0.008),
        .init(id: "m9", name: "M9 · CCD", subtitle: "ESSENTIAL COLOR", saturation: 0.94, contrast: 1.15, warmth: 0.055, lift: 0.008),
        .init(id: "m3", name: "M3 · Mono", subtitle: "ESSENTIAL MONO", saturation: 0, contrast: 1.16, warmth: 0, lift: 0.014),
        .init(id: "gold", name: "Classic Gold", subtitle: "WARM FILM", saturation: 0.92, contrast: 1.05, warmth: 0.085, lift: 0.035),
        .init(id: "noir", name: "Noir", subtitle: "LIGHT & SHADOW", saturation: 0, contrast: 1.4, warmth: 0, lift: 0),
        .init(id: "gold200", name: "Gold 200", subtitle: "WARM COLOR NEGATIVE", saturation: 1, contrast: 1, warmth: 0, lift: 0),
        .init(id: "portra400", name: "Portra 400", subtitle: "SOFT COLOR NEGATIVE", saturation: 1, contrast: 1, warmth: 0, lift: 0),
        .init(id: "ektar100", name: "Ektar 100", subtitle: "FINE COLOR NEGATIVE", saturation: 1, contrast: 1, warmth: 0, lift: 0),
        .init(id: "c200", name: "Fuji C200", subtitle: "EVERYDAY COLOR NEGATIVE", saturation: 1, contrast: 1, warmth: 0, lift: 0),
        .init(id: "hp5", name: "HP5 400", subtitle: "CLASSIC BLACK & WHITE", saturation: 0, contrast: 1, warmth: 0, lift: 0),
        .init(id: "cine800", name: "Cine 800T", subtitle: "TUNGSTEN CINEMA", saturation: 1, contrast: 1, warmth: 0, lift: 0)
    ]
}
struct ColorSettings: Codable {
    var look = Look.all[0]
    var strength: Float = 0.8
    var grain: Float = 0.15
    var vignette: Float = 0.2
    var frame = false
    var author = ""
    var ratio: CGFloat = 3.0 / 4.0 // portrait width / height
    var compare = false
    var exposure: Float = 0
    var contrast: Float = 1
    var saturation: Float = 1
    var temperature: Float = 0
    var tint: Float = 0
    var shadows: Float = 0
    var highlights: Float = 1
    var sharpness: Float = 0
    static func restored() -> ColorSettings {
        guard let data = UserDefaults.standard.data(forKey: "glens.color"), let value = try? JSONDecoder().decode(Self.self, from: data) else { return Self() }
        return value
    }
    func save() { if let data = try? JSONEncoder().encode(self) { UserDefaults.standard.set(data, forKey: "glens.color") } }
}
final class ColorEngine {
    let context = CIContext(options: [.cacheIntermediates: false])
    private let filmCubes = FilmProfile.all.mapValues { $0.cube() }
    private let grainSource = CIFilter(name: "CIRandomGenerator")?.outputImage
    private let colorSpace = CGColorSpace(name: CGColorSpace.sRGB)!
    func crop(_ image: CIImage, ratio: CGFloat) -> CIImage {
        let r = image.extent
        var size = CGSize(width: r.width, height: r.width / ratio)
        if size.height > r.height { size = CGSize(width: r.height * ratio, height: r.height) }
        let bounds = CGRect(x: r.midX - size.width / 2, y: r.midY - size.height / 2, width: size.width, height: size.height).integral
        let cropped = image.cropped(to: bounds)
        return cropped.transformed(by: CGAffineTransform(translationX: -bounds.minX, y: -bounds.minY))
    }
    func process(_ input: CIImage, settings: ColorSettings, preview: Bool) -> CIImage {
        var original = crop(input, ratio: settings.ratio)
        let limit: CGFloat = preview ? 1080 : 16384
        if max(original.extent.width, original.extent.height) > limit {
            let factor = min(1, limit / max(original.extent.width, original.extent.height))
            original = original.transformed(by: CGAffineTransform(scaleX: factor, y: factor))
        }
        if settings.compare { return original }
        let look = settings.look
        var image = original.applyingFilter("CIColorControls", parameters: [kCIInputSaturationKey: look.saturation, kCIInputContrastKey: look.contrast])
        image = image.applyingFilter("CIColorMatrix", parameters: [
            "inputBiasVector": CIVector(x: CGFloat(look.warmth * 0.46 + look.lift), y: CGFloat(look.warmth * 0.08 + look.lift), z: CGFloat(-look.warmth * 0.34 + look.lift), w: 0)
        ])
        image = image.applyingFilter("CIHighlightShadowAdjust", parameters: ["inputHighlightAmount": 0.93, "inputShadowAmount": 0.02])
        if let cube = filmCubes[look.id] {
            image = original.applyingFilter("CIColorCubeWithColorSpace", parameters: ["inputCubeDimension":32,"inputCubeData":cube,"inputColorSpace":colorSpace])
        }
        let blendBase = look.saturation == 0 ? original.applyingFilter("CIColorControls", parameters: [kCIInputSaturationKey: 0]) : original
        let mask = CIImage(color: CIColor(red: CGFloat(settings.strength), green: CGFloat(settings.strength), blue: CGFloat(settings.strength))).cropped(to: original.extent)
        image = image.applyingFilter("CIBlendWithMask", parameters: [kCIInputBackgroundImageKey: blendBase, kCIInputMaskImageKey: mask])
        image = image.applyingFilter("CIExposureAdjust", parameters: [kCIInputEVKey: settings.exposure])
        image = image.applyingFilter("CIColorControls", parameters: [kCIInputSaturationKey: settings.saturation, kCIInputContrastKey: settings.contrast])
        image = image.applyingFilter("CITemperatureAndTint", parameters: ["inputNeutral": CIVector(x: 6500, y: 0), "inputTargetNeutral": CIVector(x: 6500 + CGFloat(settings.temperature) * 2500, y: CGFloat(settings.tint) * 100)])
        image = image.applyingFilter("CIHighlightShadowAdjust", parameters: ["inputHighlightAmount": settings.highlights, "inputShadowAmount": settings.shadows])
        if settings.sharpness > 0 { image = image.applyingFilter("CISharpenLuminance", parameters: [kCIInputSharpnessKey: settings.sharpness]) }
        if settings.vignette > 0 {
            image = image.applyingFilter("CIVignette", parameters: [kCIInputIntensityKey: settings.vignette * 0.75, kCIInputRadiusKey: min(image.extent.width, image.extent.height) * 0.65])
        }
        if let profile = FilmProfile.all[look.id], profile.halation > 0, settings.strength > 0 {
            let hot = original.applyingFilter("CIColorMatrix", parameters: ["inputRVector":CIVector(x:4,y:0,z:0,w:0),"inputGVector":CIVector(x:0,y:4,z:0,w:0),"inputBVector":CIVector(x:0,y:0,z:4,w:0),"inputBiasVector":CIVector(x:-3,y:-3,z:-3,w:0)])
                .applyingFilter("CIColorClamp").clampedToExtent()
                .applyingFilter("CIGaussianBlur", parameters:[kCIInputRadiusKey:max(image.extent.width,image.extent.height)/180])
                .applyingFilter("CIColorMatrix", parameters:["inputRVector":CIVector(x:0.8,y:0.15,z:0.05,w:0),"inputGVector":CIVector(x:0.1,y:0.04,z:0,w:0),"inputBVector":CIVector(x:0,y:0,z:0,w:0)])
            let halo = hot.applyingFilter("CIScreenBlendMode",parameters:[kCIInputBackgroundImageKey:image]).cropped(to:image.extent)
            let amount = CGFloat(profile.halation*settings.strength)
            let mask = CIImage(color:CIColor(red:amount,green:amount,blue:amount)).cropped(to:image.extent)
            image = halo.applyingFilter("CIBlendWithMask",parameters:[kCIInputBackgroundImageKey:image,kCIInputMaskImageKey:mask])
        }
        if settings.grain > 0, let noise = grainSource {
            let scale = max(0.6,max(image.extent.width,image.extent.height)/1600)
            let grain = noise.transformed(by:CGAffineTransform(scaleX:scale,y:scale)).cropped(to: image.extent).applyingFilter("CIColorControls", parameters: [kCIInputSaturationKey: 0])
            let blend = grain.applyingFilter("CISoftLightBlendMode", parameters: [kCIInputBackgroundImageKey: image])
            let amount = CGFloat(settings.grain * 0.16)
            let mask = CIImage(color: CIColor(red: amount, green: amount, blue: amount)).cropped(to: image.extent)
            image = blend.applyingFilter("CIBlendWithMask", parameters: [kCIInputBackgroundImageKey: image, kCIInputMaskImageKey: mask])
        }
        return image.cropped(to: original.extent)
    }
    func uiImage(_ image: CIImage) -> UIImage? {
        guard let cg = context.createCGImage(image, from: image.extent, format: .RGBA8, colorSpace: colorSpace) else { return nil }
        return UIImage(cgImage: cg)
    }
    private func encode(_ ui: UIImage, originalProperties: [String: Any], encoding: PhotoEncoding) -> Data? {
        guard let cg = ui.cgImage else { return nil }
        let data = NSMutableData()
        guard let destination = CGImageDestinationCreateWithData(data, (encoding == .heif ? "public.heic" : "public.jpeg") as CFString, 1, nil) else { return nil }
        var properties = originalProperties
        properties[kCGImagePropertyOrientation as String] = 1
        properties[kCGImagePropertyPixelWidth as String] = cg.width
        properties[kCGImagePropertyPixelHeight as String] = cg.height
        properties[kCGImageDestinationLossyCompressionQuality as String] = 0.96
        var exif = properties[kCGImagePropertyExifDictionary as String] as? [String: Any] ?? [:]
        exif[kCGImagePropertyExifPixelXDimension as String] = cg.width
        exif[kCGImagePropertyExifPixelYDimension as String] = cg.height
        properties[kCGImagePropertyExifDictionary as String] = exif
        CGImageDestinationAddImage(destination, cg, properties as CFDictionary)
        guard CGImageDestinationFinalize(destination) else { return nil }
        return data as Data
    }
    func jpeg(_ image: CIImage, settings: ColorSettings, metadata: String, encoding: PhotoEncoding = .jpeg) -> Data? {
        guard let ui = uiImage(process(image, settings: settings, preview: false)) else { return nil }
        if !settings.frame { return encode(ui, originalProperties: image.properties, encoding: encoding) }
        let w = ui.size.width, h = ui.size.height
        let pad = round(w * 0.035), footer = round(w * 0.10)
        let format = UIGraphicsImageRendererFormat(); format.scale = 1; format.opaque = true
        let rendered = UIGraphicsImageRenderer(size: CGSize(width: w + pad * 2, height: h + pad * 2 + footer), format: format).image { ctx in
            UIColor(white: 0.98, alpha: 1).setFill(); ctx.fill(CGRect(x: 0, y: 0, width: w + pad * 2, height: h + pad * 2 + footer))
            ui.draw(in: CGRect(x: pad, y: pad, width: w, height: h))
            let ink = UIColor(red: 0.14, green: 0.18, blue: 0.12, alpha: 1)
            ("G.LENS" as NSString).draw(at: CGPoint(x: pad, y: h + pad * 1.6), withAttributes: [.font: UIFont.systemFont(ofSize: w * 0.029, weight: .semibold), .foregroundColor: ink])
            let text = settings.look.name.uppercased() + "  /  " + metadata
            (text as NSString).draw(in: CGRect(x: w * 0.27, y: h + pad * 1.55, width: w * 0.72, height: footer * 0.4), withAttributes: [.font: UIFont.monospacedSystemFont(ofSize: w * 0.012, weight: .regular), .foregroundColor: UIColor.gray])
            (settings.author as NSString).draw(at: CGPoint(x: w * 0.27, y: h + pad * 2.3), withAttributes: [.font: UIFont.systemFont(ofSize: w * 0.012), .foregroundColor: UIColor.gray])
        }
        return encode(rendered, originalProperties: image.properties, encoding: encoding)
    }
}
