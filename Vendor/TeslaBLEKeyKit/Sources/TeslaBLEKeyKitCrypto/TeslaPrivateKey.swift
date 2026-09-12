import CryptoKit
import Foundation
#if !COCOAPODS
import TeslaBLEKeyKitCore
#endif

public struct TeslaPrivateKey: Sendable {
    private let key: P256.KeyAgreement.PrivateKey
    
    public init(rawRepresentation: Data) throws {
        self.key = try P256.KeyAgreement.PrivateKey(rawRepresentation: rawRepresentation)
    }
    
    public init(pemRepresentation: String) throws {
        self.key = try P256.KeyAgreement.PrivateKey(pemRepresentation: pemRepresentation)
    }
    
    public init(derRepresentation: Data) throws {
        self.key = try P256.KeyAgreement.PrivateKey(derRepresentation: derRepresentation)
    }
    
    private init(_ key: P256.KeyAgreement.PrivateKey) {
        self.key = key
    }
    
    public static func generate() -> TeslaPrivateKey {
        TeslaPrivateKey(P256.KeyAgreement.PrivateKey())
    }
    
    public var rawRepresentation: Data {
        key.rawRepresentation
    }
    
    public var derRepresentation: Data {
        key.derRepresentation
    }
    
    public var pemRepresentation: String {
        key.pemRepresentation
    }
    
    public var publicKey: Data {
        key.publicKey.x963Representation
    }
    
    public func sharedAESKey(with remotePublicKey: Data) throws -> Data {
        let remote = try P256.KeyAgreement.PublicKey(x963Representation: remotePublicKey)
        let shared = try key.sharedSecretFromKeyAgreement(with: remote)
        let sharedSecret = shared.withUnsafeBytes { rawBuffer in
            Data(rawBuffer)
        }
        return Data(sharedSecret.sha1Digest().prefix(16))
    }
}
