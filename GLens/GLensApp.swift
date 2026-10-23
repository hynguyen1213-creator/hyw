import SwiftUI

@main
struct GLensApp: App {
    @StateObject private var camera = CameraController()
    var body: some Scene {
        WindowGroup { CameraScreen(camera: camera).preferredColorScheme(.dark) }
    }
}
