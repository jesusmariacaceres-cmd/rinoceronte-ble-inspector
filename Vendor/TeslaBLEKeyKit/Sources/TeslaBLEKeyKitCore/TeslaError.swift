import Foundation

public typealias TeslaDomain = UniversalMessage_Domain

public protocol TeslaProtocolError: Error {
    var mayHaveSucceeded: Bool { get }
    var isTemporary: Bool { get }
}

public enum TeslaError: LocalizedError, TeslaProtocolError, Equatable {
    case bluetoothUnavailable
    case bluetoothUnauthorized
    case bluetoothPoweredOff
    case bluetoothUnsupported
    case scanTimedOut
    case vehicleNotFound(String)
    case maxBLEConnectionsExceeded
    case notConnected
    case invalidVIN
    case missingCharacteristic
    case invalidFrame
    case messageTooLarge(Int)
    case malformedResponse(String)
    case missingPrivateKey
    case noSession(TeslaDomain)
    case keyNotPaired
    case vehicleBusy
    case replayedResponse
    case protocolFault(Int)
    case vcsecError(String)
    case whitelistError(Int)
    case infotainmentError(String)
    case crypto(String)
    case timeout
    
    public var errorDescription: String? {
        switch self {
        case .bluetoothUnavailable:
            return "Bluetooth is unavailable."
        case .bluetoothUnauthorized:
            return "Bluetooth permission has not been granted."
        case .bluetoothPoweredOff:
            return "Bluetooth is powered off."
        case .bluetoothUnsupported:
            return "Bluetooth is not supported on this device."
        case .scanTimedOut:
            return "Timed out while scanning for the vehicle BLE beacon."
        case .vehicleNotFound(let vin):
            return "Could not find BLE beacon for vehicle \(vin)."
        case .maxBLEConnectionsExceeded:
            return "The vehicle is already connected to the maximum number of BLE devices."
        case .notConnected:
            return "Vehicle is not connected."
        case .invalidVIN:
            return "VIN is invalid."
        case .missingCharacteristic:
            return "Vehicle BLE service did not expose the required characteristics."
        case .invalidFrame:
            return "Received an invalid BLE frame."
        case .messageTooLarge(let count):
            return "BLE message is too large: \(count) bytes."
        case .malformedResponse(let details):
            return "Vehicle response was malformed: \(details)."
        case .missingPrivateKey:
            return "A private key is required for this command."
        case .noSession(let domain):
            return "No authenticated session is available for \(domain)."
        case .keyNotPaired:
            return "The vehicle rejected this key. Pair the public key with the vehicle first."
        case .vehicleBusy:
            return "Vehicle is busy or finishing wake-up."
        case .replayedResponse:
            return "Received a duplicate vehicle response counter."
        case .protocolFault(let code):
            return "Vehicle returned protocol fault \(code)."
        case .vcsecError(let details):
            return "VCSEC could not execute command: \(details)."
        case .whitelistError(let code):
            return "Whitelist operation failed with code \(code)."
        case .infotainmentError(let details):
            return "Infotainment command failed: \(details)."
        case .crypto(let details):
            return "Cryptographic operation failed: \(details)."
        case .timeout:
            return "Operation timed out."
        }
    }
    
    public var mayHaveSucceeded: Bool {
        switch self {
        case .timeout:
            return true
        case .protocolFault(let code):
            return code == 0 || code == 25
        default:
            return false
        }
    }
    
    public var isTemporary: Bool {
        switch self {
        case .vehicleBusy, .scanTimedOut:
            return true
        case .protocolFault(let code):
            return [1, 2, 5, 6, 11, 15, 17, 20].contains(code)
        default:
            return false
        }
    }
}

public func shouldRetry(_ error: Error?) -> Bool {
    guard let error else { return false }
    if let protocolError = error as? TeslaProtocolError {
        return !protocolError.mayHaveSucceeded && protocolError.isTemporary
    }
    return false
}

public func withTimeout<T>(
    seconds: TimeInterval,
    operation: @escaping @Sendable () async throws -> T
) async throws -> T {
    try await withThrowingTaskGroup(of: T.self) { group in
        group.addTask {
            try await operation()
        }
        group.addTask {
            let nanoseconds = UInt64(max(0, seconds) * 1_000_000_000)
            try await Task.sleep(nanoseconds: nanoseconds)
            throw TeslaError.timeout
        }
        let result = try await group.next()!
        group.cancelAll()
        return result
    }
}
