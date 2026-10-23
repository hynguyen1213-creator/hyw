import SwiftUI
import PhotosUI
import UniformTypeIdentifiers

private let cameraRed = Color(red: 0.89, green: 0.19, blue: 0.15)
private let cameraWhite = Color(white: 0.96)
private let cameraBlack = Color.black
private let cameraPanel = Color(red: 0.095, green: 0.10, blue: 0.098)

struct CameraScreen: View {
    @ObservedObject var camera: CameraController
    @Environment(\.scenePhase) private var scenePhase
    @State private var color = ColorSettings.restored()
    @StateObject private var horizon = HorizonMeter()
    @State private var showProSettings = false
    @State private var showPresets = false
    @State private var pinchStart: CGFloat?
    @State private var showControls = false
    @State private var showGallery = false
    @State private var showLooks = false
    @State private var showColor = false
    @State private var showHelp = false
    @State private var showQuick = false
    @State private var showModes = false
    @State private var showFileImport = false
    @State private var picker: PhotosPickerItem?
    @State private var countdown = 0
    @State private var countdownTask: Task<Void, Never>?
    @State private var shutterPending = false
    @State private var focusPoint: CGPoint?
    @State private var focusTask: Task<Void, Never>?

    var body: some View {
        GeometryReader { geometry in
            let compact = geometry.size.height < 690
            VStack(spacing: 0) {
                header(compact: compact)
                if camera.mode == .pro { quickControls }
                viewfinder
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
                luxControlBar
                captureDeck(compact: compact)
            }
            .frame(width: geometry.size.width, height: geometry.size.height)
        }
        .background(cameraBlack.ignoresSafeArea())
        .foregroundStyle(cameraWhite)
        .task {
            if !ProcessInfo.processInfo.arguments.contains("--ui-smoke") { camera.authorizeAndStart(); horizon.start() }
            update(); camera.updateOptions()
            #if targetEnvironment(simulator)
            if ProcessInfo.processInfo.arguments.contains("--self-check") { Task.detached { await SimulatorChecks.run() } }
            #endif
            if ProcessInfo.processInfo.arguments.contains("--pro-settings") { showProSettings = true }
            if ProcessInfo.processInfo.arguments.contains("--pro-controls") { showControls = true }
            if ProcessInfo.processInfo.arguments.contains("--night-settings") { camera.changeMode(.night); showProSettings = true }
            if ProcessInfo.processInfo.arguments.contains("--pano") { camera.changeMode(.panorama) }
            if ProcessInfo.processInfo.arguments.contains("--lux-quick") { showQuick = true }
            if ProcessInfo.processInfo.arguments.contains("--film-looks") { showLooks = true }
            if ProcessInfo.processInfo.arguments.contains("--mode-picker") { showModes = true }
        }
        .onDisappear { horizon.stop() }
        .onChange(of: camera.options) { _, _ in camera.updateOptions() }
        .onChange(of: camera.colorRevision) { _, _ in color = camera.currentColor() }
        .onChange(of: camera.mode) { _, mode in
            if mode.isMovie { color.ratio = 9.0 / 16 } else { color.ratio = 3.0 / 4 }
            update()
        }
        .onChange(of: scenePhase) { _, phase in
            camera.setActive(phase == .active && !showGallery)
            if phase == .active { horizon.start() } else { horizon.stop() }
            if phase != .active {
                countdownTask?.cancel(); countdown = 0; shutterPending = false
                focusTask?.cancel(); focusPoint = nil
                camera.setCompare(false)
            }
        }
        .onChange(of: picker) { _, item in
            Task {
                guard let item, let data = try? await item.loadTransferable(type: Data.self) else { return }
                camera.importPhoto(data)
            }
        }
        .onChange(of: showGallery) { _, visible in camera.setActive(!visible && scenePhase == .active) }
        .fileImporter(isPresented: $showFileImport, allowedContentTypes: [.image, .rawImage]) { result in
            if case .success(let url) = result {
                Task {
                    let accessed = url.startAccessingSecurityScopedResource(); defer { if accessed { url.stopAccessingSecurityScopedResource() } }
                    do {
                        let size = try url.resourceValues(forKeys: [.fileSizeKey]).fileSize ?? 0
                        guard size < 150_000_000 else { camera.notify("File quá lớn; chọn ảnh dưới 150 MB."); return }
                        let data = try await Task.detached(priority: .userInitiated) { try Data(contentsOf: url) }.value; camera.importPhoto(data)
                    } catch { camera.notify(error.localizedDescription) }
                }
            }
        }
        .sheet(isPresented: $showQuick) {
            LuxQuickPanel(camera:camera,looks:{ showLooks = true },advanced:{ showProSettings = true })
                .presentationDetents([.height(620)]).presentationDragIndicator(.visible).presentationCornerRadius(26)
        }
        .sheet(isPresented: $showModes) { modeDrawer.presentationDetents([.height(450)]).presentationDragIndicator(.visible).presentationBackground(cameraPanel) }
        .onChange(of: showLooks) { _, visible in if visible { camera.prepareLookThumbnails() } }
        .sheet(isPresented: $showProSettings) { ProSettingsPanel(camera: camera) }
        .sheet(isPresented: $showPresets) { PresetPanel(camera: camera) }
        .sheet(isPresented: $showControls) {
            HardwareControls(camera: camera)
                .presentationDetents([.large]).presentationDragIndicator(.visible)
                .presentationCornerRadius(26)
        }
        .sheet(isPresented: $showGallery) { GalleryScreen(camera: camera) }
        .sheet(isPresented: $showLooks) {
            looksDrawer.presentationDetents([.height(600), .large])
                .presentationDragIndicator(.visible).presentationCornerRadius(26)
                .presentationBackground(cameraPanel)
        }
        .sheet(isPresented: $showColor) {
            colorDrawer.presentationDetents([.height(460), .large])
                .presentationDragIndicator(.visible).presentationCornerRadius(26)
                .presentationBackground(cameraPanel)
        }
        .sheet(isPresented: $showHelp) { help }
        .overlay(alignment: .top) {
            if !camera.toast.isEmpty { Text(camera.toast).font(.system(size: 12, weight: .medium)).padding(12).background(.ultraThinMaterial, in: Capsule()).padding(.top, 90).allowsHitTesting(false) }
        }
        .alert("G.LENS", isPresented: Binding(get: { !camera.message.isEmpty }, set: { if !$0 { camera.message = "" } })) {
            Button("OK") { camera.message = "" }
        } message: { Text(camera.message) }
    }

    private func header(compact: Bool) -> some View {
        HStack {
            Button { showQuick = true } label: { Image(systemName: camera.options.flash == 0 ? "bolt.slash" : "bolt").font(.system(size:19,weight:.light)).frame(width:44,height:44) }
                .accessibilityLabel("Mở thiết lập nhanh")
            Spacer()
            Text(camera.imported ? "DARKROOM" : "G.LENS").font(.system(size:12,weight:.medium,design:.monospaced)).tracking(2).foregroundStyle(.white.opacity(0.65))
            Spacer()
            Button { showQuick = true } label: { Image(systemName:"slider.horizontal.3").font(.system(size:19,weight:.light)).frame(width:44,height:44) }.accessibilityLabel("Thiết lập nhanh")
        }.padding(.horizontal,12).frame(height:compact ? 44 : 48)
    }
    private var luxControlBar: some View {
        HStack(spacing:16) {
            Button { showControls = true } label: {
                VStack(spacing:5) { Image(systemName:"dial.low").font(.system(size:20,weight:.light)); Text(camera.manualExposure ? "M" : "AUTO").font(.system(size:9,weight:.medium,design:.monospaced)) }.frame(width:48,height:52)
            }.accessibilityLabel("ISO, tốc độ, WB và lấy nét thủ công").disabled(camera.capturing || camera.sequenceActive || camera.recordingBusy)
            if camera.mode == .portrait {
                LuxDial(value:$camera.options.portraitBlur,range:0...1,step:0.05,title:"BOKEH",formatted:"\(Int(camera.options.portraitBlur*100))%")
                    .disabled(camera.capturing || camera.sequenceActive)
            } else {
                LuxDial(value:Binding(get:{ Double(camera.exposureBias) },set:{ camera.exposureBias = Float($0); camera.setEV(Float($0)) }),range:Double(camera.minEV)...Double(camera.maxEV),step:0.1,title:"EV",formatted:String(format:"%+.1f",camera.exposureBias))
                    .disabled(camera.manualExposure || camera.aeLocked || !camera.running || camera.capturing || camera.sequenceActive)
            }
            Button { showLooks = true } label: {
                VStack(spacing:5) { Image(systemName:"camera.filters").font(.system(size:20,weight:.light)); Text(camera.mode.isMovie ? "CAMERA" : color.look.name.uppercased()).font(.system(size:9,weight:.medium,design:.monospaced)).lineLimit(1).minimumScaleFactor(0.6) }.frame(width:76,height:52)
            }.accessibilityLabel("Chọn màu và preset film").disabled(camera.mode.isMovie || camera.capturing || camera.sequenceActive)
        }.padding(.horizontal,20).padding(.top,10).padding(.bottom,4)
    }
    private var modeDrawer: some View {
        VStack(alignment:.leading,spacing:20) {
            drawerHeader(eyebrow:"CAPTURE",title:"Chế độ",close:{ showModes = false })
            LazyVGrid(columns:Array(repeating:GridItem(.flexible(),spacing:10),count:3),spacing:10) {
                ForEach(ShootingMode.allCases) { mode in
                    Button { camera.changeMode(mode); showModes = false } label: {
                        VStack(spacing:8) { Text(mode == .photo ? "P" : mode == .pro ? "M" : mode == .portrait ? "A" : mode.rawValue.prefix(1).uppercased()).font(.system(size:23,weight:.light,design:.monospaced)); Text(mode.rawValue).font(.system(size:9,weight:.medium,design:.monospaced)) }
                            .frame(maxWidth:.infinity).frame(height:64).foregroundStyle(camera.mode == mode ? .white : .gray)
                            .background(.white.opacity(camera.mode == mode ? 0.1 : 0.03),in:RoundedRectangle(cornerRadius:12))
                            .overlay(RoundedRectangle(cornerRadius:12).stroke(camera.mode == mode ? cameraRed : .clear,lineWidth:1))
                    }
                }
            }
        }.padding(24).foregroundStyle(.white)
    }

    private var viewfinder: some View {
        GeometryReader { available in
            let width = min(available.size.width, available.size.height * color.ratio)
            let height = width / color.ratio
            ZStack {
                Color.black
                ZStack {
                    Color(white: 0.065)
                    if let image = camera.preview {
                        Image(uiImage: image).resizable().aspectRatio(contentMode: .fit)
                            .frame(width: width, height: height)
                    } else {
                        permissionView
                    }
                    if camera.options.grid != .off { ProGrid(style: camera.options.grid).stroke(.white.opacity(0.24), lineWidth: 0.5).allowsHitTesting(false) }
                    if let overlay = camera.analysis.overlay, !camera.imported, camera.options.zebra || camera.options.peaking {
                        Image(uiImage: overlay).resizable().interpolation(.none).frame(width: width, height: height).allowsHitTesting(false)
                    }
                    if camera.options.safeFrame { Rectangle().strokeBorder(.white.opacity(0.45), style: StrokeStyle(lineWidth: 0.7, dash: [4, 3])).padding(.horizontal, width * 0.05).padding(.vertical, height * 0.05).allowsHitTesting(false) }
                    if camera.options.level && !camera.imported && camera.preview != nil {
                        ZStack {
                            Rectangle().fill(.white.opacity(0.45)).frame(width: 68, height: 1)
                            Rectangle().fill(abs(horizon.degrees) < 1.5 ? Color.green : Color.yellow).frame(width: 68, height: 2).rotationEffect(.degrees(-horizon.degrees))
                            Circle().stroke(abs(horizon.degrees) < 1.5 ? Color.green : Color.yellow, lineWidth: 1).frame(width: 7, height: 7)
                        }.allowsHitTesting(false)
                    }
                    LinearGradient(colors: [.black.opacity(0.27), .clear, .clear, .black.opacity(0.52)], startPoint: .top, endPoint: .bottom)
                        .allowsHitTesting(false)
                    if camera.preview != nil && !camera.imported {
                        Color.clear.contentShape(Rectangle())
                            .onTapGesture(coordinateSpace: .local) { point in
                                let normalized = CGPoint(x: min(1, max(0, point.x / width)), y: min(1, max(0, point.y / height)))
                                camera.track(at: normalized)
                                focusPoint = normalized
                                focusTask?.cancel()
                                focusTask = Task { @MainActor in
                                    try? await Task.sleep(for: .seconds(1.2))
                                    if !Task.isCancelled { withAnimation(.easeOut(duration: 0.18)) { focusPoint = nil } }
                                }
                            }
                    }
                    if let target = camera.trackingTarget, !camera.imported {
                        RoundedRectangle(cornerRadius: 4).stroke(Color.green, lineWidth: 1.2)
                            .frame(width: target.box.width*width, height: target.box.height*height)
                            .position(x: target.box.midX*width, y: (1-target.box.midY)*height).allowsHitTesting(false)
                        Circle().stroke(Color.green, lineWidth: 1.5).frame(width: 16,height: 16)
                            .position(x: target.point.x*width,y: target.point.y*height).allowsHitTesting(false)
                        VStack { Text(target.label).font(.system(size: 9, weight: .semibold, design: .monospaced)).foregroundStyle(.green).padding(.top, 45); Spacer() }.allowsHitTesting(false)
                    }
                    if camera.options.histogram && !camera.imported && camera.preview != nil { VStack { HStack { Spacer(); ProHistogram(analysis: camera.analysis) }; Spacer() }.padding(.top, 59).padding(.trailing, 18).allowsHitTesting(false) }
                    if let focusPoint {
                        FocusReticle().stroke(cameraRed, lineWidth: 1)
                            .frame(width: 55, height: 55)
                            .position(x: focusPoint.x * width, y: focusPoint.y * height)
                            .allowsHitTesting(false)
                    }
                    viewfinderOverlays(width: width)
                    if countdown > 0 {
                        Text("\(countdown)").font(.system(size: 84, weight: .ultraLight, design: .rounded))
                            .shadow(color: .black.opacity(0.5), radius: 12).allowsHitTesting(false)
                    }
                    if camera.interrupted {
                        Label("Camera đang tạm gián đoạn", systemImage: "pause.circle")
                            .font(.system(size: 11)).padding(.horizontal, 16).padding(.vertical, 11)
                            .background(.black.opacity(0.8), in: Capsule())
                    }
                }
                .frame(width: max(1, width), height: max(1, height)).clipped()
                .simultaneousGesture(MagnifyGesture().onChanged { value in
                    guard !camera.imported, !camera.changingLens, !camera.capturing, !camera.sequenceActive else { return }
                    if pinchStart == nil { pinchStart = camera.zoom }
                    camera.zoom = max(1, min(camera.maxZoom, (pinchStart ?? 1) * value.magnification)); camera.setZoom(camera.zoom)
                }.onEnded { _ in pinchStart = nil })
            }.frame(width: available.size.width, height: available.size.height)
        }
    }

    private var permissionView: some View {
        VStack(spacing: 15) {
            Image(systemName: "camera.aperture").font(.system(size: 43, weight: .ultraLight))
                .foregroundStyle(.white.opacity(0.25))
            Text(camera.permissionDenied ? "Mở một góc nhìn mới." : "Chậm lại. Nhìn sâu hơn.")
                .font(.system(size: 15, weight: .light)).foregroundStyle(.white.opacity(0.6))
            if camera.permissionDenied {
                Button {
                    if let url = URL(string: UIApplication.openSettingsURLString) { UIApplication.shared.open(url) }
                } label: {
                    Label("Cho phép camera", systemImage: "arrow.up.right")
                        .font(.system(size: 11, weight: .medium)).padding(.horizontal, 16).padding(.vertical, 11)
                        .background(.white.opacity(0.08), in: Capsule())
                }
                Text("Mở Cài đặt → G.LENS → Camera")
                    .font(.system(size: 9)).foregroundStyle(.white.opacity(0.3))
            } else {
                Button("Bật camera") { camera.authorizeAndStart() }
                    .font(.system(size: 11, weight: .medium)).foregroundStyle(cameraRed)
                    .padding(.horizontal, 14).padding(.vertical, 7)
            }
        }.padding(24)
    }

    private func viewfinderOverlays(width: CGFloat) -> some View {
        VStack(spacing: 0) {
            HStack {
                Text(camera.imported ? "EDIT" : camera.mode.rawValue).font(.system(size:9,weight:.medium,design:.monospaced)).tracking(1)
                Spacer()
                Text("GỐC").font(.system(size:9,weight:.medium)).padding(8).background(.black.opacity(0.25),in:Capsule())
                    .onLongPressGesture(minimumDuration:0.05,pressing:{ camera.setCompare($0) },perform:{})
                    .accessibilityLabel("Giữ để so sánh ảnh gốc")
            }
            Spacer(minLength: 8)
            if !camera.sequenceProgress.isEmpty { Text(camera.sequenceProgress).font(.system(size: 18, weight: .medium, design: .monospaced)).padding(10).background(.black.opacity(0.5), in: Capsule()) }
            if camera.mode == .hdr { Text("HDR · 3 ảnh · giữ máy yên").font(.system(size: 10)).padding(6).background(.black.opacity(0.35), in: Capsule()) }
            if camera.mode == .night && !camera.sequenceActive { Text("NIGHT · \(camera.options.nightFrames) ảnh · giữ máy yên").font(.system(size: 10)).padding(6).background(.black.opacity(0.35), in: Capsule()) }
            if camera.mode == .panorama && !camera.sequenceActive { Text("PANO · giữ máy dọc, lia ngang chậm →").font(.system(size: 10)).padding(6).background(.black.opacity(0.35), in: Capsule()) }
            if camera.mode == .document { Text("DOC · tự sửa bốn góc khi lưu").font(.system(size: 10)).padding(6).background(.black.opacity(0.35), in: Capsule()) }
            if camera.options.tracking == .subject && camera.trackingTarget == nil && !camera.sequenceActive { Text("Chạm vào chủ thể để theo nét").font(.system(size: 10)).padding(6).background(.black.opacity(0.35), in: Capsule()) }
            if camera.mode == .portrait { Text("Xoá phông người khi lưu").font(.system(size: 10)).padding(6).background(.black.opacity(0.35), in: Capsule()) }
            if camera.mode == .longExposure { Text("STACK · \(Int(camera.options.longSeconds))s · tripod").font(.system(size: 10, design: .monospaced)).padding(6).background(.black.opacity(0.35), in: Capsule()) }
            HStack(spacing: 9) {
                Text(camera.imported ? "ON-DEVICE COLOR" : camera.running ? String(format: "ISO %.0f", camera.currentISO) : "CAMERA CHƯA BẬT")
                if !camera.imported && camera.running {
                    Text(shutterName(camera.currentShutter))
                    if camera.manualExposure { Text("M").foregroundStyle(cameraRed) }
                    Text(String(format: "%+.1f", camera.meterEV))
                    if camera.aeLocked { Text("AE-L").foregroundStyle(.yellow) }
                    if camera.afLocked { Text("AF-L").foregroundStyle(.yellow) }
                }
                Spacer()
                if !camera.imported && !camera.mode.isMovie { Text(camera.mode == .longExposure ? "1920px" : camera.photoResolution) }
            }
            .font(.system(size: 8, weight: .regular, design: .monospaced))
            .foregroundStyle(.white.opacity(0.72)).padding(.horizontal, 7).padding(.bottom, 14)
            cameraLenses(compact: width < 300)
        }.padding(15)
    }

    private func cameraLenses(compact: Bool) -> some View {
        HStack(spacing: 10) {
            if camera.imported {
                Button { camera.returnToCamera() } label: {
                    Label("Quay lại camera", systemImage: "arrow.uturn.backward")
                        .font(.system(size: 10, weight: .medium)).padding(.horizontal, 17).padding(.vertical, 11)
                }.background(.black.opacity(0.6), in: Capsule())
            } else {
                Menu {
                    ForEach(camera.lenses) { lens in
                        Button { camera.selectLens(lens.id) } label: {
                            if camera.selectedLens == lens.id { Label(lens.title, systemImage: "checkmark") }
                            else { Text(lens.title) }
                        }
                    }
                } label: {
                    HStack(spacing: 4) {
                        Text(camera.lenses.first(where: { $0.id == camera.selectedLens })?.title.uppercased() ?? "CHÍNH")
                        Image(systemName: "chevron.down").font(.system(size: 7, weight: .medium))
                    }.font(.system(size: 8, weight: .semibold)).lineLimit(1)
                        .padding(.horizontal, 10).frame(height: 36)
                        .background(.black.opacity(0.65), in: Capsule())
                }
                .disabled(!camera.running || camera.capturing || camera.changingLens || camera.recording || camera.recordingBusy || camera.sequenceActive)
                .accessibilityLabel("Chọn camera vật lý")
                HStack(spacing: 1) {
                    ForEach(compact ? [1.0, 2.0, 3.0] : [1.0, 1.2, 1.5, 2.0, 3.0], id: \.self) { value in
                        if CGFloat(value) <= camera.maxZoom {
                            let selected = abs(camera.zoom - CGFloat(value)) < 0.035
                            Button {
                                camera.zoom = CGFloat(value); camera.setZoom(CGFloat(value))
                            } label: {
                                Text(String(format: "%g", value))
                                    .font(.system(size: 10, weight: selected ? .semibold : .regular, design: .monospaced))
                                    .frame(width: 31, height: 31)
                                    .foregroundStyle(selected ? cameraRed : .white.opacity(0.75))
                                    .background(selected ? Color.white : Color.clear, in: Circle())
                            }.disabled(!camera.running || camera.capturing || camera.changingLens || camera.sequenceActive)
                                .accessibilityLabel("Zoom số \(String(format: "%g", value)) lần")
                        }
                    }
                }.padding(3).background(.black.opacity(0.65), in: Capsule())
            }
        }.frame(maxWidth: .infinity)
    }

    private func captureDeck(compact: Bool) -> some View {
        VStack(spacing: compact ? 8 : 12) {
            HStack {
                Button { showGallery = true } label: {
                    ZStack {
                        RoundedRectangle(cornerRadius: 5).fill(.white.opacity(0.06))
                        if let image = camera.lastThumbnail {
                            Image(uiImage: image).resizable().aspectRatio(contentMode: .fill)
                        } else {
                            Image(systemName: "photo.on.rectangle").font(.system(size: 19, weight: .light)).foregroundStyle(.white.opacity(0.55))
                        }
                    }.frame(width: 42, height: 46).clipped().clipShape(RoundedRectangle(cornerRadius: 5))
                        .overlay(RoundedRectangle(cornerRadius: 5).stroke(.white.opacity(0.16), lineWidth: 0.6))
                }.frame(width: 62, height: 70).accessibilityLabel("Thư viện ảnh").disabled(camera.recording || camera.recordingBusy || camera.capturing || camera.sequenceActive)
                Spacer()
                Button { timedCapture() } label: {
                    ZStack {
                        Circle().stroke(.white.opacity(0.3), lineWidth: 1)
                        if camera.recording || camera.sequenceActive { RoundedRectangle(cornerRadius: 5).fill(cameraRed).frame(width: 27, height: 27) }
                        else { Circle().fill(camera.mode.isMovie ? cameraRed : cameraWhite).padding(4) }
                        if camera.capturing || camera.recordingBusy { ProgressView().tint(.black) }
                        if shutterPending { Text("\(max(1, countdown))").font(.system(size: 20, weight: .medium, design: .monospaced)).foregroundStyle(.black) }
                    }.frame(width: compact ? 68 : 76, height: compact ? 68 : 76)
                }
                .buttonStyle(CameraShutterStyle())
                .disabled((camera.capturing && !camera.sequenceActive) || camera.changingLens || camera.recordingBusy || camera.adjustingExposure || (!camera.running && !camera.imported) || (camera.mode.isMovie && camera.selectedVideo == nil))
                .accessibilityLabel(camera.recording || camera.sequenceActive ? "Dừng" : camera.mode.isMovie ? "Quay video" : camera.imported ? "Lưu ảnh đã chỉnh màu" : "Chụp ảnh")
                Spacer()
                Button { showModes = true } label: {
                    VStack(spacing:3) {
                        Text(camera.mode == .photo ? "P" : camera.mode == .pro ? "M" : camera.mode == .portrait ? "A" : camera.mode.rawValue).font(.system(size:camera.mode.rawValue.count > 4 ? 12 : 23,weight:.light,design:.monospaced))
                        Text("MODE").font(.system(size:9,weight:.medium,design:.monospaced))
                    }.frame(width:60,height:60).overlay(RoundedRectangle(cornerRadius:15).stroke(.white.opacity(0.2),lineWidth:1))
                }.accessibilityLabel("Chọn chế độ chụp").disabled(camera.recording || camera.recordingBusy || camera.capturing || camera.sequenceActive || shutterPending || camera.imported)
            }.padding(.horizontal, 28)
        }
        .padding(.top, compact ? 5 : 10).padding(.bottom, compact ? 8 : 15)
        .background(cameraBlack)
    }

    private var looksDrawer: some View {
        VStack(alignment:.leading,spacing:22) {
            drawerHeader(eyebrow:"LOOKS / FILM",title:"Chất ảnh",close:{ showLooks = false })
            ScrollViewReader { proxy in
                ScrollView(.horizontal,showsIndicators:false) {
                    HStack(spacing:12) {
                        ForEach(Look.all) { look in
                            Button { selectLook(look) } label: {
                                VStack(alignment:.leading,spacing:9) {
                                    ZStack {
                                        if let thumbnail = camera.lookThumbnails[look.id] { Image(uiImage:thumbnail).resizable().scaledToFill() }
                                        else { LinearGradient(colors:palette(for:look),startPoint:.topLeading,endPoint:.bottomTrailing).overlay { Image(systemName:"camera.aperture").font(.system(size:28,weight:.ultraLight)).foregroundStyle(.white.opacity(0.65)) } }
                                    }.frame(width:100,height:128).clipped().clipShape(RoundedRectangle(cornerRadius:8))
                                        .overlay(RoundedRectangle(cornerRadius:8).stroke(color.look.id == look.id ? cameraRed : .clear,lineWidth:2))
                                    Text(look.name).font(.system(size:11,weight:.medium,design:.monospaced)).foregroundStyle(color.look.id == look.id ? .white : .gray)
                                    Circle().fill(color.look.id == look.id ? cameraRed : .clear).frame(width:4,height:4)
                                }
                            }.buttonStyle(.plain).id(look.id).accessibilityAddTraits(color.look.id == look.id ? .isSelected : [])
                        }
                    }.padding(.vertical,3)
                }.onAppear { proxy.scrollTo(color.look.id,anchor:.center) }
            }
            Text(FilmProfile.all[color.look.id]?.caption ?? color.look.subtitle).font(.system(size:13)).foregroundStyle(.white.opacity(0.75))
            colorSlider("Cường độ",value:$color.strength)
            HStack {
                Button { showLooks = false; DispatchQueue.main.asyncAfter(deadline:.now()+0.3) { showColor = true } } label: { Label("Hạt / màu / khung",systemImage:"slider.horizontal.3") }
                Spacer()
                Button { showLooks = false; DispatchQueue.main.asyncAfter(deadline:.now()+0.3) { showPresets = true } } label: { Image(systemName:"bookmark") }
            }.font(.system(size:12)).foregroundStyle(.white).frame(height:44)
            Text("Mô phỏng màu film do G.LENS tự xây dựng. Không phải LUT chính hãng hoặc bản quét film đã đo chuẩn.").font(.system(size:10)).foregroundStyle(.gray)
        }.padding(24).foregroundStyle(.white)
    }
    private func selectLook(_ look: Look) {
        color.look = look
        if let profile = FilmProfile.all[look.id] { color.grain = profile.grain; color.strength = 0.9; color.vignette = 0.12 }
        UISelectionFeedbackGenerator().selectionChanged(); update()
    }

    private var colorDrawer: some View {
        ScrollView(showsIndicators: false) {
            VStack(alignment: .leading, spacing: 25) {
                drawerHeader(eyebrow: "MAKE IT YOURS", title: "Tinh chỉnh", close: { showColor = false })
                HStack {
                    PhotosPicker(selection:$picker,matching:.images) { Label("Mở ảnh",systemImage:"photo") }
                    Spacer()
                    Button { showColor = false; DispatchQueue.main.asyncAfter(deadline:.now()+0.3) { showFileImport = true } } label: { Label("Mở DNG / Tệp",systemImage:"doc") }
                }.font(.system(size:12)).disabled(camera.capturing || camera.sequenceActive || camera.recording)
                VStack(spacing: 24) {
                    colorSlider("Cường độ màu", value: $color.strength)
                    colorSlider("Hạt ảnh", value: $color.grain)
                    colorSlider("Tối viền", value: $color.vignette)
                    adjustmentSlider("Bù sáng xử lý", value: $color.exposure, range: -2...2)
                    adjustmentSlider("Tương phản", value: $color.contrast, range: 0.7...1.4)
                    adjustmentSlider("Bão hoà", value: $color.saturation, range: 0...1.5)
                    adjustmentSlider("Ấm / lạnh", value: $color.temperature, range: -1...1)
                    adjustmentSlider("Tint xanh / tím", value: $color.tint, range: -1...1)
                    adjustmentSlider("Vùng tối", value: $color.shadows, range: -0.5...1)
                    adjustmentSlider("Vùng sáng", value: $color.highlights, range: 0...1)
                    colorSlider("Độ nét", value: $color.sharpness)
                }
                Rectangle().fill(.white.opacity(0.08)).frame(height: 0.5)
                Toggle(isOn: $color.frame) {
                    HStack(spacing: 12) {
                        Image(systemName: "rectangle.inset.filled").font(.system(size: 21, weight: .ultraLight)).foregroundStyle(.white.opacity(0.55))
                        VStack(alignment: .leading, spacing: 4) {
                            Text("Signature frame").font(.system(size: 12, weight: .medium))
                            Text("Khung trắng, thông số và tên tác giả").font(.system(size: 9)).foregroundStyle(.white.opacity(0.35))
                        }
                    }
                }.tint(cameraRed).onChange(of: color.frame) { _, _ in update() }
                if color.frame {
                    TextField("Tên tác giả", text: $color.author)
                        .font(.system(size: 12)).padding(13)
                        .background(.white.opacity(0.05), in: RoundedRectangle(cornerRadius: 7))
                        .onChange(of: color.author) { _, _ in update() }
                }
                Button {
                    let look = color.look; color = ColorSettings(); color.look = look; update()
                } label: {
                    Label("Đặt lại tinh chỉnh", systemImage: "arrow.counterclockwise")
                        .font(.system(size: 10)).foregroundStyle(.white.opacity(0.4)).frame(maxWidth: .infinity)
                }.padding(.top, 1)
            }.padding(.horizontal, 25).padding(.top, 30).padding(.bottom, 28)
        }.foregroundStyle(cameraWhite)
    }

    private func drawerHeader(eyebrow: String, title: String, close: @escaping () -> Void) -> some View {
        HStack(alignment: .top) {
            VStack(alignment: .leading, spacing: 7) {
                Text(eyebrow).font(.system(size: 7, weight: .medium, design: .monospaced)).tracking(2).foregroundStyle(.white.opacity(0.3))
                HStack(alignment: .firstTextBaseline, spacing: 2) {
                    Text(title).font(.system(size: 27, weight: .light)).tracking(-0.9)
                    Text(".").font(.system(size: 27, weight: .light)).foregroundStyle(cameraRed)
                }
            }
            Spacer()
            Button(action: close) {
                Image(systemName: "xmark").font(.system(size: 11, weight: .medium))
                    .foregroundStyle(.white.opacity(0.5)).frame(width: 30, height: 30)
                    .background(.white.opacity(0.05), in: Circle())
            }.accessibilityLabel("Đóng")
        }
    }

    private func colorSlider(_ title: String, value: Binding<Float>) -> some View {
        VStack(spacing: 5) {
            HStack {
                Text(title).font(.system(size: 11)).foregroundStyle(.white.opacity(0.7))
                Spacer()
                Text("\(Int(value.wrappedValue * 100))").font(.system(size: 11, design: .monospaced)).foregroundStyle(.white.opacity(0.4))
            }
            Slider(value: value, in: 0...1).tint(cameraRed)
                .onChange(of: value.wrappedValue) { _, _ in update() }
        }
    }

    private func adjustmentSlider(_ title: String, value: Binding<Float>, range: ClosedRange<Float>) -> some View {
        VStack { HStack { Text(title); Spacer(); Text(String(format: "%.2f", value.wrappedValue)).monospacedDigit() }.font(.system(size: 12)); Slider(value: value, in: range).tint(cameraRed).onChange(of: value.wrappedValue) { _, _ in update() } }
    }
    private var quickControls: some View {
        HStack(spacing: 0) {
            ForEach([("WB", camera.manualWB ? "\(Int(camera.whiteBalanceKelvin))K" : "AUTO"), ("ISO", String(format: "%.0f", camera.currentISO)), ("S", ProMath.shutterLabel(camera.currentShutter)), ("EV", String(format: "%+.1f", camera.exposureBias)), ("FOCUS", camera.manualFocus ? "MF" : "AF")], id: \.0) { item in
                Button { showControls = true } label: { VStack(spacing: 4) { Text(item.0).font(.system(size: 9)); Text(item.1).font(.system(size: 11, weight: .medium, design: .monospaced)) }.frame(maxWidth: .infinity).frame(height: 43) }
            }
        }.background(.white.opacity(0.025))
    }
    private func modeButton(_ title: String, selected: Bool, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            VStack(spacing: 5) {
                Text(title).font(.system(size: 11, weight: .medium, design: .monospaced)).tracking(0.5)
                    .foregroundStyle(selected ? cameraWhite : .white.opacity(0.3))
                Circle().fill(selected ? cameraRed : .clear).frame(width: 3, height: 3)
            }
        }.accessibilityAddTraits(selected ? .isSelected : [])
    }

    private func palette(for look: Look) -> [Color] {
        switch look.id {
        case "vibrant": return [Color(red: 0.21, green: 0.46, blue: 0.40), Color(red: 0.78, green: 0.33, blue: 0.23), Color(red: 0.86, green: 0.72, blue: 0.42)]
        case "m9": return [Color(red: 0.22, green: 0.35, blue: 0.33), Color(red: 0.65, green: 0.31, blue: 0.25), Color(red: 0.75, green: 0.64, blue: 0.47)]
        case "m3": return [Color(white: 0.20), Color(white: 0.45), Color(white: 0.77)]
        case "hp5": return [Color(white:0.12),Color(white:0.45),Color(white:0.84)]
        case "cine800": return [Color(red:0.1,green:0.3,blue:0.4),Color(red:0.6,green:0.24,blue:0.2),Color(red:0.85,green:0.68,blue:0.45)]
        case "portra400": return [Color(red:0.35,green:0.42,blue:0.38),Color(red:0.72,green:0.56,blue:0.48),Color(red:0.9,green:0.82,blue:0.72)]
        case "c200": return [Color(red:0.17,green:0.35,blue:0.29),Color(red:0.62,green:0.63,blue:0.46),Color(red:0.78,green:0.83,blue:0.77)]
        case "ektar100": return [Color(red:0.15,green:0.3,blue:0.55),Color(red:0.75,green:0.22,blue:0.17),Color(red:0.92,green:0.74,blue:0.38)]
        case "gold", "gold200": return [Color(red: 0.40, green: 0.43, blue: 0.31), Color(red: 0.70, green: 0.50, blue: 0.28), Color(red: 0.87, green: 0.74, blue: 0.51)]
        case "noir": return [Color(white: 0.08), Color(white: 0.30), Color(white: 0.92)]
        default: return [Color(red: 0.22, green: 0.30, blue: 0.26), Color(red: 0.62, green: 0.34, blue: 0.27), Color(red: 0.73, green: 0.68, blue: 0.54)]
        }
    }

    private var isEssential: Bool { color.look.id == "m9" || color.look.id == "m3" }
    private var ratioName: String { color.ratio == 1 ? "1:1" : color.ratio < 0.6 ? "16:9" : color.ratio < 0.7 ? "3:2" : "4:3" }
    private func update() { camera.updateColor(color) }
    private func timedCapture() {
        if shutterPending { countdownTask?.cancel(); countdown = 0; shutterPending = false; return }
        if camera.recording || camera.sequenceActive { camera.shutterAction(); return }
        let timer = camera.options.timerSeconds
        if timer == 0 { camera.shutterAction(); return }
        shutterPending = true
        countdownTask = Task { @MainActor in
            for count in stride(from: timer, through: 1, by: -1) {
                if Task.isCancelled { break }
                countdown = count
                try? await Task.sleep(for: .seconds(1))
            }
            countdown = 0; shutterPending = false
            if !Task.isCancelled { camera.shutterAction() }
        }
    }

    private var help: some View {
        NavigationStack {
            ScrollView {
                VStack(alignment: .leading, spacing: 25) {
                    Text("The art of seeing.").font(.system(size: 32, weight: .light)).tracking(-1)
                    helpParagraph("CHỤP THEO CÁCH CỦA MÀY", "G.LENS dùng AVFoundation để truy cập camera iPhone. Cấp quyền Camera khi hệ thống hỏi, rồi chụp bằng nút tròn trắng.")
                    helpParagraph("ỐNG KÍNH & ĐIỀU KHIỂN", "Chọn camera vật lý trong menu ở kính ngắm. Các mức 1.2×, 1.5×… là zoom số trên camera đang chọn. Nút PRO mở ISO, tốc độ, lấy nét và cân bằng trắng; chức năng không hỗ trợ sẽ bị mờ.")
                    helpParagraph("MỘT CHÚT CHẤT RIÊNG", "Chọn chất ảnh ở thanh dưới. Giữ GỐC trên kính ngắm để so sánh. Cường độ, hạt ảnh, tối viền và khung chữ ký nằm trong Tinh chỉnh.")
                    helpParagraph("ẢNH Ở LẠI TRÊN IPHONE", "Ảnh được giữ trong app cho đến khi chọn Lưu vào Ảnh hoặc Chia sẻ. RAW/ProRAW chỉ hiện khi camera hỗ trợ; DNG giữ nguyên dữ liệu gốc, JPEG áp màu riêng.")
                    Text("Màu do G.LENS tự xây dựng, lấy cảm hứng từ nhiếp ảnh Leica; không sử dụng LUT độc quyền hay tái tạo phần cứng Xiaomi. Camera2 API thuộc Android. Không quảng cáo, không tải ảnh lên mạng.")
                        .font(.system(size: 10)).lineSpacing(5).foregroundStyle(.white.opacity(0.35))
                }.padding(25)
            }.background(cameraBlack).navigationTitle("G.LENS").navigationBarTitleDisplayMode(.inline)
                .toolbar { Button("Xong") { showHelp = false }.font(.system(size: 12)).foregroundStyle(cameraWhite) }
        }.tint(cameraRed)
    }
    private func helpParagraph(_ title: String, _ detail: String) -> some View {
        VStack(alignment: .leading, spacing: 9) {
            Text(title).font(.system(size: 8, weight: .medium, design: .monospaced)).tracking(1.5).foregroundStyle(cameraRed)
            Text(detail).font(.system(size: 13, weight: .light)).lineSpacing(5).foregroundStyle(.white.opacity(0.65))
        }
    }
}

private func shutterName(_ value: Double) -> String {
    value > 0 && value < 1 ? "1/\(Int((1 / value).rounded()))s" : String(format: "%.1fs", value)
}
private struct CameraShutterStyle: ButtonStyle {
    func makeBody(configuration: Configuration) -> some View {
        configuration.label.scaleEffect(configuration.isPressed ? 0.94 : 1)
            .opacity(configuration.isPressed ? 0.85 : 1).animation(.easeOut(duration: 0.12), value: configuration.isPressed)
    }
}
private struct CompositionGrid: View {
    var body: some View {
        GeometryReader { geometry in
            Path { path in
                for fraction in [1.0 / 3, 2.0 / 3] {
                    path.move(to: CGPoint(x: geometry.size.width * fraction, y: 0))
                    path.addLine(to: CGPoint(x: geometry.size.width * fraction, y: geometry.size.height))
                    path.move(to: CGPoint(x: 0, y: geometry.size.height * fraction))
                    path.addLine(to: CGPoint(x: geometry.size.width, y: geometry.size.height * fraction))
                }
            }.stroke(.white.opacity(0.28), lineWidth: 0.5)
        }
    }
}
private struct RangefinderCorners: Shape {
    func path(in rect: CGRect) -> Path {
        var p = Path()
        let length: CGFloat = 11
        for point in [CGPoint(x: rect.minX, y: rect.minY), CGPoint(x: rect.maxX, y: rect.minY), CGPoint(x: rect.minX, y: rect.maxY), CGPoint(x: rect.maxX, y: rect.maxY)] {
            let dx: CGFloat = point.x == rect.minX ? length : -length
            let dy: CGFloat = point.y == rect.minY ? length : -length
            p.move(to: CGPoint(x: point.x + dx, y: point.y)); p.addLine(to: point)
            p.addLine(to: CGPoint(x: point.x, y: point.y + dy))
        }
        return p
    }
}
private struct FocusReticle: Shape {
    func path(in rect: CGRect) -> Path {
        var p = RangefinderCorners().path(in: rect)
        p.move(to: CGPoint(x: rect.midX - 3, y: rect.midY)); p.addLine(to: CGPoint(x: rect.midX + 3, y: rect.midY))
        p.move(to: CGPoint(x: rect.midX, y: rect.midY - 3)); p.addLine(to: CGPoint(x: rect.midX, y: rect.midY + 3))
        return p
    }
}
