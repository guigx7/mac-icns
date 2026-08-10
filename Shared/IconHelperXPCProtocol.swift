import Foundation

enum HelperProtocolVersion {
    static let current = 2
}

@objc protocol IconHelperXPCProtocol {
    func protocolVersion(withReply reply: @escaping (Int) -> Void)
    func applyIcon(_ request: IconApplyRequest, withReply reply: @escaping (NSError?) -> Void)
    func resetIcon(_ request: IconResetRequest, withReply reply: @escaping (NSError?) -> Void)
}
