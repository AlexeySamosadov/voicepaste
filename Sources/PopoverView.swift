import SwiftUI

struct PopoverView: View {
    @ObservedObject var store: VoiceStore
    @State private var showEnrollment: Bool = false

    var body: some View {
        // Top edge of the popover is anchored to the status-item bottom by
        // AppKit. To keep that anchor stable, we MUST give the SwiftUI content
        // a fixed maximum height — otherwise NSPopover sizes itself to the
        // intrinsic content height and AppKit flips/shifts the anchor when the
        // content overflows the screen below the menu bar. The long sections
        // (failed / history / voice profiles) live inside a ScrollView so the
        // outer popover frame stays bounded as content grows.
        VStack(alignment: .leading, spacing: 0) {
            // Pinned top: header + controls + live meters never scroll.
            VStack(alignment: .leading, spacing: 14) {
                headerSection
                Divider()
                controlSection

                if store.state == .recording {
                    levelSection
                }

                if store.state == .processing {
                    HStack(spacing: 8) {
                        ProgressView()
                            .controlSize(.small)
                        Text("Transcribing...")
                            .foregroundColor(.secondary)
                    }
                }

                if let error = store.lastError {
                    HStack(spacing: 6) {
                        Image(systemName: "exclamationmark.triangle.fill")
                            .foregroundColor(.red)
                        Text(error)
                            .font(.caption)
                            .foregroundColor(.red)
                            .lineLimit(2)
                    }
                }
            }
            .padding(.horizontal, 16)
            .padding(.top, 16)

            // Scrolling middle: failed / history / voice profiles. Whatever
            // overflows the maxHeight scrolls inside this region instead of
            // pushing the popover taller.
            ScrollView(.vertical, showsIndicators: true) {
                VStack(alignment: .leading, spacing: 14) {
                    if !store.failedRecordings.isEmpty {
                        Divider()
                        failedSection
                    }

                    if !store.history.isEmpty {
                        Divider()
                        historySection
                    }

                    Divider()
                    voiceProfilesSection
                }
                .padding(.horizontal, 16)
                .padding(.top, 14)
            }

            // Pinned bottom: hotkey hint + Config / Quit.
            VStack(alignment: .leading, spacing: 14) {
                Divider()
                footerSection
            }
            .padding(.horizontal, 16)
            .padding(.bottom, 16)
        }
        .frame(width: 340, height: 560)
    }

    // MARK: - Header

    private var headerSection: some View {
        HStack {
            Image(systemName: "mic.fill")
                .font(.title2)
                .foregroundColor(store.state == .recording ? .red : .accentColor)
            Text("VoicePaste")
                .font(.headline)
            Spacer()
            statusBadge
        }
    }

    private var statusBadge: some View {
        HStack(spacing: 4) {
            Circle()
                .fill(statusColor)
                .frame(width: 8, height: 8)
            Text(statusText)
                .font(.caption)
                .foregroundColor(.secondary)
        }
    }

    private var statusColor: Color {
        switch store.state {
        case .idle: return .green
        case .recording: return .red
        case .processing: return .orange
        }
    }

    private var statusText: String {
        switch store.state {
        case .idle: return "Ready"
        case .recording: return "REC \(store.formatDuration(store.recordingDuration))"
        case .processing: return "Processing"
        }
    }

    // MARK: - Controls

    private var controlSection: some View {
        Button(action: { store.toggle() }) {
            HStack {
                Spacer()
                Image(systemName: store.state == .recording ? "stop.circle.fill" : "record.circle")
                    .font(.title3)
                Text(store.state == .recording ? "Stop Recording" : "Start Recording")
                    .font(.system(.body, weight: .medium))
                Spacer()
            }
            .padding(.vertical, 8)
            .background(
                RoundedRectangle(cornerRadius: 8)
                    .fill(store.state == .recording ? Color.red.opacity(0.15) : Color.accentColor.opacity(0.1))
            )
        }
        .buttonStyle(.plain)
        .disabled(store.state == .processing)
    }

    // MARK: - Level & Silence

    private var levelSection: some View {
        VStack(alignment: .leading, spacing: 8) {
            VStack(alignment: .leading, spacing: 4) {
                HStack {
                    Text("Level")
                        .font(.caption)
                        .foregroundColor(.secondary)
                    Spacer()
                    Text(String(format: "%.3f", store.audioLevel))
                        .font(.caption)
                        .monospacedDigit()
                        .foregroundColor(.secondary)
                }
                GeometryReader { geo in
                    ZStack(alignment: .leading) {
                        RoundedRectangle(cornerRadius: 3)
                            .fill(Color.primary.opacity(0.08))
                        RoundedRectangle(cornerRadius: 3)
                            .fill(levelColor)
                            .frame(width: geo.size.width * CGFloat(min(store.audioLevel * 10, 1.0)))
                    }
                }
                .frame(height: 8)
            }

            VStack(alignment: .leading, spacing: 4) {
                HStack {
                    Text("VAD")
                        .font(.caption)
                        .foregroundColor(.secondary)
                    Spacer()
                    Text(String(format: "%.2f", store.speechProbability))
                        .font(.caption)
                        .monospacedDigit()
                        .foregroundColor(store.speechProbability >= store.config.vadThreshold ? .green : .secondary)
                }
                GeometryReader { geo in
                    ZStack(alignment: .leading) {
                        RoundedRectangle(cornerRadius: 3)
                            .fill(Color.primary.opacity(0.08))
                        RoundedRectangle(cornerRadius: 3)
                            .fill(store.speechProbability >= store.config.vadThreshold ? Color.green : Color.gray)
                            .frame(width: geo.size.width * CGFloat(store.speechProbability))
                    }
                }
                .frame(height: 6)
            }

            VStack(alignment: .leading, spacing: 4) {
                HStack {
                    Text("Silence")
                        .font(.caption)
                        .foregroundColor(.secondary)
                    Spacer()
                    Text(String(format: "%.1fs / %.0fs", store.silenceCountdown, store.config.silenceDuration))
                        .font(.caption)
                        .monospacedDigit()
                        .foregroundColor(store.silenceCountdown > 3 ? .orange : .secondary)
                }
                ProgressView(value: store.silenceCountdown, total: store.config.silenceDuration)
                    .tint(store.silenceCountdown > 3 ? .orange : .blue)
            }
        }
    }

    private var levelColor: Color {
        if store.audioLevel < 0.01 { return .gray }
        if store.audioLevel < 0.05 { return .green }
        if store.audioLevel < 0.1 { return .yellow }
        return .orange
    }

    // MARK: - Failed Recordings

    private var failedSection: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack {
                Image(systemName: "exclamationmark.triangle")
                    .foregroundColor(.orange)
                Text("Failed (\(store.failedRecordings.count))")
                    .font(.caption)
                    .foregroundColor(.secondary)
            }

            ForEach(store.failedRecordings.prefix(5)) { rec in
                HStack(spacing: 8) {
                    VStack(alignment: .leading, spacing: 2) {
                        Text(rec.fileURL.lastPathComponent)
                            .font(.caption2)
                            .lineLimit(1)
                        Text(rec.error)
                            .font(.caption2)
                            .foregroundColor(.red)
                            .lineLimit(1)
                    }

                    Spacer()

                    if rec.isRetrying {
                        ProgressView()
                            .controlSize(.small)
                    } else {
                        Button(action: { store.retryFailed(rec) }) {
                            Image(systemName: "arrow.clockwise")
                                .font(.caption)
                        }
                        .buttonStyle(.plain)
                        .foregroundColor(.accentColor)

                        Button(action: { store.dismissFailed(rec) }) {
                            Image(systemName: "xmark")
                                .font(.caption2)
                        }
                        .buttonStyle(.plain)
                        .foregroundColor(.secondary)
                    }
                }
                .padding(6)
                .background(
                    RoundedRectangle(cornerRadius: 6)
                        .fill(Color.red.opacity(0.06))
                )
            }
        }
    }

    // MARK: - History

    private var historySection: some View {
        VStack(alignment: .leading, spacing: 8) {
            Text("Recent")
                .font(.caption)
                .foregroundColor(.secondary)

            ForEach(store.history.prefix(3)) { entry in
                VStack(alignment: .leading, spacing: 4) {
                    Button(action: {
                        NSPasteboard.general.clearContents()
                        NSPasteboard.general.setString(entry.text, forType: .string)
                        NSSound(named: "Tink")?.play()
                    }) {
                        HStack(alignment: .top, spacing: 8) {
                            Image(systemName: "doc.on.clipboard")
                                .font(.caption)
                                .foregroundColor(.secondary)
                                .frame(width: 14)
                            VStack(alignment: .leading, spacing: 2) {
                                Text(entry.text)
                                    .font(.caption)
                                    .lineLimit(2)
                                    .foregroundColor(.primary)
                                Text(entry.date, style: .time)
                                    .font(.caption2)
                                    .foregroundColor(.secondary)
                            }
                            Spacer()
                        }
                        .padding(6)
                        .background(
                            RoundedRectangle(cornerRadius: 6)
                                .fill(Color.primary.opacity(0.04))
                        )
                    }
                    .buttonStyle(.plain)

                    if !entry.matches.isEmpty {
                        ForEach(entry.matches) { match in
                            HStack(spacing: 6) {
                                Image(systemName: match.matchedProfileId == nil
                                      ? "xmark.circle.fill" : "checkmark.circle.fill")
                                    .foregroundColor(match.matchedProfileId == nil ? .red : .green)
                                    .font(.caption2)
                                Text(matchLabel(match))
                                    .font(.caption2).foregroundColor(.secondary)
                                Spacer()
                                if match.matchedProfileId == nil && !match.embedding.isEmpty {
                                    Button("Should have passed?") {
                                        store.acceptRejectedSegment(historyId: entry.id, matchId: match.id)
                                    }
                                    .buttonStyle(.plain)
                                    .font(.caption2)
                                    .foregroundColor(.accentColor)
                                }
                            }
                            .padding(.horizontal, 6)
                        }
                    }
                }
            }
        }
    }

    private func matchLabel(_ m: SegmentMatch) -> String {
        let dur = String(format: "%.1f–%.1fs", m.startTime, m.endTime)
        if let name = m.matchedProfileName, m.matchedProfileId != nil {
            return "\(dur)  matched: \(name) (\(String(format: "%.2f", m.similarity)))"
        }
        if let name = m.matchedProfileName {
            return "\(dur)  rejected — best: \(name) (\(String(format: "%.2f", m.similarity)))"
        }
        return "\(dur)  rejected"
    }

    // MARK: - Voice Profiles

    private var voiceProfilesSection: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack {
                Image(systemName: "person.wave.2")
                    .foregroundColor(.accentColor)
                Text("Voice Profiles (\(store.voiceprints.profiles.count))")
                    .font(.caption).foregroundColor(.secondary)
                Spacer()
                Button {
                    showEnrollment = true
                } label: {
                    Label("Add", systemImage: "plus")
                        .font(.caption)
                }
                .buttonStyle(.plain)
                .foregroundColor(.accentColor)
            }

            if store.voiceprints.profiles.isEmpty {
                Text("No profiles enrolled. All audio will be transcribed (no speaker filter).")
                    .font(.caption2)
                    .foregroundColor(.secondary)
            } else {
                ForEach(store.voiceprints.profiles) { profile in
                    HStack(spacing: 8) {
                        Circle().fill(Color.accentColor).frame(width: 6, height: 6)
                        Text(profile.name).font(.caption)
                        Spacer()
                        Text(String(format: "thr %.2f", profile.threshold))
                            .font(.caption2).foregroundColor(.secondary).monospacedDigit()
                        Button {
                            store.voiceprints.remove(id: profile.id)
                        } label: {
                            Image(systemName: "trash").font(.caption2)
                        }
                        .buttonStyle(.plain)
                        .foregroundColor(.secondary)
                    }
                }
            }
        }
        .sheet(isPresented: $showEnrollment) {
            EnrollmentView(store: store)
        }
    }

    // MARK: - Footer

    private var footerSection: some View {
        HStack {
            Text("⌘⇧R")
                .font(.caption)
                .padding(.horizontal, 6)
                .padding(.vertical, 2)
                .background(
                    RoundedRectangle(cornerRadius: 4)
                        .fill(Color.primary.opacity(0.08))
                )

            Spacer()

            Button("Settings...") {
                NotificationCenter.default.post(name: .voicePasteOpenSettings, object: nil)
            }
            .buttonStyle(.plain)
            .foregroundColor(.secondary)
            .font(.caption)

            Text(" | ")
                .foregroundColor(.gray)

            Button("Quit") {
                NSApplication.shared.terminate(nil)
            }
            .buttonStyle(.plain)
            .foregroundColor(.secondary)
            .font(.caption)
        }
    }
}
