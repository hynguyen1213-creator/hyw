#if targetEnvironment(simulator)
import Foundation
import CoreImage
import UIKit

// Content-based fixtures test registration direction, seams, noise, cancellation
// and persistence independently of a camera sensor. Hardware AF remains untested.
enum AdvancedChecks {
    static func run(context: CIContext) -> ([String: Bool], [String]) {
        var checks: [String:Bool] = [:], notes: [String] = []
        let w = 640, h = 256
        var data = [UInt8](repeating:255,count:w*h*4)
        for y in 0..<h { for x in 0..<w {
            let seed = UInt64((x/4)*73856093) ^ UInt64((y/4)*19349663)
            let value = UInt8(40 + seed % 170), i = (y*w+x)*4
            data[i] = value; data[i+1] = UInt8(30 + (seed/7)%180); data[i+2] = UInt8(40+(seed/13)%170)
        } }
        let world = ImageRegistration.image(data,width:w,height:h)
        let first = world.cropped(to:CGRect(x:0,y:0,width:256,height:256))
        let second = world.cropped(to:CGRect(x:64,y:0,width:256,height:256)).transformed(by:CGAffineTransform(translationX:-64,y:0))
        if let t = ImageRegistration.translation(second,to:first,context:context,maxFraction:0.48) {
            checks["Registration recovers positive 64px offset"] = abs(t.tx-64)<2 && abs(t.ty)<2
            notes.append("Known shift recovered: \(t.tx),\(t.ty)")
        } else { checks["Registration recovers positive 64px offset"] = false }
        let blank = CIImage(color:CIColor(red:0.5,green:0.5,blue:0.5)).cropped(to:first.extent)
        checks["Featureless registration is rejected"] = ImageRegistration.translation(blank,to:blank,context:context) == nil
        let pano = PanoramaStitcher()
        _ = pano.append(first,now:0,context:context); _ = pano.append(second,now:1,context:context)
        if let output = pano.finish(context:context) {
            checks["Panorama expands and preserves height"] = output.extent.width > 310 && output.extent.width < 325 && output.extent.height >= 253
            let reference = world.cropped(to:CGRect(x:0,y:0,width:output.extent.width,height:output.extent.height))
            checks["Panorama seam matches known scene"] = ImageRegistration.correlation(reference,output,context:context) < 0.04
        } else { checks["Panorama expands and preserves height"] = false }
        let refused = PanoramaStitcher(); _ = refused.append(blank,now:0,context:context); _ = refused.append(blank,now:1,context:context)
        checks["Panorama refuses duplicate blank frames"] = refused.tiles.count == 1 && refused.finish(context:context) == nil
        let original = ImageRegistration.pixels(first,bounds:first.extent,context:context)
        var noisyA = original, noisyB = original
        for i in 0..<original.count where i%4 != 3 {
            let n = Int((UInt64(i/4) &* 1664525 &+ 1013904223) >> 8) % 21 - 10
            noisyA[i] = UInt8(max(0,min(255,Int(original[i])+n)))
            noisyB[i] = UInt8(max(0,min(255,Int(original[i])-n)))
        }
        let a = ImageRegistration.image(noisyA,width:256,height:256), b = ImageRegistration.image(noisyB,width:256,height:256)
        if let result = ImageFusion.fuse([a,b],kind:.night,context:context) {
            checks["Night registers both noisy frames"] = result.used == 2
            let transform = ImageRegistration.translation(b,to:a,context:context)
            notes.append("Night translation: \(String(describing: transform)); extent: \(result.image.extent)")
            // Their noise has opposite sign; averaging should reduce it substantially.
            let rect = CGRect(x:16,y:16,width:224,height:224)
            let out = ImageRegistration.pixels(result.image,bounds:rect,context:context)
            let truth = ImageRegistration.pixels(first,bounds:rect,context:context)
            let error = zip(out,truth).enumerated().filter { $0.offset%4 != 3 }.reduce(0.0) { $0+abs(Double($1.element.0)-Double($1.element.1)) } / Double(224*224*3)
            checks["Night reduces known noise"] = error < 3
            notes.append("Night mean absolute error: \(error)")
            notes.append("Night truth \(Array(truth.prefix(12))), out \(Array(out.prefix(12)))")
        } else { checks["Night registers both noisy frames"] = false }
        let darker = first.applyingFilter("CIExposureAdjust",parameters:[kCIInputEVKey:-0.6])
        let lighter = first.applyingFilter("CIExposureAdjust",parameters:[kCIInputEVKey:0.6])
        if let result = ImageFusion.fuse([darker,first,lighter],kind:.hdr,context:context) {
            checks["HDR registers exposure differences"] = result.used == 3
            checks["HDR output is finite and opaque"] = result.image.extent.width > 240 && result.image.extent.height > 240 && !ImageRegistration.pixels(result.image,bounds:result.image.extent,context:context).enumerated().contains { $0.offset%4 == 3 && $0.element < 250 }
        } else { checks["HDR registers exposure differences"] = false }
        var filmSignatures: Set<Data> = []
        let engine = ColorEngine()
        for look in Look.all where FilmProfile.all[look.id] != nil {
            var settings = ColorSettings(); settings.look = look; settings.ratio = 1; settings.grain = 0; settings.vignette = 0; settings.strength = 1
            let result = engine.process(first,settings:settings,preview:false)
            let bytes = ImageRegistration.pixels(result,bounds:first.extent,context:context)
            filmSignatures.insert(Data(bytes))
            checks["Film renders " + look.id] = bytes.count == 256*256*4 && bytes.enumerated().filter { $0.offset%4 != 3 }.contains { $0.element > 20 && $0.element < 240 }
            if look.id == "hp5" {
                var monochrome = true
                for i in stride(from:0,to:bytes.count,by:4) {
                    let red = Int(bytes[i]), green = Int(bytes[i+1]), blue = Int(bytes[i+2])
                    if abs(red-green) > 1 || abs(green-blue) > 1 { monochrome = false; break }
                }
                checks["HP5 is monochrome"] = monochrome
            }
        }
        checks["Six film profiles produce distinct images"] = filmSignatures.count == 6
        let legacy = Data("{\"encoding\":\"HEIF\",\"timerSeconds\":5,\"zebra\":true}".utf8)
        if let options = ProOptions.migrated(legacy) { checks["v0.3 options migrate without resetting choices"] = options.encoding == .heif && options.timerSeconds == 5 && options.zebra && options.tracking == .off && options.nightFrames == 6 }
        else { checks["v0.3 options migrate without resetting choices"] = false }
        let tracker = SubjectTracker()
        checks["Eye tracker clears on blank image"] = tracker.update(blank,mode:.eye,now:0).target == nil
        checks["Subject tracker waits for user selection"] = tracker.update(first,mode:.subject,now:1).target == nil
        checks["Tracker off does not invent targets"] = tracker.update(first,mode:.off,now:2).target == nil
        let controller = CameraController()
        let (document,found) = controller.documentImage(blank,monochrome:false)
        checks["Document missing corners keeps original"] = !found && document.extent == blank.extent
        return (checks,notes)
    }
}
#endif
