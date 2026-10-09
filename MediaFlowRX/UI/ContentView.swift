import AppKit
import SwiftUI

struct ContentView: View {
    @Environment(AppSettings.self) private var settings
    @Environment(IngestEngine.self) private var engine
    @State private var infoExpanded = true
    @State private var streamInfoExpanded = false
    @State private var chromeVisible = true
    @State private var hideTask: Task<Void, Never>?
    @State private var hosts = PublishLine.localHosts()

    var body: some View {
        ZStack {
            VideoCanvas(player: engine.preview)
                .background(.black)
            if engine.phase == .listening {
                waitingState
                    .allowsHitTesting(false)
            }
            if chromeVisible {
                VStack(spacing: 10) {
                    Spacer(minLength: 0)
                    if infoExpanded {
                        publishPanel
                            .transition(.opacity.combined(with: .move(edge: .bottom)))
                    }
                    if streamInfoExpanded {
                        streamPanel
                            .transition(.opacity.combined(with: .move(edge: .bottom)))
                    }
                    controlBar
                }
                .padding(16)
                .transition(.opacity)
            }
        }
        .background(.black)
        .frame(minWidth: 960, minHeight: 540)
        .animation(.easeInOut(duration: 0.2), value: chromeVisible)
        .animation(.snappy(duration: 0.25), value: infoExpanded)
        .animation(.snappy(duration: 0.25), value: streamInfoExpanded)
        .onHover { inside in
            if inside {
                revealChrome()
            } else {
                scheduleHide()
            }
        }
        .onReceive(NotificationCenter.default.publisher(for: NSApplication.didBecomeActiveNotification)) { _ in
            hosts = PublishLine.localHosts()
        }
        .onAppear {
            engine.start(settings)
            scheduleHide()
        }
    }

    // MARK: - Control visibility

    private func revealChrome() {
        hideTask?.cancel()
        hideTask = nil
        chromeVisible = true
    }

    private func scheduleHide() {
        hideTask?.cancel()
        hideTask = Task { @MainActor in
            try? await Task.sleep(for: .seconds(2))
            guard !Task.isCancelled else { return }
            chromeVisible = false
        }
    }

    // MARK: - Layout

    private var publishLines: [PublishLine] {
        PublishLine.make(settings.connection, hosts: hosts)
    }

    private var waitingState: some View {
        VStack(spacing: 10) {
            Image(systemName: engine.listenError == nil ? "antenna.radiowaves.left.and.right" : "exclamationmark.triangle.fill")
                .font(.system(size: 40, weight: .light))
            Text(engine.listenError ?? String(localized: "Waiting for the encoder"))
                .font(.title3.weight(.semibold))
                .multilineTextAlignment(.center)
            if engine.listenError == nil {
                Text("Point the encoder at the address in the bar below")
                    .font(.callout)
                    .foregroundStyle(.white.opacity(0.6))
            }
        }
        .foregroundStyle(engine.listenError == nil ? Color.white.opacity(0.85) : Color.red)
        .padding(24)
    }

    private var publishPanel: some View {
        VStack(alignment: .leading, spacing: 8) {
            ForEach(publishLines) { line in
                CopyRow(line: line)
            }
            Text("Click a value to copy it")
                .font(AppStyle.hint)
                .foregroundStyle(.white.opacity(0.55))
        }
        .padding(12)
        .frame(maxWidth: 900)
        .environment(\.colorScheme, .dark)
        .overlayCard()
    }

    private var controlBar: some View {
        HStack(spacing: 14) {
            Button {
                infoExpanded.toggle()
            } label: {
                HStack(spacing: 6) {
                    Image(systemName: "dot.radiowaves.left.and.right")
                    Text("Publish")
                    Image(systemName: "chevron.up")
                        .font(.caption.weight(.bold))
                        .rotationEffect(.degrees(infoExpanded ? 0 : 180))
                }
                .font(.subheadline.weight(.semibold))
            }
            .buttonStyle(.plain)
            .foregroundStyle(infoExpanded ? Color.white : Color.white.opacity(0.7))
            .help(LocalizedStringKey(infoExpanded ? "Hide addresses" : "Show addresses for the encoder"))

            Button {
                streamInfoExpanded.toggle()
            } label: {
                HStack(spacing: 6) {
                    Image(systemName: "info.circle")
                    Text("Info")
                    Image(systemName: "chevron.up")
                        .font(.caption.weight(.bold))
                        .rotationEffect(.degrees(streamInfoExpanded ? 0 : 180))
                }
                .font(.subheadline.weight(.semibold))
            }
            .buttonStyle(.plain)
            .foregroundStyle(streamInfoExpanded ? Color.white : Color.white.opacity(0.7))
            .help(LocalizedStringKey(streamInfoExpanded ? "Hide stream details" : "Incoming video and audio details"))

            Divider().frame(height: 20)

            HStack(spacing: 8) {
                Circle()
                    .fill(engine.indicatorColor)
                    .frame(width: 9, height: 9)
                    .shadow(color: engine.indicatorColor.opacity(0.9), radius: engine.isRecording ? 5 : 0)
                Text(engine.statusText)
                    .font(.subheadline.weight(.semibold))
                    .lineLimit(1)
                if let since = engine.recordingSince {
                    TimelineView(.periodic(from: since, by: 1)) { context in
                        Text(elapsedText(from: since, to: context.date))
                            .font(.subheadline.monospacedDigit())
                            .foregroundStyle(.secondary)
                    }
                }
            }
            .layoutPriority(1)

            if let name = engine.lastFileName {
                Text(name)
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
                    .truncationMode(.middle)
            }

            Spacer(minLength: 0)

            Button {
                engine.muted.toggle()
            } label: {
                Label(
                    LocalizedStringKey(engine.muted ? "Unmute" : "Mute"),
                    systemImage: engine.muted ? "speaker.slash.fill" : "speaker.wave.2.fill"
                )
            }
            .tint(engine.muted ? .orange : .white)
            .help(LocalizedStringKey(engine.muted ? "Unmute audio (⇧⌘M)" : "Mute audio (⇧⌘M)"))

            Button {
                engine.toggleRecording()
            } label: {
                Label(
                    LocalizedStringKey(engine.isRecording ? "Stop" : "Record"),
                    systemImage: engine.isRecording ? "stop.fill" : "record.circle"
                )
            }
            .buttonStyle(.borderedProminent)
            .tint(.red)
            .disabled(!engine.recordEnabled)
            .help(LocalizedStringKey(engine.recordEnabled ? "Start or stop recording (⌘R)" : "Available when a stream is coming in"))
        }
        .labelStyle(.titleAndIcon)
        .controlSize(.large)
        .environment(\.colorScheme, .dark)
        .padding(.horizontal, 16)
        .padding(.vertical, 10)
        .frame(maxWidth: 900)
        .overlayCard(Capsule())
    }

    private var streamPanel: some View {
        let info = engine.streamInfo
        return HStack(alignment: .top, spacing: 20) {
            streamColumn(String(localized: "Video")) {
                infoRow(String(localized: "Codec"), info.videoCodec.isEmpty ? "—" : info.videoCodec)
                infoRow(String(localized: "Profile"), info.videoProfile.isEmpty ? "—" : info.videoProfile)
                infoRow(String(localized: "Resolution"), info.width > 0 && info.height > 0 ? "\(info.width) × \(info.height)" : "—")
                infoRow(String(localized: "Frame rate"), info.fps > 0 ? String(localized: "\(info.fps) fps") : "—")
                infoRow(String(localized: "Bitrate"), bitrateText(info.videoBitrateKbps))
                infoRow(String(localized: "GOP"), gopText(info.gopMs, frames: info.gopFrames))
            }
            columnDivider
            streamColumn(String(localized: "Audio")) {
                infoRow(String(localized: "Codec"), info.audioCodec.isEmpty ? "—" : info.audioCodec)
                infoRow(String(localized: "Sample rate"), sampleRateText(info.sampleRate))
                infoRow(String(localized: "Channels"), channelText(info.channels))
                infoRow(String(localized: "Bit depth"), info.sampleBits > 0 ? String(localized: "\(info.sampleBits) bit") : "—")
                infoRow(String(localized: "Bitrate"), bitrateText(info.audioBitrateKbps))
                GridRow {
                    infoLabel(String(localized: "Level"))
                    AudioMeter(player: engine.preview, active: !info.audioCodec.isEmpty)
                }
            }
            columnDivider
            streamColumn(String(localized: "Source")) {
                infoRow(String(localized: "Encoder"), info.publisher.isEmpty ? "—" : info.publisher)
                infoRow(String(localized: "Path"), info.path.isEmpty ? "—" : info.path)
                GridRow {
                    infoLabel(String(localized: "Connected for"))
                    if let since = info.connectedSince {
                        TimelineView(.periodic(from: since, by: 1)) { context in
                            infoValue(elapsedText(from: since, to: context.date))
                        }
                    } else {
                        infoValue("—")
                    }
                }
                infoRow(String(localized: "Received"), info.totalBytes > 0 ? byteText(Int64(info.totalBytes)) : "—")
                infoRow(String(localized: "Video gaps"), info.hasMedia ? "\(info.videoGaps)" : "—")
                infoRow(String(localized: "Jitter"), info.hasMedia ? "\(info.jitterMs) ms" : "—")
                if let bytes = info.recordingBytes {
                    infoRow(String(localized: "Recording file"), byteText(bytes))
                }
            }
        }
        .padding(.horizontal, 14)
        .padding(.vertical, 12)
        .fixedSize()
        .environment(\.colorScheme, .dark)
        .overlayCard()
    }

    private var columnDivider: some View {
        Rectangle()
            .fill(Color.white.opacity(0.16))
            .frame(width: 1)
    }

    private func streamColumn<Rows: View>(_ title: String, @ViewBuilder rows: () -> Rows) -> some View {
        Grid(alignment: .leading, horizontalSpacing: 12, verticalSpacing: 6) {
            GridRow {
                Text(title)
                    .font(AppStyle.sectionTitle)
                    .foregroundStyle(.white)
                    .gridCellColumns(2)
            }
            rows()
        }
    }

    private func infoRow(_ label: String, _ value: String) -> some View {
        GridRow {
            infoLabel(label)
            infoValue(value)
        }
    }

    private func infoLabel(_ text: String) -> some View {
        Text(text)
            .font(AppStyle.label)
            .foregroundStyle(.white.opacity(0.55))
    }

    private func infoValue(_ text: String) -> some View {
        Text(text)
            .font(AppStyle.value)
            .foregroundStyle(.white)
            .lineLimit(1)
    }

    private func byteText(_ bytes: Int64) -> String {
        bytes.formatted(.byteCount(style: .file))
    }

    private func bitrateText(_ kbps: Int) -> String {
        guard kbps > 0 else { return "—" }
        if kbps >= 1000 {
            let value = (Double(kbps) / 1000).formatted(.number.precision(.fractionLength(1)))
            return "\(value) Mb/s"
        }
        return "\(kbps) kb/s"
    }

    private func sampleRateText(_ rate: Int) -> String {
        guard rate > 0 else { return "—" }
        if rate.isMultiple(of: 1000) {
            return "\(rate / 1000) kHz"
        }
        return "\(rate) Hz"
    }

    private func channelText(_ channels: Int) -> String {
        switch channels {
        case 0: "—"
        case 1: String(localized: "Mono")
        case 2: String(localized: "Stereo")
        default: String(localized: "\(channels) channels")
        }
    }

    private func gopText(_ ms: Int, frames: Int) -> String {
        guard ms > 0 else { return "—" }
        let time: String
        if ms >= 1000 {
            let value = (Double(ms) / 1000).formatted(.number.precision(.fractionLength(1)))
            time = "\(value) s"
        } else {
            time = "\(ms) ms"
        }
        guard frames > 0 else { return time }
        return "\(time) · " + String(localized: "\(frames) frames")
    }

    private func elapsedText(from start: Date, to now: Date) -> String {
        let total = max(0, Int(now.timeIntervalSince(start)))
        let hours = total / 3600
        let minutes = (total % 3600) / 60
        let seconds = total % 60
        return hours > 0
            ? String(format: "%d:%02d:%02d", hours, minutes, seconds)
            : String(format: "%02d:%02d", minutes, seconds)
    }
}

extension IngestEngine {
    var indicatorColor: Color {
        if phase == .listening, listenError != nil { return .red }
        switch phase {
        case .listening: return .gray
        case .live: return isRecording ? .red : .green
        case .interrupted: return .orange
        }
    }
}
