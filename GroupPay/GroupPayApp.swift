import SwiftUI

@main
struct GroupPayApp: App {
    @UIApplicationDelegateAdaptor(GroupPayAppDelegate.self) var appDelegate
    init() {
        let navigation = UINavigationBarAppearance()
        navigation.configureWithTransparentBackground()
        navigation.backgroundColor = UIColor(GP.background)
        navigation.largeTitleTextAttributes = [
            .font: UIFont(name: "Caprasimo-Regular", size: 34) ?? UIFont.preferredFont(forTextStyle: .largeTitle),
            .foregroundColor: UIColor(GP.text)
        ]
        navigation.titleTextAttributes = [
            .font: UIFont(name: "Figtree-SemiBold", size: 17) ?? UIFont.preferredFont(forTextStyle: .headline),
            .foregroundColor: UIColor(GP.text)
        ]
        UINavigationBar.appearance().standardAppearance = navigation
        UINavigationBar.appearance().scrollEdgeAppearance = navigation
    }

    var body: some Scene {
        WindowGroup {
            ContentView()
        }
    }
}
