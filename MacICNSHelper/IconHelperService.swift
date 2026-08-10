import AppKit
import Foundation

final class IconHelperService: NSObject, NSXPCListenerDelegate, IconHelperXPCProtocol {
    private let listener = NSXPCListener(machServiceName: "com.guigx.macicns.helper")
    private let clientValidator: ClientValidator
    private let iconOperation: PrivilegedIconOperation

    init(
        clientValidator: ClientValidator = ClientValidator(),
        iconOperation: PrivilegedIconOperation = PrivilegedIconOperation()
    ) {
        self.clientValidator = clientValidator
        self.iconOperation = iconOperation
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
            let validatedRequest = try request.revalidated()
            guard NSXPCConnection.current() != nil else {
                reply(helperError(code: 1, description: "The caller could not be identified."))
                return
            }
            try iconOperation.apply(request: validatedRequest)
            reply(nil)
        } catch {
            if let writeError = error as? StableApplicationIconWriter.WriteError {
                reply(writeError.xpcError)
            } else {
                reply(error as NSError)
            }
        }
    }

    func resetIcon(_ request: IconResetRequest, withReply reply: @escaping (NSError?) -> Void) {
        do {
            let validatedRequest = try IconResetRequest(applicationURL: request.applicationURL)
            guard NSXPCConnection.current() != nil else {
                reply(helperError(code: 1, description: "The caller could not be identified."))
                return
            }
            try iconOperation.reset(request: validatedRequest)
            reply(nil)
        } catch {
            if let writeError = error as? StableApplicationIconWriter.WriteError {
                reply(writeError.xpcError)
            } else {
                reply(error as NSError)
            }
        }
    }

    private func helperError(code: Int, description: String) -> NSError {
        NSError(domain: "com.guigx.macicns.helper", code: code, userInfo: [NSLocalizedDescriptionKey: description])
    }
}
