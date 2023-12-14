/*
 Copyright © 2023 Gunnar Beutner.

 Permission is hereby granted, free of charge, to any person obtaining a copy of this software and associated documentation files (the "Software"), to deal in the Software without restriction, including without limitation the rights to use, copy, modify, merge, publish, distribute, sublicense, and/or sell copies of the Software, and to permit persons to whom the Software is furnished to do so, subject to the following conditions:

 The above copyright notice and this permission notice shall be included in all copies or substantial portions of the Software.

 THE SOFTWARE IS PROVIDED "AS IS", WITHOUT WARRANTY OF ANY KIND, EXPRESS OR IMPLIED, INCLUDING BUT NOT LIMITED TO THE WARRANTIES OF MERCHANTABILITY, FITNESS FOR A PARTICULAR PURPOSE AND NONINFRINGEMENT. IN NO EVENT SHALL THE AUTHORS OR COPYRIGHT HOLDERS BE LIABLE FOR ANY CLAIM, DAMAGES OR OTHER LIABILITY, WHETHER IN AN ACTION OF CONTRACT, TORT OR OTHERWISE, ARISING FROM, OUT OF OR IN CONNECTION WITH THE SOFTWARE OR THE USE OR OTHER DEALINGS IN THE SOFTWARE.
*/

import MQTTNIO
import NIOCore
import Foundation

public struct DeviceMessage: Decodable {
    var id: String
    var name: String
    /*var disc: String*/
    var idType: Int
    /* var rssi@1m: Int */
    var rssi: Int
    var raw: Float
    var chn: Int
    var distance: Float
    var mac: String
    var int: Int
}

public struct Measurement {
    public var distance: Float
    public var chn: Int
    public var rssi: Int
    public var timestamp: Date
}

public class ESPresenseManager {
    private var mqttClient: MQTTClient
    @Published public var measurements: [String: Measurement] = [:]
    public var delegate: ESPresenseManagerDelegate?
    private var accessoryName: String?

    public init(host: String, port: Int? = nil, identifier: String, username: String, password: String) {
        mqttClient = MQTTClient(
            host: host,
            port: port,
            identifier: identifier,
            eventLoopGroupProvider: .createNew,
            configuration: MQTTClient.Configuration(
                userName: username,
                password: password
            )
        )
    }
    
    public func run(accessoryName: String) async {
        do {
            try await mqttClient.connect()
            print("Successfully connected")
        } catch {
            print("Error while connecting \(error)")
        }
        self.accessoryName = accessoryName
        let subscription = MQTTSubscribeInfo(topicFilter: "espresense/devices/\(accessoryName)/#", qos: .atLeastOnce)
        do {
            _ = try await mqttClient.subscribe(to: [subscription])
        } catch {
            print("Failed to subscribe")
            return
        }
        let listener = mqttClient.createPublishListener()
        for await result in listener {
            switch result {
            case .success(let publish):
                let tokens = publish.topicName.components(separatedBy: "/")
                let nodeName = tokens[3]
                guard let message = try? JSONDecoder().decode(DeviceMessage.self, from: publish.payload) else { continue }
                var measurement = Measurement(distance: message.distance, chn: message.chn, rssi: message.rssi, timestamp: Date.now)
                measurements[nodeName] = measurement
                delegate?.didUpdateAccessory(node: nodeName, measurement: measurement)
            case .failure(let error):
                print("Error while receiving PUBLISH event")
            }
        }
    }
    
    public func sendLocation<T>(_ location: T) where T : Encodable {
        do {
            let json = try JSONEncoder().encode(location)
            let data = ByteBuffer(data: json)
            mqttClient.publish(to: "openuwb/data", payload: data, qos: MQTTQoS.atLeastOnce)
        } catch {
            print(error)
        }
    }
}

public protocol ESPresenseManagerDelegate {
    func didUpdateAccessory(node: String, measurement: Measurement)
}
