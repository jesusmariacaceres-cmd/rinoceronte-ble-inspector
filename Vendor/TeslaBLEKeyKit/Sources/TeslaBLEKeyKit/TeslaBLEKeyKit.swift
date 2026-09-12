#if !COCOAPODS
@_exported import TeslaBLEKeyKitCore
@_exported import TeslaBLEKeyKitCrypto
@_exported import TeslaBLEKeyKitBLE
#endif

import Foundation

public enum TeslaBLEKeyKit {
    public static let vehicleCommandSource = "teslamotors/vehicle-command"
}

public typealias TeslaVCSECStatus = VCSEC_VehicleStatus
public typealias TeslaVCSECResponse = VCSEC_FromVCSECMessage
public typealias TeslaCarServerResponse = CarServer_Response
public typealias TeslaVehicleData = CarServer_VehicleData
public typealias TeslaVehicleAction = CarServer_VehicleAction
