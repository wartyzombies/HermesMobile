//  HermesMobileApp.swift
//  iOS app shell: owns the SwiftUI scene and injects a single GatewayConnection.
//
//  The `@main` entry point and `AppDelegate` are iOS-only (UIKit). The package
//  also declares a macOS platform for the shared `Gateway`/`GeneratedModels`
//  modules, so the app shell is guarded with `#if canImport(UIKit)` (Y7) —
//  a macOS consumer resolves the library targets without pulling in UIKit.

import SwiftUI

#if canImport(UIKit)
@main
struct HermesMobileApp: App {
    @UIApplicationDelegateAdaptor(AppDelegate.self) private var appDelegate

    var body: some Scene {
        WindowGroup {
            RootView()
                .environment(appDelegate.gateway)
                .environment(appDelegate.transcriptStore)
                .environment(\.hermesClient, appDelegate.gateway.api)
        }
    }
}

final class AppDelegate: NSObject, UIApplicationDelegate {
    let gateway = GatewayConnection()
    lazy var transcriptStore = TranscriptStore(gateway: gateway)

    func application(
        _ application: UIApplication,
        didFinishLaunchingWithOptions launchOptions: [UIApplication.LaunchOptionsKey: Any]? = nil
    ) -> Bool {
        return true
    }
}
#endif
