@preconcurrency import CoreBluetooth
import Foundation
#if !COCOAPODS
import TeslaBLEKeyKitCore
#endif

public final class BLEConnection: NSObject, VehicleConnector, @unchecked Sendable {
    public static let vehicleServiceUUID = CBUUID(string: "00000211-b2d1-43f0-9b88-960cebf8b91e")
    public static let toVehicleCharacteristicUUID = CBUUID(string: "00000212-b2d1-43f0-9b88-960cebf8b91e")
    public static let fromVehicleCharacteristicUUID = CBUUID(string: "00000213-b2d1-43f0-9b88-960cebf8b91e")

    public var vin: String
    public let localName: String
    public let retryInterval: TimeInterval
    public let allowedLatency: TimeInterval
    public let preferredAuthMethod: ConnectorAuthMethod = .aesGCM

    private let queue = DispatchQueue(label: "TeslaBLEKeyKit.BLEConnection")
    private var central: CBCentralManager?
    private var targetLocalName: String
    private var peripheral: CBPeripheral?
    private var txCharacteristic: CBCharacteristic?
    private var rxCharacteristic: CBCharacteristic?
    private var connectContinuation: CheckedContinuation<Void, Error>?
    private var writeContinuations: [CheckedContinuation<Void, Error>] = []
    private var framer = BLEFramer()
    private var blockLength = 20
    private var receiveContinuation: AsyncStream<Data>.Continuation?
    private var receiveStreamStorage: AsyncStream<Data>!

    public init(
        vin: String,
        retryInterval: TimeInterval = 1,
        allowedLatency: TimeInterval = 4
    ) throws {
        self.vin = vin
        self.targetLocalName = try vehicleLocalName(forVIN: vin)
        self.localName = self.targetLocalName
        self.retryInterval = retryInterval
        self.allowedLatency = allowedLatency
        super.init()
        self.receiveStreamStorage = AsyncStream { [weak self] continuation in
            self?.queue.async {
                self?.receiveContinuation = continuation
            }
        }
    }

    public init(
        advertisement: VehicleAdvertisement,
        retryInterval: TimeInterval = 1,
        allowedLatency: TimeInterval = 4
    ) {
        self.vin = advertisement.localName
        self.localName = advertisement.localName
        self.targetLocalName = advertisement.localName
        self.retryInterval = retryInterval
        self.allowedLatency = allowedLatency
        super.init()
        self.receiveStreamStorage = AsyncStream { [weak self] continuation in
            self?.queue.async {
                self?.receiveContinuation = continuation
            }
        }
    }

    public init(
        localName: String,
        retryInterval: TimeInterval = 1,
        allowedLatency: TimeInterval = 4
    ) throws {
        guard localName.count == 18,
              localName.hasPrefix("S"),
              localName.hasSuffix("C") else {
            throw TeslaError.invalidVIN
        }
        self.vin = localName
        self.localName = localName
        self.targetLocalName = localName
        self.retryInterval = retryInterval
        self.allowedLatency = allowedLatency
        super.init()
        self.receiveStreamStorage = AsyncStream { [weak self] continuation in
            self?.queue.async {
                self?.receiveContinuation = continuation
            }
        }
    }

    public func connect(timeout: TimeInterval = 20) async throws {
        Log.info("Connecting to \(targetLocalName), timeout=\(timeout)s")
        do {
            try await withTimeout(seconds: timeout) {
                try await withTaskCancellationHandler(operation: {
                try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<Void, Error>) in
                    self.queue.async {
                        self.connectContinuation = continuation
                        if self.central == nil {
                            self.central = CBCentralManager(delegate: self, queue: self.queue)
                        } else if self.central?.state == .poweredOn {
                            self.startScan()
                        } else if let central = self.central {
                            self.handleCentralState(central.state)
                        }
                    }
                }
                }, onCancel: { self.close() })
            }
            Log.info("Connected to \(targetLocalName)")
        } catch {
            Log.error("Connect failed for \(targetLocalName):", Log.errorSummary(error))
            throw error
        }
    }

    public func receiveMessages() -> AsyncStream<Data> {
        receiveStreamStorage
    }

    public func send(_ message: Data) async throws {
        Log.debug("TX \(Log.dataSummary(message)), blockLength=\(blockLength)")
        let framed = try BLEFramer.encode(message)
        var chunks: [Data] = []
        var offset = 0
        while offset < framed.count {
            let end = min(offset + blockLength, framed.count)
            chunks.append(Data(framed[framed.index(framed.startIndex, offsetBy: offset)..<framed.index(framed.startIndex, offsetBy: end)]))
            offset = end
        }

        for chunk in chunks {
            try await withTimeout(seconds: 10) {
                try await withTaskCancellationHandler(operation: {
                    try await self.write(chunk)
                }, onCancel: { self.close() })
            }
        }
    }

    public func close() {
        Log.info("Closing BLE connection to \(targetLocalName)")
        queue.async {
            self.central?.stopScan()
            if let peripheral = self.peripheral {
                self.central?.cancelPeripheralConnection(peripheral)
            }
            self.receiveContinuation?.finish()
            self.receiveContinuation = nil
            self.resumeConnect(with: TeslaError.notConnected)
            for continuation in self.writeContinuations {
                continuation.resume(throwing: TeslaError.notConnected)
            }
            self.writeContinuations.removeAll()
            self.peripheral = nil
            self.txCharacteristic = nil
            self.rxCharacteristic = nil
        }
    }

    private func write(_ chunk: Data) async throws {
        try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<Void, Error>) in
            queue.async {
                guard let peripheral = self.peripheral, let tx = self.txCharacteristic else {
                    continuation.resume(throwing: TeslaError.notConnected)
                    return
                }
                self.writeContinuations.append(continuation)
                peripheral.writeValue(chunk, for: tx, type: .withResponse)
            }
        }
    }

    private func startScan() {
        central?.scanForPeripherals(
            withServices: nil,
            options: [CBCentralManagerScanOptionAllowDuplicatesKey: false]
        )
    }

    private func handleCentralState(_ state: CBManagerState) {
        Log.debug("Central state: \(state.rawValue)")
        switch state {
        case .poweredOn:
            startScan()
        case .unauthorized:
            resumeConnect(with: TeslaError.bluetoothUnauthorized)
        case .poweredOff:
            resumeConnect(with: TeslaError.bluetoothPoweredOff)
        case .unsupported:
            resumeConnect(with: TeslaError.bluetoothUnsupported)
        case .resetting, .unknown:
            break
        @unknown default:
            resumeConnect(with: TeslaError.bluetoothUnavailable)
        }
    }

    private func resumeConnect() {
        guard let continuation = connectContinuation else { return }
        connectContinuation = nil
        continuation.resume()
    }

    private func resumeConnect(with error: Error) {
        guard let continuation = connectContinuation else { return }
        connectContinuation = nil
        continuation.resume(throwing: error)
    }
}

extension BLEConnection: CBCentralManagerDelegate {
    public func centralManagerDidUpdateState(_ central: CBCentralManager) {
        queue.async {
            self.handleCentralState(central.state)
        }
    }

    public func centralManager(
        _ central: CBCentralManager,
        didDiscover peripheral: CBPeripheral,
        advertisementData: [String: Any],
        rssi RSSI: NSNumber
    ) {
        queue.async {
            let localName = advertisementData[CBAdvertisementDataLocalNameKey] as? String
            guard localName == self.targetLocalName else { return }

            let connectable = (advertisementData[CBAdvertisementDataIsConnectable] as? NSNumber)?.boolValue ?? true
            Log.debug("Discovered \(localName ?? "nil"), RSSI=\(RSSI), connectable=\(connectable)")
            guard connectable else {
                Log.error("Device not connectable (max BLE connections exceeded)")
                self.resumeConnect(with: TeslaError.maxBLEConnectionsExceeded)
                return
            }

            central.stopScan()
            self.peripheral = peripheral
            peripheral.delegate = self
            central.connect(peripheral, options: nil)
        }
    }

    public func centralManager(_ central: CBCentralManager, didConnect peripheral: CBPeripheral) {
        Log.debug("Peripheral connected, discovering services")
        queue.async {
            peripheral.discoverServices([Self.vehicleServiceUUID])
        }
    }

    public func centralManager(_ central: CBCentralManager, didFailToConnect peripheral: CBPeripheral, error: Error?) {
        Log.error("Failed to connect peripheral:", error.map { Log.errorSummary($0) } ?? "unknown")
        queue.async {
            self.resumeConnect(with: error ?? TeslaError.notConnected)
        }
    }

    public func centralManager(_ central: CBCentralManager, didDisconnectPeripheral peripheral: CBPeripheral, error: Error?) {
        Log.info("Peripheral disconnected:", error.map { Log.errorSummary($0) } ?? "clean")
        queue.async {
            for continuation in self.writeContinuations {
                continuation.resume(throwing: error ?? TeslaError.notConnected)
            }
            self.writeContinuations.removeAll()
            self.receiveContinuation?.finish()
            self.resumeConnect(with: error ?? TeslaError.notConnected)
        }
    }
}

extension BLEConnection: CBPeripheralDelegate {
    public func peripheral(_ peripheral: CBPeripheral, didDiscoverServices error: Error?) {
        queue.async {
            if let error {
                self.resumeConnect(with: error)
                return
            }
            guard let service = peripheral.services?.first(where: { $0.uuid == Self.vehicleServiceUUID }) else {
                self.resumeConnect(with: TeslaError.missingCharacteristic)
                return
            }
            peripheral.discoverCharacteristics(
                [Self.toVehicleCharacteristicUUID, Self.fromVehicleCharacteristicUUID],
                for: service
            )
        }
    }

    public func peripheral(_ peripheral: CBPeripheral, didDiscoverCharacteristicsFor service: CBService, error: Error?) {
        queue.async {
            if let error {
                Log.error("Characteristic discovery failed:", Log.errorSummary(error))
                self.resumeConnect(with: error)
                return
            }
            for characteristic in service.characteristics ?? [] {
                if characteristic.uuid == Self.toVehicleCharacteristicUUID {
                    self.txCharacteristic = characteristic
                } else if characteristic.uuid == Self.fromVehicleCharacteristicUUID {
                    self.rxCharacteristic = characteristic
                }
            }
            guard let rx = self.rxCharacteristic, self.txCharacteristic != nil else {
                Log.error("Missing TX/RX characteristics")
                self.resumeConnect(with: TeslaError.missingCharacteristic)
                return
            }
            self.blockLength = max(1, min(peripheral.maximumWriteValueLength(for: .withResponse), BLEFramer.maximumMessageSize))
            Log.debug("Characteristics ready, blockLength=\(self.blockLength)")
            peripheral.setNotifyValue(true, for: rx)
        }
    }

    public func peripheral(
        _ peripheral: CBPeripheral,
        didUpdateNotificationStateFor characteristic: CBCharacteristic,
        error: Error?
    ) {
        queue.async {
            if let error {
                self.resumeConnect(with: error)
                return
            }
            guard characteristic.uuid == Self.fromVehicleCharacteristicUUID, characteristic.isNotifying else {
                self.resumeConnect(with: TeslaError.missingCharacteristic)
                return
            }
            self.resumeConnect()
        }
    }

    public func peripheral(_ peripheral: CBPeripheral, didWriteValueFor characteristic: CBCharacteristic, error: Error?) {
        queue.async {
            guard !self.writeContinuations.isEmpty else { return }
            let continuation = self.writeContinuations.removeFirst()
            if let error {
                continuation.resume(throwing: error)
            } else {
                continuation.resume()
            }
        }
    }

    public func peripheral(_ peripheral: CBPeripheral, didUpdateValueFor characteristic: CBCharacteristic, error: Error?) {
        queue.async {
            guard error == nil, characteristic.uuid == Self.fromVehicleCharacteristicUUID, let value = characteristic.value else {
                if let error { Log.error("RX notification error:", Log.errorSummary(error)) }
                return
            }
            do {
                let messages = try self.framer.receive(value)
                for message in messages {
                    Log.debug("RX \(Log.dataSummary(message))")
                    self.receiveContinuation?.yield(message)
                }
            } catch {
                Log.error("Framer error:", Log.errorSummary(error))
                self.receiveContinuation?.finish()
            }
        }
    }
}
