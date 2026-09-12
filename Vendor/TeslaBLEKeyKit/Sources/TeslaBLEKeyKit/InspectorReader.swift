import Foundation
import SwiftProtobuf
import TeslaBLEKeyKitCore

public enum InspectorEndpoint: String, CaseIterable, Sendable {
    case getGuiSettings
    case getChargeState
    case getClimateState
    case getDriveState
    case getLegacyVehicleState
    case getVehicleConfig
    case getLocationState
    case getClosuresState
    case getParkedAccessoryState
    case getChargeScheduleState
    case getPreconditioningScheduleState
    case getSohState
    case getVehicleDetailState
    case getTirePressureState
    case getMediaState
    case getMediaDetailState
    case getSoftwareUpdateState
    case getVehicleState
    case getParentalControlsState
    case getAlertState
    case getLightShowState
    case getSuspensionState
    case getChildPresenceDetectionState
    case getDisplayState
    public func request() -> CarServer_GetVehicleData {
        var request = CarServer_GetVehicleData()
        switch self {
        case .getGuiSettings: request.getGuiSettings = CarServer_GetGuiSettings()
        case .getChargeState: request.getChargeState = CarServer_GetChargeState()
        case .getClimateState: request.getClimateState = CarServer_GetClimateState()
        case .getDriveState: request.getDriveState = CarServer_GetDriveState()
        case .getLegacyVehicleState: request.getLegacyVehicleState = CarServer_GetLegacyVehicleState()
        case .getVehicleConfig: request.getVehicleConfig = CarServer_GetVehicleConfig()
        case .getLocationState: request.getLocationState = CarServer_GetLocationState()
        case .getClosuresState: request.getClosuresState = CarServer_GetClosuresState()
        case .getParkedAccessoryState: request.getParkedAccessoryState = CarServer_GetParkedAccessoryState()
        case .getChargeScheduleState: request.getChargeScheduleState = CarServer_GetChargeScheduleState()
        case .getPreconditioningScheduleState: request.getPreconditioningScheduleState = CarServer_GetPreconditioningScheduleState()
        case .getSohState: request.getSohState = CarServer_GetSohState()
        case .getVehicleDetailState: request.getVehicleDetailState = CarServer_GetVehicleDetailState()
        case .getTirePressureState: request.getTirePressureState = CarServer_GetTirePressureState()
        case .getMediaState: request.getMediaState = CarServer_GetMediaState()
        case .getMediaDetailState: request.getMediaDetailState = CarServer_GetMediaDetailState()
        case .getSoftwareUpdateState: request.getSoftwareUpdateState = CarServer_GetSoftwareUpdateState()
        case .getVehicleState: request.getVehicleState = CarServer_GetVehicleState()
        case .getParentalControlsState: request.getParentalControlsState = CarServer_GetParentalControlsState()
        case .getAlertState: request.getAlertState = CarServer_GetAlertState()
        case .getLightShowState: request.getLightShowState = CarServer_GetLightShowState()
        case .getSuspensionState: request.getSuspensionState = CarServer_GetSuspensionState()
        case .getChildPresenceDetectionState: request.getChildPresenceDetectionState = CarServer_GetChildPresenceDetectionState()
        case .getDisplayState: request.getDisplayState = CarServer_GetDisplayState()
        }
        return request
    }
}

extension TeslaVehicle {
    public func readInspector(_ endpoint: InspectorEndpoint) async throws -> CarServer_Response {
        var action = CarServer_VehicleAction()
        action.getVehicleData = endpoint.request()
        return try await sendVehicleAction(action)
    }
}
