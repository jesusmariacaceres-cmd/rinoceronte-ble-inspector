import Foundation
#if !COCOAPODS
import TeslaBLEKeyKitCore
#endif

public enum AESGCMNonceMode: Sendable, Equatable {
    /// Current Tesla vehicle-command documentation and Go implementation use a random 12-byte nonce.
    case standard12Byte
    
    /// Compatibility mode for protocol variants that carry a 4-byte nonce.
    case teslaBLE4Byte
    
    /// Custom nonce length for tests or future protocol variants.
    case custom(Int)
    
    public var length: Int {
        switch self {
        case .standard12Byte:
            return 12
        case .teslaBLE4Byte:
            return 4
        case .custom(let count):
            return count
        }
    }
}

public struct AESGCMSealedBox: Sendable, Equatable {
    public let nonce: Data
    public let ciphertext: Data
    public let tag: Data
    
    public init(nonce: Data, ciphertext: Data, tag: Data) {
        self.nonce = nonce
        self.ciphertext = ciphertext
        self.tag = tag
    }
}

/// AES-GCM implementation that accepts arbitrary nonce lengths, including 4 bytes.
///
/// CryptoKit is still used elsewhere for P-256, SHA, and HMAC primitives. The AES block
/// function and GCM composition are implemented here because platform AES-GCM convenience APIs
/// commonly assume a 12-byte nonce.
public struct VariableNonceAESGCM: Sendable {
    public static let tagLength = 16
    
    private let aes: AES128
    private let hashSubkey: [UInt8]
    
    public init(key: Data) throws {
        self.aes = try AES128(key: key)
        self.hashSubkey = try aes.encryptBlock(Array(repeating: 0, count: 16))
    }
    
    public func seal(
        plaintext: Data,
        authenticatedData: Data = Data(),
        nonceMode: AESGCMNonceMode = .standard12Byte
    ) throws -> AESGCMSealedBox {
        let nonce = try ByteUtilities.randomData(count: nonceMode.length)
        return try seal(plaintext: plaintext, authenticatedData: authenticatedData, nonce: nonce)
    }
    
    public func seal(
        plaintext: Data,
        authenticatedData: Data = Data(),
        nonce: Data
    ) throws -> AESGCMSealedBox {
        guard !nonce.isEmpty else {
            throw TeslaError.crypto("AES-GCM nonce must not be empty")
        }
        let j0 = try initialCounterBlock(nonce: nonce)
        let ciphertext = try crypt(input: plaintext, initialCounter: increment32(j0))
        let authentication = ghash(authenticatedData: authenticatedData, ciphertext: ciphertext)
        let encryptedJ0 = try aes.encryptBlock(j0)
        let tag = Data(zip(encryptedJ0, authentication).map { $0 ^ $1 })
        return AESGCMSealedBox(nonce: nonce, ciphertext: ciphertext, tag: tag)
    }
    
    public func open(
        _ sealedBox: AESGCMSealedBox,
        authenticatedData: Data = Data()
    ) throws -> Data {
        guard sealedBox.tag.count == Self.tagLength else {
            throw TeslaError.crypto("AES-GCM tag must be 16 bytes")
        }
        let j0 = try initialCounterBlock(nonce: sealedBox.nonce)
        let authentication = ghash(authenticatedData: authenticatedData, ciphertext: sealedBox.ciphertext)
        let encryptedJ0 = try aes.encryptBlock(j0)
        let expectedTag = Data(zip(encryptedJ0, authentication).map { $0 ^ $1 })
        guard expectedTag.constantTimeEquals(sealedBox.tag) else {
            throw TeslaError.crypto("AES-GCM authentication failed")
        }
        return try crypt(input: sealedBox.ciphertext, initialCounter: increment32(j0))
    }
    
    private func initialCounterBlock(nonce: Data) throws -> [UInt8] {
        if nonce.count == 12 {
            return Array(nonce) + [0, 0, 0, 1]
        }
        return ghash(authenticatedData: Data(), ciphertext: nonce)
    }
    
    private func crypt(input: Data, initialCounter: [UInt8]) throws -> Data {
        var counter = initialCounter
        var output = Data(capacity: input.count)
        var offset = 0
        
        while offset < input.count {
            let keyStream = try aes.encryptBlock(counter)
            let remaining = min(16, input.count - offset)
            for index in 0..<remaining {
                output.append(input[input.index(input.startIndex, offsetBy: offset + index)] ^ keyStream[index])
            }
            counter = increment32(counter)
            offset += remaining
        }
        return output
    }
    
    private func ghash(authenticatedData: Data, ciphertext: Data) -> [UInt8] {
        var y = Array(repeating: UInt8(0), count: 16)
        
        for block in blocks(from: authenticatedData) {
            y.xorInPlace(block)
            y = multiply(y, hashSubkey)
        }
        for block in blocks(from: ciphertext) {
            y.xorInPlace(block)
            y = multiply(y, hashSubkey)
        }
        
        var lengthBlock = [UInt8]()
        lengthBlock.reserveCapacity(16)
        let aadBits = UInt64(authenticatedData.count) * 8
        let ciphertextBits = UInt64(ciphertext.count) * 8
        lengthBlock.append(contentsOf: aadBits.bigEndianBytes)
        lengthBlock.append(contentsOf: ciphertextBits.bigEndianBytes)
        y.xorInPlace(lengthBlock)
        return multiply(y, hashSubkey)
    }
    
    private func blocks(from data: Data) -> [[UInt8]] {
        guard !data.isEmpty else { return [] }
        var blocks: [[UInt8]] = []
        var offset = 0
        while offset < data.count {
            let end = min(offset + 16, data.count)
            var block = Array(data[data.index(data.startIndex, offsetBy: offset)..<data.index(data.startIndex, offsetBy: end)])
            if block.count < 16 {
                block.append(contentsOf: repeatElement(UInt8(0), count: 16 - block.count))
            }
            blocks.append(block)
            offset += 16
        }
        return blocks
    }
    
    private func multiply(_ x: [UInt8], _ y: [UInt8]) -> [UInt8] {
        var z = Array(repeating: UInt8(0), count: 16)
        var v = y
        
        for bitIndex in 0..<128 {
            if bit(in: x, at: bitIndex) == 1 {
                z.xorInPlace(v)
            }
            let lsb = v[15] & 1
            shiftRightOne(&v)
            if lsb == 1 {
                v[0] ^= 0xe1
            }
        }
        return z
    }
    
    private func bit(in bytes: [UInt8], at index: Int) -> UInt8 {
        let byte = bytes[index / 8]
        let shift = 7 - (index % 8)
        return (byte >> UInt8(shift)) & 1
    }
    
    private func shiftRightOne(_ bytes: inout [UInt8]) {
        var carry: UInt8 = 0
        for index in 0..<bytes.count {
            let nextCarry = bytes[index] & 1
            bytes[index] = (bytes[index] >> 1) | (carry << 7)
            carry = nextCarry
        }
    }
    
    private func increment32(_ block: [UInt8]) -> [UInt8] {
        var result = block
        var value = UInt32(result[12]) << 24
        | UInt32(result[13]) << 16
        | UInt32(result[14]) << 8
        | UInt32(result[15])
        value &+= 1
        result[12] = UInt8((value >> 24) & 0xff)
        result[13] = UInt8((value >> 16) & 0xff)
        result[14] = UInt8((value >> 8) & 0xff)
        result[15] = UInt8(value & 0xff)
        return result
    }
}

private extension UInt64 {
    var bigEndianBytes: [UInt8] {
        [
            UInt8((self >> 56) & 0xff),
            UInt8((self >> 48) & 0xff),
            UInt8((self >> 40) & 0xff),
            UInt8((self >> 32) & 0xff),
            UInt8((self >> 24) & 0xff),
            UInt8((self >> 16) & 0xff),
            UInt8((self >> 8) & 0xff),
            UInt8(self & 0xff),
        ]
    }
}
