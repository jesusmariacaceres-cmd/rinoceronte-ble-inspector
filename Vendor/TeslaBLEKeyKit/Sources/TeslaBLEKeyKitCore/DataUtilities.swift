import CryptoKit
import Foundation
import Security

public enum ByteUtilities {
    public static func randomData(count: Int) throws -> Data {
        var data = Data(count: count)
        let status = data.withUnsafeMutableBytes { buffer in
            SecRandomCopyBytes(kSecRandomDefault, count, buffer.baseAddress!)
        }
        guard status == errSecSuccess else {
            throw TeslaError.crypto("SecRandomCopyBytes failed with status \(status)")
        }
        return data
    }

    public static func randomBytes(count: Int) throws -> [UInt8] {
        Array(try randomData(count: count))
    }
}

public extension Data {
    init(uint32BigEndian value: UInt32) {
        var bigEndian = value.bigEndian
        self = Swift.withUnsafeBytes(of: &bigEndian) { Data($0) }
    }

    mutating func appendUInt32BigEndian(_ value: UInt32) {
        append(Data(uint32BigEndian: value))
    }

    mutating func appendUInt64BigEndian(_ value: UInt64) {
        var bigEndian = value.bigEndian
        append(Swift.withUnsafeBytes(of: &bigEndian) { Data($0) })
    }

    func sha1Digest() -> Data {
        Data(Insecure.SHA1.hash(data: self))
    }

    func sha256Digest() -> Data {
        Data(SHA256.hash(data: self))
    }

    func hmacSHA256(key: Data) -> Data {
        let symmetricKey = SymmetricKey(data: key)
        return Data(HMAC<SHA256>.authenticationCode(for: self, using: symmetricKey))
    }

    func constantTimeEquals(_ other: Data) -> Bool {
        guard count == other.count else { return false }
        var difference: UInt8 = 0
        for (lhs, rhs) in zip(self, other) {
            difference |= lhs ^ rhs
        }
        return difference == 0
    }

    func hexString() -> String {
        map { String(format: "%02x", $0) }.joined()
    }
}

public extension Array where Element == UInt8 {
    mutating func xorInPlace(_ other: [UInt8]) {
        precondition(count == other.count)
        for index in indices {
            self[index] ^= other[index]
        }
    }
}
