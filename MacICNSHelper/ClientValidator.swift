import Foundation
import Security

struct ClientValidator {
    static let requiredClientRequirement = "identifier \"com.guigx.macicns\" and anchor apple generic"

    func isValid(connection: NSXPCConnection) -> Bool {
        // NSXPCConnection exposes the kernel-provided peer PID publicly; unlike raw XPC,
        // it does not expose the peer audit token. SecCode resolves that peer directly and
        // validates its signature against the application's designated requirement.
        let attributes = [kSecGuestAttributePid: NSNumber(value: connection.processIdentifier)] as CFDictionary
        var clientCode: SecCode?

        guard SecCodeCopyGuestWithAttributes(nil, attributes, [], &clientCode) == errSecSuccess,
              let clientCode
        else {
            return false
        }

        var requirement: SecRequirement?
        guard SecRequirementCreateWithString(Self.requiredClientRequirement as CFString, [], &requirement) == errSecSuccess,
              let requirement
        else {
            return false
        }

        return SecCodeCheckValidity(clientCode, [], requirement) == errSecSuccess
    }
}
