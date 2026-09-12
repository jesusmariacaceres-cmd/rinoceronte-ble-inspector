import Foundation
#if !COCOAPODS
import TeslaBLEKeyKitCore
#endif

public struct VehicleAdvertisement: Sendable, Equatable {
    public let localName: String
    public let rssi: Int
    public let identifier: UUID?
    public let isConnectable: Bool
    
    public init(localName: String, rssi: Int, identifier: UUID?, isConnectable: Bool) {
        self.localName = localName
        self.rssi = rssi
        self.identifier = identifier
        self.isConnectable = isConnectable
    }
}

public func vehicleLocalName(forVIN vin: String) throws -> String {
    guard !vin.isEmpty else {
        throw TeslaError.invalidVIN
    }
    let digest = Data(vin.utf8).sha1Digest()
    let identifier = digest.prefix(8).hexString()
    return "S\(identifier)C"
}
