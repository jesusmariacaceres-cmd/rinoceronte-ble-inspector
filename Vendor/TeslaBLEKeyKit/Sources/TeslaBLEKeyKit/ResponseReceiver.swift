import Foundation
#if !COCOAPODS
import TeslaBLEKeyKitCore
#endif

final class ResponseReceiver {
    let key: ReceiverKey
    let requestID: Data
    let sentAt: Date
    var antiReplay = SlidingWindow()

    private let lock = NSLock()
    private var continuation: AsyncStream<UniversalMessage_RoutableMessage>.Continuation?
    private let stream: AsyncStream<UniversalMessage_RoutableMessage>
    private weak var dispatcher: TeslaDispatcher?

    init(key: ReceiverKey, requestID: Data, dispatcher: TeslaDispatcher) {
        self.key = key
        self.requestID = requestID
        self.sentAt = Date()
        self.dispatcher = dispatcher
        var localContinuation: AsyncStream<UniversalMessage_RoutableMessage>.Continuation?
        self.stream = AsyncStream { continuation in
            localContinuation = continuation
        }
        self.continuation = localContinuation
    }

    func messages() -> AsyncStream<UniversalMessage_RoutableMessage> {
        stream
    }

    func yield(_ message: UniversalMessage_RoutableMessage) {
        lock.withLock {
            continuation?.yield(message)
        }
    }

    func close() {
        dispatcher?.close(self)
        lock.withLock {
            continuation?.finish()
            continuation = nil
        }
    }

    func expired(maxLatency: TimeInterval) -> Bool {
        Date().timeIntervalSince(sentAt) > maxLatency
    }
}

struct ReceiverKey: Hashable, Sendable {
    var address: Data
    var uuid: Data
    var domain: TeslaDomain
}

extension AsyncStream {
    func firstValue(timeout: TimeInterval) async throws -> Element {
        try await withTimeout(seconds: timeout) {
            var iterator = self.makeAsyncIterator()
            guard let value = await iterator.next() else {
                throw TeslaError.notConnected
            }
            return value
        }
    }
}
