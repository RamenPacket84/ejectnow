//
//  StatusItemController.swift
//  ejectnow
//

import AppKit

@MainActor
final class StatusItemController: NSObject {
    private let statusItem: NSStatusItem
    private let menu = NSMenu()
    private let volumeService: VolumeService
    private var blockerScanTask: Task<Void, Never>?

    init(volumeService: VolumeService) {
        self.volumeService = volumeService
        statusItem = NSStatusBar.system.statusItem(withLength: NSStatusItem.squareLength)
        super.init()

        statusItem.autosaveName = "EjectNowStatusItem"
        statusItem.isVisible = true

        if let button = statusItem.button {
            button.image = Self.menuBarImage()
            button.toolTip = "EjectNow"
        }

        menu.delegate = self
        statusItem.menu = menu

        volumeService.onVolumesChanged = { [weak self] _ in
            self?.rebuildMenu()
        }
        rebuildMenu()
    }

    private static func menuBarImage() -> NSImage {
        if let image = NSImage(named: "MenuBarIcon") {
            image.isTemplate = true
            image.size = NSSize(width: 18, height: 18)
            return image
        }

        if let symbol = NSImage(
            systemSymbolName: "eject.fill",
            accessibilityDescription: "EjectNow"
        ) {
            symbol.isTemplate = true
            return symbol
        }

        let fallback = NSImage(size: NSSize(width: 18, height: 18))
        fallback.isTemplate = true
        return fallback
    }

    private func rebuildMenu() {
        menu.removeAllItems()

        let volumes = volumeService.volumes
        if volumes.isEmpty {
            let emptyItem = NSMenuItem(
                title: "No Ejectable Volumes",
                action: nil,
                keyEquivalent: ""
            )
            emptyItem.isEnabled = false
            menu.addItem(emptyItem)
        } else {
            for volume in volumes {
                let item = NSMenuItem(
                    title: volume.name,
                    action: nil,
                    keyEquivalent: ""
                )
                item.representedObject = volume
                item.toolTip = "\(volume.mountPath) (\(volume.bsdName))"
                item.image = NSWorkspace.shared.icon(forFile: volume.mountPath)
                item.image?.size = NSSize(width: 16, height: 16)

                let submenu = NSMenu(title: volume.name)
                let ejectItem = NSMenuItem(
                    title: "Eject",
                    action: #selector(ejectVolume(_:)),
                    keyEquivalent: ""
                )
                ejectItem.target = self
                ejectItem.representedObject = volume

                let blockersItem = NSMenuItem(
                    title: "Show Blockers…",
                    action: #selector(showBlockers(_:)),
                    keyEquivalent: ""
                )
                blockersItem.target = self
                blockersItem.representedObject = volume

                let forceItem = NSMenuItem(
                    title: "Force Eject…",
                    action: #selector(forceEjectVolume(_:)),
                    keyEquivalent: ""
                )
                forceItem.target = self
                forceItem.representedObject = volume

                submenu.addItem(ejectItem)
                submenu.addItem(blockersItem)
                submenu.addItem(.separator())
                submenu.addItem(forceItem)
                item.submenu = submenu

                menu.addItem(item)
            }
        }

        menu.addItem(.separator())

        let quitItem = NSMenuItem(
            title: "Quit EjectNow",
            action: #selector(quitApp),
            keyEquivalent: "q"
        )
        quitItem.target = self
        menu.addItem(quitItem)
    }

    @objc
    private func ejectVolume(_ sender: NSMenuItem) {
        guard let volume = sender.representedObject as? Volume else { return }
        requestEject(volume, force: false)
    }

    @objc
    private func forceEjectVolume(_ sender: NSMenuItem) {
        guard let volume = sender.representedObject as? Volume else { return }
        confirmForceEject(volume)
    }

    @objc
    private func showBlockers(_ sender: NSMenuItem) {
        guard let volume = sender.representedObject as? Volume else { return }
        presentBlockers(for: volume, offerEjectActions: true)
    }

    private func confirmForceEject(_ volume: Volume) {
        let alert = NSAlert()
        alert.messageText = "Force Eject “\(volume.name)”?"
        alert.informativeText =
            "Force ejecting may cause data loss if apps are still writing to this volume."
        alert.alertStyle = .warning
        alert.addButton(withTitle: "Force Eject")
        alert.addButton(withTitle: "Cancel")

        NSApp.activate(ignoringOtherApps: true)
        guard alert.runModal() == .alertFirstButtonReturn else { return }
        requestEject(volume, force: true)
    }

    private func requestEject(_ volume: Volume, force: Bool) {
        NSLog(
            "EjectNow: %@ eject requested for %@ (%@)",
            force ? "force" : "default",
            volume.name,
            volume.mountPath
        )

        volumeService.eject(volume: volume, force: force) { [weak self] outcome in
            self?.handleEjectOutcome(outcome, volume: volume, wasForce: force)
        }
    }

    private func handleEjectOutcome(_ outcome: EjectOutcome, volume: Volume, wasForce: Bool) {
        switch outcome {
        case .succeeded:
            NSLog("EjectNow: ejected %@", volume.name)

        case .busy(let message):
            NSLog("EjectNow: busy — %@", message)
            if wasForce {
                presentError(
                    title: "Couldn’t Force Eject “\(volume.name)”",
                    message: message
                )
            } else {
                presentBlockers(for: volume, offerEjectActions: true, daMessage: message)
            }

        case .failed(let message):
            NSLog("EjectNow: failed — %@", message)
            presentError(
                title: "Couldn’t Eject “\(volume.name)”",
                message: message
            )
        }
    }

    private func presentBlockers(
        for volume: Volume,
        offerEjectActions: Bool,
        daMessage: String? = nil
    ) {
        blockerScanTask?.cancel()
        blockerScanTask = Task { [weak self] in
            guard let self else { return }

            let blockers: [ProcessBlocker]
            do {
                blockers = try await BlockerService.findBlockers(on: volume.mountPath)
            } catch {
                if Task.isCancelled { return }
                presentError(
                    title: "Couldn’t Scan Blockers",
                    message: error.localizedDescription
                )
                return
            }

            if Task.isCancelled { return }

            let choice = presentBlockersAlert(
                volume: volume,
                blockers: blockers,
                offerEjectActions: offerEjectActions,
                daMessage: daMessage
            )

            switch choice {
            case .killAndEject:
                await killBlockersAndRetryEject(volume: volume, blockers: blockers)
            case .forceEject:
                requestEject(volume, force: true)
            case .dismiss:
                break
            }
        }
    }

    private enum BlockerAlertChoice {
        case killAndEject
        case forceEject
        case dismiss
    }

    private func presentBlockersAlert(
        volume: Volume,
        blockers: [ProcessBlocker],
        offerEjectActions: Bool,
        daMessage: String?
    ) -> BlockerAlertChoice {
        let alert = NSAlert()
        alert.messageText = blockers.isEmpty
            ? "No Process Blockers Found"
            : "“\(volume.name)” is in use"
        alert.alertStyle = .warning

        if blockers.isEmpty {
            var info = "No processes currently report open files on \(volume.mountPath)."
            if let daMessage, !daMessage.isEmpty {
                info += "\n\nDisk Arbitration still reported the volume as busy (\(daMessage))."
            }
            if offerEjectActions {
                info += "\n\nYou can force eject (may cause data loss)."
            }
            alert.informativeText = info
        } else {
            alert.informativeText =
                "\(blockers.count) process(es) have open files on \(volume.mountPath)."
            alert.accessoryView = makeBlockersAccessory(blockers)
        }

        if offerEjectActions {
            if !blockers.isEmpty {
                alert.addButton(withTitle: "Kill & Eject")
            }
            alert.addButton(withTitle: "Force Eject")
            alert.addButton(withTitle: "Cancel")
        } else {
            if !blockers.isEmpty {
                alert.addButton(withTitle: "Kill Processes")
            }
            alert.addButton(withTitle: "OK")
        }

        NSApp.activate(ignoringOtherApps: true)
        let response = alert.runModal()

        if offerEjectActions {
            if !blockers.isEmpty {
                switch response {
                case .alertFirstButtonReturn:
                    return .killAndEject
                case .alertSecondButtonReturn:
                    return .forceEject
                default:
                    return .dismiss
                }
            } else {
                switch response {
                case .alertFirstButtonReturn:
                    return .forceEject
                default:
                    return .dismiss
                }
            }
        } else if !blockers.isEmpty, response == .alertFirstButtonReturn {
            return .killAndEject
        }

        return .dismiss
    }

    private func makeBlockersAccessory(_ blockers: [ProcessBlocker]) -> NSView {
        let text = blockers.map { blocker in
            var lines = ["\(blocker.processName) (pid \(blocker.pid))"]
            for path in blocker.paths.prefix(3) {
                lines.append("  \(path)")
            }
            return lines.joined(separator: "\n")
        }.joined(separator: "\n\n")

        let scroll = NSScrollView(frame: NSRect(x: 0, y: 0, width: 420, height: 140))
        scroll.hasVerticalScroller = true
        scroll.borderType = .bezelBorder
        scroll.autohidesScrollers = true

        let textView = NSTextView(frame: scroll.bounds)
        textView.string = text
        textView.isEditable = false
        textView.isSelectable = true
        textView.font = NSFont.monospacedSystemFont(ofSize: 11, weight: .regular)
        textView.backgroundColor = NSColor.textBackgroundColor
        textView.textContainerInset = NSSize(width: 6, height: 6)

        scroll.documentView = textView
        return scroll
    }

    private func killBlockersAndRetryEject(volume: Volume, blockers: [ProcessBlocker]) async {
        let pids = blockers.map(\.pid)
        let denied = await ProcessKiller.terminateAll(pids)

        if !denied.isEmpty {
            let names = blockers
                .filter { denied.contains($0.pid) }
                .map { "\($0.processName) (pid \($0.pid))" }
                .joined(separator: "\n")
            presentError(
                title: "Some Processes Need Elevation",
                message:
                    "Couldn’t terminate:\n\(names)\n\nA privileged helper (next phase) is required to kill these. You can still force eject."
            )
        }

        requestEject(volume, force: false)
    }

    private func presentError(title: String, message: String) {
        let alert = NSAlert()
        alert.messageText = title
        alert.informativeText = message
        alert.alertStyle = .warning
        alert.addButton(withTitle: "OK")
        NSApp.activate(ignoringOtherApps: true)
        alert.runModal()
    }

    @objc
    private func quitApp() {
        blockerScanTask?.cancel()
        NSApp.terminate(nil)
    }
}

extension StatusItemController: NSMenuDelegate {
    func menuWillOpen(_ menu: NSMenu) {
        volumeService.rescan()
        rebuildMenu()
    }
}
