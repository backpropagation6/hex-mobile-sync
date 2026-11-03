import SwiftUI

@main
struct HexMobileApp: App {
    @State private var services = AppServices.shared
    @Environment(\.scenePhase) private var scenePhase
    #if DEBUG
    @State private var autoStarted = false
    #endif

    init() {
        // Category in place before any background start (Action Button).
        try? AudioCapture.configureCategory()
    }

    var body: some Scene {
        WindowGroup {
            RootView()
                .environment(services)
                .environment(services.settings)
                .environment(services.sync)
                .environment(services.history)
                .environment(services.dictation)
                .environment(services.speechAssets)
                .preferredColorScheme(services.settings.lightAppearance ? .light : .dark)
                .tint(HexPalette.foreground)
                .onOpenURL { url in
                    Task { await services.handle(url: url) }
                }
        }
        .onChange(of: scenePhase, initial: true) { old, phase in
            // `initial: true` calls this once at launch with old == new.
            Diagnostics.record(old == phase ? "scene phase initial \(phase)" : "scene phase \(old) -> \(phase)")
            if phase == .active {
                services.dictation.configureAudioCategoryForForeground()
                Task { await services.refreshOnForeground() }
                #if DEBUG
                if LaunchOptions.autoStart, !autoStarted {
                    autoStarted = true
                    Task { await services.runAutoStart() }
                }
                #endif
            }
        }
    }
}
