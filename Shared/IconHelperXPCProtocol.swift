import Foundation

@objc protocol IconHelperXPCProtocol {
    func applyIcon(_ request: IconApplyRequest, withReply reply: @escaping (NSError?) -> Void)
    func resetIcon(_ request: IconResetRequest, withReply reply: @escaping (NSError?) -> Void)
}
