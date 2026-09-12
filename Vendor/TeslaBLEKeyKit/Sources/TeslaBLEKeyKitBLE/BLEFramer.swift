import Foundation
#if !COCOAPODS
import TeslaBLEKeyKitCore
#endif

public struct BLEFramer {
    public static let maximumMessageSize = 1024
    
    private var buffer = Data()
    private var lastReceiveDate = Date.distantPast
    private let chunkTimeout: TimeInterval
    
    public init(chunkTimeout: TimeInterval = 1) {
        self.chunkTimeout = chunkTimeout
    }

    public static func encode(_ message: Data) throws -> Data {
        guard message.count <= maximumMessageSize else {
            throw TeslaError.messageTooLarge(message.count)
        }
        var framed = Data()
        framed.append(UInt8((message.count >> 8) & 0xff))
        framed.append(UInt8(message.count & 0xff))
        framed.append(message)
        return framed
    }
    
    public mutating func receive(_ chunk: Data, now: Date = Date()) throws -> [Data] {
        if now.timeIntervalSince(lastReceiveDate) > chunkTimeout {
            buffer.removeAll(keepingCapacity: true)
        }
        lastReceiveDate = now
        buffer.append(chunk)
        
        var messages: [Data] = []
        while buffer.count >= 2 {
            let messageLength = (Int(buffer[buffer.startIndex]) << 8)
            + Int(buffer[buffer.index(after: buffer.startIndex)])
            guard messageLength <= Self.maximumMessageSize else {
                buffer.removeAll(keepingCapacity: true)
                throw TeslaError.invalidFrame
            }
            guard buffer.count >= messageLength + 2 else {
                break
            }
            let payloadStart = buffer.index(buffer.startIndex, offsetBy: 2)
            let payloadEnd = buffer.index(payloadStart, offsetBy: messageLength)
            messages.append(Data(buffer[payloadStart..<payloadEnd]))
            buffer.removeSubrange(buffer.startIndex..<payloadEnd)
        }
        return messages
    }
}
