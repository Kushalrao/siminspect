import SwiftUI

@main
struct SimInspectorApp: App {
    var body: some Scene {
        WindowGroup {
            MainView()
                .frame(minWidth: 700, minHeight: 500)
        }
        .windowStyle(.titleBar)
        .defaultSize(width: 900, height: 650)
    }
}
