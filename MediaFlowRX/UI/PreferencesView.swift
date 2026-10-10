import AppKit
import SwiftUI

struct PreferencesView: View {
    @Environment(AppSettings.self) private var settings
    @Environment(IngestEngine.self) private var engine

    @State private var draft = SettingsDraft()
    @State private var hosts = PublishLine.localHosts()
    @State private var language = AppLanguage.stored

    private var current: SettingsDraft { draft.normalized }
    private var dirty: Bool { current != settings.draft }
    private var issue: String? { current.validationError }
    private var listenerChanged: Bool { current.connection != settings.connection }

    var body: some View {
        VStack(spacing: 0) {
            TabView {
                generalTab
                    .tabItem { Label("General", systemImage: "gearshape") }
                serverTab
                    .tabItem { Label("Server", systemImage: "server.rack") }
                credentialsTab
                    .tabItem { Label("Credentials", systemImage: "key.horizontal") }
                recordingTab
                    .tabItem { Label("Recording", systemImage: "record.circle") }
            }
            footer
        }
        .frame(width: 640)
        .fixedSize(horizontal: false, vertical: true)
        .onAppear {
            draft = settings.draft
            hosts = PublishLine.localHosts()
            language = AppLanguage.stored
        }
        .onChange(of: language) { _, newValue in
            newValue.save()
        }
    }

    // MARK: - General

    private var generalTab: some View {
        Form {
            Section {
                Picker("Language", selection: $language) {
                    Text("System").tag(AppLanguage.system)
                    Text("Italian").tag(AppLanguage.italian)
                    Text("English").tag(AppLanguage.english)
                }
                if language.needsRelaunch {
                    Button("Relaunch") {
                        language.relaunch()
                    }
                }
            } header: {
                Text("Language")
            } footer: {
                Text("The language applies the next time the app opens.")
            }
        }
        .formStyle(.grouped)
    }

    // MARK: - Server

    private var serverTab: some View {
        let connection = current.connection
        let kind = connection.kind
        return Form {
            Section {
                Picker("Protocol", selection: $draft.connection.kind) {
                    ForEach(IngestKind.allCases) { item in
                        Text(item.title).tag(item)
                    }
                }
                .pickerStyle(.segmented)
                .labelsHidden()
            } header: {
                Text("Protocol")
            } footer: {
                Text(kind.summary)
            }

            Section {
                LabeledContent("Port \(kind.title)") {
                    HStack(spacing: 8) {
                        TextField("Port", value: portBinding, format: .number.grouping(.never))
                            .labelsHidden()
                            .multilineTextAlignment(.trailing)
                            .frame(width: 80)
                        Stepper("Port", value: portBinding, in: 1...65535)
                            .labelsHidden()
                        Button("Default") {
                            portBinding.wrappedValue = kind.defaultPort
                        }
                        .disabled(connection.activePort == kind.defaultPort)
                    }
                }
                if !ConnectionConfig.isPort(connection.activePort) {
                    Label("Between 1 and 65535", systemImage: "exclamationmark.circle.fill")
                        .font(.caption)
                        .foregroundStyle(.red)
                } else if connection.activePort < 1024 {
                    Label("Ports below 1024 require an administrator", systemImage: "exclamationmark.triangle.fill")
                        .font(.caption)
                        .foregroundStyle(.orange)
                }
            } header: {
                Text("Port")
            }

            Section {
                ForEach(PublishLine.make(connection, hosts: hosts)) { line in
                    CopyRow(line: line)
                        .listRowInsets(EdgeInsets(top: 4, leading: 8, bottom: 4, trailing: 8))
                }
            } header: {
                Text("Paste into the encoder")
            }
        }
        .formStyle(.grouped)
    }

    // MARK: - Credentials

    private var credentialsTab: some View {
        Form {
            Section {
                TextField("Slug", text: $draft.connection.slug, prompt: Text("live"))
                if !ConnectionConfig.isToken(current.connection.slug) {
                    fieldError
                }
                TextField("Key", text: $draft.connection.streamKey, prompt: Text("stream"))
                if !ConnectionConfig.isToken(current.connection.streamKey) {
                    fieldError
                }
            } header: {
                Text("Path")
            } footer: {
                Text("Slug and key identify the stream. Allowed: letters, numbers, dot, hyphen and underscore. One encoder at a time.")
            }

            Section {
                TextField("User", text: $draft.connection.username, prompt: Text("optional"))
                SecureField("Password", text: $draft.connection.password, prompt: Text("optional"))
            } header: {
                Text("Authentication")
            } footer: {
                Text(draft.connection.kind.credentialsHint)
            }
        }
        .formStyle(.grouped)
    }

    private var fieldError: some View {
        Label("Invalid characters", systemImage: "exclamationmark.circle.fill")
            .font(.caption)
            .foregroundStyle(.red)
    }

    // MARK: - Recording

    private var recordingTab: some View {
        Form {
            Section {
                Toggle("Start recording when the signal arrives", isOn: $draft.autoRecord)
            } header: {
                Text("Start")
            } footer: {
                Text("When the stream is live, the file starts on its own. Record and Stop stay available in the main window.")
            }

            Section {
                LabeledContent("Tolerance") {
                    Text("\(draft.graceSeconds) s")
                        .monospacedDigit()
                }
                Slider(value: graceBinding, in: 1...120, step: 1) {
                    Text("Tolerance")
                } minimumValueLabel: {
                    Text("1 s").font(.caption)
                } maximumValueLabel: {
                    Text("120 s").font(.caption)
                }
                .labelsHidden()
            } header: {
                Text("Interruptions")
            } footer: {
                Text("If the encoder drops, the file stays open for this long. If it returns in time, recording continues.")
            }

            Section {
                HStack(spacing: 10) {
                    Image(systemName: "folder.fill")
                        .foregroundStyle(.secondary)
                    Text(draft.folderPath)
                        .lineLimit(1)
                        .truncationMode(.middle)
                    Spacer(minLength: 0)
                    Button {
                        NSWorkspace.shared.open(URL(fileURLWithPath: draft.folderPath, isDirectory: true))
                    } label: {
                        Image(systemName: "arrow.up.forward.app")
                    }
                    .help("Show in Finder")
                    Button("Choose…") {
                        chooseFolder()
                    }
                }
            } header: {
                Text("Folder")
            }
        }
        .formStyle(.grouped)
    }

    // MARK: - Footer

    private var footer: some View {
        HStack(spacing: 12) {
            if let issue {
                Label(issue, systemImage: "exclamationmark.triangle.fill")
                    .foregroundStyle(.red)
            } else if dirty, listenerChanged, engine.hasSource {
                Label("The current stream will be interrupted", systemImage: "exclamationmark.triangle")
                    .foregroundStyle(.orange)
            } else if dirty {
                Label("Changes not applied yet", systemImage: "circle.fill")
                    .foregroundStyle(.secondary)
            } else {
                Label("All applied", systemImage: "checkmark.circle")
                    .foregroundStyle(.secondary)
            }
            Spacer(minLength: 0)
            Button("Defaults") {
                resetToDefaults()
            }
            Button("Cancel") {
                draft = settings.draft
            }
            .disabled(!dirty)
            Button("Apply") {
                apply()
            }
            .keyboardShortcut(.defaultAction)
            .buttonStyle(.borderedProminent)
            .disabled(!dirty || issue != nil)
        }
        .font(.callout)
        .labelStyle(.titleAndIcon)
        .padding(.horizontal, 20)
        .padding(.vertical, 12)
        .background(.bar)
    }

    // MARK: - Bindings and actions

    private var portBinding: Binding<Int> {
        Binding(
            get: { draft.connection.activePort },
            set: { draft.connection.activePort = $0 }
        )
    }

    private var graceBinding: Binding<Double> {
        Binding(
            get: { Double(draft.graceSeconds) },
            set: { draft.graceSeconds = Int($0.rounded()) }
        )
    }

    private func apply() {
        let previous = settings.draft
        let next = current
        guard next.validationError == nil else { return }
        settings.apply(next)
        draft = next

        // Changing the protocol, ports or credentials restarts listening.
        // The rest (recording, folder, grace) applies without touching the stream.
        if next.connection != previous.connection {
            engine.apply(settings)
            return
        }
        if next.graceSeconds != previous.graceSeconds {
            engine.updateGrace(next.graceSeconds)
        }
        if next.folderPath != previous.folderPath {
            engine.updateFolder(next.folderPath)
        }
        if next.autoRecord != previous.autoRecord {
            engine.updateAutoRecord(next.autoRecord)
        }
    }

    private func resetToDefaults() {
        var fresh = SettingsDraft()
        fresh.folderPath = draft.folderPath
        draft = fresh
    }

    private func chooseFolder() {
        let panel = NSOpenPanel()
        panel.canChooseDirectories = true
        panel.canChooseFiles = false
        panel.canCreateDirectories = true
        panel.prompt = String(localized: "Choose")
        panel.directoryURL = URL(fileURLWithPath: draft.folderPath, isDirectory: true)
        guard panel.runModal() == .OK, let url = panel.url else { return }
        draft.folderPath = url.path
    }
}

private extension IngestKind {
    var summary: String {
        switch self {
        case .rtmp: String(localized: "The most common choice: OBS and most encoders. One stream at a time.")
        case .srt: String(localized: "More tolerant of unstable networks. Slug and key travel in the streamid, without encryption.")
        case .rtsp: String(localized: "For encoders that publish over RTSP. OBS does not publish RTSP.")
        }
    }

    var credentialsHint: String {
        switch self {
        case .rtmp: String(localized: "On RTMP they are added to the stream key. Optional: when both are empty, the slug and key are enough.")
        case .srt: String(localized: "On SRT they are added to the streamid. Optional: when both are empty, the slug and key are enough.")
        case .rtsp: String(localized: "On RTSP they are added to the URL query. Optional: when both are empty, the slug and key are enough.")
        }
    }
}
