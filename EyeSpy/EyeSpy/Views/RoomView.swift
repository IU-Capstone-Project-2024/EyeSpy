//
//  RoomView.swift
//  EyeSpy
//
//  Created by Aleksandr Strizhnev on 18.07.2024.
//

import SwiftUI

func getSystemUUID() -> String? {
    let platformExpert = IOServiceGetMatchingService(
        kIOMainPortDefault,
        IOServiceMatching("IOPlatformExpertDevice")
    )
    guard platformExpert != 0 else { return nil }
    defer { IOObjectRelease(platformExpert) }
    
    return IORegistryEntryCreateCFProperty(
        platformExpert,
        kIOPlatformUUIDKey as CFString,
        kCFAllocatorDefault,
        0
    ).takeUnretainedValue() as? String
}

class WebsocketManager: ObservableObject {
    static let shared = WebsocketManager()
    private init() {}
    
    @Published var isConnected = false
    var user: User? {
        didSet {
            guard let webSocketTask else {
                return
            }
            
            let userMessage = URLSessionWebSocketTask.Message.data(
                try! jsonEncoder.encode(user)
            )
            Task {
                try? await webSocketTask.send(userMessage)
            }
        }
    }
    
    private var webSocketTask: URLSessionWebSocketTask?
    private var jsonEncoder: JSONEncoder = .init()
    
    func connect(roomId: String, name: String) {
        print(URL(string: "ws://127.0.0.1:8000/ws/rooms/\(roomId)/client")!)
        self.webSocketTask = URLSession.shared.webSocketTask(
            with: URL(string: "ws://127.0.0.1:8000/ws/rooms/\(roomId)/client")!
        )
        
        webSocketTask?.resume()
        webSocketTask?.receive { result in
            if case .failure(let failure) = result {
                print(failure.localizedDescription)
            }
        }
        isConnected = true
        
        user = User(
            deviceId: getSystemUUID() ?? "err",
            name: name,
            gaze: .init(x: 0, y: 0),
            isCheating: false
        )
    }
}

struct RoomView: View {
    @State private var roomId = ""
    @State private var name = ""
    
    @StateObject private var websocketManager = WebsocketManager.shared
    
    var body: some View {
        if websocketManager.isConnected {
            LandmarksView()
                .environmentObject(websocketManager)
        } else {
            VStack {
                Text("Join EyeSpy Room")
                    .font(.headline)
                
                Group {
                    TextField("Room Id", text: $roomId)
                    
                    TextField("Name", text: $name)
                }
                .textFieldStyle(.roundedBorder)
                
                Button(action: {
                    websocketManager.connect(roomId: roomId, name: name)
                }) {
                    Text("Join")
                        .padding(5)
                }
            }
            .padding()
        }
    }
}

#Preview {
    RoomView()
}
