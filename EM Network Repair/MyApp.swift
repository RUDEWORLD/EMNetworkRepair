import SwiftUI
import Combine

@main struct MyApp: App {
    @StateObject private var updateChecker = UpdateChecker()

    var body: some Scene {
        WindowGroup("EventMaster 9.2 Network Fix") {
            ContentView()
                .environmentObject(updateChecker)
                .onAppear {
                    // Silent auto-check shortly after launch. If a newer
                    // version exists the user is ASKED (Download & Install /
                    // Later); when up to date or offline, nothing is shown.
                    DispatchQueue.main.asyncAfter(deadline: .now() + 1.0) {
                        updateChecker.checkForUpdates()
                    }
                }
        }
        .windowResizability(.contentSize)
    }
}
