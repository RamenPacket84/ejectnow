//
//  EjectNowApp.swift
//  ejectnow
//

import SwiftUI

@main
struct EjectNowApp: App {
    @NSApplicationDelegateAdaptor(AppDelegate.self) private var appDelegate

    var body: some Scene {
        // Required Scene for the SwiftUI lifecycle; no windows are shown.
        Settings {
            EmptyView()
        }
    }
}
