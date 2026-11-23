import SwiftUI
import NetBoostCore

public struct AcceleratorView: View {
    @EnvironmentObject private var appState: AppState

    public init() {}

    public var body: some View {
        ScrollView(.vertical, showsIndicators: true) {
            VStack(alignment: .leading, spacing: 20) {
                // Header
                HStack {
                    VStack(alignment: .leading, spacing: 4) {
                        Text("Multi-Connection Download Accelerator")
                            .font(.system(size: 20, weight: .bold, design: .rounded))
                            .foregroundColor(.white)
                        Text("High-throughput segmented downloader with 8–16 concurrent byte-range chunk workers")
                            .font(.system(size: 12))
                            .foregroundColor(GlassTheme.textSecondary)
                    }
                    Spacer()
                    if let task = appState.activeDownloadTask {
                        StatusPill(
                            text: task.status.rawValue.uppercased(),
                            color: taskStatusColor(task.status),
                            showPulse: task.status == .downloading
                        )
                    }
                }

                // Clipboard Auto-Detect Banner
                if let detected = appState.detectedClipboardURL {
                    HStack {
                        Image(systemName: "doc.on.clipboard.fill")
                            .foregroundColor(GlassTheme.cyanNeon)
                        VStack(alignment: .leading, spacing: 2) {
                            Text("Download URL detected in clipboard:")
                                .font(.system(size: 11, weight: .semibold))
                                .foregroundColor(GlassTheme.textSecondary)
                            Text(detected.absoluteString)
                                .font(.system(size: 11, design: .monospaced))
                                .foregroundColor(.white)
                                .lineLimit(1)
                        }
                        Spacer()
                        Button("Paste URL") {
                            appState.downloadURLInput = detected.absoluteString
                            appState.detectedClipboardURL = nil
                        }
                        .buttonStyle(GlowingButtonStyle(accentColor: GlassTheme.cyanNeon))
                    }
                    .padding(12)
                    .background(GlassTheme.cyanNeon.opacity(0.12))
                    .cornerRadius(10)
                    .overlay(
                        RoundedRectangle(cornerRadius: 10)
                            .stroke(GlassTheme.cyanNeon.opacity(0.35), lineWidth: 1)
                    )
                }

                // Download URL Input & Chunk Selector
                VStack(alignment: .leading, spacing: 14) {
                    Text("New Accelerated Download")
                        .font(.system(size: 15, weight: .bold))
                        .foregroundColor(.white)

                    HStack(spacing: 12) {
                        TextField("Enter direct file download URL (http:// or https://)...", text: $appState.downloadURLInput)
                            .textFieldStyle(.plain)
                            .font(.system(size: 13, design: .monospaced))
                            .padding(10)
                            .background(Color.black.opacity(0.35))
                            .cornerRadius(8)
                            .overlay(
                                RoundedRectangle(cornerRadius: 8)
                                    .stroke(Color.white.opacity(0.15), lineWidth: 1)
                            )

                        Picker("Chunks", selection: $appState.selectedChunkCount) {
                            Text("8 Chunks").tag(8)
                            Text("12 Chunks").tag(12)
                            Text("16 Chunks").tag(16)
                        }
                        .pickerStyle(.segmented)
                        .frame(width: 220)

                        Button {
                            Task {
                                try? await appState.startDownload()
                            }
                        } label: {
                            HStack(spacing: 6) {
                                Image(systemName: "arrow.down.to.line.compact")
                                Text("Start")
                            }
                        }
                        .buttonStyle(GlowingButtonStyle(accentColor: GlassTheme.violetAccent, isProminent: true))
                        .disabled(appState.downloadURLInput.isEmpty)
                    }

                    if let err = appState.downloadError {
                        Text(err)
                            .font(.system(size: 11))
                            .foregroundColor(GlassTheme.redAlert)
                    }

                    // Checksum Verification Fields
                    HStack(spacing: 12) {
                        Picker("Algorithm", selection: $appState.selectedChecksumAlgorithm) {
                            Text("SHA-256").tag("SHA-256")
                            Text("SHA-1").tag("SHA-1")
                            Text("MD5").tag("MD5")
                        }
                        .pickerStyle(.menu)
                        .frame(width: 110)

                        TextField("Expected checksum (optional)...", text: $appState.expectedChecksum)
                            .textFieldStyle(.plain)
                            .font(.system(size: 12, design: .monospaced))
                            .padding(8)
                            .background(Color.black.opacity(0.25))
                            .cornerRadius(6)

                        if appState.activeDownloadTask != nil && !appState.expectedChecksum.isEmpty {
                            Button("Verify") {
                                Task {
                                    _ = await appState.verifyChecksum()
                                }
                            }
                            .buttonStyle(GlowingButtonStyle(accentColor: GlassTheme.cyanNeon))

                            if let match = appState.checksumMatchStatus {
                                StatusPill(
                                    text: match ? "CHECKSUM PASS" : "CHECKSUM MISMATCH",
                                    color: match ? GlassTheme.emeraldGreen : GlassTheme.redAlert,
                                    showPulse: false
                                )
                            }
                        }
                    }
                }
                .padding(16)
                .glassCard(cornerRadius: 14)

                // Active Download Progress & Segmented Chunk Visualizer
                if let task = appState.activeDownloadTask {
                    VStack(alignment: .leading, spacing: 14) {
                        HStack {
                            VStack(alignment: .leading, spacing: 2) {
                                Text(task.url.lastPathComponent)
                                    .font(.system(size: 14, weight: .bold))
                                    .foregroundColor(.white)
                                Text("\(SpeedFormatter.formatSpeed(Double(task.downloadedBytes))) of \(SpeedFormatter.formatSpeed(Double(task.totalBytes))) (\(Int(task.progress * 100))%)")
                                    .font(.system(size: 11, design: .monospaced))
                                    .foregroundColor(GlassTheme.textSecondary)
                            }
                            Spacer()
                            VStack(alignment: .trailing, spacing: 2) {
                                Text(SpeedFormatter.formatSpeed(task.speedBytesPerSec))
                                    .font(.system(size: 16, weight: .bold, design: .monospaced))
                                    .foregroundColor(GlassTheme.violetAccent)
                                if let eta = task.etaSeconds {
                                    Text(String(format: "ETA: %.0fs", eta))
                                        .font(.system(size: 10, design: .monospaced))
                                        .foregroundColor(GlassTheme.textTertiary)
                                }
                            }

                            // Controls: Pause, Resume, Cancel
                            HStack(spacing: 8) {
                                if task.status == .downloading {
                                    Button {
                                        Task { try? await appState.pauseDownload() }
                                    } label: {
                                        Image(systemName: "pause.fill")
                                    }
                                    .buttonStyle(GlowingButtonStyle(accentColor: GlassTheme.amberWarning))
                                } else if task.status == .paused {
                                    Button {
                                        Task { try? await appState.resumeDownload() }
                                    } label: {
                                        Image(systemName: "play.fill")
                                    }
                                    .buttonStyle(GlowingButtonStyle(accentColor: GlassTheme.emeraldGreen))
                                }

                                Button {
                                    Task { try? await appState.cancelDownload() }
                                } label: {
                                    Image(systemName: "xmark.fill")
                                }
                                .buttonStyle(GlowingButtonStyle(accentColor: GlassTheme.redAlert))
                            }
                        }

                        // Aggregate Progress Bar
                        GeometryReader { geo in
                            ZStack(alignment: .leading) {
                                RoundedRectangle(cornerRadius: 6)
                                    .fill(Color.white.opacity(0.08))
                                RoundedRectangle(cornerRadius: 6)
                                    .fill(
                                        LinearGradient(
                                            colors: [GlassTheme.violetAccent, GlassTheme.cyanNeon],
                                            startPoint: .leading,
                                            endPoint: .trailing
                                        )
                                    )
                                    .frame(width: max(0, geo.size.width * CGFloat(task.progress)))
                            }
                        }
                        .frame(height: 10)

                        Divider().background(Color.white.opacity(0.08))

                        // Segmented Parallel Chunk Visualizer (8–16 Chunk Lanes)
                        Text("Segmented Chunk Worker Lanes (\(task.chunks.count) connections)")
                            .font(.system(size: 12, weight: .bold))
                            .foregroundColor(GlassTheme.textSecondary)

                        LazyVGrid(columns: [GridItem(.flexible()), GridItem(.flexible())], spacing: 8) {
                            ForEach(task.chunks) { chunk in
                                chunkLaneView(chunk: chunk)
                            }
                        }
                    }
                    .padding(16)
                    .glassCard(cornerRadius: 14, strokeColor: GlassTheme.violetAccent.opacity(0.5))
                } else {
                    // Empty State Placeholder
                    VStack(spacing: 10) {
                        Image(systemName: "bolt.horizontal.circle")
                            .font(.system(size: 32))
                            .foregroundColor(GlassTheme.violetAccent.opacity(0.6))
                        Text("Download Accelerator Idle")
                            .font(.system(size: 14, weight: .semibold))
                            .foregroundColor(.white)
                        Text("Paste a file URL above to initiate multi-stream accelerated downloading.")
                            .font(.system(size: 12))
                            .foregroundColor(GlassTheme.textSecondary)
                    }
                    .frame(maxWidth: .infinity)
                    .padding(.vertical, 36)
                    .glassCard(cornerRadius: 14)
                }
            }
            .padding(20)
        }
    }

    private func chunkLaneView(chunk: DownloadChunkInfo) -> some View {
        HStack(spacing: 8) {
            Text(String(format: "#%02d", chunk.id + 1))
                .font(.system(size: 10, weight: .bold, design: .monospaced))
                .foregroundColor(GlassTheme.textTertiary)
                .frame(width: 24)

            GeometryReader { geo in
                ZStack(alignment: .leading) {
                    RoundedRectangle(cornerRadius: 4)
                        .fill(Color.white.opacity(0.06))
                    RoundedRectangle(cornerRadius: 4)
                        .fill(chunkColor(chunk.status))
                        .frame(width: max(0, geo.size.width * CGFloat(chunk.progress)))
                }
            }
            .frame(height: 8)

            Text("\(Int(chunk.progress * 100))%")
                .font(.system(size: 10, design: .monospaced))
                .foregroundColor(chunkColor(chunk.status))
                .frame(width: 32, alignment: .trailing)
        }
        .padding(8)
        .background(Color.white.opacity(0.03))
        .cornerRadius(6)
    }

    private func chunkColor(_ status: ChunkStatus) -> Color {
        switch status {
        case .downloading:
            return GlassTheme.cyanSapphire   // Cyan #00D2FF
        case .completed:
            return GlassTheme.emeraldGreen  // Green #00E676
        case .pending:
            return Color(hex: "#757575")    // Grey #757575
        case .failed:
            return GlassTheme.redAlert      // Red #FF1744
        }
    }

    private func taskStatusColor(_ status: DownloadTaskStatus) -> Color {
        switch status {
        case .downloading: return GlassTheme.cyanNeon
        case .completed: return GlassTheme.emeraldGreen
        case .paused: return GlassTheme.amberWarning
        case .failed: return GlassTheme.redAlert
        case .queued, .probing, .assembling, .verifying, .cancelled: return GlassTheme.textTertiary
        }
    }
}
