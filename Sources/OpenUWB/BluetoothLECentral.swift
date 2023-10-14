/*
 Copyright © 2023 Gunnar Beutner,
 Copyright © 2022 Apple Inc.

 Permission is hereby granted, free of charge, to any person obtaining a copy of this software and associated documentation files (the "Software"), to deal in the Software without restriction, including without limitation the rights to use, copy, modify, merge, publish, distribute, sublicense, and/or sell copies of the Software, and to permit persons to whom the Software is furnished to do so, subject to the following conditions:

 The above copyright notice and this permission notice shall be included in all copies or substantial portions of the Software.

 THE SOFTWARE IS PROVIDED "AS IS", WITHOUT WARRANTY OF ANY KIND, EXPRESS OR IMPLIED, INCLUDING BUT NOT LIMITED TO THE WARRANTIES OF MERCHANTABILITY, FITNESS FOR A PARTICULAR PURPOSE AND NONINFRINGEMENT. IN NO EVENT SHALL THE AUTHORS OR COPYRIGHT HOLDERS BE LIABLE FOR ANY CLAIM, DAMAGES OR OTHER LIABILITY, WHETHER IN AN ACTION OF CONTRACT, TORT OR OTHERWISE, ARISING FROM, OUT OF OR IN CONNECTION WITH THE SOFTWARE OR THE USE OR OTHER DEALINGS IN THE SOFTWARE.
*/

import CoreBluetooth
import os

struct TransferService {
    static let discoverUUID = CBUUID(string: "FE9A")
    static let serviceUUID = CBUUID(string: "6E400001-B5A3-F393-E0A9-E50E24DCCA9E")
    static let interactionUUID = CBUUID(string: "48FE3E40-0817-4BB2-8633-3073689C2DBA")
    static let rxCharacteristicUUID = CBUUID(string: "6E400002-B5A3-F393-E0A9-E50E24DCCA9E")
    static let txCharacteristicUUID = CBUUID(string: "6E400003-B5A3-F393-E0A9-E50E24DCCA9E")
    static let accessoryConfigDataUUID = CBUUID(string: "95E8D9D5-D8EF-4721-9A4E-807375F53328")
}

enum BluetoothLECentralError: Error {
    case noPeripheral
}

class BluetoothAccessory {
    var centralManager: CBCentralManager!
    var discoveredPeripheral: CBPeripheral!
    var name: String?
    var protocolVersion: UInt8
    var publicIdentifier: String
    var rxCharacteristic: CBCharacteristic?
    var txCharacteristic: CBCharacteristic?
    var available = false
    var backgroundCapable = false
    
    let logger = os.Logger(subsystem: "com.example.apple-samplecode.NINearbyAccessorySample", category: "BluetoothAccessory")
    
    init(centralManager: CBCentralManager, discoveredPeripheral: CBPeripheral, protocolVersion: UInt8, publicIdentifier: String) {
        self.centralManager = centralManager
        self.discoveredPeripheral = discoveredPeripheral
        self.protocolVersion = protocolVersion
        self.publicIdentifier = publicIdentifier
    }
    
    func sendData(_ data: Data) throws {
        if discoveredPeripheral == nil {
            throw BluetoothLECentralError.noPeripheral
        }
        writeData(data)
    }
    
    // Sends data to the peripheral.
    private func writeData(_ data: Data) {

        guard let discoveredPeripheral = discoveredPeripheral,
              let transferCharacteristic = rxCharacteristic
        else { return }

        let mtu = discoveredPeripheral.maximumWriteValueLength(for: .withResponse)

        let bytesToCopy: size_t = min(mtu, data.count)

        var rawPacket = [UInt8](repeating: 0, count: bytesToCopy)
        data.copyBytes(to: &rawPacket, count: bytesToCopy)
        let packetData = Data(bytes: &rawPacket, count: bytesToCopy)

        let stringFromData = packetData.map { String(format: "0x%02x, ", $0) }.joined()
        logger.info("Writing \(bytesToCopy) bytes: \(String(describing: stringFromData))")

        discoveredPeripheral.writeValue(packetData, for: transferCharacteristic, type: .withResponse)
    }
    
    /*
     * Stops an erroneous or completed connection. Note, `didUpdateNotificationStateForCharacteristic`
     * cancels the connection if a subscriber exists.
     */
    internal func cleanup() {
        // Don't do anything if we're not connected
        guard let discoveredPeripheral = discoveredPeripheral,
              case .connected = discoveredPeripheral.state else { return }

        for service in (discoveredPeripheral.services ?? [] as [CBService]) {
            for characteristic in (service.characteristics ?? [] as [CBCharacteristic]) {
                if characteristic.uuid == TransferService.rxCharacteristicUUID && characteristic.isNotifying {
                    // It is notifying, so unsubscribe
                    self.discoveredPeripheral?.setNotifyValue(false, for: characteristic)
                }
            }
        }

        // When a connection exists without a subscriber, only disconnect.
        centralManager.cancelPeripheralConnection(discoveredPeripheral)
    }
}

class DataCommunicationChannel: NSObject {
    var centralManager: CBCentralManager!
    
    var accessories = [UUID: BluetoothAccessory]()
    
    var accessoryDataHandler: ((BluetoothAccessory, Data) -> Void)?
    var accessoryConnectedHandler: ((BluetoothAccessory) -> Void)?
    var accessoryDisconnectedHandler: ((BluetoothAccessory) -> Void)?
    
    var bluetoothReady = false
    var shouldStartWhenReady = false
    
    let logger = os.Logger(subsystem: "com.example.apple-samplecode.NINearbyAccessorySample", category: "DataChannel")
    
    override init() {
        super.init()
        centralManager = CBCentralManager(delegate: self, queue: nil, options: [CBCentralManagerOptionShowPowerAlertKey: true])
    }
    
    deinit {
        centralManager.stopScan()
        logger.info("Scanning stopped")
    }
    
    func start() {
        if bluetoothReady {
            centralManager.scanForPeripherals(withServices: [TransferService.discoverUUID],
                                              options: [CBCentralManagerScanOptionAllowDuplicatesKey: true])
        } else {
            shouldStartWhenReady = true
        }
    }
}

// MARK: - Helper Methods.

extension DataCommunicationChannel: CBCentralManagerDelegate {
    /*
     * When Bluetooth is powered, starts Bluetooth operations.
     *
     * The protocol requires a `centralManagerDidUpdateState` implementation.
     * Ensure you can use the Central by checking whether the its state is
     * `poweredOn`. Your app can check other states to ensure availability such
     * as whether the current device supports Bluetooth LE.
     */
    internal func centralManagerDidUpdateState(_ central: CBCentralManager) {
        switch central.state {
            
        // Begin communicating with the peripheral.
        case .poweredOn:
            logger.info("CBManager is powered on")
            bluetoothReady = true
            if shouldStartWhenReady {
                start()
            }
        // In your app, deal with the following states as necessary.
        case .poweredOff:
            logger.error("CBManager is not powered on")
            return
        case .resetting:
            logger.error("CBManager is resetting")
            return
        case .unauthorized:
            handleCBUnauthorized()
            return
        case .unknown:
            logger.error("CBManager state is unknown")
            return
        case .unsupported:
            logger.error("Bluetooth is not supported on this device")
            return
        @unknown default:
            logger.error("A previously unknown central manager state occurred")
            return
        }
    }

    // Reacts to the varying causes of Bluetooth restriction.
    internal func handleCBUnauthorized() {
        switch CBManager.authorization {
        case .denied:
            // In your app, consider sending the user to Settings to change authorization.
            logger.error("The user denied Bluetooth access.")
        case .restricted:
            logger.error("Bluetooth is restricted")
        default:
            logger.error("Unexpected authorization")
        }
    }

    // Reacts to transfer service UUID discovery.
    // Consider checking the RSSI value before attempting to connect.
    func centralManager(_ central: CBCentralManager, didDiscover peripheral: CBPeripheral,
                        advertisementData: [String: Any], rssi RSSI: NSNumber) {
        logger.info("Discovered \( String(describing: peripheral.name)) at \(RSSI.intValue)")
        
        // Check if the app recognizes the in-range peripheral device.
        if !accessories.keys.contains(peripheral.identifier) {
            guard let serviceData = advertisementData[CBAdvertisementDataServiceDataKey] as? [CBUUID: Data] else {
                return
            }
            
            guard let estimoteServiceData = serviceData[TransferService.discoverUUID] else {
                return
            }

            let estimoteProtocolVersion = estimoteServiceData[0] >> 0x4 & ((1 << 0x4) - 1)
            let estimoteIdentifier = estimoteServiceData[1..<17].map { String(format: "%02x", $0) }.joined()

            // Save a local copy of the peripheral so Core Bluetooth doesn't
            // deallocate it.
            let accessory = BluetoothAccessory(centralManager: centralManager, discoveredPeripheral: peripheral, protocolVersion: estimoteProtocolVersion, publicIdentifier: estimoteIdentifier)
            accessory.name = advertisementData[CBAdvertisementDataLocalNameKey] as? String
            accessories[peripheral.identifier] = accessory

            // Connect to the peripheral.
            logger.info("Connecting to peripheral \(peripheral)")
            centralManager.connect(peripheral, options: nil)
        }
    }

    // Reacts to connection failure.
    func centralManager(_ central: CBCentralManager, didFailToConnect peripheral: CBPeripheral, error: Error?) {
        logger.error("Failed to connect to \(peripheral). \( String(describing: error))")
        guard let accessory = accessories[peripheral.identifier] else {
            return
        }
        accessory.cleanup()
    }

    // Discovers the services and characteristics to find the 'TransferService'
    // characteristic after peripheral connection.
    func centralManager(_ central: CBCentralManager, didConnect peripheral: CBPeripheral) {
        logger.info("Connected to \(peripheral)")
        
        // Set the `CBPeripheral` delegate to receive callbacks for its services discovery.
        peripheral.delegate = self
        
        // Search only for services that match the service UUID.
        peripheral.discoverServices([TransferService.interactionUUID, TransferService.serviceUUID])
    }

    // Cleans up the local copy of the peripheral after disconnection.
    func centralManager(_ central: CBCentralManager, didDisconnectPeripheral peripheral: CBPeripheral, error: Error?) {
        logger.info("Disconnected from \(peripheral)")
        guard let accessory = accessories[peripheral.identifier] else {
            return
        }
        
        if accessory.available, let didDisconnectHandler = accessoryDisconnectedHandler {
            didDisconnectHandler(accessory)
        }
        
        accessories.removeValue(forKey: peripheral.identifier)
    }

}

// An extention to implement `CBPeripheralDelegate` methods.
extension DataCommunicationChannel: CBPeripheralDelegate {
    
    // Reacts to peripheral services invalidation.
    func peripheral(_ peripheral: CBPeripheral, didModifyServices invalidatedServices: [CBService]) {

        for service in invalidatedServices where service.uuid == TransferService.serviceUUID {
            logger.error("Transfer service is invalidated - rediscover services")
            peripheral.discoverServices([TransferService.serviceUUID])
        }
    }

    // Reacts to peripheral services discovery.
    func peripheral(_ peripheral: CBPeripheral, didDiscoverServices error: Error?) {
        if let error = error {
            logger.error("Error discovering services: \(error.localizedDescription)")
            guard let accessory = accessories[peripheral.identifier] else {
                return
            }
            accessory.cleanup()
            return
        }
        logger.info("discovered service. Now discovering characteristics")
        // Check the newly filled peripheral services array for more services.
        guard let peripheralServices = peripheral.services else { return }
        for service in peripheralServices {
            if service.uuid == TransferService.serviceUUID {
                peripheral.discoverCharacteristics([TransferService.rxCharacteristicUUID, TransferService.txCharacteristicUUID], for: service)
            } else if service.uuid == TransferService.interactionUUID {
                peripheral.discoverCharacteristics([TransferService.accessoryConfigDataUUID], for: service)
            }
        }
    }

    // Subscribes to a discovered characteristic, which lets the peripheral know we want the data it contains.
    func peripheral(_ peripheral: CBPeripheral, didDiscoverCharacteristicsFor service: CBService, error: Error?) {
        let accessory = accessories[peripheral.identifier]!

        // Deal with errors (if any).
        if let error = error {
            logger.error("Error discovering characteristics: \(error.localizedDescription)")
            accessory.cleanup()
            return
        }

        // Check the newly filled peripheral services array for more services.
        guard let serviceCharacteristics = service.characteristics else { return }
        for characteristic in serviceCharacteristics where characteristic.uuid == TransferService.rxCharacteristicUUID {
            // Subscribe to the transfer service's `rxCharacteristic`.
            accessory.rxCharacteristic = characteristic
            logger.info("discovered characteristic: \(characteristic)")
            peripheral.setNotifyValue(true, for: characteristic)
        }

        for characteristic in serviceCharacteristics where characteristic.uuid == TransferService.txCharacteristicUUID {
            // Subscribe to the transfer service's `txCharacteristic`.
            accessory.txCharacteristic = characteristic
            logger.info("discovered characteristic: \(characteristic)")
            peripheral.setNotifyValue(true, for: characteristic)
        }

        for characteristic in serviceCharacteristics where characteristic.uuid == TransferService.accessoryConfigDataUUID {
            logger.info("discovered characteristic: \(characteristic)")
            accessory.backgroundCapable = true
            peripheral.readValue(for: characteristic)
        }
        
        if !accessory.available, accessory.rxCharacteristic != nil, accessory.txCharacteristic != nil {
            accessory.available = true
            if let didConnectHandler = accessoryConnectedHandler {
                didConnectHandler(accessory)
            }
        }
        
        // Wait for the peripheral to send data.
    }

    // Reacts to data arrival through the characteristic notification.
    func peripheral(_ peripheral: CBPeripheral, didUpdateValueFor characteristic: CBCharacteristic, error: Error?) {
        // Check if the peripheral reported an error.
        let accessory = accessories[peripheral.identifier]!

        if let error = error {
            logger.error("Error discovering characteristics:\(error.localizedDescription)")
            accessory.cleanup()
            return
        }
        guard let characteristicData = characteristic.value else { return }
    
        let str = characteristicData.map { String(format: "0x%02x, ", $0) }.joined()
        logger.info("Received \(characteristicData.count) bytes: \(str)")
        
        if let dataHandler = self.accessoryDataHandler {
            dataHandler(accessory, characteristicData)
        }
    }

    // Reacts to the subscription status.
    func peripheral(_ peripheral: CBPeripheral, didUpdateNotificationStateFor characteristic: CBCharacteristic, error: Error?) {
        // Check if the peripheral reported an error.
        if let error = error {
            logger.error("Error changing notification state: \(error.localizedDescription)")
            return
        }

        if characteristic.isNotifying {
            // Indicates the notification began.
            logger.info("Notification began on \(characteristic)")
        } else {
            // Because the notification stopped, disconnect from the peripheral.
            logger.info("Notification stopped on \(characteristic). Disconnecting")
            let accessory = accessories[peripheral.identifier]!
            accessory.cleanup()
        }
    }
}
