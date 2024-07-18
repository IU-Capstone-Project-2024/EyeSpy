//
//  User.swift
//  EyeSpy
//
//  Created by Aleksandr Strizhnev on 18.07.2024.
//

struct Vector: Codable {
    var x: Double
    var y: Double
}

struct User: Codable {
    var deviceId: String
    var name: String
    var gaze: Vector
    var isCheating: Bool
    
    enum CodingKeys: String, CodingKey {
        case deviceId = "device_id"
        case name
        case gaze
        case isCheating = "is_cheating"
    }
}
