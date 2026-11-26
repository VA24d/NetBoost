import Foundation
import NetBoostCore
import SwiftUI

public struct AIDoctorView: View {
    @EnvironmentObject private var appState: AppState
    @State private var chatInputText = ""
    @State private var isRefreshingModels = false
    @State private var showTelemetryJSON = false
    @State private var telemetryJSONString = ""
    @State private var executingToolIDs: Set<String> = []
    @State private var toolErrorMessage: String? = nil

    public init() {}

    public var body: some View {
        ScrollView(.vertical, showsIndicators: true) {
            VStack(alignment: .leading, spacing: 16) {
                headerRow
                connectionBarCard

                if showTelemetryJSON {
                    telemetryInspectorCard
                }

                if let analysis = appState.latestAnalysis,
                   !analysis.toolCalls.isEmpty || (appState.chatMessages.isEmpty && !analysis.diagnosis.isEmpty) {
                    proposedToolsCard(analysis: analysis)
                }

                chatCard

                if !appState.toolExecutionLogs.isEmpty {
                    toolExecutionLogsCard
                }
            }
            .padding(20)
        }
    }

    // MARK: - Header

    private var headerRow: some View {
        HStack(alignment: .center, spacing: 12) {
            PageHeader(
                title: "AI Network Doctor",
                subtitle: "Local LLM diagnostics and human-approved remediation via LM Studio"
            )
            Spacer()
            StatusPill(
                text: appState.isLMStudioConnected ? "Connected" : "Offline",
                color: appState.isLMStudioConnected ? GlassTheme.emeraldGreen : GlassTheme.amberWarning,
                showPulse: appState.isLMStudioConnected
            )
        }
    }

    // MARK: - LM Studio Connection Bar

    private var connectionBarCard: some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack(spacing: 10) {
                Text("Endpoint")
                    .font(.system(size: 12.5))
                    .foregroundColor(GlassTheme.textSecondary)
                    .frame(width: 62, alignment: .leading)

                TextField("http://localhost:1234/v1/chat/completions", text: $appState.lmStudioEndpointString)
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
                    .onSubmit {
                        applyEndpointAndRefresh()
                    }

                Button("Apply") {
                    applyEndpointAndRefresh()
                }
                .buttonStyle(GlowingButtonStyle(accentColor: GlassTheme.cyanSapphire))
            }

            HStack(spacing: 10) {
                Text("Model")
                    .font(.system(size: 12.5))
                    .foregroundColor(GlassTheme.textSecondary)
                    .frame(width: 62, alignment: .leading)

                Picker("Model", selection: $appState.selectedAIModel) {
                    Text("Auto / Default").tag("")
                    ForEach(modelOptions, id: \.self) { model in
                        Text(model).tag(model)
                    }
                }
                .labelsHidden()
                .pickerStyle(.menu)
                .frame(minWidth: 140, maxWidth: 220)

                Button {
                    Task {
                        isRefreshingModels = true
                        await appState.refreshAIModels()
                        isRefreshingModels = false
                    }
                } label: {
                    HStack(spacing: 5) {
                        if isRefreshingModels {
                            ProgressView().controlSize(.small)
                        } else {
                            Image(systemName: "arrow.clockwise")
                        }
                        Text("Refresh Models")
                    }
                }
                .buttonStyle(GlowingButtonStyle(accentColor: GlassTheme.cyanSapphire))
                .disabled(isRefreshingModels)

                Spacer()

                Button {
                    Task { await appState.runDiagnosticsAndAnalyze() }
                } label: {
                    HStack(spacing: 5) {
                        if appState.isAIAnalyzing {
                            ProgressView().controlSize(.small)
                        } else {
                            Image(systemName: "waveform.path.ecg")
                        }
                        Text(appState.isAIAnalyzing ? "Analyzing..." : "Analyze Network")
                    }
                }
                .buttonStyle(GlowingButtonStyle(accentColor: GlassTheme.violetAccent, isProminent: true))
                .disabled(appState.isAIAnalyzing)
            }
        }
        .padding(14)
        .glassCard(cornerRadius: 12)
    }

    // MARK: - Optional Telemetry JSON Inspector

    private var telemetryInspectorCard: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack {
                SectionLabel("Network Telemetry Snapshot")
                Spacer()
                Button("Close") { showTelemetryJSON = false }
                    .buttonStyle(.plain)
                    .font(.system(size: 11.5))
                    .foregroundColor(GlassTheme.textSecondary)
            }

            ScrollView(.vertical, showsIndicators: true) {
                Text(telemetryJSONString)
                    .font(.system(size: 11, design: .monospaced))
                    .monospacedDigit()
                    .foregroundColor(GlassTheme.textPrimary.opacity(0.9))
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .padding(10)
            }
            .textSelection(.enabled)
            .frame(height: 140)
            .background(Color.black.opacity(0.35))
            .clipShape(RoundedRectangle(cornerRadius: 8, style: .continuous))
        }
        .padding(14)
        .glassCard(cornerRadius: 12, strokeColor: GlassTheme.cyanSapphire.opacity(0.3))
    }

    // MARK: - Proposed Remediation Tools

    private func proposedToolsCard(analysis: LLMAnalysis) -> some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack {
                SectionLabel("Proposed Remediation Tools")
                Spacer()
                if !analysis.toolCalls.isEmpty {
                    StatusPill(
                        text: "\(analysis.toolCalls.count) Pending",
                        color: GlassTheme.amberWarning,
                        showPulse: false
                    )
                }
            }

            if appState.chatMessages.isEmpty && !analysis.diagnosis.isEmpty {
                Text(analysis.diagnosis)
                    .font(.system(size: 12.5))
                    .foregroundColor(GlassTheme.textPrimary)
                    .padding(10)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .background(GlassTheme.controlFill)
                    .clipShape(RoundedRectangle(cornerRadius: 8, style: .continuous))
            }

            if let toolErrorMessage {
                HStack(spacing: 8) {
                    Image(systemName: "exclamationmark.triangle.fill")
                        .foregroundColor(GlassTheme.redAlert)
                    Text(toolErrorMessage)
                        .font(.system(size: 12))
                        .foregroundColor(GlassTheme.redAlert)
                    Spacer()
                    Button {
                        self.toolErrorMessage = nil
                    } label: {
                        Image(systemName: "xmark")
                            .font(.system(size: 11, weight: .semibold))
                            .foregroundColor(GlassTheme.textTertiary)
                    }
                    .buttonStyle(.plain)
                }
            }

            ForEach(analysis.toolCalls, id: \.id) { call in
                proposedToolRow(call: call)
            }
        }
        .padding(16)
        .glassCard(cornerRadius: 12, strokeColor: GlassTheme.violetAccent.opacity(0.35))
    }

    private func proposedToolRow(call: ToolCallInvocation) -> some View {
        let isExecuting = executingToolIDs.contains(call.id)
        let argsText = formattedArguments(call.arguments)

        return HStack(spacing: 12) {
            VStack(alignment: .leading, spacing: 3) {
                Text(call.name)
                    .font(.system(size: 12.5, weight: .semibold, design: .monospaced))
                    .foregroundColor(GlassTheme.cyanSapphire)
                Text(argsText.isEmpty ? "No parameters" : argsText)
                    .font(.system(size: 11.5, design: .monospaced))
                    .monospacedDigit()
                    .foregroundColor(GlassTheme.textSecondary)
                    .lineLimit(2)
            }

            Spacer()

            Button {
                let callId = call.id
                let callName = call.name
                let strArgs = Self.stringifyArguments(call.arguments)
                Task {
                    await executeProposedTool(name: callName, arguments: strArgs, toolCallId: callId)
                }
            } label: {
                HStack(spacing: 5) {
                    if isExecuting {
                        ProgressView().controlSize(.small)
                    } else {
                        Image(systemName: "checkmark.shield")
                    }
                    Text(isExecuting ? "Running..." : "Approve & Run")
                }
            }
            .buttonStyle(GlowingButtonStyle(accentColor: GlassTheme.emeraldGreen, isProminent: true))
            .disabled(isExecuting)
        }
        .padding(10)
        .background(GlassTheme.controlFill)
        .clipShape(RoundedRectangle(cornerRadius: 8, style: .continuous))
        .overlay(
            RoundedRectangle(cornerRadius: 8, style: .continuous)
                .strokeBorder(GlassTheme.controlBorder, lineWidth: 0.75)
        )
    }

    // MARK: - Interactive Chat

    private var chatCard: some View {
        let trimmedMessage = chatInputText.trimmingCharacters(in: .whitespacesAndNewlines)

        return VStack(alignment: .leading, spacing: 12) {
            HStack {
                SectionLabel("Diagnostic Chat")
                Spacer()
                if appState.isAIAnalyzing {
                    HStack(spacing: 6) {
                        ProgressView().controlSize(.small)
                        Text("Analyzing...")
                            .font(.system(size: 11.5))
                            .foregroundColor(GlassTheme.textSecondary)
                    }
                }
                Button(showTelemetryJSON ? "Hide Telemetry" : "Telemetry JSON") {
                    Task { await toggleTelemetryPreview() }
                }
                .buttonStyle(GlowingButtonStyle(accentColor: GlassTheme.textSecondary))
            }

            ScrollViewReader { proxy in
                ScrollView(.vertical, showsIndicators: true) {
                    LazyVStack(spacing: 10) {
                        if appState.chatMessages.isEmpty {
                            Text("Ask about Wi-Fi drops, MTU sizing, DNS failures, or route conflicts.")
                                .font(.system(size: 12))
                                .foregroundColor(GlassTheme.textTertiary)
                                .frame(maxWidth: .infinity)
                                .padding(.vertical, 40)
                        } else {
                            ForEach(Array(appState.chatMessages.enumerated()), id: \.offset) { index, msg in
                                chatBubble(message: msg)
                                    .id(index)
                            }
                        }
                    }
                    .padding(12)
                }
                .onChange(of: appState.chatMessages.count) { _, newCount in
                    guard newCount > 0 else { return }
                    withAnimation(.easeOut(duration: 0.2)) {
                        proxy.scrollTo(newCount - 1, anchor: .bottom)
                    }
                }
            }
            .frame(minHeight: 190, maxHeight: 280)
            .background(Color.black.opacity(0.32))
            .clipShape(RoundedRectangle(cornerRadius: 10, style: .continuous))
            .overlay(
                RoundedRectangle(cornerRadius: 10, style: .continuous)
                    .strokeBorder(GlassTheme.controlBorder, lineWidth: 0.75)
            )

            HStack(spacing: 10) {
                TextField("Ask AI Doctor to diagnose or suggest a fix...", text: $chatInputText)
                    .textFieldStyle(.plain)
                    .font(.system(size: 12.5))
                    .foregroundColor(GlassTheme.textPrimary)
                    .padding(.horizontal, 10)
                    .padding(.vertical, 8)
                    .background(GlassTheme.controlFill)
                    .clipShape(RoundedRectangle(cornerRadius: 8, style: .continuous))
                    .overlay(
                        RoundedRectangle(cornerRadius: 8, style: .continuous)
                            .strokeBorder(GlassTheme.controlBorder, lineWidth: 0.75)
                    )
                    .onSubmit {
                        submitChatMessage()
                    }

                Button("Send") {
                    submitChatMessage()
                }
                .buttonStyle(GlowingButtonStyle(accentColor: GlassTheme.cyanSapphire, isProminent: true))
                .disabled(trimmedMessage.isEmpty || appState.isAIAnalyzing)
            }
        }
        .padding(16)
        .glassCard(cornerRadius: 12)
    }

    private func chatBubble(message: ChatMessage) -> some View {
        let isUser = message.role == "user"
        let roleLabel: String = {
            switch message.role {
            case "user": return "You"
            case "tool": return message.name ?? "Tool"
            default: return "AI Doctor"
            }
        }()

        return HStack {
            if isUser { Spacer(minLength: 64) }

            VStack(alignment: isUser ? .trailing : .leading, spacing: 4) {
                Text(roleLabel)
                    .font(.system(size: 10.5, weight: .semibold))
                    .foregroundColor(isUser ? GlassTheme.cyanSapphire : GlassTheme.violetAccent)

                Text(message.content)
                    .font(.system(size: 12.5))
                    .foregroundColor(GlassTheme.textPrimary)
                    .textSelection(.enabled)
                    .fixedSize(horizontal: false, vertical: true)
            }
            .padding(.horizontal, 12)
            .padding(.vertical, 9)
            .background(
                isUser
                    ? GlassTheme.sapphireBlue.opacity(0.24)
                    : GlassTheme.controlFill
            )
            .clipShape(RoundedRectangle(cornerRadius: 10, style: .continuous))
            .overlay(
                RoundedRectangle(cornerRadius: 10, style: .continuous)
                    .strokeBorder(
                        isUser ? GlassTheme.cyanSapphire.opacity(0.32) : GlassTheme.controlBorder,
                        lineWidth: 0.75
                    )
            )

            if !isUser { Spacer(minLength: 64) }
        }
    }

    // MARK: - Tool Execution Log

    private var toolExecutionLogsCard: some View {
        VStack(alignment: .leading, spacing: 10) {
            SectionLabel("Recent Tool Execution")

            VStack(spacing: 6) {
                ForEach(appState.toolExecutionLogs.reversed()) { log in
                    HStack(alignment: .top, spacing: 8) {
                        Image(systemName: log.success ? "checkmark.circle.fill" : "xmark.circle.fill")
                            .font(.system(size: 12))
                            .foregroundColor(log.success ? GlassTheme.emeraldGreen : GlassTheme.redAlert)
                            .padding(.top, 2)

                        VStack(alignment: .leading, spacing: 2) {
                            HStack(spacing: 6) {
                                Text(log.toolName)
                                    .font(.system(size: 12, weight: .semibold, design: .monospaced))
                                    .foregroundColor(GlassTheme.textPrimary)
                                if !log.arguments.isEmpty {
                                    Text(log.arguments)
                                        .font(.system(size: 11, design: .monospaced))
                                        .foregroundColor(GlassTheme.textTertiary)
                                        .lineLimit(1)
                                }
                            }
                            Text(log.output)
                                .font(.system(size: 11.5, design: .monospaced))
                                .foregroundColor(GlassTheme.textSecondary)
                                .textSelection(.enabled)
                        }

                        Spacer()

                        Text(log.timestamp.formatted(date: .omitted, time: .standard))
                            .font(.system(size: 10.5, design: .monospaced))
                            .monospacedDigit()
                            .foregroundColor(GlassTheme.textTertiary)
                    }
                    .padding(9)
                    .background(GlassTheme.controlFill)
                    .clipShape(RoundedRectangle(cornerRadius: 8, style: .continuous))
                }
            }
        }
        .padding(16)
        .glassCard(cornerRadius: 12)
    }

    // MARK: - Helpers & Actions

    private var modelOptions: [String] {
        var options = appState.availableAIModels
        if !appState.selectedAIModel.isEmpty && !options.contains(appState.selectedAIModel) {
            options.append(appState.selectedAIModel)
        }
        return options
    }

    private func applyEndpointAndRefresh() {
        appState.updateLMStudioEndpoint(appState.lmStudioEndpointString)
        Task {
            isRefreshingModels = true
            await appState.refreshAIModels()
            isRefreshingModels = false
        }
    }

    private func toggleTelemetryPreview() async {
        if showTelemetryJSON {
            showTelemetryJSON = false
            return
        }
        let report = await appState.campusDoctor.runFullDiagnostics()
        if let formatted = try? TelemetryExporter.exportJSON(report: report, pretty: true) {
            telemetryJSONString = formatted
            showTelemetryJSON = true
        }
    }

    private func submitChatMessage() {
        let trimmed = chatInputText.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty, !appState.isAIAnalyzing else { return }
        chatInputText = ""
        Task {
            await appState.sendChatMessage(text: trimmed)
        }
    }

    private func executeProposedTool(name: String, arguments: [String: String], toolCallId: String) async {
        executingToolIDs.insert(toolCallId)
        toolErrorMessage = nil
        defer { executingToolIDs.remove(toolCallId) }
        do {
            _ = try await appState.approveAndExecuteTool(
                name: name,
                arguments: arguments,
                toolCallId: toolCallId
            )
        } catch {
            toolErrorMessage = "Failed to execute \(name): \(error.localizedDescription)"
        }
    }

    private func formattedArguments(_ arguments: [String: Any]) -> String {
        Self.stringifyArguments(arguments)
            .sorted { $0.key < $1.key }
            .map { "\($0.key): \($0.value)" }
            .joined(separator: ", ")
    }

    private static func stringifyArguments(_ arguments: [String: Any]) -> [String: String] {
        arguments.reduce(into: [String: String]()) { acc, elem in
            acc[elem.key] = stringifyValue(elem.value)
        }
    }

    private static func stringifyValue(_ value: Any) -> String {
        if let str = value as? String {
            return str
        }
        if let arr = value as? [Any] {
            return arr.map { stringifyValue($0) }.joined(separator: ", ")
        }
        if let num = value as? NSNumber {
            if CFGetTypeID(num) == CFBooleanGetTypeID() {
                return num.boolValue ? "true" : "false"
            }
            return num.stringValue
        }
        return "\(value)"
    }
}
