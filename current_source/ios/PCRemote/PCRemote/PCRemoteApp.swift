import SwiftUI
@main
struct ComfyRemoteApp: App {
    @StateObject private var settings = ConnectionSettings()
    var body: some Scene {
        WindowGroup {
            RootView().environmentObject(settings)
        }
    }
}
