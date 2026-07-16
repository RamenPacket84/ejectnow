//
//  VolumeService.swift
//  ejectnow
//

import AppKit
import Darwin
import DiskArbitration
import Foundation

enum EjectOutcome: Sendable {
    case succeeded
    case busy(statusMessage: String)
    case failed(statusMessage: String)
}

@MainActor
final class VolumeService: NSObject {
    private(set) var volumes: [Volume] = [] {
        didSet {
            guard volumes != oldValue else { return }
            onVolumesChanged?(volumes)
        }
    }

    var onVolumesChanged: (([Volume]) -> Void)?

    private let session: DASession
    private var disksByBSDName: [String: DADisk] = [:]

    static func make() -> VolumeService? {
        guard let session = DASessionCreate(kCFAllocatorDefault) else {
            NSLog("EjectNow: DASessionCreate failed")
            return nil
        }
        return VolumeService(session: session)
    }

    private init(session: DASession) {
        self.session = session
        super.init()

        DASessionScheduleWithRunLoop(
            session,
            CFRunLoopGetMain(),
            CFRunLoopMode.defaultMode.rawValue as CFString
        )

        let context = Unmanaged.passUnretained(self).toOpaque()

        DARegisterDiskAppearedCallback(session, nil, diskAppeared, context)
        DARegisterDiskDisappearedCallback(session, nil, diskDisappeared, context)
        DARegisterDiskDescriptionChangedCallback(
            session,
            nil,
            [
                kDADiskDescriptionVolumePathKey,
                kDADiskDescriptionVolumeNameKey,
            ] as CFArray,
            diskDescriptionChanged,
            context
        )

        NotificationCenter.default.addObserver(
            self,
            selector: #selector(handleVolumesNeedRescan(_:)),
            name: .ejectNowVolumesNeedRescan,
            object: nil
        )

        rescan()
    }

    deinit {
        NotificationCenter.default.removeObserver(self)
        DASessionUnscheduleFromRunLoop(
            session,
            CFRunLoopGetMain(),
            CFRunLoopMode.defaultMode.rawValue as CFString
        )
    }

    @objc
    private func handleVolumesNeedRescan(_ notification: Notification) {
        rescan()
    }

    func rescan() {
        let urls = FileManager.default.mountedVolumeURLs(
            includingResourceValuesForKeys: [
                .volumeNameKey,
                .volumeIsRemovableKey,
                .volumeIsEjectableKey,
                .volumeIsInternalKey,
                .volumeIsRootFileSystemKey,
            ],
            options: [.skipHiddenVolumes]
        ) ?? []

        var nextVolumes: [Volume] = []
        var nextDisks: [String: DADisk] = [:]

        for url in urls {
            guard let disk = DADiskCreateFromVolumePath(
                kCFAllocatorDefault,
                session,
                url as CFURL
            ) else {
                continue
            }

            guard let volume = Self.makeVolume(from: disk, fallbackPath: url.path) else {
                continue
            }

            nextVolumes.append(volume)
            nextDisks[volume.bsdName] = disk
        }

        nextVolumes.sort {
            $0.name.localizedCaseInsensitiveCompare($1.name) == .orderedAscending
        }

        disksByBSDName = nextDisks
        volumes = nextVolumes
    }

    func eject(volume: Volume, force: Bool, completion: @escaping @MainActor @Sendable (EjectOutcome) -> Void) {
        if disksByBSDName[volume.bsdName] == nil {
            rescan()
        }

        guard let disk = disksByBSDName[volume.bsdName] else {
            completion(.failed(statusMessage: "Volume is no longer available."))
            return
        }

        let options: DADiskUnmountOptions = force
            ? DADiskUnmountOptions(kDADiskUnmountOptionForce)
            : DADiskUnmountOptions(kDADiskUnmountOptionDefault)

        let continuation = Unmanaged.passRetained(
            EjectContinuation(volume: volume, completion: completion)
        )
        DADiskUnmount(disk, options, unmountCompleted, continuation.toOpaque())
    }

    fileprivate func handleDiskEvent() {
        rescan()
    }

    nonisolated static func outcome(from dissenter: DADissenter) -> EjectOutcome {
        let status = DADissenterGetStatus(dissenter)
        let message = (DADissenterGetStatusString(dissenter) as String?)?
            .trimmingCharacters(in: .whitespacesAndNewlines)
        let resolved = (message?.isEmpty == false)
            ? message!
            : "Disk Arbitration error \(status)."

        if isBusyStatus(status) {
            return .busy(statusMessage: resolved)
        }
        return .failed(statusMessage: resolved)
    }

    nonisolated private static func isBusyStatus(_ status: DAReturn) -> Bool {
        if status == DAReturn(kDAReturnBusy) {
            return true
        }
        // Some paths surface raw UNIX EBUSY.
        return (status & 0xff) == DAReturn(EBUSY)
    }

    private static func makeVolume(from disk: DADisk, fallbackPath: String) -> Volume? {
        guard let raw = DADiskCopyDescription(disk) as NSDictionary? else {
            return nil
        }

        if raw[kDADiskDescriptionVolumeNetworkKey] as? Bool == true {
            return nil
        }

        let mountPath: String
        if let pathURL = raw[kDADiskDescriptionVolumePathKey] as? URL {
            mountPath = pathURL.path
        } else if let pathURL = raw[kDADiskDescriptionVolumePathKey] as? NSURL {
            mountPath = pathURL.path ?? fallbackPath
        } else {
            mountPath = fallbackPath
        }

        guard !mountPath.isEmpty, mountPath != "/" else {
            return nil
        }

        if let isRoot = try? URL(fileURLWithPath: mountPath)
            .resourceValues(forKeys: [.volumeIsRootFileSystemKey])
            .volumeIsRootFileSystem,
           isRoot {
            return nil
        }

        let isRemovable = raw[kDADiskDescriptionMediaRemovableKey] as? Bool ?? false
        let isEjectable = raw[kDADiskDescriptionMediaEjectableKey] as? Bool ?? false
        let underVolumes = mountPath.hasPrefix("/Volumes/")

        guard isRemovable || isEjectable || underVolumes else {
            return nil
        }

        let bsdName: String
        if let name = raw[kDADiskDescriptionMediaBSDNameKey] as? String {
            bsdName = name
        } else if let cName = DADiskGetBSDName(disk) {
            bsdName = String(cString: cName)
        } else {
            return nil
        }

        let name = (raw[kDADiskDescriptionVolumeNameKey] as? String)?
            .trimmingCharacters(in: .whitespacesAndNewlines)
        let displayName = (name?.isEmpty == false)
            ? name!
            : URL(fileURLWithPath: mountPath).lastPathComponent

        return Volume(
            bsdName: bsdName,
            name: displayName,
            mountPath: mountPath,
            isEjectable: isEjectable,
            isRemovable: isRemovable
        )
    }
}

// MARK: - Continuations & C callbacks
// Callbacks must be `nonisolated` so they can be passed as C function pointers
// (SWIFT_DEFAULT_ACTOR_ISOLATION = MainActor would otherwise isolate them).

private final class EjectContinuation: NSObject, Sendable {
    let volume: Volume
    let completion: @MainActor @Sendable (EjectOutcome) -> Void

    init(volume: Volume, completion: @escaping @MainActor @Sendable (EjectOutcome) -> Void) {
        self.volume = volume
        self.completion = completion
    }
}

private nonisolated func hopToVolumeService(
    _ context: UnsafeMutableRawPointer?,
    _ body: @MainActor @escaping @Sendable (VolumeService) -> Void
) {
    guard let context else { return }
    // Raw pointers are not Sendable; pass an integer bit pattern across the Task boundary.
    let bitPattern = UInt(bitPattern: context)
    Task { @MainActor in
        guard let pointer = UnsafeMutableRawPointer(bitPattern: bitPattern) else { return }
        body(Unmanaged<VolumeService>.fromOpaque(pointer).takeUnretainedValue())
    }
}

private nonisolated func diskAppeared(
    disk: DADisk?,
    context: UnsafeMutableRawPointer?
) {
    hopToVolumeService(context) { service in
        service.handleDiskEvent()
    }
}

private nonisolated func diskDisappeared(
    disk: DADisk?,
    context: UnsafeMutableRawPointer?
) {
    hopToVolumeService(context) { service in
        service.handleDiskEvent()
    }
}

private nonisolated func diskDescriptionChanged(
    disk: DADisk?,
    keys: CFArray?,
    context: UnsafeMutableRawPointer?
) {
    hopToVolumeService(context) { service in
        service.handleDiskEvent()
    }
}

private nonisolated func unmountCompleted(
    disk: DADisk?,
    dissenter: DADissenter?,
    context: UnsafeMutableRawPointer?
) {
    guard let context else { return }
    let continuation = Unmanaged<EjectContinuation>.fromOpaque(context).takeRetainedValue()

    Task { @MainActor in
        if let dissenter {
            continuation.completion(VolumeService.outcome(from: dissenter))
            return
        }

        guard let disk else {
            NotificationCenter.default.post(name: .ejectNowVolumesNeedRescan, object: nil)
            continuation.completion(.succeeded)
            return
        }

        let description = DADiskCopyDescription(disk) as NSDictionary?
        let mediaEjectable = description?[kDADiskDescriptionMediaEjectableKey] as? Bool ?? false
        let shouldEject = continuation.volume.isEjectable || mediaEjectable

        guard shouldEject else {
            NotificationCenter.default.post(name: .ejectNowVolumesNeedRescan, object: nil)
            continuation.completion(.succeeded)
            return
        }

        let wholeDisk = DADiskCopyWholeDisk(disk) ?? disk
        let retained = Unmanaged.passRetained(
            EjectContinuation(volume: continuation.volume, completion: continuation.completion)
        )
        DADiskEject(
            wholeDisk,
            DADiskEjectOptions(kDADiskEjectOptionDefault),
            ejectCompleted,
            retained.toOpaque()
        )
    }
}

private nonisolated func ejectCompleted(
    disk: DADisk?,
    dissenter: DADissenter?,
    context: UnsafeMutableRawPointer?
) {
    guard let context else { return }
    let continuation = Unmanaged<EjectContinuation>.fromOpaque(context).takeRetainedValue()

    Task { @MainActor in
        if let dissenter {
            continuation.completion(VolumeService.outcome(from: dissenter))
        } else {
            NotificationCenter.default.post(name: .ejectNowVolumesNeedRescan, object: nil)
            continuation.completion(.succeeded)
        }
    }
}

extension Notification.Name {
    static let ejectNowVolumesNeedRescan = Notification.Name("EjectNowVolumesNeedRescan")
}
