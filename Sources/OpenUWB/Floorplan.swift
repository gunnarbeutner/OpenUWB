/*
 Copyright © 2023 Gunnar Beutner.

 Permission is hereby granted, free of charge, to any person obtaining a copy of this software and associated documentation files (the "Software"), to deal in the Software without restriction, including without limitation the rights to use, copy, modify, merge, publish, distribute, sublicense, and/or sell copies of the Software, and to permit persons to whom the Software is furnished to do so, subject to the following conditions:

 The above copyright notice and this permission notice shall be included in all copies or substantial portions of the Software.

 THE SOFTWARE IS PROVIDED "AS IS", WITHOUT WARRANTY OF ANY KIND, EXPRESS OR IMPLIED, INCLUDING BUT NOT LIMITED TO THE WARRANTIES OF MERCHANTABILITY, FITNESS FOR A PARTICULAR PURPOSE AND NONINFRINGEMENT. IN NO EVENT SHALL THE AUTHORS OR COPYRIGHT HOLDERS BE LIABLE FOR ANY CLAIM, DAMAGES OR OTHER LIABILITY, WHETHER IN AN ACTION OF CONTRACT, TORT OR OTHERWISE, ARISING FROM, OUT OF OR IN CONNECTION WITH THE SOFTWARE OR THE USE OR OTHER DEALINGS IN THE SOFTWARE.
*/

import Combine
import Foundation
import Yams
import CoreGraphics

/*struct Point2D: Codable {
    var x: Float
    var y: Float
}

struct Point3D: Codable {
    var x: Float
    var y: Float
    var z: Float
}*/

public struct Room: Codable {
    public var name: String
    public var points: [[Double]]
}

public struct Floor: Codable {
    public var id: String
    public var name: String
    public var bounds: [[Double]]
    public var rooms: [Room]
}

public struct Accessory: Codable {
    public var id: String
    public var location: [Double]
    public var exact: Bool
}

public struct Floorplan: Codable {
    public var floors: [Floor]
    public var accessories: [Accessory]
}

public func loadFloorplan(_ data: Data) -> Floorplan {
    let decoder = YAMLDecoder()
    return try! decoder.decode(Floorplan.self, from: data)
}
