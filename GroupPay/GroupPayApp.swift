import SwiftUI

@main
struct GroupPayApp: App {
    @UIApplicationDelegateAdaptor(GroupPayAppDelegate.self) var appDelegate
    var body: some Scene {
        WindowGroup {
            ContentView()
        }
    }
}
