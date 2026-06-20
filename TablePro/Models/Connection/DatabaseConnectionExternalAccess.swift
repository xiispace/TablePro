//
//  DatabaseConnectionExternalAccess.swift
//  TablePro
//

import Foundation

extension DatabaseConnection {
    static let persistedExternalAccessFieldKey = "externalAccess"

    var resolvedExternalAccess: ExternalAccessLevel {
        additionalFields[Self.persistedExternalAccessFieldKey]
            .flatMap(ExternalAccessLevel.init(rawValue:))
            ?? externalAccess
    }
}
