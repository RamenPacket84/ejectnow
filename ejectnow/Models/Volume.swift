//
//  Volume.swift
//  ejectnow
//

import Foundation

struct Volume: Identifiable, Hashable, Sendable {
    /// BSD name, e.g. `disk4s1`.
    var id: String { bsdName }

    let bsdName: String
    let name: String
    let mountPath: String
    let isEjectable: Bool
    let isRemovable: Bool
}
