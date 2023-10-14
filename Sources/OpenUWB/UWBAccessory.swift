/*
 Copyright © 2023 Gunnar Beutner,
 Copyright © 2022 Apple Inc.

 Permission is hereby granted, free of charge, to any person obtaining a copy of this software and associated documentation files (the "Software"), to deal in the Software without restriction, including without limitation the rights to use, copy, modify, merge, publish, distribute, sublicense, and/or sell copies of the Software, and to permit persons to whom the Software is furnished to do so, subject to the following conditions:

 The above copyright notice and this permission notice shall be included in all copies or substantial portions of the Software.

 THE SOFTWARE IS PROVIDED "AS IS", WITHOUT WARRANTY OF ANY KIND, EXPRESS OR IMPLIED, INCLUDING BUT NOT LIMITED TO THE WARRANTIES OF MERCHANTABILITY, FITNESS FOR A PARTICULAR PURPOSE AND NONINFRINGEMENT. IN NO EVENT SHALL THE AUTHORS OR COPYRIGHT HOLDERS BE LIABLE FOR ANY CLAIM, DAMAGES OR OTHER LIABILITY, WHETHER IN AN ACTION OF CONTRACT, TORT OR OTHERWISE, ARISING FROM, OUT OF OR IN CONNECTION WITH THE SOFTWARE OR THE USE OR OTHER DEALINGS IN THE SOFTWARE.
*/

import os.log
import NearbyInteraction

public class UWBAccessory: NSObject {
    var manager: UWBManager
    var bluetoothAccessory: BluetoothAccessory
    var niSession = NISession()
    var configuration: NINearbyAccessoryConfiguration?
    
    public var distance: Float?
    
    // A mapping from a discovery token to a name.
    var accessoryMap = [NIDiscoveryToken: String]()
    
    let logger = os.Logger(subsystem: "name.beutner.OpenUWB", category: "UWBAccessory")
    
    init(manager: UWBManager, bluetoothAccessory: BluetoothAccessory) {
        self.manager = manager
        self.bluetoothAccessory = bluetoothAccessory
    }
    
    public var publicIdentifier: String {
        get {
            return bluetoothAccessory.publicIdentifier
        }
    }
    
    public var connected: Bool {
        get {
            return bluetoothAccessory.available
        }
    }
    
    func cacheToken(_ token: NIDiscoveryToken, identifier: String) {
        accessoryMap[token] = identifier
    }
    
    func sendDataToAccessory(_ data: Data) {
        do {
            try bluetoothAccessory.sendData(data)
        } catch {
            manager.delegate.log("Failed to send data to accessory: \(error)")
        }
    }
    
    func handleSessionInvalidation() {
        manager.delegate.log("Session invalidated. Restarting.")
        // Ask the accessory to stop.
        sendDataToAccessory(Data([MessageId.stop.rawValue]))

        // Replace the invalidated session with a new one.
        self.niSession = NISession()

        // Ask the accessory to start.
        sendDataToAccessory(Data([MessageId.initialize.rawValue]))
    }
    
    public func start() {
        sendDataToAccessory(Data([MessageId.initialize.rawValue]))
    }
}

extension UWBAccessory : Identifiable {
    public var id: String {
        get {
            return publicIdentifier
        }
    }
}

// MARK: - `NISessionDelegate`.

extension UWBAccessory: NISessionDelegate {
    public func session(_ session: NISession, didGenerateShareableConfigurationData shareableConfigurationData: Data, for object: NINearbyObject) {
        guard object.discoveryToken == configuration?.accessoryDiscoveryToken else { return }
        
        // Prepare to send a message to the accessory.
        var msg = Data([MessageId.configureAndStart.rawValue])
        msg.append(shareableConfigurationData)
        
        let str = msg.map { String(format: "0x%02x, ", $0) }.joined()
        logger.info("Sending shareable configuration bytes: \(str)")
        
        let accessoryName = accessoryMap[object.discoveryToken] ?? "Unknown"
        
        // Send the message to the accessory.
        sendDataToAccessory(msg)
        manager.delegate.log("Sent shareable configuration data to \(publicIdentifier).")
    }
    
    public func session(_ session: NISession, didUpdate nearbyObjects: [NINearbyObject]) {
        guard let accessory = nearbyObjects.first else { return }
        //guard let distance = accessory.distance else { return }
        //guard let name = accessoryMap[accessory.discoveryToken] else { return }
        
        self.distance = accessory.distance
        manager.delegate.didUpdateAccessory(accessory: self)
    }

    public func session(_ session: NISession, didRemove nearbyObjects: [NINearbyObject], reason: NINearbyObject.RemovalReason) {
        // Retry the session only if the peer timed out.
        guard reason == .timeout else { return }
        manager.delegate.log("Session with \(publicIdentifier) timed out.")
        
        // The session runs with one accessory.
        guard let accessory = nearbyObjects.first else { return }
        
        // Clear the app's accessory state.
        accessoryMap.removeValue(forKey: accessory.discoveryToken)
        
        sendDataToAccessory(Data([MessageId.stop.rawValue]))
        
        DispatchQueue.main.asyncAfter(deadline: .now() + .seconds(5), execute: {
            // TODO: exponential back-off?
            if self.bluetoothAccessory.peripheral.state == .connected {
                self.sendDataToAccessory(Data([MessageId.initialize.rawValue]))
            }
        })
    }
    
    public func sessionWasSuspended(_ session: NISession) {
        manager.delegate.log("Session with \(publicIdentifier) was suspended.")
        sendDataToAccessory(Data([MessageId.stop.rawValue]))
    }
    
    public func sessionSuspensionEnded(_ session: NISession) {
        manager.delegate.log("Session suspension for \(publicIdentifier) ended.")
        // When suspension ends, restart the configuration procedure with the accessory.
        sendDataToAccessory(Data([MessageId.initialize.rawValue]))
    }
    
    public func session(_ session: NISession, didInvalidateWith error: Error) {
        switch error {
        case NIError.invalidConfiguration:
            // Debug the accessory data to ensure an expected format.
            manager.delegate.log("The accessory configuration data is invalid. Please debug it and try again.")
        case NIError.userDidNotAllow:
            manager.delegate.didRequirePermissions()
        default:
            handleSessionInvalidation()
        }
    }
}
