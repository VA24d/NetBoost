import AppKit
import Foundation
import NetBoostCore

@MainActor
extension AppState {

    // MARK: - Download Accelerator Actions

    public func chooseDownloadDirectory() {
        let panel = NSOpenPanel()
        panel.canChooseDirectories = true
        panel.canChooseFiles = false
        panel.canCreateDirectories = true
        panel.directoryURL = downloadDirectory
        panel.prompt = "Select Download Folder"
        if panel.runModal() == .OK, let url = panel.url {
            downloadDirectory = url
        }
    }

    public func revealDownloadedFile() {
        guard let task = activeDownloadTask else { return }
        NSWorkspace.shared.activateFileViewerSelecting([task.destinationURL])
    }

    public func startDownload() async throws {
        let trimmed = downloadURLInput.trimmingCharacters(in: .whitespacesAndNewlines)
        guard let url = URL(string: trimmed),
              let scheme = url.scheme?.lowercased(),
              (scheme == "http" || scheme == "https"),
              let host = url.host,
              !host.isEmpty else {
            downloadError = "Invalid download URL: must begin with http:// or https:// and include a valid host"
            return
        }

        let rawName = url.lastPathComponent.replacingOccurrences(of: "/", with: "")
        let filename = (rawName.isEmpty || rawName == "." || rawName == "..") ? "download.bin" : rawName
        let destination = downloadDirectory.appendingPathComponent(filename)
        let expected = expectedChecksum.isEmpty ? nil : expectedChecksum

        appendRepairLog("Starting accelerated download: \(url.absoluteString) with \(selectedChunkCount) chunks")
        activeDownloadTask = try await downloadManager.startDownload(
            url: url,
            destination: destination,
            chunksCount: selectedChunkCount,
            expectedChecksum: expected
        )
        checksumMatchStatus = nil
        downloadError = nil
    }

    public func pauseDownload() async throws {
        guard let task = activeDownloadTask else { return }
        try await downloadManager.pauseDownload(id: task.id)
        appendRepairLog("Download paused: \(task.destinationURL.lastPathComponent)")
    }

    public func resumeDownload() async throws {
        guard let task = activeDownloadTask else { return }
        try await downloadManager.resumeDownload(id: task.id)
        appendRepairLog("Download resumed: \(task.destinationURL.lastPathComponent)")
    }

    public func cancelDownload() async throws {
        guard let task = activeDownloadTask else { return }
        try await downloadManager.cancelDownload(id: task.id)
        activeDownloadTask = nil
        checksumMatchStatus = nil
        appendRepairLog("Download cancelled: \(task.destinationURL.lastPathComponent)")
    }

    internal func resolvedChecksumAlgorithm() -> ChecksumAlgorithm? {
        switch selectedChecksumAlgorithm {
        case "SHA-256": return .sha256
        case "SHA-1": return .sha1
        case "MD5": return .md5
        default: return nil
        }
    }

    public func verifyChecksum() async -> Bool {
        guard let task = activeDownloadTask, !expectedChecksum.isEmpty else {
            checksumMatchStatus = nil
            return false
        }
        let validator = ChecksumValidator()
        let match = (try? await validator.validate(
            fileURL: task.destinationURL,
            expectedChecksum: expectedChecksum,
            algorithm: resolvedChecksumAlgorithm()
        )) ?? false
        checksumMatchStatus = match
        appendRepairLog("Checksum verification (\(selectedChecksumAlgorithm)): \(match ? "PASS" : "FAIL")")
        return match
    }

    // MARK: - AI Doctor Actions

    public func updateLMStudioEndpoint(_ raw: String) {
        lmStudioEndpointString = raw
        if let parsed = URL(string: raw.trimmingCharacters(in: .whitespacesAndNewlines)),
           let scheme = parsed.scheme?.lowercased(),
           (scheme == "http" || scheme == "https"),
           parsed.host != nil {
            lmStudioEndpoint = parsed
        }
    }

    public func refreshAIModels() async {
        guard let concreteBridge = llmBridge as? LLMDoctorBridge else { return }
        do {
            let models = try await concreteBridge.listModels(endpoint: lmStudioEndpoint)
            availableAIModels = models
            isLMStudioConnected = true
            if selectedAIModel.isEmpty, let first = models.first {
                selectedAIModel = first
            }
        } catch {
            availableAIModels = []
            isLMStudioConnected = false
        }
    }

    public func sendChatMessage(text: String) async {
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return }
        chatMessages.append(ChatMessage(role: "user", content: trimmed))
        isAIAnalyzing = true

        guard let bridge = llmBridge else {
            chatMessages.append(ChatMessage(role: "assistant", content: "LLM Bridge is not configured."))
            isAIAnalyzing = false
            return
        }

        if let concreteBridge = bridge as? LLMDoctorBridge {
            concreteBridge.selectedModel = selectedAIModel.isEmpty ? nil : selectedAIModel
        }

        do {
            let report = await campusDoctor.runFullDiagnostics()
            let analysis = try await bridge.sendChat(message: trimmed, report: report, endpoint: lmStudioEndpoint)
            latestAnalysis = analysis
            let reply = analysis.diagnosis.isEmpty
                ? (analysis.toolCalls.isEmpty ? "Diagnostics reviewed." : "Proposed \(analysis.toolCalls.count) tool action(s) below for approval.")
                : analysis.diagnosis
            chatMessages.append(ChatMessage(role: "assistant", content: reply))
            isLMStudioConnected = true
        } catch {
            isLMStudioConnected = false
            chatMessages.append(ChatMessage(
                role: "assistant",
                content: "Could not reach LM Studio at \(lmStudioEndpoint.absoluteString): \(error.localizedDescription)"
            ))
        }

        isAIAnalyzing = false
    }

    public func runDiagnosticsAndAnalyze() async {
        isAIAnalyzing = true
        appendRepairLog("Sending telemetry report to AI Doctor...")

        guard let bridge = llmBridge else {
            appendRepairLog("LLM Bridge not available")
            isAIAnalyzing = false
            return
        }

        if let concreteBridge = bridge as? LLMDoctorBridge {
            concreteBridge.selectedModel = selectedAIModel.isEmpty ? nil : selectedAIModel
        }

        do {
            let report = await campusDoctor.runFullDiagnostics()
            let analysis = try await bridge.sendTelemetry(report: report, endpoint: lmStudioEndpoint)
            latestAnalysis = analysis
            isLMStudioConnected = true
            if !analysis.diagnosis.isEmpty {
                chatMessages.append(ChatMessage(role: "assistant", content: analysis.diagnosis))
            }
            appendRepairLog("AI analysis received")
        } catch {
            isLMStudioConnected = false
            appendRepairLog("AI Doctor offline: \(error.localizedDescription)")
        }

        isAIAnalyzing = false
    }

    nonisolated internal static func runTool(
        bridge: any LLMDoctorBridgeProtocol,
        name: String,
        arguments: [String: String]
    ) async throws -> ToolResult {
        let anyArgs: [String: Any] = arguments
        return try await bridge.executeTool(name: name, arguments: anyArgs)
    }

    public func approveAndExecuteTool(
        name: String,
        arguments: [String: String],
        toolCallId: String? = nil
    ) async throws -> ToolResult {
        guard let bridge = llmBridge else {
            throw NSError(domain: "NetBoost", code: 404, userInfo: [NSLocalizedDescriptionKey: "LLM Bridge unavailable"])
        }

        appendRepairLog("Executing AI approved tool: \(name)")
        let result = try await Self.runTool(bridge: bridge, name: name, arguments: arguments)
        let callId = toolCallId ?? "call_\(UUID().uuidString.prefix(8))"
        bridge.appendToolResult(toolCallId: callId, name: name, output: result.output)

        let argsString = arguments.map { "\($0.key)=\($0.value)" }.joined(separator: ", ")
        toolExecutionLogs.append(
            ToolExecutionLog(
                toolName: name,
                arguments: argsString,
                success: result.success,
                output: result.output
            )
        )

        appendRepairLog("Tool [\(name)] output: \(result.output)")
        return result
    }
}
