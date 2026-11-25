import Foundation
import NetBoostCore

@MainActor
extension AppState {

    // MARK: - Hotspot Actions

    public var canEnableHotspot: Bool {
        upstreamInterface == "en10" || activeEnvironment.isCampusLAN || (activeEnvironment.primaryInterface == "en10")
    }

    public var hotspotPasswordValidationError: String? {
        if hotspotSSID.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty || hotspotSSID.utf8.count > 32 {
            return "Network name must be 1 to 32 bytes."
        }
        if hotspotPassword.utf8.count < 8 || hotspotPassword.utf8.count > 63 {
            return "WPA passphrase must be between 8 and 63 bytes."
        }
        return nil
    }

    public func toggleHotspot() async throws {
        guard canEnableHotspot else {
            hotspotError = "Hotspot sharing requires active Wired Ethernet (en10)."
            appendRepairLog("Hotspot toggle failed: \(upstreamInterface) not active")
            return
        }

        if isHotspotActive {
            try await hotspotController.stopHotspot()
            isHotspotActive = false
            isRadioBroadcasting = false
            connectedClients = []
            hotspotConfig.isActive = false
            appendRepairLog("Hotspot stopped on \(downstreamInterface)")
        } else {
            if let validationErr = hotspotPasswordValidationError {
                hotspotError = validationErr
                appendRepairLog("Hotspot configuration invalid: \(validationErr)")
                return
            }

            hotspotConfig.upstreamInterface = upstreamInterface
            hotspotConfig.interfaceName = downstreamInterface
            hotspotConfig.ssid = hotspotSSID
            hotspotConfig.password = hotspotPassword
            hotspotConfig.securityType = hotspotSecurityType
            hotspotController.updateConfiguration(hotspotConfig)

            try await hotspotController.startHotspot(configuration: hotspotConfig)
            await refreshAuthorizationStatus()
            isHotspotActive = true
            hotspotConfig.isActive = true
            isRadioBroadcasting = await hotspotController.isRadioBroadcasting()
            connectedClients = await hotspotController.connectedClients()
            appendRepairLog("Hotspot started sharing \(upstreamInterface) -> \(downstreamInterface)")
        }
        hotspotError = nil
    }

    public func openSystemSharingSettings() {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/usr/bin/open")
        process.arguments = ["x-apple.systempreferences:com.apple.Sharing-Settings.extension"]
        try? process.run()
    }

    public func refreshHotspotClients() async {
        isRadioBroadcasting = await hotspotController.isRadioBroadcasting()
        guard isHotspotActive || isRadioBroadcasting else { return }
        connectedClients = await hotspotController.connectedClients()
    }
}
