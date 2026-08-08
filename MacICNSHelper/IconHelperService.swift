import AppKit
import Foundation

final class IconHelperService: NSObject, NSXPCListenerDelegate, IconHelperXPCProtocol {
    private let listener = NSXPCListener(machServiceName: "com.guigx.macicns.helper")
    private let clientValidator: ClientValidator

    init(clientValidator: ClientValidator = ClientValidator()) {
        self.clientValidator = clientValidator
        super.init()
        listener.delegate = self
    }

    func run() {
        listener.resume()
    }

    func listener(_ listener: NSXPCListener, shouldAcceptNewConnection connection: NSXPCConnection) -> Bool {
        guard clientValidator.isValid(connection: connection) else {
            return false
        }

        connection.exportedInterface = NSXPCInterface(with: IconHelperXPCProtocol.self)
        connection.setCodeSigningRequirement(ClientValidator.requiredClientRequirement)
        connection.exportedObject = self
        connection.resume()
        return true
    }

    func applyIcon(_ request: IconApplyRequest, withReply reply: @escaping (NSError?) -> Void) {
        do {
            let validatedRequest = try IconApplyRequest(
                applicationURL: request.applicationURL,
                iconURL: request.iconURL
            )
            guard NSXPCConnection.current() != nil else {
                reply(helperError(code: 1, description: "The caller could not be identified."))
                return
            }
            try PrivilegedPathValidator.validate(
                applicationURL: validatedRequest.applicationURL
            )
            let image = try IconDataReader.image(at: validatedRequest.iconURL)

            let succeeded = NSWorkspace.shared.setIcon(
                image,
                forFile: validatedRequest.applicationURL.path,
                options: []
            )
            reply(succeeded ? nil : helperError(code: 3, description: "The icon could not be applied."))
        } catch {
            reply(error as NSError)
        }
    }

    private func helperError(code: Int, description: String) -> NSError {
        NSError(domain: "com.guigx.macicns.helper", code: code, userInfo: [NSLocalizedDescriptionKey: description])
    }
}
