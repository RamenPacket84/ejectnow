//
//  BlockerService.swift
//  ejectnow
//

import Foundation

enum BlockerService {
    /// Finds processes with open files (or cwd) on the given mount path.
    static func findBlockers(on mountPath: String) async throws -> [ProcessBlocker] {
        try await Task.detached(priority: .userInitiated) {
            try runLsof(mountPath: mountPath)
        }.value
    }

    /// Runs off the main actor (called from `Task.detached`).
    nonisolated private static func runLsof(mountPath: String) throws -> [ProcessBlocker] {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/usr/sbin/lsof")
        // `-F pcfn`: machine-readable pid, command, fd, name.
        // Passing the mount path asks lsof for activity on that filesystem.
        process.arguments = ["-F", "pcfn", "--", mountPath]

        let stdout = Pipe()
        let stderr = Pipe()
        process.standardOutput = stdout
        process.standardError = stderr

        try process.run()
        process.waitUntilExit()

        let data = stdout.fileHandleForReading.readDataToEndOfFile()
        // lsof exits 1 when there are no matching processes — treat as empty.
        if process.terminationStatus != 0 && data.isEmpty {
            return []
        }

        let ourPID = ProcessInfo.processInfo.processIdentifier
        return parseLsofFieldOutput(data, excludingPID: ourPID)
    }

    /// Parses `lsof -F pcfn` output into unique blockers.
    nonisolated static func parseLsofFieldOutput(_ data: Data, excludingPID: pid_t) -> [ProcessBlocker] {
        guard let text = String(data: data, encoding: .utf8), !text.isEmpty else {
            return []
        }

        struct Partial {
            var pid: pid_t?
            var command: String?
            var paths: [String] = []
        }

        var current = Partial()
        var byPID: [pid_t: Partial] = [:]

        func commit() {
            guard let pid = current.pid, pid != excludingPID else {
                current = Partial()
                return
            }
            var existing = byPID[pid] ?? Partial(pid: pid, command: current.command, paths: [])
            if existing.command == nil {
                existing.command = current.command
            }
            for path in current.paths where !existing.paths.contains(path) {
                existing.paths.append(path)
            }
            byPID[pid] = existing
            current = Partial()
        }

        for rawLine in text.split(whereSeparator: \.isNewline) {
            let line = String(rawLine)
            guard let tag = line.first else { continue }
            let value = String(line.dropFirst())

            switch tag {
            case "p":
                if current.pid != nil {
                    commit()
                }
                current.pid = pid_t(value)
            case "c":
                current.command = value
            case "n":
                if !value.isEmpty {
                    current.paths.append(value)
                }
            default:
                break
            }
        }
        commit()

        return byPID.keys.sorted().compactMap { pid in
            guard let partial = byPID[pid] else { return nil }
            let name = partial.command?.trimmingCharacters(in: .whitespacesAndNewlines)
            let processName = (name?.isEmpty == false) ? name! : "pid \(pid)"
            // Cap paths shown per process to keep alerts readable.
            let paths = Array(partial.paths.prefix(5))
            return ProcessBlocker(pid: pid, processName: processName, paths: paths)
        }
    }
}
