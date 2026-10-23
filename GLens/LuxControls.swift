import SwiftUI
import CoreImage

struct LuxDial: View {
    @Binding var value: Double
    let range: ClosedRange<Double>
    let step: Double
    let title: String
    let formatted: String
    @State private var start: Double?
    var body: some View {
        VStack(spacing: 3) {
            HStack(spacing: 6) { Text(title).foregroundStyle(.gray); Text(formatted).foregroundStyle(.white) }
                .font(.system(size: 11,weight: .medium,design:.monospaced))
            Canvas { context,size in
                let spacing: CGFloat = 12
                let center = size.width/2
                for tick in -14...14 {
                    let x = center + CGFloat(tick)*spacing - CGFloat((value/step).truncatingRemainder(dividingBy: 1))*spacing
                    guard x > 0 && x < size.width else { continue }
                    let major = (Int((value/step).rounded(.down))+tick)%5 == 0
                    var p = Path(); p.move(to:CGPoint(x:x,y:major ? 4 : 10)); p.addLine(to:CGPoint(x:x,y:23))
                    context.stroke(p,with:.color(.white.opacity(major ? 0.65 : 0.25)),lineWidth:1)
                }
                var marker = Path(); marker.move(to:CGPoint(x:center,y:0)); marker.addLine(to:CGPoint(x:center,y:26))
                context.stroke(marker,with:.color(.red),lineWidth:2)
            }.frame(height:27).contentShape(Rectangle())
                .gesture(DragGesture(minimumDistance:1).onChanged { drag in
                    if start == nil { start = value }
                    let raw = (start ?? value)-Double(drag.translation.width)/12*step
                    value = max(range.lowerBound,min(range.upperBound,(raw/step).rounded()*step))
                }.onEnded { _ in start = nil })
        }.accessibilityElement(children:.ignore).accessibilityLabel(title).accessibilityValue(formatted)
            .accessibilityAdjustableAction { direction in value = max(range.lowerBound,min(range.upperBound,value+(direction == .increment ? step : -step))) }
    }
}
struct LuxQuickPanel: View {
    @ObservedObject var camera: CameraController
    let looks: () -> Void
    let advanced: () -> Void
    @Environment(\.dismiss) private var dismiss
    var body: some View {
        ScrollView {
        VStack(spacing:20) {
            HStack { Text("G.LENS").font(.system(size:19,weight:.semibold,design:.monospaced)); Spacer(); Button("Xong") { dismiss() }.foregroundStyle(.white) }
            LazyVGrid(columns:[GridItem(.flexible()),GridItem(.flexible())],spacing:12) {
                tile(camera.rawEnabled ? "RAW + JPEG" : camera.options.encoding.rawValue,"Định dạng",icon:"photo") { if camera.supportsRaw { camera.rawEnabled.toggle() } }.disabled(!camera.supportsRaw || camera.mode.computational || camera.mode.isMovie || camera.imported)
                tile(camera.currentColor().look.name,"Chất ảnh",icon:"camera.filters") { dismiss(); DispatchQueue.main.asyncAfter(deadline:.now()+0.3) { looks() } }.disabled(camera.mode.isMovie)
                tile(camera.options.timerSeconds == 0 ? "TẮT" : "\(camera.options.timerSeconds)s","Hẹn giờ",icon:"timer") { camera.options.timerSeconds = camera.options.timerSeconds == 0 ? 3 : camera.options.timerSeconds == 3 ? 10 : 0 }
                tile(camera.options.flash == 0 ? "TẮT" : camera.options.flash == 1 ? "AUTO" : "BẬT","Flash",icon:camera.options.flash == 0 ? "bolt.slash" : "bolt") { camera.options.flash = (camera.options.flash+1)%3 }.disabled(!camera.supportsFlash || camera.mode.computational || camera.mode.isMovie)
                tile(camera.options.grid == .off ? "TẮT" : "BẬT","Lưới",icon:"grid") { camera.options.grid = camera.options.grid == .off ? .thirds : .off }
                tile(camera.options.level ? "BẬT" : "TẮT","Cân bằng",icon:"level") { camera.options.level.toggle() }
                tile(camera.options.histogram ? "BẬT" : "TẮT","Histogram",icon:"chart.bar.xaxis") { camera.options.histogram.toggle() }
                tile(camera.options.peaking ? "BẬT" : "TẮT","Peaking",icon:"viewfinder") { camera.options.peaking.toggle() }
            }
            Button { dismiss(); DispatchQueue.main.asyncAfter(deadline:.now()+0.3) { advanced() } } label: { Label("Tất cả thiết lập",systemImage:"gearshape").frame(maxWidth:.infinity).frame(height:44) }.foregroundStyle(.white)
        }.padding(24).background(Color(white:0.07)).disabled(camera.capturing || camera.recording || camera.recordingBusy || camera.sequenceActive)
        }
    }
    private func tile(_ value: String,_ title: String,icon: String,action: @escaping () -> Void) -> some View {
        Button(action:action) {
            VStack(spacing:7) { Image(systemName:icon).font(.system(size:21,weight:.light)); Text(value).font(.system(size:12,weight:.medium,design:.monospaced)).lineLimit(1).minimumScaleFactor(0.7); Text(title).font(.system(size:11)).foregroundStyle(.gray) }
                .frame(maxWidth:.infinity).frame(height:94).background(Color(white:0.12),in:RoundedRectangle(cornerRadius:14))
                .overlay(RoundedRectangle(cornerRadius:14).stroke(.white.opacity(0.1),lineWidth:1))
        }.foregroundStyle(.white)
    }
}
extension CameraController {
    func prepareLookThumbnails() {
        guard let source = locked({ importedImage ?? lookPreviewSource }) else { return }
        photoQueue.async {
            let small = ImageRegistration.normalized(source,longest:220)
            var result: [String:UIImage] = [:]
            for look in Look.all {
                var settings = ColorSettings(); settings.look = look; settings.ratio = 0.8; settings.grain = 0; settings.vignette = 0; settings.strength = 0.9
                result[look.id] = self.engine.uiImage(self.engine.process(small,settings:settings,preview:true))
            }
            DispatchQueue.main.async { self.lookThumbnails = result }
        }
    }
}
