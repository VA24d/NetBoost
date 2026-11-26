# NetBoost product specification

NetBoost targets macOS 27 (Golden Gate), requiring Xcode 16+ or Swift 6.0+ Command Line Tools. It handles networks where 802.1X Ethernet, tethering, split OpenVPN, and rate limits collide.

## Functional requirements

### 1. Ethernet-to-Wi-Fi sharing

Many 802.1X networks use PEAP or MSCHAPv2, and Apple's `configd` blocks Internet Sharing on any adapter running `eapolclient`. NetBoost checks for active 802.1X sessions first. It avoids writing stale NAT rules for locked adapters and selects clean non-802.1X Ethernet or USB uplinks when present. For eligible uplinks, it sets `net.inet.ip.forwarding=1`, loads the `netboost` PF anchor, and writes WPA2 or WPA3 settings to `com.apple.nat`. When wired Ethernet (`en10`) runs 802.1X, the UI points traffic to Proxy Dispatcher (`127.0.0.1:1080`). Active clients appear from `bootpd` leases and ARP scans.

### 2. Wired LAN VPN automation

Split-tunnel OpenVPN profiles on wired Ethernet collide with local switch routes. Away from wired LAN on a hotspot or external Wi-Fi, you still need that tunnel to reach internal hosts. Events from `NWPathMonitor` trigger `VPNRuleEngine` to drop the VPN on any active wired Ethernet subnet. Off wired LAN, it reconnects after checking `.ovpn` files for route overlap.

### 3. Per-interface proxy dispatcher and route pinning

Cluster jobs can stay on Ethernet while browser traffic uses Wi-Fi. `InterfaceProxyDispatcher` runs SOCKS5 and HTTP CONNECT listeners on `127.0.0.1` using `IP_BOUND_IF` and `IPV6_BOUND_IF`:

- Port `1080` binds outbound sockets to `en10`
- Port `1081` binds outbound sockets to `en0`
- Port `1082` alternates between `en10` and `en0`

The Proxy tab copies shell export variables, runs commands with proxy variables set, and pins subnets (`10.8.0.0/16`, `10.4.0.0/16`) to Ethernet.

### 4. Multi-connection download accelerator

When gateways throttle single TCP flows, `DownloadManager` probes `Accept-Ranges: bytes` support and opens 4 to 16 streaming `URLSession.bytes` workers. Each worker writes segments directly into `~/Downloads` through random-access `FileHandle` seeks. A background clipboard monitor catches HTTP and HTTPS download URLs, and `ChecksumValidator` checks SHA-256, SHA-1, or MD5 digests.

### 5. Network repairs and persistent authorization

Mobile tethering at MTU 1500 can cause TLS `bad record mac` failures, while broken IPv6 routes stall TCP connections. Users pick a target service (`Wi-Fi`, `USB 10/100 LAN`, or a custom adapter) to run repairs. Fixes cover MTU 1280 tuning, DNS and ARP flushes, IPv6 toggles, proxy cleanups, service ordering, and Private Relay bypass rules. The first admin prompt installs a LaunchDaemon so future repairs run without repeat password dialogs.

### 6. Local AI diagnostics

`LLMDoctorBridge` posts live `NetworkTelemetryReport` snapshots and follow-up questions to a local LM Studio server (`http://localhost:1234/v1`). It queries `/v1/models`, shows suggested diagnostic or repair tool calls, and requires user approval before running any command.

### 7. Native desktop interface

`MainWindowView` provides a translucent sidebar (`Cmd+1` to `Cmd+7`), live throughput readouts, `Cmd+Shift+F` auto-fix, and `Cmd+R` telemetry refresh. Layouts fit down to 920 by 600 points and fall back to solid fills under reduced transparency. The macOS menu bar item and popover display the active wired LAN adapter, IPv4 address, and `802.1X` or `Connected` status.

## File structure guide

```text
Hotspot NAT, DHCP, DNS, ARP        Sources/Core/Hotspot/        Tests/HotspotTests/, Tests/DiagnosticsTests/
Proxy dispatcher & route pinning   Sources/Core/NetworkEngine/  Tests/ProxyTests/
Wired LAN VPN rules & .ovpn parser Sources/Core/VPN/            Tests/VPNTests/
Multi-chunk HTTP downloader        Sources/Core/Downloader/     Tests/DownloaderTests/
Network doctor, MTU, probes        Sources/Core/Diagnostics/    Tests/DiagnosticsTests/
Privilege client & sockets         Sources/Core/System/         Tests/CoreTests/
Root LaunchDaemon executable       Sources/NetBoostHelper/      Tests/CoreTests/HelperProtocolAndDaemonTests.swift
LM Studio bridge & tool schemas    Sources/Core/AIBridge/       Tests/LLMBridgeTests/
SwiftUI window, theme, tabs        Sources/NetBoostApp/         Tests/AppTests/, Tests/E2ETests/Tier1..Tier5/
Build, test, DMG scripts           Scripts/, Makefile, vfs.yaml Tests/E2ETests/Tier1_FeatureCoverage/Tier1_05_BuildToolingTests.swift
```
