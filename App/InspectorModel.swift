import Foundation
import SwiftUI
import SwiftProtobuf
import TeslaBLEKeyKit

struct Capture: Codable, Identifiable {
    var id = UUID()
    let timestamp: String
    let endpoint: String
    let decodedJSON: String?
    let rawBase64: String
    let rawHex: String
    let error: String?
}

// Synchronous callback from authenticated response decoding; protected across executor hops.
final class PayloadBox: @unchecked Sendable {
    private let lock = NSLock()
    private var data = Data()
    func set(_ value: Data) { lock.lock(); defer { lock.unlock() }; data = value }
    func get() -> Data { lock.lock(); defer { lock.unlock() }; return data }
}

@MainActor final class InspectorModel: ObservableObject {
    @Published var vin = ""
    @Published var status = "Desconectado"
    @Published var busy = false
    @Published var connected = false
    @Published var authenticated = false
    @Published var captures: [Capture] = []
    @Published var query = ""
    @Published var exportURL: URL?
    private var connection: BLEConnection?
    private var vehicle: TeslaVehicle?
    private var key: TeslaPrivateKey?
    private let raw = PayloadBox()

    init() {
        if let data = try? Data(contentsOf: Self.captureURL),
           let saved = try? JSONDecoder().decode([Capture].self, from: data) { captures = saved }
    }
    private static var captureURL: URL {
        FileManager.default.urls(for: .documentDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("captures.json")
    }
    var visibleCaptures: [Capture] {
        guard !query.isEmpty else { return captures }
        return captures.filter { ($0.endpoint + ($0.decodedJSON ?? "") + ($0.error ?? "") + $0.rawHex).localizedCaseInsensitiveContains(query) }
    }
    private func persist() throws {
        let encoder = JSONEncoder(); encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        try encoder.encode(captures).write(to: Self.captureURL, options: [.atomic, .completeFileProtection])
    }
    func connect() async {
        guard !busy else { return }; busy = true; defer { busy = false }
        status = "Buscando el nombre BLE derivado del VIN…"
        do {
            let clean = vin.trimmingCharacters(in: .whitespacesAndNewlines).uppercased()
            let key = try KeyStore.loadOrCreate()
            let link = try BLEConnection(vin: clean)
            self.connection = link; self.key = key
            try await link.connect(timeout: 20)
            connected = true; status = "BLE conectado. Empareja una vez o inicia sesión."
        } catch { disconnect(); status = error.localizedDescription }
    }
    func pair() async {
        guard !busy, let connection, let key, vehicle == nil else { return }
        busy = true; defer { busy = false }
        status = "Acepta la nueva clave en el coche. Rol solicitado: monitor."
        do {
            try await TeslaPairing(connector: connection).requestPairing(publicKey: key.publicKey, role: .vehicleMonitor)
            status = "Solicitud procesada. Reconecta e inicia sesión para comprobar el acceso."
        } catch { status = error.localizedDescription }
        let pairingStatus = status
        disconnect()
        status = pairingStatus + " Reconecta antes de iniciar sesión; no repitas el emparejamiento si ya lo aceptaste."
        // Pairing and session dispatcher must never consume the same stream concurrently.
    }
    func authenticate() async {
        guard !busy, let connection, let key else { return }
        busy = true; defer { busy = false }
        do {
            let v: TeslaVehicle
            if let existing = vehicle { v = existing }
            else {
                v = try TeslaVehicle(connector: connection, privateKey: key, configuration: .fourByteNonceBLE)
                v.diagnosticPayloadHandler = { [raw] bytes in raw.set(bytes) }
                vehicle = v
                try await v.connect()
            }
            try await v.startInfotainmentSession()
            authenticated = true
            status = "Sesión autenticada. Clave solicitada como monitor; permisos efectivos aún por probar."
        } catch { authenticated = false; status = error.localizedDescription }
    }
    func read(_ endpoint: InspectorEndpoint) async {
        guard !busy, authenticated, let vehicle else { return }
        busy = true; defer { busy = false }
        raw.set(Data()); status = "Leyendo \(endpoint.rawValue)…"
        var decoded: String?; var failure: String?
        do { decoded = try await vehicle.readInspector(endpoint).jsonString() }
        catch { failure = error.localizedDescription }
        let bytes = raw.get()
        let capture = Capture(timestamp: ISO8601DateFormatter().string(from: Date()), endpoint: endpoint.rawValue,
            decodedJSON: decoded, rawBase64: bytes.base64EncodedString(),
            rawHex: bytes.map { String(format: "%02x", $0) }.joined(), error: failure)
        captures.insert(capture, at: 0)
        do { try persist(); status = failure ?? "Respuesta guardada: \(bytes.count) bytes" }
        catch { status = "Lectura conservada en memoria; no se pudo guardar: \(error.localizedDescription)" }
        // No polling, no wake command, no automatic retry or role escalation.
    }
    func disconnect() {
        vehicle?.disconnect(); connection?.close()
        vehicle = nil; connection = nil; key = nil
        connected = false; authenticated = false; status = "Desconectado"
    }
    func export() {
        do {
            try persist()
            let url = FileManager.default.temporaryDirectory.appendingPathComponent("rinoceronte-diagnostico.json")
            let encoder = JSONEncoder(); encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
            try encoder.encode(captures).write(to: url, options: [.atomic, .completeFileProtection])
            exportURL = url
        } catch { status = error.localizedDescription }
    }
}
