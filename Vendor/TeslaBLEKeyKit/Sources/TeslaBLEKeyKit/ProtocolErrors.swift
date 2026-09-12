import Foundation
#if !COCOAPODS
import TeslaBLEKeyKitCore
#endif

func protocolError(from message: UniversalMessage_RoutableMessage) -> Error? {
    let fault = message.signedMessageStatus.signedMessageFault
    if fault.rawValue != 0 {
        if fault.rawValue == 3 {
            return TeslaError.keyNotPaired
        }
        return TeslaError.protocolFault(fault.rawValue)
    }
    
    if case .sessionInfo(let encodedInfo)? = message.payload,
       let info = try? Signatures_SessionInfo(serializedBytes: encodedInfo) {
        switch info.status {
        case .ok:
            break
        case .keyNotOnWhitelist:
            return TeslaError.keyNotPaired
        case .UNRECOGNIZED(let code):
            return TeslaError.protocolFault(code)
        }
    }
    
    switch message.signedMessageStatus.operationStatus.rawValue {
    case 0:
        return nil
    case 1:
        return TeslaError.vehicleBusy
    case 2:
        return TeslaError.protocolFault(2)
    default:
        return TeslaError.protocolFault(message.signedMessageStatus.operationStatus.rawValue)
    }
}

func vcsecResponse(from message: UniversalMessage_RoutableMessage) throws -> VCSEC_FromVCSECMessage {
    if let error = protocolError(from: message) {
        throw error
    }
    
    guard case .protobufMessageAsBytes(let payload)? = message.payload else {
        return VCSEC_FromVCSECMessage()
    }
    
    let response = try VCSEC_FromVCSECMessage(serializedBytes: payload)
    if case .nominalError(let nominal)? = response.subMessage {
        throw TeslaError.vcsecError(String(describing: nominal.genericError))
    }
    
    if response.hasCommandStatus {
        switch response.commandStatus.operationStatus.rawValue {
        case 0:
            break
        case 1:
            throw TeslaError.vehicleBusy
        case 2:
            if case .whitelistOperationStatus(let whitelist)? = response.commandStatus.subMessage {
                let code = whitelist.whitelistOperationInformation.rawValue
                if code != 0 {
                    throw TeslaError.whitelistError(code)
                }
            }
            if response.commandStatus.subMessage == nil {
                throw TeslaError.protocolFault(2)
            }
        default:
            throw TeslaError.protocolFault(response.commandStatus.operationStatus.rawValue)
        }
    }
    return response
}

extension VCSEC_FromVCSECMessage {
    var hasCommandStatus: Bool {
        if case .commandStatus? = subMessage {
            return true
        }
        return false
    }
}

func carServerResponse(from message: UniversalMessage_RoutableMessage) throws -> CarServer_Response {
    if let error = protocolError(from: message) {
        throw error
    }

    guard case .protobufMessageAsBytes(let payload)? = message.payload else {
        return CarServer_Response()
    }

    let response = try CarServer_Response(serializedBytes: payload)
    if response.hasActionStatus && response.actionStatus.result == .rror {
        let reason: String
        if response.actionStatus.hasResultReason, case .plainText(let text)? = response.actionStatus.resultReason.reason {
            reason = text
        } else {
            reason = "unknown error"
        }
        throw TeslaError.infotainmentError(reason)
    }
    return response
}
