import AppKit
import SwiftUI

@main
struct MyApp: App {
    @State private var settings = AppSettings()
    @State private var engine = IngestEngine()

    init() {
        // Only one window receives the stream, so no extra tabs or windows.
        NSWindow.allowsAutomaticWindowTabbing = false
    }

    var body: some Scene {
        Window("MediaFlowRX", id: "main") {
            ContentView()
                .environment(settings)
                .environment(engine)
        }
        .defaultSize(width: 1280, height: 720)
        .commands {
            CommandMenu("Recording") {
                Button("Start or stop recording") {
                    engine.toggleRecording()
                }
                .keyboardShortcut("r", modifiers: .command)

                Button("Mute or unmute audio") {
                    engine.muted.toggle()
                }
                .keyboardShortcut("m", modifiers: [.command, .shift])
            }
        }
        Settings {
            PreferencesView()
                .environment(settings)
                .environment(engine)
        }
    }
}
