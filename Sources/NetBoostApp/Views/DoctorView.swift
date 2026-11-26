import AppKit
import NetBoostCore
import SwiftUI

public struct DoctorView: View {
    @EnvironmentObject private var appState: AppState
    @State private var isScanning = false
    @State private var activeRepairLabel: String? = nil

    public init() {}

    private struct EndpointMeta: Identifiable {
        let host: String
        let label: String
        let role: String
        var id: String { host }
    }

    private var endpointMetadata: [EndpointMeta] {
        AppState.targetEndpoints.map { host in
            switch host {
            case "10.1.36.1":
                return EndpointMeta(host: host, label: "Switch Gateway", role: "Local Switch")
            case "10.8.0.80":
                return EndpointMeta(host: host, label: "Core Gateway", role: "Core Gateway")
            case "turing.iiit.ac.in":
                return EndpointMeta(host: host, label: "Turing HPC", role: "Compute Host")
            case "google.com":
                return EndpointMeta(host: host, label: "Google", role: "External Web")
            case "claude.com":
                return EndpointMeta(host: host, label: "Claude", role: "AI Service")
            default:
                return EndpointMeta(host: host, label: host, role: "Endpoint")
            }
        }
    }

    public var body: some View {
        ScrollView(.vertical, showsIndicators: true) {
            VStack(alignment: .leading, spacing: 16) {
                headerRow
                serviceToolbarCard

                if appState.captivePortalStatus == .detected || appState.captivePortalStatus == .redirecting {
                    captivePortalBanner
                }

                latencyMatrixCard
                repairToolsCard
                tracerouteCard
                activeIssuesCard
                repairLogCard
            }
            .padding(20)
        }
    }

    // MARK: - Header & Service Toolbar

    private var headerRow: some View {
        HStack(alignment: .center, spacing: 12) {
            PageHeader(
                title: "Network Doctor",
                subtitle: "Endpoint latency, captive portal detection, traceroute, and interface repair"
            )
            Spacer()
            StatusPill(
                text: captivePortalLabel(appState.captivePortalStatus),
                color: captivePortalColor(appState.captivePortalStatus),
                showPulse: appState.captivePortalStatus == .detected || appState.captivePortalStatus == .redirecting
            )
        }
    }

    private var serviceToolbarCard: some View {
        HStack(spacing: 12) {
            Text("Service")
                .font(.system(size: 12.5, weight: .medium))
                .foregroundColor(GlassTheme.textSecondary)

            Picker("Service", selection: $appState.selectedRepairService) {
                ForEach(availableServiceOptions, id: \.self) { service in
                    Text(service).tag(service)
                }
            }
            .labelsHidden()
            .pickerStyle(.menu)
            .frame(minWidth: 150, maxWidth: 230)
            .onChange(of: appState.selectedRepairService) { _, _ in
                Task { await appState.refreshPrivateRelayStatus() }
            }

            Spacer()

            Button {
                Task {
                    isScanning = true
                    await appState.runDiagnostics()
                    isScanning = false
                }
            } label: {
                HStack(spacing: 5) {
                    if isScanning {
                        ProgressView().controlSize(.small)
                    } else {
                        Image(systemName: "arrow.clockwise")
                    }
                    Text(isScanning ? "Scanning..." : "Run Diagnostics")
                }
            }
            .buttonStyle(GlowingButtonStyle(accentColor: GlassTheme.cyanSapphire))
            .disabled(isScanning)

            Button {
                Task { await appState.executeAutoFix() }
            } label: {
                HStack(spacing: 5) {
                    if appState.isAutoFixRunning {
                        ProgressView().controlSize(.small)
                    } else {
                        Image(systemName: "bolt.fill")
                    }
                    Text(appState.isAutoFixRunning ? "Fixing..." : "Auto-Fix")
                }
            }
            .buttonStyle(GlowingButtonStyle(accentColor: GlassTheme.sapphireBlue, isProminent: true))
            .disabled(appState.isAutoFixRunning)
        }
        .padding(.horizontal, 14)
        .padding(.vertical, 10)
        .glassCard(cornerRadius: 12)
    }

    private var captivePortalBanner: some View {
        HStack(spacing: 12) {
            Image(systemName: "lock.shield.fill")
                .font(.system(size: 20))
                .foregroundColor(GlassTheme.amberWarning)

            VStack(alignment: .leading, spacing: 2) {
                Text("Captive Portal Detected")
                    .font(.system(size: 13, weight: .semibold))
                    .foregroundColor(GlassTheme.amberWarning)
                Text("Network requires web authentication before external traffic is permitted.")
                    .font(.system(size: 12))
                    .foregroundColor(GlassTheme.textPrimary)
            }

            Spacer()

            Button("Open Login Page") {
                if let url = URL(string: "http://captive.apple.com") {
                    NSWorkspace.shared.open(url)
                }
            }
            .buttonStyle(GlowingButtonStyle(accentColor: GlassTheme.amberWarning, isProminent: true))
        }
        .padding(14)
        .glassCard(cornerRadius: 12, strokeColor: GlassTheme.amberWarning.opacity(0.45))
    }

    // MARK: - Latency Matrix

    private var latencyMatrixCard: some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack {
                SectionLabel("Latency Matrix")
                Spacer()
                Text("\(endpointMetadata.count) Endpoints")
                    .font(.system(size: 11.5))
                    .monospacedDigit()
                    .foregroundColor(GlassTheme.textTertiary)
            }

            LazyVGrid(
                columns: [GridItem(.adaptive(minimum: 185), spacing: 10)],
                spacing: 10
            ) {
                ForEach(endpointMetadata) { item in
                    latencyCell(item: item, probe: appState.endpointRTTs[item.host])
                }
            }
        }
        .padding(16)
        .glassCard(cornerRadius: 12)
    }

    private func latencyCell(item: EndpointMeta, probe: ProbeResult?) -> some View {
        let isReachable = probe?.isReachable ?? false
        let latency = probe?.latencyMs ?? 0
        let indicatorColor: Color = {
            guard let probe else { return GlassTheme.textTertiary }
            return latencyColor(latency: probe.latencyMs, isReachable: probe.isReachable)
        }()

        return VStack(alignment: .leading, spacing: 6) {
            HStack(spacing: 6) {
                Circle()
                    .fill(indicatorColor)
                    .frame(width: 7, height: 7)
                Text(item.label)
                    .font(.system(size: 12.5, weight: .semibold))
                    .foregroundColor(GlassTheme.textPrimary)
                    .lineLimit(1)
                Spacer()
                if isReachable {
                    Text(String(format: "%.1f ms", latency))
                        .font(.system(size: 12.5, weight: .semibold, design: .monospaced))
                        .monospacedDigit()
                        .foregroundColor(indicatorColor)
                } else {
                    Text(probe == nil ? "Probing..." : "Offline")
                        .font(.system(size: 11.5, weight: .medium))
                        .foregroundColor(indicatorColor)
                }
            }

            Text(item.host)
                .font(.system(size: 11, design: .monospaced))
                .foregroundColor(GlassTheme.textSecondary)
                .lineLimit(1)
                .truncationMode(.middle)

            HStack(spacing: 6) {
                Text(probe?.targetIP ?? "Unresolved")
                    .font(.system(size: 10.5, design: .monospaced))
                    .monospacedDigit()
                    .foregroundColor(GlassTheme.textTertiary)
                    .lineLimit(1)
                Spacer()
                if let loss = probe?.packetLossPercent, loss > 0 {
                    Text(String(format: "%.0f%% loss", loss))
                        .font(.system(size: 10.5, design: .monospaced))
                        .monospacedDigit()
                        .foregroundColor(GlassTheme.amberWarning)
                } else {
                    Text(item.role)
                        .font(.system(size: 10.5))
                        .foregroundColor(GlassTheme.textTertiary)
                }
            }
        }
        .padding(11)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(GlassTheme.controlFill)
        .clipShape(RoundedRectangle(cornerRadius: 9, style: .continuous))
        .overlay(
            RoundedRectangle(cornerRadius: 9, style: .continuous)
                .strokeBorder(indicatorColor.opacity(0.28), lineWidth: 0.75)
        )
    }

    // MARK: - Repair Grid & Private Relay

    private var repairToolsCard: some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack {
                SectionLabel("Manual Repairs")
                Spacer()
                if let activeRepairLabel {
                    HStack(spacing: 5) {
                        ProgressView().controlSize(.small)
                        Text(activeRepairLabel)
                            .font(.system(size: 11.5))
                            .foregroundColor(GlassTheme.textSecondary)
                    }
                } else {
                    Text("Target: \(appState.selectedRepairService)")
                        .font(.system(size: 11.5))
                        .foregroundColor(GlassTheme.textTertiary)
                }
            }

            LazyVGrid(
                columns: [GridItem(.adaptive(minimum: 136), spacing: 8)],
                spacing: 8
            ) {
                repairButton("Fix MTU (1280)", accent: GlassTheme.amberWarning) {
                    try await appState.manualFixMTU()
                }
                repairButton("Flush DNS", accent: GlassTheme.cyanSapphire) {
                    try await appState.manualFlushDNS()
                }
                repairButton("Flush ARP", accent: GlassTheme.cyanSapphire) {
                    try await appState.manualFlushARP()
                }
                repairButton("Disable IPv6", accent: GlassTheme.textSecondary) {
                    try await appState.manualDisableIPv6()
                }
                repairButton("Enable IPv6", accent: GlassTheme.textSecondary) {
                    try await appState.manualEnableIPv6()
                }
                repairButton("Reset DNS", accent: GlassTheme.textSecondary) {
                    try await appState.manualResetDNS()
                }
                repairButton("Clear Proxies", accent: GlassTheme.textSecondary) {
                    try await appState.manualCleanProxies()
                }
            }

            Rectangle()
                .fill(GlassTheme.separator)
                .frame(height: 1)

            HStack(spacing: 12) {
                VStack(alignment: .leading, spacing: 2) {
                    Text("iCloud Private Relay Isolation")
                        .font(.system(size: 13, weight: .medium))
                        .foregroundColor(GlassTheme.textPrimary)
                    Text("Bypass Private Relay canary domains on \(appState.selectedRepairService) to prevent captive portal interference.")
                        .font(.system(size: 11.5))
                        .foregroundColor(GlassTheme.textSecondary)
                }

                Spacer()

                StatusPill(
                    text: appState.isPrivateRelayIsolated ? "Isolated" : "Standard",
                    color: appState.isPrivateRelayIsolated ? GlassTheme.amberWarning : GlassTheme.textTertiary,
                    showPulse: false
                )

                Toggle("iCloud Private Relay Isolation", isOn: privateRelayBinding)
                    .labelsHidden()
                    .toggleStyle(.switch)
                    .disabled(activeRepairLabel != nil)
            }
        }
        .padding(16)
        .glassCard(cornerRadius: 12)
    }

    private func repairButton(
        _ title: String,
        accent: Color,
        action: @escaping @MainActor () async throws -> Void
    ) -> some View {
        Button {
            Task {
                await runRepairAction(label: title, operation: action)
            }
        } label: {
            Text(title)
                .frame(maxWidth: .infinity)
        }
        .buttonStyle(GlowingButtonStyle(accentColor: accent))
        .disabled(activeRepairLabel != nil)
    }

    // MARK: - Traceroute

    private var tracerouteCard: some View {
        let trimmedTarget = appState.tracerouteTarget.trimmingCharacters(in: .whitespacesAndNewlines)

        return VStack(alignment: .leading, spacing: 10) {
            HStack {
                SectionLabel("Traceroute")
                Spacer()
                if appState.isTracerouting {
                    HStack(spacing: 5) {
                        ProgressView().controlSize(.small)
                        Text("Tracing...")
                            .font(.system(size: 11.5))
                            .foregroundColor(GlassTheme.textSecondary)
                    }
                }
            }

            HStack(spacing: 10) {
                TextField("Hostname or IP address", text: $appState.tracerouteTarget)
                    .textFieldStyle(.plain)
                    .font(.system(size: 12.5, design: .monospaced))
                    .foregroundColor(GlassTheme.textPrimary)
                    .padding(.horizontal, 10)
                    .padding(.vertical, 6.5)
                    .background(GlassTheme.controlFill)
                    .clipShape(RoundedRectangle(cornerRadius: 8, style: .continuous))
                    .overlay(
                        RoundedRectangle(cornerRadius: 8, style: .continuous)
                            .strokeBorder(GlassTheme.controlBorder, lineWidth: 0.75)
                    )
                    .onSubmit {
                        guard !trimmedTarget.isEmpty, !appState.isTracerouting else { return }
                        Task { await appState.runTraceroute() }
                    }

                Button("Trace") {
                    Task { await appState.runTraceroute() }
                }
                .buttonStyle(GlowingButtonStyle(accentColor: GlassTheme.cyanSapphire))
                .disabled(trimmedTarget.isEmpty || appState.isTracerouting)
            }

            ScrollView(.vertical, showsIndicators: true) {
                VStack(alignment: .leading, spacing: 4) {
                    if appState.tracerouteHops.isEmpty {
                        Text("Enter a host or IP above and click Trace to inspect network hops.")
                            .font(.system(size: 11.5, design: .monospaced))
                            .foregroundColor(GlassTheme.textTertiary)
                            .frame(maxWidth: .infinity, alignment: .leading)
                    } else {
                        ForEach(Array(appState.tracerouteHops.enumerated()), id: \.offset) { _, hop in
                            Text(hop)
                                .font(.system(size: 11.5, design: .monospaced))
                                .monospacedDigit()
                                .foregroundColor(GlassTheme.textPrimary)
                                .frame(maxWidth: .infinity, alignment: .leading)
                        }
                    }
                }
                .padding(10)
            }
            .textSelection(.enabled)
            .frame(minHeight: 74, maxHeight: 135)
            .background(Color.black.opacity(0.35))
            .clipShape(RoundedRectangle(cornerRadius: 8, style: .continuous))
            .overlay(
                RoundedRectangle(cornerRadius: 8, style: .continuous)
                    .strokeBorder(GlassTheme.controlBorder, lineWidth: 0.75)
            )
        }
        .padding(16)
        .glassCard(cornerRadius: 12)
    }

    // MARK: - Active Issues

    private var activeIssuesCard: some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack {
                SectionLabel("Active Issues")
                Spacer()
                StatusPill(
                    text: "\(appState.activeIssues.count)",
                    color: appState.activeIssues.isEmpty ? GlassTheme.emeraldGreen : GlassTheme.amberWarning,
                    showPulse: false
                )
            }

            if appState.activeIssues.isEmpty {
                HStack(spacing: 8) {
                    Image(systemName: "checkmark.circle.fill")
                        .foregroundColor(GlassTheme.emeraldGreen)
                    Text("No active issues detected.")
                        .font(.system(size: 12))
                        .foregroundColor(GlassTheme.textSecondary)
                }
                .padding(10)
                .frame(maxWidth: .infinity, alignment: .leading)
                .background(GlassTheme.controlFill)
                .clipShape(RoundedRectangle(cornerRadius: 8, style: .continuous))
            } else {
                VStack(spacing: 8) {
                    ForEach(appState.activeIssues) { issue in
                        HStack(alignment: .top, spacing: 10) {
                            StatusPill(
                                text: severityLabel(issue.severity),
                                color: severityColor(issue.severity),
                                showPulse: false
                            )
                            VStack(alignment: .leading, spacing: 3) {
                                Text(issue.title)
                                    .font(.system(size: 12.5, weight: .semibold))
                                    .foregroundColor(GlassTheme.textPrimary)
                                Text(issue.description)
                                    .font(.system(size: 11.5))
                                    .foregroundColor(GlassTheme.textSecondary)
                                Text("Suggested action: \(issue.recommendedFixAction)")
                                    .font(.system(size: 11, design: .monospaced))
                                    .foregroundColor(GlassTheme.textTertiary)
                            }
                            Spacer()
                        }
                        .padding(10)
                        .background(GlassTheme.controlFill)
                        .clipShape(RoundedRectangle(cornerRadius: 8, style: .continuous))
                    }
                }
            }
        }
        .padding(16)
        .glassCard(cornerRadius: 12)
    }

    // MARK: - Repair Log Console

    private var repairLogCard: some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack {
                SectionLabel("Repair Log")
                Spacer()
                Button("Clear") {
                    appState.clearRepairLogs()
                }
                .buttonStyle(GlowingButtonStyle(accentColor: GlassTheme.textSecondary))
                .disabled(appState.repairLogs.isEmpty)
            }

            ScrollView(.vertical, showsIndicators: true) {
                LazyVStack(alignment: .leading, spacing: 4) {
                    if appState.repairLogs.isEmpty {
                        Text("No repair events logged. Diagnostic and remediation output will appear here.")
                            .font(.system(size: 11.5, design: .monospaced))
                            .foregroundColor(GlassTheme.textTertiary)
                            .frame(maxWidth: .infinity, alignment: .leading)
                    } else {
                        ForEach(Array(appState.repairLogs.enumerated()), id: \.offset) { _, line in
                            Text(line)
                                .font(.system(size: 11.5, design: .monospaced))
                                .monospacedDigit()
                                .foregroundColor(lineColor(for: line))
                                .frame(maxWidth: .infinity, alignment: .leading)
                        }
                    }
                }
                .padding(10)
            }
            .textSelection(.enabled)
            .frame(height: 155)
            .background(Color.black.opacity(0.35))
            .clipShape(RoundedRectangle(cornerRadius: 8, style: .continuous))
            .overlay(
                RoundedRectangle(cornerRadius: 8, style: .continuous)
                    .strokeBorder(GlassTheme.controlBorder, lineWidth: 0.75)
            )
        }
        .padding(16)
        .glassCard(cornerRadius: 12)
    }

    // MARK: - Helpers & Actions

    private var availableServiceOptions: [String] {
        var services = appState.availableServices
        if !appState.selectedRepairService.isEmpty && !services.contains(appState.selectedRepairService) {
            services.append(appState.selectedRepairService)
        }
        if services.isEmpty {
            services = ["Wi-Fi"]
        }
        return services
    }

    private var privateRelayBinding: Binding<Bool> {
        Binding(
            get: { appState.isPrivateRelayIsolated },
            set: { _ in
                Task {
                    await runRepairAction(label: "Updating Private Relay") {
                        try await appState.togglePrivateRelayIsolation()
                    }
                }
            }
        )
    }

    private func runRepairAction(
        label: String,
        operation: @MainActor () async throws -> Void
    ) async {
        activeRepairLabel = label
        defer { activeRepairLabel = nil }
        do {
            try await operation()
        } catch {
            appState.appendRepairLog("\(label) failed: \(error.localizedDescription)")
        }
    }

    private func latencyColor(latency: Double, isReachable: Bool) -> Color {
        guard isReachable else { return GlassTheme.redAlert }
        if latency < 50.0 {
            return GlassTheme.emeraldGreen
        } else if latency < 150.0 {
            return GlassTheme.amberWarning
        } else {
            return GlassTheme.redAlert
        }
    }

    private func captivePortalLabel(_ status: CaptivePortalStatus) -> String {
        switch status {
        case .notDetected: return "Portal Clear"
        case .authenticated: return "Portal Authenticated"
        case .detected: return "Captive Portal"
        case .redirecting: return "Portal Redirecting"
        case .unknown: return "Portal Unknown"
        }
    }

    private func captivePortalColor(_ status: CaptivePortalStatus) -> Color {
        switch status {
        case .notDetected, .authenticated: return GlassTheme.emeraldGreen
        case .detected, .redirecting: return GlassTheme.amberWarning
        case .unknown: return GlassTheme.textTertiary
        }
    }

    private func severityLabel(_ severity: IssueSeverity) -> String {
        switch severity {
        case .info: return "Info"
        case .warning: return "Warning"
        case .critical: return "Critical"
        }
    }

    private func severityColor(_ severity: IssueSeverity) -> Color {
        switch severity {
        case .info: return GlassTheme.cyanSapphire
        case .warning: return GlassTheme.amberWarning
        case .critical: return GlassTheme.redAlert
        }
    }

    private func lineColor(for line: String) -> Color {
        let lower = line.lowercased()
        if lower.contains("error") || lower.contains("failed") || lower.contains("denied") {
            return GlassTheme.redAlert
        } else if lower.contains("complete") || lower.contains("restored") || lower.contains("flushed") || lower.contains("authorized") {
            return GlassTheme.emeraldGreen
        } else if lower.contains("warning") || lower.contains("debounced") || lower.contains("cancelled") {
            return GlassTheme.amberWarning
        } else {
            return GlassTheme.textPrimary.opacity(0.88)
        }
    }
}
