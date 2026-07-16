//
//  ProcessBlocker.swift
//  ejectnow
//

import Foundation

struct ProcessBlocker: Identifiable, Hashable, Sendable {
    var id: pid_t { pid }

    let pid: pid_t
    let processName: String
    /// Sample open paths under the volume (cwd, files, etc.).
    let paths: [String]

    var summaryLine: String {
        if let first = paths.first {
            return "\(processName) (pid \(pid)) — \(first)"
        }
        return "\(processName) (pid \(pid))"
    }
}
