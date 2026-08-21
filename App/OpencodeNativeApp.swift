import SwiftUI
import OpencodeNativeCore

@main
public struct OpencodeNativeApp: App {
    public init() {}
    
    public var body: some Scene {
        WindowGroup {
            ConsoleView()
        }
    }
}