import SwiftUI
import TeslaBLEKeyKit

@main struct RinoceronteApp: App {
    @StateObject private var model = InspectorModel()
    @Environment(\.scenePhase) private var phase
    var body: some Scene {
        WindowGroup {
            NavigationStack {
                List {
                    Section("Rinoceronte · BLE Inspector 0.1.0") {
                        Text(model.status)
                        TextField("VIN del coche (solo en este dispositivo)", text: $model.vin)
                            .textInputAutocapitalization(.characters).autocorrectionDisabled()
                            .disabled(model.connected || model.busy)
                        Button("Conectar por Bluetooth") { Task { await model.connect() } }
                            .disabled(model.busy || model.connected)
                        Button("Emparejar clave de monitor") { Task { await model.pair() } }
                            .disabled(model.busy || !model.connected || model.authenticated)
                        Button("Iniciar sesión de lectura") { Task { await model.authenticate() } }
                            .disabled(model.busy || !model.connected || model.authenticated)
                        Button("Desconectar") { model.disconnect() }
                            .disabled(model.busy || !model.connected)
                    }
                    Section("Lecturas individuales") {
                        ForEach(InspectorEndpoint.allCases, id: \.rawValue) { endpoint in
                            Button(endpoint.rawValue) { Task { await model.read(endpoint) } }
                                .disabled(model.busy || !model.authenticated)
                        }
                    }
                    Section("Diagnóstico") {
                        Text("Los datos raw conservan campos desconocidos y pueden contener información personal del coche. Las claves privadas no se exportan.")
                            .font(.caption)
                        TextField("Buscar campo o valor", text: $model.query)
                        Button("Preparar exportación JSON") { model.export() }
                        if let url = model.exportURL { ShareLink("Compartir diagnóstico", item: url) }
                        ForEach(model.visibleCaptures) { capture in
                            NavigationLink(capture.endpoint + " · " + capture.timestamp) {
                                ScrollView {
                                    Text((capture.error ?? "") + "\n" + (capture.decodedJSON ?? "Sin JSON decodificado") + "\nRAW HEX\n" + capture.rawHex)
                                        .font(.system(.caption, design: .monospaced)).textSelection(.enabled).padding()
                                }.navigationTitle(capture.endpoint)
                            }
                        }
                    }
                }.navigationTitle("Rinoceronte")
            }
            .onChange(of: phase) { value in
                if value == .background { model.disconnect() }
            }
        }
    }
}
