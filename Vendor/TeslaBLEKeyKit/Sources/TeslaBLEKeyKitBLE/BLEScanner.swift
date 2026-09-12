@preconcurrency import CoreBluetooth
import Foundation
#if !COCOAPODS
import TeslaBLEKeyKitCore
#endif

public final class BLEScanner: NSObject, @unchecked Sendable {
    private let queue = DispatchQueue(label: "TeslaBLEKeyKit.BLEScanner")
    private var central: CBCentralManager?
    private var continuation: AsyncStream<VehicleAdvertisement>.Continuation?
    private var stream: AsyncStream<VehicleAdvertisement>?
    private var isScanning = false

    public override init() {
        super.init()
    }

    public func scan() -> AsyncStream<VehicleAdvertisement> {
        let (stream, continuation) = AsyncStream<VehicleAdvertisement>.makeStream()
        self.continuation = continuation
        self.stream = stream

        continuation.onTermination = { [weak self] _ in
            self?.stop()
        }

        queue.async {
            if self.central == nil {
                self.central = CBCentralManager(delegate: self, queue: self.queue)
            } else if self.central?.state == .poweredOn {
                self.startScan()
            }
        }

        return stream
    }

    public func stop() {
        queue.async {
            self.isScanning = false
            self.central?.stopScan()
            self.continuation?.finish()
            self.continuation = nil
            self.stream = nil
        }
    }

    private func startScan() {
        guard !isScanning else { return }
        isScanning = true
        central?.scanForPeripherals(
            withServices: nil,
            options: [CBCentralManagerScanOptionAllowDuplicatesKey: true]
        )
    }

    private static func isTeslaLocalName(_ name: String) -> Bool {
        guard name.count == 18,
              name.hasPrefix("S"),
              name.hasSuffix("C") else {
            return false
        }
        let hex = name.dropFirst().dropLast()
        return hex.allSatisfy { $0.isHexDigit }
    }
}

extension BLEScanner: CBCentralManagerDelegate {
    public func centralManagerDidUpdateState(_ central: CBCentralManager) {
        queue.async {
            switch central.state {
            case .poweredOn:
                self.startScan()
            case .poweredOff, .unauthorized, .unsupported:
                self.continuation?.finish()
                self.continuation = nil
                self.isScanning = false
            case .resetting, .unknown:
                break
            @unknown default:
                break
            }
        }
    }

    public func centralManager(
        _ central: CBCentralManager,
        didDiscover peripheral: CBPeripheral,
        advertisementData: [String: Any],
        rssi RSSI: NSNumber
    ) {
        queue.async {
            guard let localName = advertisementData[CBAdvertisementDataLocalNameKey] as? String,
                  Self.isTeslaLocalName(localName) else {
                return
            }

            let connectable = (advertisementData[CBAdvertisementDataIsConnectable] as? NSNumber)?.boolValue ?? false
            let advertisement = VehicleAdvertisement(
                localName: localName,
                rssi: RSSI.intValue,
                identifier: peripheral.identifier,
                isConnectable: connectable
            )
            self.continuation?.yield(advertisement)
        }
    }
}
