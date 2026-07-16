//
//  ProcessKiller.swift
//  ejectnow
//

import Darwin
import Foundation

enum KillOutcome: Sendable, Equatable {
    case terminated
    case alreadyGone
    case permissionDenied
    case failed(errno: Int32)
}

enum ProcessKiller {
    /// Sends SIGTERM (or SIGKILL when `force` is true) to a process.
    @discardableResult
    static func terminate(pid: pid_t, force: Bool) -> KillOutcome {
        let signal = force ? SIGKILL : SIGTERM
        if kill(pid, signal) == 0 {
            return .terminated
        }
        let err = errno
        switch err {
        case ESRCH:
            return .alreadyGone
        case EPERM:
            return .permissionDenied
        default:
            return .failed(errno: err)
        }
    }

    /// SIGTERM all, brief wait, SIGKILL survivors. Returns PIDs that still need elevation (EPERM).
    static func terminateAll(_ pids: [pid_t], waitNanoseconds: UInt64 = 600_000_000) async -> [pid_t] {
        var permissionDenied: [pid_t] = []

        for pid in pids {
            switch terminate(pid: pid, force: false) {
            case .permissionDenied:
                permissionDenied.append(pid)
            case .terminated, .alreadyGone, .failed:
                break
            }
        }

        try? await Task.sleep(nanoseconds: waitNanoseconds)

        for pid in pids where !permissionDenied.contains(pid) {
            if isAlive(pid) {
                switch terminate(pid: pid, force: true) {
                case .permissionDenied:
                    permissionDenied.append(pid)
                case .terminated, .alreadyGone, .failed:
                    break
                }
            }
        }

        try? await Task.sleep(nanoseconds: 200_000_000)
        return permissionDenied
    }

    static func isAlive(_ pid: pid_t) -> Bool {
        if kill(pid, 0) == 0 {
            return true
        }
        // EPERM means the process exists but we lack permission to signal it.
        return errno != ESRCH
    }
}
