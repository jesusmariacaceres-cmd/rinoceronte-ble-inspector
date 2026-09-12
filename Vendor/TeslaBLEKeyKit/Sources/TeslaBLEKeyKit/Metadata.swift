import Foundation
#if !COCOAPODS
import TeslaBLEKeyKitCore
#endif

struct MetadataBuilder {
    enum Context {
        case sha256
        case hmacSHA256(key: Data)
    }
    
    private var encoded = Data()
    private var lastTagRawValue = -1
    private let context: Context
    
    init(context: Context = .sha256) {
        self.context = context
    }
    
    mutating func add(_ tag: Signatures_Tag, value: Data?) throws {
        guard let value else { return }
        let rawValue = tag.rawValue
        guard rawValue >= lastTagRawValue else {
            throw TeslaError.crypto("metadata tags must be added in ascending order")
        }
        guard value.count <= 255 else {
            throw TeslaError.crypto("metadata field is longer than 255 bytes")
        }
        lastTagRawValue = rawValue
        encoded.append(UInt8(rawValue & 0xff))
        encoded.append(UInt8(value.count))
        encoded.append(value)
    }
    
    mutating func addUInt32(_ tag: Signatures_Tag, value: UInt32) throws {
        try add(tag, value: Data(uint32BigEndian: value))
    }
    
    func checksum(message: Data? = nil) -> Data {
        var data = encoded
        data.append(UInt8(Signatures_Tag.end.rawValue))
        if let message {
            data.append(message)
        }
        switch context {
        case .sha256:
            return data.sha256Digest()
        case .hmacSHA256(let key):
            return data.hmacSHA256(key: key)
        }
    }
}
