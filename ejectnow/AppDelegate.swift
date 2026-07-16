//
//  AppDelegate.swift
//  ejectnow
//

import AppKit

final class AppDelegate: NSObject, NSApplicationDelegate {
    private var statusItemController: StatusItemController?
    private var volumeService: VolumeService?

    func applicationDidFinishLaunching(_ notification: Notification) {
        NSApp.setActivationPolicy(.accessory)

        guard let volumeService = VolumeService.make() else {
            NSLog("EjectNow: failed to start VolumeService")
            presentStartupFailure()
            return
        }

        self.volumeService = volumeService
        statusItemController = StatusItemController(volumeService: volumeService)
        NSLog("EjectNow: status item ready (%d volume(s))", volumeService.volumes.count)
    }

    func applicationShouldTerminateAfterLastWindowClosed(_ sender: NSApplication) -> Bool {
        false
    }

    private func presentStartupFailure() {
        let alert = NSAlert()
        alert.messageText = "EjectNow couldn’t start"
        alert.informativeText = "Disk Arbitration session creation failed."
        alert.alertStyle = .critical
        alert.addButton(withTitle: "Quit")
        alert.runModal()
        NSApp.terminate(nil)
    }
}
