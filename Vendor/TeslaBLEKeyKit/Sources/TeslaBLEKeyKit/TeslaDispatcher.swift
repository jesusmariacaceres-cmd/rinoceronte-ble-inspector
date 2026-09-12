import Foundation
import SwiftProtobuf
#if !COCOAPODS
import TeslaBLEKeyKitCore
#endif
#if !COCOAPODS
import TeslaBLEKeyKitCrypto
#endif

final class TeslaDispatcher {
    private static let addressLength = 16
    private static let uuidLength = 16
    private static let defaultExpiration: TimeInterval = 5
    
    private let connector: VehicleConnector
    private let privateKey: TeslaPrivateKey?
    private let nonceMode: AESGCMNonceMode
    private let address: Data
    
    private let lock = NSLock()
    private var listenTask: Task<Void, Never>?
    private var sessions: [TeslaDomain: DomainSessionState] = [:]
    private var handlers: [ReceiverKey: ResponseReceiver] = [:]
    
    init(
        connector: VehicleConnector,
        privateKey: TeslaPrivateKey?,
        nonceMode: AESGCMNonceMode
    ) throws {
        self.connector = connector
        self.privateKey = privateKey
        self.nonceMode = nonceMode
        self.address = try ByteUtilities.randomData(count: Self.addressLength)
    }
    
    func start() {
        lock.withLock {
            guard listenTask == nil else { return }
            Log.info("Dispatcher started")
            listenTask = Task { [weak self] in
                await self?.listen()
            }
        }
    }

    func stop() {
        let task = lock.withLock { () -> Task<Void, Never>? in
            let task = listenTask
            listenTask = nil
            return task
        }
        task?.cancel()
        Log.info("Dispatcher stopped")
    }
    
    func startSession(domain: TeslaDomain, timeout: TimeInterval) async throws {
        guard let privateKey else {
            throw TeslaError.missingPrivateKey
        }
        let session = sessionState(for: domain, privateKey: privateKey)
        if session.isReady {
            Log.debug("Session already ready for domain \(domain)")
            return
        }

        let receiver = try await requestSessionInfo(domain: domain, publicKey: privateKey.publicKey)
        defer { receiver.close() }
        let message = try await receiver.messages().firstValue(timeout: timeout)
        if let error = protocolError(from: message) { throw error }
        guard session.isReady else {
            throw TeslaError.malformedResponse("Session response was not authenticated")
        }
    }
    
    func send(
        _ message: UniversalMessage_RoutableMessage,
        auth: AuthMethod,
        timeout: TimeInterval
    ) async throws -> ResponseReceiver {
        guard lock.withLock({ listenTask != nil }) else {
            throw TeslaError.notConnected
        }

        var command = message
        let domain = command.toDestination.domain
        guard domain != .broadcast else {
            throw TeslaError.malformedResponse("cannot send without a destination domain")
        }

        let uuid = try ByteUtilities.randomData(count: Self.uuidLength)
        let routingAddress: Data
        var receiverUUID = Data()
        if domain == .vehicleSecurity {
            routingAddress = try ByteUtilities.randomData(count: Self.addressLength)
        } else {
            routingAddress = address
            receiverUUID = uuid
        }

        command.uuid = uuid
        command.fromDestination.routingAddress = routingAddress

        if auth != .none {
            let session = lock.withLock { sessions[domain] }
            guard let session, session.isReady else {
                throw TeslaError.noSession(domain)
            }
            try session.authorize(
                message: &command,
                method: auth,
                expiresIn: timeout > 0 ? timeout : Self.defaultExpiration
            )
        }

        let requestID = lock.withLock { sessions[domain]?.requestID(for: command) } ?? Data()
        let key = ReceiverKey(address: routingAddress, uuid: receiverUUID, domain: domain)
        let receiver = ResponseReceiver(key: key, requestID: requestID, dispatcher: self)
        lock.withLock {
            handlers[key] = receiver
        }

        do {
            let bytes = try command.serializedData()
            Log.debug("Sending to domain \(domain), auth=\(auth), \(Log.dataSummary(bytes))")
            try await connector.send(bytes)
            return receiver
        } catch {
            close(receiver)
            throw error
        }
    }
    
    func close(_ receiver: ResponseReceiver) {
        lock.withLock {
            handlers.removeValue(forKey: receiver.key)
        }
    }
    
    private func requestSessionInfo(domain: TeslaDomain, publicKey: Data) async throws -> ResponseReceiver {
        var request = UniversalMessage_RoutableMessage()
        request.toDestination.domain = domain
        request.sessionInfoRequest.publicKey = publicKey
        return try await send(request, auth: .none, timeout: Self.defaultExpiration)
    }
    
    private func listen() async {
        for await bytes in connector.receiveMessages() {
            if Task.isCancelled { return }
            do {
                let message = try UniversalMessage_RoutableMessage(serializedBytes: bytes)
                process(message)
            } catch {
                Log.debug("Failed to parse inbound message:", Log.errorSummary(error))
                continue
            }
        }
    }

    private func process(_ inbound: UniversalMessage_RoutableMessage) {
        var message = inbound
        guard let key = receiverKey(for: message) else {
            return
        }

        guard let handler = lock.withLock({ handlers[key] }) else {
            Log.debug("No handler for domain \(key.domain), dropping message")
            return
        }

        checkForSessionUpdate(message: message, handler: handler)

        do {
            if case .aesGcmResponseData? = message.signatureData.sigType {
                let session = lock.withLock { sessions[key.domain] }
                guard let session else {
                    throw TeslaError.noSession(key.domain)
                }
                let counter = try session.decrypt(message: &message, requestID: handler.requestID)
                if !handler.antiReplay.update(counter) {
                    Log.fault("Replayed response detected, counter=\(counter), domain \(key.domain)")
                    throw TeslaError.replayedResponse
                }
            }
            handler.yield(message)
        } catch {
            Log.error("Process response failed for domain \(key.domain):", Log.errorSummary(error))
            return
        }
    }
    
    private func receiverKey(for message: UniversalMessage_RoutableMessage) -> ReceiverKey? {
        let domain = message.fromDestination.domain
        var uuid = Data()
        if domain != .vehicleSecurity {
            guard message.requestUuid.count == Self.uuidLength else {
                return nil
            }
            uuid = message.requestUuid
        }
        let address = message.toDestination.routingAddress
        guard address.count == Self.addressLength else {
            return nil
        }
        return ReceiverKey(address: address, uuid: uuid, domain: domain)
    }
    
    private func checkForSessionUpdate(
        message: UniversalMessage_RoutableMessage,
        handler: ResponseReceiver
    ) {
        guard case .sessionInfo(let encodedInfo)? = message.payload else {
            return
        }
        guard !handler.expired(maxLatency: connector.allowedLatency) else {
            Log.debug("Session info arrived but handler expired")
            return
        }
        guard case .sessionInfoTag(let sessionInfoTag)? = message.signatureData.sigType else {
            return
        }

        let domain = handler.key.domain
        guard let session = lock.withLock({ sessions[domain] }) else {
            return
        }

        do {
            try session.processHello(
                challenge: message.requestUuid,
                encodedInfo: encodedInfo,
                tag: sessionInfoTag.tag
            )
            Log.info("Session info processed for domain \(domain)")
        } catch {
            Log.error("Session info processing failed for domain \(domain):", Log.errorSummary(error))
            return
        }
    }
    
    private func sessionState(for domain: TeslaDomain, privateKey: TeslaPrivateKey) -> DomainSessionState {
        lock.withLock {
            if let session = sessions[domain] {
                return session
            }
            let session = DomainSessionState(
                privateKey: privateKey,
                vin: connector.vin,
                nonceMode: nonceMode
            )
            sessions[domain] = session
            return session
        }
    }
}
