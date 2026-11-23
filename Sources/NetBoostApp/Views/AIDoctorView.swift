import SwiftUI
import NetBoostCore

public struct AIDoctorView: View {
    @EnvironmentObject private var appState: AppState
    @State private var chatInputText: String = ""
    @State private var showTelemetryJSON: Bool = false
    @State private var telemetryJSONString: String = ""

    public init() {}

    public var body: some View {
        ScrollView(.vertical, showsIndicators: true) {
            VStack(alignment: .leading, spacing: 20) {
                // Header
                HStack {
                    VStack(alignment: .leading, spacing: 4) {
                        Text("Autonomous AI Network Doctor")
                            .font(.system(size: 20, weight: .bold, design: .rounded))
                            .foregroundColor(.white)
                        Text("Local LLM integration via LM Studio (http://localhost:1234/v1) for diagnosis & remediation")
                            .font(.system(size: 12))
                            .foregroundColor(GlassTheme.textSecondary)
                    }
                    Spacer()
                    StatusPill(
                        text: appState.isLMStudioConnected ? "LM STUDIO ONLINE" : "LOCAL SERVER (1234)",
                        color: appState.isLMStudioConnected ? GlassTheme.emeraldGreen : GlassTheme.amberWarning,
                        showPulse: appState.isLMStudioConnected
                    )
                }

                // AI Diagnostics Trigger & Telemetry Card
                HStack(spacing: 12) {
                    Button {
                        Task {
                            await appState.runDiagnosticsAndAnalyze()
                        }
                    } label: {
                        HStack(spacing: 6) {
                            if appState.isAIAnalyzing {
                                ProgressView().controlSize(.small).colorScheme(.dark)
                            } else {
                                Image(systemName: "cpu")
                            }
                            Text(appState.isAIAnalyzing ? "Analyzing Telemetry..." : "Scan & Analyze with AI")
                        }
                    }
                    .buttonStyle(GlowingButtonStyle(accentColor: GlassTheme.violetAccent, isProminent: true))
                    .disabled(appState.isAIAnalyzing)

                    Button("View Telemetry JSON") {
                        Task {
                            let report = await appState.campusDoctor.runFullDiagnostics()
                            let encoder = JSONEncoder()
                            encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
                            if let data = try? encoder.encode(report),
                               let str = String(data: data, encoding: .utf8) {
                                telemetryJSONString = str
                                showTelemetryJSON.toggle()
                            }
                        }
                    }
                    .buttonStyle(GlowingButtonStyle(accentColor: GlassTheme.cyanNeon))

                    Spacer()
                }

                // Telemetry JSON Viewer Box
                if showTelemetryJSON {
                    VStack(alignment: .leading, spacing: 6) {
                        HStack {
                            Text("NetworkTelemetryReport (JSON)")
                                .font(.system(size: 11, weight: .bold))
                                .foregroundColor(GlassTheme.cyanNeon)
                            Spacer()
                            Button("Close") { showTelemetryJSON = false }
                                .font(.system(size: 11))
                                .foregroundColor(GlassTheme.textTertiary)
                        }
                        ScrollView(.vertical) {
                            Text(telemetryJSONString)
                                .font(.system(size: 10, design: .monospaced))
                                .foregroundColor(Color.white.opacity(0.85))
                                .frame(maxWidth: .infinity, alignment: .leading)
                        }
                        .frame(height: 140)
                    }
                    .padding(12)
                    .background(Color.black.opacity(0.5))
                    .cornerRadius(10)
                    .overlay(
                        RoundedRectangle(cornerRadius: 10)
                            .stroke(GlassTheme.cyanNeon.opacity(0.3), lineWidth: 1)
                    )
                }

                // Latest Analysis & Recommended Tool Approvals
                if let analysis = appState.latestAnalysis {
                    VStack(alignment: .leading, spacing: 12) {
                        HStack {
                            Image(systemName: "sparkles")
                                .foregroundColor(GlassTheme.violetAccent)
                            Text("AI Diagnosis & Recommended Actions")
                                .font(.system(size: 14, weight: .bold))
                                .foregroundColor(.white)
                        }

                        Text(analysis.diagnosis)
                            .font(.system(size: 12))
                            .foregroundColor(Color.white.opacity(0.9))
                            .padding(10)
                            .background(Color.black.opacity(0.3))
                            .cornerRadius(8)

                        if !analysis.toolCalls.isEmpty {
                            Text("RECOMMENDED TOOL INVOCATIONS (AWAITING APPROVAL)")
                                .font(.system(size: 10, weight: .bold))
                                .foregroundColor(GlassTheme.amberWarning)

                            VStack(spacing: 8) {
                                ForEach(analysis.toolCalls, id: \.id) { call in
                                    HStack {
                                        VStack(alignment: .leading, spacing: 2) {
                                            Text(call.name)
                                                .font(.system(size: 12, weight: .bold, design: .monospaced))
                                                .foregroundColor(GlassTheme.cyanNeon)
                                            Text(call.arguments.map { "\($0.key): \($0.value)" }.joined(separator: ", "))
                                                .font(.system(size: 10, design: .monospaced))
                                                .foregroundColor(GlassTheme.textSecondary)
                                        }
                                        Spacer()
                                        Button("Approve & Execute") {
                                            Task {
                                                let strArgs = call.arguments.reduce(into: [String: String]()) { acc, elem in
                                                    acc[elem.key] = "\(elem.value)"
                                                }
                                                _ = try? await appState.approveAndExecuteTool(
                                                    name: call.name,
                                                    arguments: strArgs
                                                )
                                            }
                                        }
                                        .buttonStyle(GlowingButtonStyle(accentColor: GlassTheme.emeraldGreen))
                                    }
                                    .padding(10)
                                    .background(Color.white.opacity(0.04))
                                    .cornerRadius(8)
                                }
                            }
                        }
                    }
                    .padding(16)
                    .glassCard(cornerRadius: 14, strokeColor: GlassTheme.violetAccent.opacity(0.4))
                }

                // Multi-Turn Chat Interface
                VStack(alignment: .leading, spacing: 12) {
                    Text("Interactive Diagnostic Chat")
                        .font(.system(size: 14, weight: .bold))
                        .foregroundColor(.white)

                    // Chat messages list
                    VStack(spacing: 10) {
                        if appState.chatMessages.isEmpty {
                            Text("No chat history. Ask AI Doctor about campus Wi-Fi drops, MTU issues, or routing.")
                                .font(.system(size: 12))
                                .foregroundColor(GlassTheme.textTertiary)
                                .frame(maxWidth: .infinity)
                                .padding(.vertical, 24)
                        } else {
                            ForEach(Array(appState.chatMessages.enumerated()), id: \.offset) { _, msg in
                                HStack {
                                    if msg.role == "user" { Spacer() }
                                    VStack(alignment: msg.role == "user" ? .trailing : .leading, spacing: 2) {
                                        Text(msg.role.uppercased())
                                            .font(.system(size: 8, weight: .bold))
                                            .foregroundColor(msg.role == "user" ? GlassTheme.cyanNeon : GlassTheme.violetAccent)
                                        Text(msg.content)
                                            .font(.system(size: 12))
                                            .foregroundColor(.white)
                                    }
                                    .padding(10)
                                    .background(msg.role == "user" ? GlassTheme.cyanNeon.opacity(0.15) : Color.white.opacity(0.06))
                                    .cornerRadius(10)
                                    if msg.role != "user" { Spacer() }
                                }
                            }
                        }
                    }
                    .padding(12)
                    .background(Color.black.opacity(0.3))
                    .cornerRadius(10)

                    // Input bar
                    HStack(spacing: 10) {
                        TextField("Ask AI Doctor to diagnose or remediate...", text: $chatInputText)
                            .textFieldStyle(.plain)
                            .font(.system(size: 12))
                            .padding(10)
                            .background(Color.black.opacity(0.35))
                            .cornerRadius(8)
                            .onSubmit {
                                let text = chatInputText
                                chatInputText = ""
                                Task { await appState.sendChatMessage(text: text) }
                            }

                        Button("Send") {
                            let text = chatInputText
                            chatInputText = ""
                            Task { await appState.sendChatMessage(text: text) }
                        }
                        .buttonStyle(GlowingButtonStyle(accentColor: GlassTheme.violetAccent))
                        .disabled(chatInputText.isEmpty || appState.isAIAnalyzing)
                    }
                }
                .padding(16)
                .glassCard(cornerRadius: 14)

                // Tool Execution History Logs
                if !appState.toolExecutionLogs.isEmpty {
                    VStack(alignment: .leading, spacing: 10) {
                        Text("Autonomous Tool Execution Logs")
                            .font(.system(size: 14, weight: .bold))
                            .foregroundColor(.white)

                        VStack(spacing: 6) {
                            ForEach(appState.toolExecutionLogs) { log in
                                HStack {
                                    Image(systemName: log.success ? "checkmark.circle.fill" : "xmark.circle.fill")
                                        .foregroundColor(log.success ? GlassTheme.emeraldGreen : GlassTheme.redAlert)
                                    Text(log.toolName)
                                        .font(.system(size: 11, weight: .bold, design: .monospaced))
                                        .foregroundColor(.white)
                                    Text(log.output)
                                        .font(.system(size: 11, design: .monospaced))
                                        .foregroundColor(GlassTheme.textSecondary)
                                        .lineLimit(1)
                                    Spacer()
                                }
                                .padding(8)
                                .background(Color.white.opacity(0.03))
                                .cornerRadius(6)
                            }
                        }
                    }
                    .padding(16)
                    .glassCard(cornerRadius: 14)
                }
            }
            .padding(20)
        }
    }
}
