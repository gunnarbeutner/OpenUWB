/*
 Copyright © 2023 Gunnar Beutner,
 Copyright © 2022 Apple Inc.

 Permission is hereby granted, free of charge, to any person obtaining a copy of this software and associated documentation files (the "Software"), to deal in the Software without restriction, including without limitation the rights to use, copy, modify, merge, publish, distribute, sublicense, and/or sell copies of the Software, and to permit persons to whom the Software is furnished to do so, subject to the following conditions:

 The above copyright notice and this permission notice shall be included in all copies or substantial portions of the Software.

 THE SOFTWARE IS PROVIDED "AS IS", WITHOUT WARRANTY OF ANY KIND, EXPRESS OR IMPLIED, INCLUDING BUT NOT LIMITED TO THE WARRANTIES OF MERCHANTABILITY, FITNESS FOR A PARTICULAR PURPOSE AND NONINFRINGEMENT. IN NO EVENT SHALL THE AUTHORS OR COPYRIGHT HOLDERS BE LIABLE FOR ANY CLAIM, DAMAGES OR OTHER LIABILITY, WHETHER IN AN ACTION OF CONTRACT, TORT OR OTHERWISE, ARISING FROM, OUT OF OR IN CONNECTION WITH THE SOFTWARE OR THE USE OR OTHER DEALINGS IN THE SOFTWARE.
*/

import os.log
import NearbyInteraction
#if !os(watchOS)
import ARKit
#endif

// An example messaging protocol for communications between the app and the
// accessory. In your app, modify or extend this enumeration to your app's
// user experience and conform the accessory accordingly.
enum MessageId: UInt8 {
    // Messages from the accessory.
    case accessoryConfigurationData = 0x1
    case accessoryUwbDidStart = 0x2
    case accessoryUwbDidStop = 0x3

    // Messages to the accessory.
    case initialize = 0xA
    case configureAndStart = 0xB
    case stop = 0xC
}

public struct UWBManagerOptions {
    public var handleConnectivity: Bool = true
    
#if !os(watchOS)
    @available(iOS 16.0, *)
    public var useCameraAssistance: Bool {
        get {
            return _useCameraAssistance
        }
        set {
            _useCameraAssistance = newValue
        }
    }
    
    private var _useCameraAssistance: Bool = false
#endif

    public init() {
        
    }
}

#if !os(watchOS)
private class UWBManagerARSessionDelegate : NSObject, ARSessionDelegate {
    func sessionShouldAttemptRelocalization(_ session: ARSession) -> Bool {
        return false
    }
}
#endif

public class UWBManager: ObservableObject {
    var dataChannel = DataCommunicationChannel()
    public var delegate: UWBManagerDelegate?
    private var options = UWBManagerOptions()
#if !os(watchOS)
    // XXX: make private
    public var arSession: ARSession?
    private var arSessionDelegate: UWBManagerARSessionDelegate?
#endif
    
    // XXX: get rid of this and let the caller keep references to the accessories?
    public var accessories: [String: UWBAccessory] = [:]

#if !os(watchOS)
    @available(iOS 16.0, *)
    public func setARSession(_ session: ARSession) {
        assert(self.arSession == nil)
        self.arSession = session
    }
#endif
    
    @available(iOS 16, *)
    @available(watchOS 9, *)
    public var convergenceContext: NIAlgorithmConvergence? {
        return _convergenceContext as? NIAlgorithmConvergence
    }
    
    internal var _convergenceContext: Any??
    
    public init() {
        
    }
    
    public func run(options: UWBManagerOptions = UWBManagerOptions()) {
        self.options = options

#if !os(watchOS)
        if #available(iOS 16.0, *), options.useCameraAssistance, self.arSession == nil {
            self.arSession = ARSession()
            let arConfiguration = ARWorldTrackingConfiguration()
            
            self.arSessionDelegate = UWBManagerARSessionDelegate()
            arSession!.delegate = arSessionDelegate
            
            // These are all defaults anyway, at least when tested with iOS 17.0
            arConfiguration.worldAlignment = .gravity
            arConfiguration.isCollaborationEnabled = false
            arConfiguration.userFaceTrackingEnabled = false
            arConfiguration.initialWorldMap = nil
            
            self.arSession!.run(arConfiguration)
        }
#endif

        dataChannel.accessoryDiscoveredHandler = accessoryDiscovered
        dataChannel.accessoryConnectedHandler = accessoryConnected
        dataChannel.accessoryDisconnectedHandler = accessoryDisconnected
        dataChannel.accessoryDataHandler = accessorySharedData
        dataChannel.start()
    }
    
    public func connect(_ accessory: BluetoothAccessory) {
        dataChannel.connect(accessory: accessory)
    }

    public func disconnect(_ accessory: BluetoothAccessory) {
        dataChannel.disconnect(accessory: accessory)
    }
    
#if !os(watchOS)
    @available(iOS 16, *)
    public func worldTransform(for accessory: UWBAccessory) -> simd_float4x4? {
        guard let nearbyObject = accessory.nearbyObject else { return nil }
        return accessory.niSession.worldTransform(for: nearbyObject)
    }
#endif

    // MARK: - Data channel methods
    
    func accessorySharedData(bluetoothAccessory: OpenUWB.BluetoothAccessory, data: Data) {
        // The accessory begins each message with an identifier byte.
        // Ensure the message length is within a valid range.
        if data.count < 1 {
            delegate?.log("Accessory shared data length was less than 1.")
            return
        }
        
        // Assign the first byte which is the message identifier.
        guard let messageId = MessageId(rawValue: data.first!) else {
            fatalError("\(data.first!) is not a valid MessageId.")
        }
        
        // Handle the data portion of the message based on the message identifier.
        switch messageId {
        case .accessoryConfigurationData:
            // Access the message data by skipping the message identifier.
            assert(data.count > 1)
            let message = data.advanced(by: 1)
            guard let accessory = accessories[bluetoothAccessory.publicIdentifier] else { return }
            setupAccessory(accessory: accessory, configData: message)
        case .accessoryUwbDidStart:
            handleAccessoryUwbDidStart()
        case .accessoryUwbDidStop:
            handleAccessoryUwbDidStop()
        case .configureAndStart:
            fatalError("Accessory should not send 'configureAndStart'.")
        case .initialize:
            fatalError("Accessory should not send 'initialize'.")
        case .stop:
            fatalError("Accessory should not send 'stop'.")
        }
    }
    
    func accessoryDiscovered(bluetoothAccessory: BluetoothAccessory, rssi: NSNumber) {
        if options.handleConnectivity {
            connect(bluetoothAccessory)
        }
        delegate?.didDiscover(accessory: bluetoothAccessory, rssi: rssi)
    }
    
    func accessoryConnected(bluetoothAccessory: BluetoothAccessory) {
        delegate?.didConnect(accessory: bluetoothAccessory)
        let accessory = UWBAccessory(manager: self, bluetoothAccessory: bluetoothAccessory)
        accessories[bluetoothAccessory.publicIdentifier] = accessory
        accessory.start()

        delegate?.didUpdateBluetoothState(state: true)
        delegate?.log("Connected to '\(accessory.publicIdentifier)'")
    }
    
    func accessoryFailedToConnect(bluetoothAccessory: BluetoothAccessory) {
        delegate?.didFailToConnect(accessory: bluetoothAccessory)
    }

    func accessoryDisconnected(bluetoothAccessory: BluetoothAccessory) {
        delegate?.didDisconnect(accessory: bluetoothAccessory)
        accessories.removeValue(forKey: bluetoothAccessory.publicIdentifier)
        if accessories.count == 0 {
            delegate?.didUpdateBluetoothState(state: false)
        }
        delegate?.log("Accessory \(bluetoothAccessory.publicIdentifier) disconnected")
    }
    
    // MARK: - Accessory messages handling
    
    func setupAccessory(accessory: UWBAccessory, configData: Data) {
        delegate?.log("Received configuration data from '\(accessory.publicIdentifier)'. Running session.")
        
        do {
            if accessory.bluetoothAccessory.backgroundCapable {
#if os(watchOS)
                accessory.bluetoothAccessory.backgroundCapable = false
#else
                if #available(iOS 16.0, *) {
                    accessory.configuration = try NINearbyAccessoryConfiguration(accessoryData: configData, bluetoothPeerIdentifier: accessory.bluetoothAccessory.peripheral.identifier)
                }
#endif
            }
            if !accessory.bluetoothAccessory.backgroundCapable {
                accessory.configuration = try NINearbyAccessoryConfiguration(data: configData)
            }
        } catch {
            // Stop and display the issue because the incoming data is invalid.
            // In your app, debug the accessory data to ensure an expected
            // format.
            delegate?.log("Failed to create NINearbyAccessoryConfiguration for '\(accessory.publicIdentifier)'. Error: \(error)")
            return
        }

#if !os(watchOS)
        if #available(iOS 16.0, *) {
            accessory.configuration!.isCameraAssistanceEnabled = options.useCameraAssistance
            if let arSession = self.arSession {
                accessory.niSession.setARSession(arSession)
            }
        }
#endif
        
        // Cache the token to correlate updates with this accessory.
        accessory.cacheToken(accessory.configuration!.accessoryDiscoveryToken, identifier: accessory.publicIdentifier)
        accessory.niSession.delegate = accessory
        accessory.niSession.run(accessory.configuration!)
    }
    
    func handleAccessoryUwbDidStart() {
        delegate?.didUpdateUWBState(state: true)
    }
    
    func handleAccessoryUwbDidStop() {
        if accessories.count == 0 {
            delegate?.didUpdateUWBState(state: false)
        }
    }
}

public protocol UWBManagerDelegate {
    func didDiscover(accessory: BluetoothAccessory, rssi: NSNumber)
    func didConnect(accessory: BluetoothAccessory)
    func didDisconnect(accessory: BluetoothAccessory)
    func didFailToConnect(accessory: BluetoothAccessory)

    func didUpdateBluetoothState(state: Bool)
    func didUpdateUWBState(state: Bool)

    func didRequirePermissions()
    func didUpdateAccessory(accessory: UWBAccessory)
    func log(_ message: String)
}

public extension UWBManagerDelegate {
    func didDiscover(accessory: BluetoothAccessory, rssi: NSNumber) { }
    func didConnect(accessory: BluetoothAccessory) { }
    func didDisconnect(accessory: BluetoothAccessory) { }
    func didFailToConnect(accessory: BluetoothAccessory) { }

    func didUpdateBluetoothState(state: Bool) { }
    func didUpdateUWBState(state: Bool) { }
    func didRequirePermissions() { }
    func didUpdateAccessory(accessory: UWBAccessory) { }
    func log(_ message: String) { }
}
