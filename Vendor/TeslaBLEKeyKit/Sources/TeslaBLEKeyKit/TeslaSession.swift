import Foundation
import SwiftProtobuf
#if !COCOAPODS
import TeslaBLEKeyKitCore
#endif
#if !COCOAPODS
import TeslaBLEKeyKitCrypto
#endif

final class TeslaSession {
    private static let labelSessionInfo = "session info"
    private static let labelMessageAuth = "authenticated command"
    private static let epochLength: TimeInterval = Double(1 << 30)
    
    private let verifierName: Data
    private let privateKey: TeslaPrivateKey
    private let verifierPublicKey: Data
    private let sessionKey: Data
    private let nonceMode: AESGCMNonceMode
    private var counter: UInt32
    private var epoch: Data
    private var timeZero: Date
    private var setTime: UInt32
    
    init(
        privateKey: TeslaPrivateKey,
        verifierName: Data,
        verifierInfo: Signatures_SessionInfo,
        generatedAt: Date = Date(),
        nonceMode: AESGCMNonceMode
    ) throws {
        guard verifierName.count <= 255 else {
            throw TeslaError.crypto("verifier name is longer than 255 bytes")
        }
        self.privateKey = privateKey
        self.verifierName = verifierName
        self.verifierPublicKey = verifierInfo.publicKey
        self.sessionKey = try privateKey.sharedAESKey(with: verifierInfo.publicKey)
        self.counter = verifierInfo.counter
        self.epoch = verifierInfo.epoch
        self.setTime = verifierInfo.clockTime
        self.timeZero = generatedAt.addingTimeInterval(-TimeInterval(verifierInfo.clockTime))
        self.nonceMode = nonceMode
    }
    
    convenience init(
        privateKey: TeslaPrivateKey,
        verifierName: Data,
        challenge: Data,
        encodedInfo: Data,
        tag: Data,
        nonceMode: AESGCMNonceMode
    ) throws {
        let info = try Signatures_SessionInfo(serializedBytes: encodedInfo)
        try self.init(
            privateKey: privateKey,
            verifierName: verifierName,
            verifierInfo: info,
            nonceMode: nonceMode
        )
        let expected = try sessionInfoHMAC(
            verifierName: verifierName,
            challenge: challenge,
            encodedInfo: encodedInfo
        )
        guard expected.constantTimeEquals(tag) else {
            Log.fault("Session info HMAC verification failed")
            throw TeslaError.crypto("session info HMAC is invalid")
        }
        Log.info("Session created, epoch=\(Log.dataSummary(info.epoch)), counter=\(info.counter)")
    }
    
    func exportSessionInfo() throws -> Data {
        var info = Signatures_SessionInfo()
        info.counter = counter
        info.publicKey = verifierPublicKey
        info.epoch = epoch
        info.clockTime = timestamp()
        return try info.serializedData()
    }
    
    func updateSessionInfo(_ info: Signatures_SessionInfo) throws {
        guard info.publicKey == verifierPublicKey else {
            throw TeslaError.crypto("vehicle public key changed unexpectedly")
        }
        if info.epoch != epoch || setTime <= info.clockTime {
            counter = max(counter, info.counter)
            epoch = info.epoch
            setTime = info.clockTime
            timeZero = Date().addingTimeInterval(-TimeInterval(info.clockTime))
        }
    }
    
    func updateSignedSessionInfo(challenge: Data, encodedInfo: Data, tag: Data) throws {
        let expected = try sessionInfoHMAC(
            verifierName: verifierName,
            challenge: challenge,
            encodedInfo: encodedInfo
        )
        guard expected.constantTimeEquals(tag) else {
            Log.fault("Session info update HMAC verification failed")
            throw TeslaError.crypto("session info HMAC is invalid")
        }
        let info = try Signatures_SessionInfo(serializedBytes: encodedInfo)
        Log.debug("Updating session info, epoch=\(Log.dataSummary(info.epoch)), counter=\(info.counter)")
        try updateSessionInfo(info)
    }
    
    func authorize(
        message: inout UniversalMessage_RoutableMessage,
        method: AuthMethod,
        expiresIn: TimeInterval
    ) throws {
        Log.debug("Authorizing message, method=\(method), counter=\(counter)")
        switch method {
        case .none:
            return
        case .gcm:
            try encrypt(message: &message, expiresIn: expiresIn)
        case .hmac:
            try authorizeHMAC(message: &message, expiresIn: expiresIn)
        }
    }
    
    func decrypt(
        message: inout UniversalMessage_RoutableMessage,
        requestID: Data
    ) throws -> UInt32 {
        guard case .aesGcmResponseData(let gcmInfo)? = message.signatureData.sigType else {
            throw TeslaError.crypto("missing AES-GCM response data")
        }
        Log.debug("Decrypting response, counter=\(gcmInfo.counter)")
        let authenticatedData = try responseMetadata(
            message: message,
            requestID: requestID,
            counter: gcmInfo.counter
        )
        let gcm = try VariableNonceAESGCM(key: sessionKey)
        let plaintext = try gcm.open(
            AESGCMSealedBox(
                nonce: gcmInfo.nonce,
                ciphertext: message.protobufMessageAsBytes,
                tag: gcmInfo.tag
            ),
            authenticatedData: authenticatedData
        )
        message.protobufMessageAsBytes = plaintext
        message.subSigData = nil
        return gcmInfo.counter
    }
    
    func requestID(for message: UniversalMessage_RoutableMessage) -> Data? {
        switch message.signatureData.sigType {
        case .aesGcmPersonalizedData(let data):
            return Data([UInt8(Signatures_SignatureType.aesGcmPersonalized.rawValue)]) + data.tag
        case .hmacPersonalizedData(let data):
            var tag = data.tag
            if message.toDestination.domain == .vehicleSecurity, tag.count > 16 {
                tag = Data(tag.prefix(16))
            }
            return Data([UInt8(Signatures_SignatureType.hmacPersonalized.rawValue)]) + tag
        default:
            return nil
        }
    }
    
    private func encrypt(
        message: inout UniversalMessage_RoutableMessage,
        expiresIn: TimeInterval
    ) throws {
        guard counter < UInt32.max else {
            throw TeslaError.crypto("session counter rolled over")
        }
        counter += 1
        
        var gcmData = Signatures_AES_GCM_Personalized_Signature_Data()
        gcmData.epoch = epoch
        gcmData.counter = counter
        gcmData.expiresAt = expirationTimestamp(expiresIn: expiresIn)
        
        var signature = Signatures_SignatureData()
        signature.signerIdentity.publicKey = privateKey.publicKey
        signature.aesGcmPersonalizedData = gcmData
        message.signatureData = signature
        
        let authenticatedData = try metadata(
            for: message,
            info: SessionMessageInfo(
                counter: gcmData.counter,
                epoch: gcmData.epoch,
                expiresAt: gcmData.expiresAt
            ),
            signatureType: .aesGcmPersonalized
        ).checksum()
        
        let gcm = try VariableNonceAESGCM(key: sessionKey)
        let sealed = try gcm.seal(
            plaintext: message.protobufMessageAsBytes,
            authenticatedData: authenticatedData,
            nonceMode: nonceMode
        )
        gcmData.nonce = sealed.nonce
        gcmData.tag = sealed.tag
        signature.aesGcmPersonalizedData = gcmData
        message.signatureData = signature
        message.protobufMessageAsBytes = sealed.ciphertext
    }
    
    private func authorizeHMAC(
        message: inout UniversalMessage_RoutableMessage,
        expiresIn: TimeInterval
    ) throws {
        counter += 1
        var hmacData = Signatures_HMAC_Personalized_Signature_Data()
        hmacData.epoch = epoch
        hmacData.counter = counter
        hmacData.expiresAt = expirationTimestamp(expiresIn: expiresIn)
        
        var signature = Signatures_SignatureData()
        signature.signerIdentity.publicKey = privateKey.publicKey
        signature.hmacPersonalizedData = hmacData
        message.signatureData = signature
        
        let meta = try metadata(
            for: message,
            info: SessionMessageInfo(
                counter: hmacData.counter,
                epoch: hmacData.epoch,
                expiresAt: hmacData.expiresAt
            ),
            signatureType: .hmacPersonalized,
            context: .hmacSHA256(key: subkey(label: Self.labelMessageAuth))
        )
        hmacData.tag = meta.checksum(message: message.protobufMessageAsBytes)
        signature.hmacPersonalizedData = hmacData
        message.signatureData = signature
    }
    
    private func metadata(
        for message: UniversalMessage_RoutableMessage,
        info: SessionMessageInfo,
        signatureType: Signatures_SignatureType,
        context: MetadataBuilder.Context = .sha256
    ) throws -> MetadataBuilder {
        var meta = MetadataBuilder(context: context)
        try meta.add(.signatureType, value: Data([UInt8(signatureType.rawValue)]))
        
        let domain = message.toDestination.domain
        guard domain.rawValue >= 0 && domain.rawValue <= 255 else {
            throw TeslaError.malformedResponse("domain is out of range")
        }
        try meta.add(.domain, value: Data([UInt8(domain.rawValue)]))
        try meta.add(.personalization, value: verifierName)
        try meta.add(.epoch, value: info.epoch)
        try meta.addUInt32(.expiresAt, value: info.expiresAt)
        try meta.addUInt32(.counter, value: info.counter)
        if message.flags > 0 {
            try meta.addUInt32(.flags, value: message.flags)
        }
        return meta
    }
    
    private func responseMetadata(
        message: UniversalMessage_RoutableMessage,
        requestID: Data,
        counter: UInt32
    ) throws -> Data {
        var meta = MetadataBuilder()
        try meta.add(.signatureType, value: Data([UInt8(Signatures_SignatureType.aesGcmResponse.rawValue)]))
        
        let domain = message.fromDestination.domain
        guard domain.rawValue >= 0 && domain.rawValue <= 255 else {
            throw TeslaError.malformedResponse("response domain is out of range")
        }
        try meta.add(.domain, value: Data([UInt8(domain.rawValue)]))
        try meta.add(.personalization, value: verifierName)
        try meta.addUInt32(.counter, value: counter)
        try meta.addUInt32(.flags, value: message.flags)
        try meta.add(.requestHash, value: requestID)
        try meta.addUInt32(.fault, value: UInt32(message.signedMessageStatus.signedMessageFault.rawValue))
        return meta.checksum()
    }
    
    private func sessionInfoHMAC(
        verifierName: Data,
        challenge: Data,
        encodedInfo: Data
    ) throws -> Data {
        var meta = MetadataBuilder(context: .hmacSHA256(key: subkey(label: Self.labelSessionInfo)))
        try meta.add(.signatureType, value: Data([UInt8(Signatures_SignatureType.hmac.rawValue)]))
        try meta.add(.personalization, value: verifierName)
        try meta.add(.challenge, value: challenge)
        return meta.checksum(message: encodedInfo)
    }
    
    private func subkey(label: String) -> Data {
        Data(label.utf8).hmacSHA256(key: sessionKey)
    }
    
    private func timestamp() -> UInt32 {
        UInt32(max(0, Date().timeIntervalSince(timeZero)))
    }
    
    private func expirationTimestamp(expiresIn: TimeInterval) -> UInt32 {
        let bounded = min(max(0, expiresIn), Self.epochLength)
        return UInt32(max(0, Date().addingTimeInterval(bounded).timeIntervalSince(timeZero)))
    }
}

private struct SessionMessageInfo {
    let counter: UInt32
    let epoch: Data
    let expiresAt: UInt32
}

final class DomainSessionState {
    private let lock = NSLock()
    private let privateKey: TeslaPrivateKey
    private let verifierName: Data
    private let nonceMode: AESGCMNonceMode
    private var session: TeslaSession?
    private var readyContinuations: [CheckedContinuation<Void, Error>] = []
    
    init(privateKey: TeslaPrivateKey, vin: String, nonceMode: AESGCMNonceMode) {
        self.privateKey = privateKey
        self.verifierName = Data(vin.utf8)
        self.nonceMode = nonceMode
    }
    
    var isReady: Bool {
        lock.withLock { session != nil }
    }
    
    func waitUntilReady() async throws {
        if isReady { return }
        try await withCheckedThrowingContinuation { continuation in
            lock.lock()
            if session != nil {
                lock.unlock()
                continuation.resume()
            } else {
                readyContinuations.append(continuation)
                lock.unlock()
            }
        }
    }
    
    func processHello(challenge: Data, encodedInfo: Data, tag: Data) throws {
        var continuations: [CheckedContinuation<Void, Error>] = []
        try lock.withLock {
            if let session {
                try session.updateSignedSessionInfo(challenge: challenge, encodedInfo: encodedInfo, tag: tag)
            } else {
                session = try TeslaSession(
                    privateKey: privateKey,
                    verifierName: verifierName,
                    challenge: challenge,
                    encodedInfo: encodedInfo,
                    tag: tag,
                    nonceMode: nonceMode
                )
                Log.info("Domain session initialized, \(readyContinuations.count) waiter(s) resumed")
                continuations = readyContinuations
                readyContinuations.removeAll()
            }
        }
        for continuation in continuations {
            continuation.resume()
        }
    }
    
    func authorize(
        message: inout UniversalMessage_RoutableMessage,
        method: AuthMethod,
        expiresIn: TimeInterval
    ) throws {
        guard let session = lock.withLock({ session }) else {
            throw TeslaError.noSession(message.toDestination.domain)
        }
        try session.authorize(message: &message, method: method, expiresIn: expiresIn)
    }
    
    func decrypt(message: inout UniversalMessage_RoutableMessage, requestID: Data) throws -> UInt32 {
        guard let session = lock.withLock({ session }) else {
            throw TeslaError.noSession(message.fromDestination.domain)
        }
        return try session.decrypt(message: &message, requestID: requestID)
    }
    
    func requestID(for message: UniversalMessage_RoutableMessage) -> Data? {
        lock.withLock { session?.requestID(for: message) }
    }
}

extension NSLock {
    @discardableResult
    func withLock<T>(_ body: () throws -> T) rethrows -> T {
        lock()
        defer { unlock() }
        return try body()
    }
}
