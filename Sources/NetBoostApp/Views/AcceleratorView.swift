import AppKit
import NetBoostCore
import SwiftUI

public struct AcceleratorView: View {
    @EnvironmentObject private var appState: AppState

    public init() {}

    public var body: some View {
        ScrollView(.vertical, showsIndicators: true) {
            VStack(alignment: .leading, spacing: 16) {
                headerRow

                if let detected = appState.detectedClipboardURL {
                    clipboardBanner(url: detected)
                }

                transferSetupCard

                if let task = appState.activeDownloadTask {
                    activeTransferCard(task: task)
                } else {
                    emptyTransferCard
                }
            }
            .padding(20)
        }
    }

    // MARK: - Header

    private var headerRow: some View {
        HStack(alignment: .center, spacing: 12) {
            PageHeader(
                title: "Download Accelerator",
                subtitle: "Multi-connection byte-range transfers with checksum verification"
            )
            Spacer()
            if let task = appState.activeDownloadTask {
                StatusPill(
                    text: taskStatusLabel(task.status),
                    color: taskStatusColor(task.status),
                    showPulse: task.status == .downloading || task.status == .probing || task.status == .verifying
                )
            }
        }
    }

    // MARK: - Clipboard Banner

    private func clipboardBanner(url: URL) -> some View {
        HStack(spacing: 10) {
            Image(systemName: "doc.on.clipboard")
                .font(.system(size: 14, weight: .medium))
                .foregroundColor(GlassTheme.cyanSapphire)

            VStack(alignment: .leading, spacing: 2) {
                Text("Download URL detected in clipboard")
                    .font(.system(size: 12, weight: .medium))
                    .foregroundColor(GlassTheme.textPrimary)
                Text(url.absoluteString)
                    .font(.system(size: 11.5, design: .monospaced))
                    .foregroundColor(GlassTheme.textSecondary)
                    .lineLimit(1)
                    .truncationMode(.middle)
            }

            Spacer()

            Button("Use URL") {
                appState.downloadURLInput = url.absoluteString
                appState.detectedClipboardURL = nil
            }
            .buttonStyle(GlowingButtonStyle(accentColor: GlassTheme.cyanSapphire))

            Button {
                appState.detectedClipboardURL = nil
            } label: {
                Image(systemName: "xmark")
                    .font(.system(size: 11, weight: .semibold))
                    .foregroundColor(GlassTheme.textTertiary)
            }
            .buttonStyle(.plain)
            .help("Dismiss clipboard suggestion")
        }
        .padding(12)
        .glassCard(cornerRadius: 10, strokeColor: GlassTheme.cyanSapphire.opacity(0.4))
    }

    // MARK: - Setup Card

    private var transferSetupCard: some View {
        let isBusy = isTaskInFlight(appState.activeDownloadTask?.status)
        let trimmedInput = appState.downloadURLInput.trimmingCharacters(in: .whitespacesAndNewlines)

        return VStack(alignment: .leading, spacing: 12) {
            SectionLabel("Transfer Configuration")

            // Download URL Row
            HStack(spacing: 10) {
                Text("Download URL")
                    .font(.system(size: 12.5))
                    .foregroundColor(GlassTheme.textSecondary)
                    .frame(width: 92, alignment: .leading)

                TextField("https://example.com/archive.tar.gz", text: $appState.downloadURLInput)
                    .textFieldStyle(.plain)
                    .font(.system(size: 12.5, design: .monospaced))
                    .foregroundColor(GlassTheme.textPrimary)
                    .padding(.horizontal, 10)
                    .padding(.vertical, 7)
                    .background(GlassTheme.controlFill)
                    .clipShape(RoundedRectangle(cornerRadius: 8, style: .continuous))
                    .overlay(
                        RoundedRectangle(cornerRadius: 8, style: .continuous)
                            .strokeBorder(GlassTheme.controlBorder, lineWidth: 0.75)
                    )
                    .onSubmit {
                        guard !trimmedInput.isEmpty, !isBusy else { return }
                        Task { await initiateDownload() }
                    }

                Button {
                    Task { await initiateDownload() }
                } label: {
                    HStack(spacing: 5) {
                        Image(systemName: "arrow.down.to.line")
                        Text("Start")
                    }
                }
                .buttonStyle(GlowingButtonStyle(accentColor: GlassTheme.cyanSapphire, isProminent: true))
                .disabled(trimmedInput.isEmpty || isBusy)
            }

            // Connections Picker Row
            HStack(spacing: 10) {
                Text("Connections")
                    .font(.system(size: 12.5))
                    .foregroundColor(GlassTheme.textSecondary)
                    .frame(width: 92, alignment: .leading)

                Picker("Connections", selection: $appState.selectedChunkCount) {
                    Text("4").tag(4)
                    Text("8").tag(8)
                    Text("12").tag(12)
                    Text("16").tag(16)
                }
                .labelsHidden()
                .pickerStyle(.segmented)
                .frame(width: 220)

                Text("Concurrent byte-range streams")
                    .font(.system(size: 11.5))
                    .foregroundColor(GlassTheme.textTertiary)

                Spacer()
            }

            // Destination Folder Row
            HStack(spacing: 10) {
                Text("Destination")
                    .font(.system(size: 12.5))
                    .foregroundColor(GlassTheme.textSecondary)
                    .frame(width: 92, alignment: .leading)

                HStack(spacing: 6) {
                    Image(systemName: "folder")
                        .font(.system(size: 12))
                        .foregroundColor(GlassTheme.textSecondary)
                    Text(shortenedPath(appState.downloadDirectory.path))
                        .font(.system(size: 12, design: .monospaced))
                        .foregroundColor(GlassTheme.textPrimary)
                        .lineLimit(1)
                        .truncationMode(.middle)
                }
                .padding(.horizontal, 10)
                .padding(.vertical, 6)
                .frame(maxWidth: .infinity, alignment: .leading)
                .background(GlassTheme.controlFill)
                .clipShape(RoundedRectangle(cornerRadius: 8, style: .continuous))
                .overlay(
                    RoundedRectangle(cornerRadius: 8, style: .continuous)
                        .strokeBorder(GlassTheme.controlBorder, lineWidth: 0.75)
                )
                .help(appState.downloadDirectory.path)

                Button("Choose...") {
                    appState.chooseDownloadDirectory()
                }
                .buttonStyle(GlowingButtonStyle(accentColor: GlassTheme.cyanSapphire))

                if appState.activeDownloadTask != nil {
                    Button {
                        appState.revealDownloadedFile()
                    } label: {
                        HStack(spacing: 5) {
                            Image(systemName: "arrow.up.forward.app")
                            Text("Reveal in Finder")
                        }
                    }
                    .buttonStyle(GlowingButtonStyle(accentColor: GlassTheme.cyanSapphire))
                }
            }

            // Checksum Row
            HStack(spacing: 10) {
                Text("Checksum")
                    .font(.system(size: 12.5))
                    .foregroundColor(GlassTheme.textSecondary)
                    .frame(width: 92, alignment: .leading)

                Picker("Algorithm", selection: $appState.selectedChecksumAlgorithm) {
                    Text("SHA-256").tag("SHA-256")
                    Text("SHA-1").tag("SHA-1")
                    Text("MD5").tag("MD5")
                }
                .labelsHidden()
                .pickerStyle(.menu)
                .frame(width: 98)

                TextField("Optional expected digest", text: $appState.expectedChecksum)
                    .textFieldStyle(.plain)
                    .font(.system(size: 12, design: .monospaced))
                    .foregroundColor(GlassTheme.textPrimary)
                    .padding(.horizontal, 10)
                    .padding(.vertical, 6.5)
                    .background(GlassTheme.controlFill)
                    .clipShape(RoundedRectangle(cornerRadius: 8, style: .continuous))
                    .overlay(
                        RoundedRectangle(cornerRadius: 8, style: .continuous)
                            .strokeBorder(GlassTheme.controlBorder, lineWidth: 0.75)
                    )

                Button("Verify") {
                    Task {
                        _ = await appState.verifyChecksum()
                    }
                }
                .buttonStyle(GlowingButtonStyle(accentColor: GlassTheme.cyanSapphire))
                .disabled(
                    appState.activeDownloadTask == nil
                        || appState.expectedChecksum.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
                )

                if let match = appState.checksumMatchStatus {
                    StatusPill(
                        text: match ? "Verified" : "Mismatch",
                        color: match ? GlassTheme.emeraldGreen : GlassTheme.redAlert,
                        showPulse: false
                    )
                }
            }

            if let err = appState.downloadError {
                HStack(spacing: 8) {
                    Image(systemName: "exclamationmark.triangle.fill")
                        .foregroundColor(GlassTheme.redAlert)
                    Text(err)
                        .font(.system(size: 12))
                        .foregroundColor(GlassTheme.redAlert)
                        .fixedSize(horizontal: false, vertical: true)
                    Spacer()
                    Button {
                        appState.downloadError = nil
                    } label: {
                        Image(systemName: "xmark")
                            .font(.system(size: 11, weight: .semibold))
                            .foregroundColor(GlassTheme.textTertiary)
                    }
                    .buttonStyle(.plain)
                }
                .padding(.top, 2)
            }
        }
        .padding(16)
        .glassCard(cornerRadius: 12)
    }

    // MARK: - Active Transfer Card

    private func activeTransferCard(task: DownloadTaskInfo) -> some View {
        let percent = Int((task.progress * 100).rounded())
        let downloadedText = SpeedFormatter.formatBytes(task.downloadedBytes)
        let totalText = SpeedFormatter.formatBytes(task.totalBytes)

        return VStack(alignment: .leading, spacing: 14) {
            HStack(alignment: .center, spacing: 12) {
                Image(systemName: "doc.fill")
                    .font(.system(size: 18))
                    .foregroundColor(GlassTheme.cyanSapphire)

                VStack(alignment: .leading, spacing: 3) {
                    Text(task.destinationURL.lastPathComponent)
                        .font(.system(size: 14, weight: .semibold))
                        .foregroundColor(GlassTheme.textPrimary)
                        .lineLimit(1)
                        .truncationMode(.middle)

                    Text("\(downloadedText) / \(totalText) (\(percent)%)")
                        .font(.system(size: 12, design: .monospaced))
                        .monospacedDigit()
                        .foregroundColor(GlassTheme.textSecondary)
                }

                Spacer()

                VStack(alignment: .trailing, spacing: 3) {
                    Text(SpeedFormatter.formatSpeed(task.speedBytesPerSec))
                        .font(.system(size: 15, weight: .semibold, design: .monospaced))
                        .monospacedDigit()
                        .foregroundColor(GlassTheme.cyanSapphire)

                    if let eta = task.etaSeconds, task.status == .downloading {
                        Text("ETA \(SpeedFormatter.formatDuration(eta))")
                            .font(.system(size: 11.5, design: .monospaced))
                            .monospacedDigit()
                            .foregroundColor(GlassTheme.textTertiary)
                    }
                }

                HStack(spacing: 6) {
                    if task.status == .downloading {
                        Button {
                            Task { await runTaskAction { try await appState.pauseDownload() } }
                        } label: {
                            Image(systemName: "pause.fill")
                        }
                        .buttonStyle(GlowingButtonStyle(accentColor: GlassTheme.amberWarning))
                        .help("Pause download")
                        .accessibilityLabel("Pause download")
                    } else if task.status == .paused || task.status == .failed {
                        Button {
                            Task { await runTaskAction { try await appState.resumeDownload() } }
                        } label: {
                            Image(systemName: "play.fill")
                        }
                        .buttonStyle(GlowingButtonStyle(accentColor: GlassTheme.emeraldGreen))
                        .help("Resume download")
                        .accessibilityLabel("Resume download")
                    }

                    Button {
                        Task { await runTaskAction { try await appState.cancelDownload() } }
                    } label: {
                        Image(systemName: "xmark")
                    }
                    .buttonStyle(GlowingButtonStyle(accentColor: GlassTheme.redAlert))
                    .help(task.status == .completed ? "Clear transfer" : "Cancel download")
                    .accessibilityLabel("Cancel download")
                }
            }

            // Overall Progress Bar
            GeometryReader { geo in
                ZStack(alignment: .leading) {
                    RoundedRectangle(cornerRadius: 4, style: .continuous)
                        .fill(GlassTheme.controlFill)
                    if task.status == .completed {
                        RoundedRectangle(cornerRadius: 4, style: .continuous)
                            .fill(GlassTheme.emeraldGreen)
                            .frame(width: max(0, geo.size.width * CGFloat(task.progress)))
                    } else {
                        RoundedRectangle(cornerRadius: 4, style: .continuous)
                            .fill(
                                LinearGradient(
                                    colors: [GlassTheme.cyanSapphire, GlassTheme.violetAccent],
                                    startPoint: .leading,
                                    endPoint: .trailing
                                )
                            )
                            .frame(width: max(0, geo.size.width * CGFloat(task.progress)))
                    }
                }
                .animation(.easeOut(duration: 0.15), value: task.progress)
            }
            .frame(height: 8)

            if !task.chunks.isEmpty {
                Rectangle()
                    .fill(GlassTheme.separator)
                    .frame(height: 1)

                HStack {
                    SectionLabel("Chunk Streams")
                    Text("(\(task.chunks.count))")
                        .font(.system(size: 12, design: .monospaced))
                        .monospacedDigit()
                        .foregroundColor(GlassTheme.textTertiary)
                    Spacer()
                }

                LazyVGrid(
                    columns: [GridItem(.adaptive(minimum: 220), spacing: 8)],
                    spacing: 8
                ) {
                    ForEach(task.chunks) { chunk in
                        chunkLaneView(chunk: chunk)
                    }
                }
            }
        }
        .padding(16)
        .glassCard(
            cornerRadius: 12,
            strokeColor: taskStatusColor(task.status).opacity(0.35)
        )
    }

    private func chunkLaneView(chunk: DownloadChunkInfo) -> some View {
        let color = chunkColor(chunk.status)
        let percent = Int((chunk.progress * 100).rounded())

        return HStack(spacing: 8) {
            Text(String(format: "#%02d", chunk.id + 1))
                .font(.system(size: 11, weight: .semibold, design: .monospaced))
                .monospacedDigit()
                .foregroundColor(GlassTheme.textTertiary)
                .frame(width: 28, alignment: .leading)

            GeometryReader { geo in
                ZStack(alignment: .leading) {
                    RoundedRectangle(cornerRadius: 3, style: .continuous)
                        .fill(Color.white.opacity(0.06))
                    RoundedRectangle(cornerRadius: 3, style: .continuous)
                        .fill(color)
                        .frame(width: max(0, geo.size.width * CGFloat(chunk.progress)))
                }
            }
            .frame(height: 6)

            if chunk.status == .downloading && chunk.speedBytesPerSec > 0 {
                Text(SpeedFormatter.formatSpeed(chunk.speedBytesPerSec))
                    .font(.system(size: 10.5, design: .monospaced))
                    .monospacedDigit()
                    .foregroundColor(GlassTheme.textSecondary)
                    .frame(width: 68, alignment: .trailing)
            }

            Text("\(percent)%")
                .font(.system(size: 11, weight: .medium, design: .monospaced))
                .monospacedDigit()
                .foregroundColor(color)
                .frame(width: 34, alignment: .trailing)
        }
        .padding(.horizontal, 10)
        .padding(.vertical, 7)
        .background(GlassTheme.controlFill)
        .clipShape(RoundedRectangle(cornerRadius: 8, style: .continuous))
    }

    private var emptyTransferCard: some View {
        VStack(spacing: 10) {
            Image(systemName: "arrow.down.circle")
                .font(.system(size: 28))
                .foregroundColor(GlassTheme.textTertiary)
            Text("Ready to Download")
                .font(.system(size: 14, weight: .semibold))
                .foregroundColor(GlassTheme.textPrimary)
            Text("Enter a direct HTTP or HTTPS URL above to start a multi-connection transfer.")
                .font(.system(size: 12))
                .foregroundColor(GlassTheme.textSecondary)
                .multilineTextAlignment(.center)
        }
        .frame(maxWidth: .infinity)
        .padding(.vertical, 32)
        .padding(.horizontal, 16)
        .glassCard(cornerRadius: 12)
    }

    // MARK: - Helpers & Actions

    private func initiateDownload() async {
        await runTaskAction {
            try await appState.startDownload()
        }
    }

    private func runTaskAction(_ operation: () async throws -> Void) async {
        do {
            try await operation()
        } catch {
            appState.downloadError = error.localizedDescription
        }
    }

    private func shortenedPath(_ path: String) -> String {
        (path as NSString).abbreviatingWithTildeInPath
    }

    private func isTaskInFlight(_ status: DownloadTaskStatus?) -> Bool {
        guard let status else { return false }
        switch status {
        case .queued, .probing, .downloading, .assembling, .verifying:
            return true
        case .paused, .completed, .failed, .cancelled:
            return false
        }
    }

    private func chunkColor(_ status: ChunkStatus) -> Color {
        switch status {
        case .downloading: return GlassTheme.cyanSapphire
        case .completed: return GlassTheme.emeraldGreen
        case .pending: return GlassTheme.textTertiary
        case .failed: return GlassTheme.redAlert
        }
    }

    private func taskStatusLabel(_ status: DownloadTaskStatus) -> String {
        switch status {
        case .queued: return "Queued"
        case .probing: return "Probing"
        case .downloading: return "Downloading"
        case .paused: return "Paused"
        case .assembling: return "Assembling"
        case .verifying: return "Verifying"
        case .completed: return "Completed"
        case .failed: return "Failed"
        case .cancelled: return "Cancelled"
        }
    }

    private func taskStatusColor(_ status: DownloadTaskStatus) -> Color {
        switch status {
        case .downloading: return GlassTheme.cyanSapphire
        case .completed: return GlassTheme.emeraldGreen
        case .paused: return GlassTheme.amberWarning
        case .failed: return GlassTheme.redAlert
        case .probing, .assembling, .verifying: return GlassTheme.violetAccent
        case .queued, .cancelled: return GlassTheme.textTertiary
        }
    }
}
