# NetBoost architecture

NetBoost splits core engines, desktop UI, and root tools across three Swift 6 targets. The package builds with Swift Package Manager for macOS 14 and newer.

## Package targets

```text
NetBoostCore    Sources/Core            Headless networking, parsers, diagnostics, downloader, privilege client
NetBoostApp     Sources/NetBoostApp     SwiftUI window, menu bar popover, and @MainActor AppState
NetBoostHelper  Sources/NetBoostHelper  Root LaunchDaemon at /Library/LaunchDaemons/com.netboost.helper.plist
NetBoostTests   Tests                   Swift Testing unit, mock, and Tier 1 to Tier 5 suites
```

## File structure

```text
Sources/
├── Core/
│   ├── AIBridge/       LLMDoctorBridge.swift, TelemetryExporter.swift, ToolSchema.swift
│   ├── Diagnostics/    CampusDoctor.swift, CaptivePortalDetector.swift, LatencyProbe.swift,
│   │                   MTUManager.swift, RepairRoutines.swift, ServiceOrderManager.swift
│   ├── Downloader/     DownloadManager.swift, RangeProbe.swift, ChunkPartitionEngine.swift,
│   │                   ChunkWorker.swift, DiskAssembler.swift, ChecksumValidator.swift, ClipboardWatcher.swift
│   ├── Hotspot/        HotspotNATController.swift, DHCPServer.swift, DNSProxy.swift, ARPScanner.swift
│   ├── Models/         AcceleratorModels.swift, DiagnosticModels.swift, HotspotModels.swift,
│   │                   InterfaceModels.swift, ProxyModels.swift, VPNModels.swift
│   ├── NetworkEngine/  InterfaceProxyDispatcher.swift, SOCKS5Server.swift, HTTPProxyServer.swift,
│   │                   ProxySocketIO.swift, RoutePinningEngine.swift, ShellEnvGenerator.swift
│   ├── System/         PrivilegeHelper.swift, HelperProtocol.swift, DarwinSocketHelper.swift, ShellCommand.swift
│   └── VPN/            NetworkSensor.swift, VPNRuleEngine.swift, PassepartoutController.swift,
│                       OpenVPNParser.swift, RouteConflictDetector.swift
├── NetBoostApp/
│   ├── App/            NetBoostApp.swift, AppState.swift, AppStateTypes.swift,
│   │                   AppState+Hotspot.swift, AppState+ProxyAndVPN.swift,
│   │                   AppState+DownloaderAndAI.swift, AppState+Diagnostics.swift
│   ├── Theme/          GlassTheme.swift
│   └── Views/          MainWindowView.swift, HeaderBarView.swift, MenuBarPopupView.swift,
│                       WindowConfigurator.swift, DashboardView.swift, HotspotView.swift,
│                       DispatcherView.swift, VPNView.swift, AcceleratorView.swift,
│                       DoctorView.swift, AIDoctorView.swift
└── NetBoostHelper/
    └── main.swift

Assets/                 AppIcon.png, screenshots/

Scripts/                build.sh, run_tests.sh, package_dmg.sh, netboost-helper.sh,
                        empty.modulemap, empty.swiftoverlay, testing_foundation.modulemap
Tests/                  AppTests/, CoreTests/, DiagnosticsTests/, DownloaderTests/, LLMBridgeTests/,
                        MockVerificationTests/, ProxyTests/, VPNTests/, E2ETests/Tier1..Tier5/,
                        Mocks/, Fixtures/, Helpers/
```

## Subsystems

### Privilege boundary (`PrivilegeHelper` and `NetBoostHelper`)

1. `PrivilegeHelper` pings `/var/run/netboost/helper.sock` and compares the bundled `NetBoostHelper` SHA-256 hash with `/Library/PrivilegedHelperTools/com.netboost.helper`.
2. If the daemon is absent or outdated, one `osascript` admin prompt installs the binary. That setup also saves the calling UID under `/Library/Application Support/NetBoost/authorized_uid` and bootstraps the LaunchDaemon.
3. On each request, `NetBoostHelper` checks the client UID with `LOCAL_PEERCRED` (`xucred`) before reading payload bytes. Validated `HelperAction` requests run system binaries via Foundation `Process` without `/bin/sh`.

### Proxy dispatcher and static routes

`InterfaceProxyDispatcher` listens on `127.0.0.1` ports `1080`, `1081`, and `1082`. Peeking the first byte selects SOCKS5 (`SOCKS5Server`) or HTTP CONNECT (`HTTPProxyServer`). Upstream sockets bind via `IP_BOUND_IF` or `IPV6_BOUND_IF`, clear read timeouts once relaying begins, and count transferred bytes. `RoutePinningEngine` parses `netstat -rn` and runs `route add` or `route delete` for pinned subnets.

### Hotspot NAT (`HotspotNATController`)

`HotspotNATController` writes rules into the `netboost` and `com.apple/netboost` PF anchor files and checks syntax with `pfctl -nf`. It imports `com.apple.nat` XML plists validated by `plutil -lint`. If `bridge100` already controls `en0`, setup skips the alias step. Connected devices come from `/var/db/dhcpd_leases` merged with `ARPScanner` results.

### VPN automation (`NetworkSensor` and `PassepartoutController`)

`NetworkSensor` merges `NWPathMonitor` callbacks with `getifaddrs` metadata and ignores `bridge100` and hotspot aliases. That classifier detects campus Ethernet, cellular hotspots, external Wi-Fi, or offline state. `VPNRuleEngine`, `PassepartoutController`, and `RouteConflictDetector` control `scutil --nc` services. Imported `.ovpn` files are also checked against physical LAN interfaces for route overlap.

### Downloader, diagnostics, and AI bridge

`DownloadManager` coordinates `RangeProbe`, `ChunkPartitionEngine`, `ChunkWorker`, `DiskAssembler`, and `ChecksumValidator`. Workers stream HTTP byte ranges in 64 KB buffers, keeping memory flat.

`CampusDoctor` runs `RepairRoutines`, `MTUManager`, `ServiceOrderManager`, `LatencyProbe`, and `CaptivePortalDetector`. Repair commands quote multi-word service names safely. Separately, `LLMDoctorBridge` queries `/v1/models` and `/v1/chat/completions` on LM Studio. Proposed tool calls wait for user approval.

### Desktop UI (`NetBoostApp`)

`MainWindowView` renders a translucent sidebar (`Cmd+1` to `Cmd+7`). In the top bar, `HeaderBarView` shows live throughput and helper status, while `MenuBarPopupView` shows quick toggles. `GlassTheme` sets dark color tokens and a 920 by 600 point minimum frame. Reduced transparency swaps blur layers for solid fills.
