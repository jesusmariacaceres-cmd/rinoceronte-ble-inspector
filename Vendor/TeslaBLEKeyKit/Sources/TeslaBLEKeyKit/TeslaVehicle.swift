import Foundation
import SwiftProtobuf
#if !COCOAPODS
import TeslaBLEKeyKitCore
#endif
#if !COCOAPODS
import TeslaBLEKeyKitCrypto
#endif

public struct TeslaVehicleConfiguration: Sendable, Equatable {
    public var nonceMode: AESGCMNonceMode
    public var commandTimeout: TimeInterval
    public var sessionTimeout: TimeInterval
    
    public init(
        nonceMode: AESGCMNonceMode = .standard12Byte,
        commandTimeout: TimeInterval = 10,
        sessionTimeout: TimeInterval = 15
    ) {
        self.nonceMode = nonceMode
        self.commandTimeout = commandTimeout
        self.sessionTimeout = sessionTimeout
    }
    
    public static let standard = TeslaVehicleConfiguration()
    public static let fourByteNonceBLE = TeslaVehicleConfiguration(nonceMode: .teslaBLE4Byte)
}

public enum TeslaClosure: Sendable, Equatable {
    case trunk
    case frunk
    case tonneau
    case chargePort
}

public final class TeslaVehicle {
    public static let defaultFlags = UInt32(1 << UniversalMessage_Flags.flagEncryptResponse.rawValue)
    
    public var diagnosticPayloadHandler: ((Data) -> Void)?
    public var flags: UInt32
    public let vin: String
    
    private let connector: VehicleConnector
    private let dispatcher: TeslaDispatcher
    private let configuration: TeslaVehicleConfiguration
    
    public init(
        connector: VehicleConnector,
        privateKey: TeslaPrivateKey?,
        configuration: TeslaVehicleConfiguration = .standard
    ) throws {
        self.connector = connector
        self.dispatcher = try TeslaDispatcher(
            connector: connector,
            privateKey: privateKey,
            nonceMode: configuration.nonceMode
        )
        self.configuration = configuration
        self.vin = connector.vin
        self.flags = Self.defaultFlags
    }
    
    public func connect() async throws {
        Log.info("TeslaVehicle connecting, VIN=\(vin)")
        dispatcher.start()
    }

    public func disconnect() {
        Log.info("TeslaVehicle disconnecting, VIN=\(vin)")
        dispatcher.stop()
        connector.close()
    }

    public func startInfotainmentSession() async throws {
        Log.info("Starting Infotainment session")
        try await dispatcher.startSession(
            domain: .infotainment,
            timeout: configuration.sessionTimeout
        )
    }

    @discardableResult
    func sendVehicleAction(_ action: CarServer_VehicleAction) async throws -> CarServer_Response {
        guard case .getVehicleData(let request)? = action.vehicleActionMsg,
              try InspectorEndpoint.allCases.contains(where: {
                  try $0.request().serializedData() == request.serializedData()
              }) else {
            throw TeslaError.malformedResponse("Inspector only permits GetVehicleData")
        }
        var carAction = CarServer_Action()
        carAction.vehicleAction = action
        let bytes = try carAction.serializedData()
        return try await getInfotainmentResult(payload: bytes, auth: connector.preferredAuthMethod.internalAuthMethod)
    }

    private func getInfotainmentResult(
        payload: Data,
        auth: AuthMethod
    ) async throws -> CarServer_Response {
        let receiver = try await getReceiver(domain: .infotainment, payload: payload, auth: auth)
        defer { receiver.close() }
        return try await readInfotainmentResponse(receiver: receiver)
    }
    
    private func readInfotainmentResponse(
        receiver: ResponseReceiver
    ) async throws -> CarServer_Response {
        try await withTimeout(seconds: configuration.commandTimeout) {
            for await message in receiver.messages() {
                if case .protobufMessageAsBytes(let payload)? = message.payload {
                    self.diagnosticPayloadHandler?(payload)
                }
                return try carServerResponse(from: message)
            }
            throw TeslaError.notConnected
        }
    }

    public func startVCSECSession() async throws {
        Log.info("Starting VCSEC session")
        try await dispatcher.startSession(
            domain: .vehicleSecurity,
            timeout: configuration.sessionTimeout
        )
    }

    private func getReceiver(
        domain: TeslaDomain,
        payload: Data,
        auth: AuthMethod
    ) async throws -> ResponseReceiver {
        var message = UniversalMessage_RoutableMessage()
        message.toDestination.domain = domain
        message.protobufMessageAsBytes = payload
        message.flags = flags
        return try await dispatcher.send(
            message,
            auth: auth,
            timeout: configuration.commandTimeout
        )
    }
}
