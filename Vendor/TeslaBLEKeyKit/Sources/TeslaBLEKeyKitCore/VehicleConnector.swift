import Foundation

public protocol VehicleConnector: AnyObject {
    var vin: String { get set }
    var localName: String { get }
    var retryInterval: TimeInterval { get }
    var allowedLatency: TimeInterval { get }
    var preferredAuthMethod: ConnectorAuthMethod { get }

    func receiveMessages() -> AsyncStream<Data>
    func send(_ message: Data) async throws
    func close()
}

public enum ConnectorAuthMethod: Sendable, Equatable {
    case none
    case aesGCM
    case hmacSHA256
}

extension ConnectorAuthMethod {
    public var internalAuthMethod: AuthMethod {
        switch self {
        case .none:
            return .none
        case .aesGCM:
            return .gcm
        case .hmacSHA256:
            return .hmac
        }
    }
}
