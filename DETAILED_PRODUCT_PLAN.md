# NetBoost - Comprehensive Product & Implementation Blueprint

**Location:** `/Users/va/NetBoost`
**Platform:** macOS 14+ / Sonoma & Sequoia / macOS 26
**Tech Stack:** Native Swift 5.9+, SwiftUI (Liquid Glassmorphism), Apple Network.framework, CoreWLAN, PF (Packet Filter) NAT engine.

---

## 1. Feature Specifications

### Feature 1: 802.1X Wired-to-Wireless Internet Sharing (Hotspot for iPad & Devices)
* **The Problem:**
  The college network mandates 802.1X enterprise authentication (PEAP/MSCHAPv2 / RADIUS tokens). iPads, e-readers, game consoles, and secondary devices often lack support for this specific enterprise configuration, fail certificate validation, or run into device limit quotas.
* **The Core Idea:**
  Turn the Mac into an authenticated hardware router. The Mac stays connected to the campus switch via authenticated Wired Ethernet (`en10`), and broadcasts a standard, encrypted WPA2/WPA3 Personal Wi-Fi network via its internal airport card (`en0`).
* **How It Will Be Implemented:**
  1. **Interface Detection:** Automatically query `networksetup -listallhardwareports` to identify the active upstream gateway (`en10`) and available broadcast device (`en0`).
  2. **NAT & IP Forwarding:**
     * Enable kernel packet forwarding: `sysctl -w net.inet.ip.forwarding=1`.
     * Configure a localized packet filter (`/etc/pf.anchors/netboost.nat`):
       `nat on en10 from 192.168.2.0/24 to any -> (en10)`
       `pass all`
     * Load the anchor dynamically using `pfctl -a netboost -f <ruleset>` without disrupting other system rules.
  3. **DHCP & DNS Daemon:** Spawn a sandboxed `bootpd` or lightweight local DHCP service assigning IP leases `192.168.2.10`-`192.168.2.100` and directing clients to the Mac as their DNS proxy.
  4. **Active Client Discovery:** Parse `arp -an` to display live connected devices (hostname, iPad MAC address, IP, and real-time bandwidth consumption).

---

### Feature 2: Context-Aware VPN Automation (.ovpn Profile Intelligence)
* **The Problem:**
  Split-tunnel OpenVPN (`iiit-split.ovpn`) routes `10.1.0.0/16` through the virtual tunnel (`utun4`). When plugged into campus Ethernet (`10.1.36.52`), this creates conflicting routing entries with the local switch gateway (`10.1.36.1`), causing broken connectivity and connection dropouts. Conversely, when disconnecting Ethernet and switching to phone hotspot/Wi-Fi, the VPN *must* be active to reach `turing.iiit.ac.in` and campus servers.
* **The Core Idea:**
  Automated network sensing. The app detects the physical network environment and toggles or updates VPN profiles accordingly.
* **How It Will Be Implemented:**
  1. **Network Environment Sensor:** Monitor routing changes and SSID/subnet using Apple Network framework `NWPathMonitor`.
  2. **Rule Matrix:**
     * **Condition A (On Campus LAN):** IP is within `10.1.0.0/16`.
       * *Action:* Automatically pause or disconnect `iiit-split.ovpn` in Passepartout / OpenVPN, restoring clean native routing to `10.1.36.1`.
     * **Condition B (Off Campus / On Mobile Hotspot):** IP is `172.20.10.x` or public.
       * *Action:* Automatically start `iiit-split.ovpn` tunnel or notify user with one click, restoring access to `turing` (`10.8.0.80`).
  3. **Tunnel Profile Manager:** Native file reader for `/Users/va/Downloads/iiit-split.ovpn` and `macos.ovpn` allowing quick switching and route inspection directly in-app.

---

### Feature 3: Per-App and Per-Job Interface Dispatcher
* **The Problem:**
  Certain background tasks (e.g. HPC SSH sessions, Claude coding agents, batch file transfers) must remain locked to high-reliability campus Ethernet (`en10`), while streaming, Zoom calls, or personal browsing can run over mobile Wi-Fi without saturating the wired port.
* **The Core Idea:**
  Provide targeted interface binding at the task, command, and proxy levels.
* **How It Will Be Implemented:**
  1. **Local Multi-Port SOCKS5/HTTP Dispatcher:**
     * Built using Swift Network.framework (`NWListener` + `NWConnection`).
     * `127.0.0.1:1080` -> Hard-binds outbound sockets exclusively to `NWParameters.requiredInterface = en10` (Ethernet).
     * `127.0.0.1:1081` -> Hard-binds outbound sockets exclusively to `NWParameters.requiredInterface = en0` (Wi-Fi).
  2. **Task & CLI Helper:**
     * In-app Launch Command or generated shell alias:
       `ALL_PROXY=socks5://127.0.0.1:1080 <command>`
  3. **Static Subnet Pinning:**
     * Automatically ensure kernel routing keeps `10.8.0.0/16` (Turing / HPC) and `10.4.0.0/16` (DNS & Campus Core) pinned to `en10` regardless of Wi-Fi state:
       `route add -net 10.8.0.0/16 10.1.36.1 -ifp en10`

---

### Feature 4: Multi-Connection Download Accelerator
* **The Problem:**
  Campus gateways enforce traffic shaping that limits bandwidth to **~40 Mbps per individual TCP connection**, despite higher available total bandwidth.
* **The Core Idea:**
  Segment incoming downloads into 8 to 16 concurrent HTTP range streams, bypassing single-stream throttles.
* **How It Will Be Implemented:**
  1. **Header Probe:** Send an asynchronous HEAD or initial request to check `Accept-Ranges: bytes` and `Content-Length`.
  2. **Byte Chunk Partitioning:** Calculate chunk boundaries: `Chunk_i = [i * size, (i+1) * size - 1]`.
  3. **Parallel Fetch Pool:** Spawn concurrent `URLSessionDataTask` instances with headers `Range: bytes=start-end`.
  4. **Random-Access File Assembler:** Write directly into pre-allocated file space using Swift FileHandle seek(toOffset:), eliminating memory bottlenecks.
  5. **Live Metrics:** Real-time progress bars for each individual segment, transfer speed, and instantaneous download acceleration factor.

---

### Feature 5: Campus Doctor (Network Health & Self-Repair)
* **The Problem:**
  macOS frequently hangs on campus networks due to Happy Eyeballs (IPv6 timeouts adding 500ms delay), stale DNS cache entries, and incorrect DNS overrides.
* **The Core Idea:**
  A one-click diagnostic and automated repair system built into the app.
* **How It Will Be Implemented:**
  1. **Instant Ping & Latency Matrix:**
     * Pings Local Switch Gateway (`10.1.36.1`), Campus Core (`10.8.0.80`), and External CDN (`142.250.77.142`).
  2. **Auto-Fix Routine:**
     * Flushes local DNS cache: `dscacheutil -flushcache; killall -HUP mDNSResponder`.
     * Resets DNS servers on USB LAN to campus DHCP defaults: `networksetup -setdnsservers "USB 10/100 LAN" empty`.
     * Turns off unrouted IPv6 on LAN to eliminate timeout delays: `networksetup -setv6off "USB 10/100 LAN"`.
     * Tests and verifies `turing.iiit.ac.in` and `google.com`.

---

### Feature 6: In-App Service Order & Priority Switcher
* **The Problem:**
  macOS defaults to Wi-Fi unless the service order is manually altered deep in System Settings.
* **The Core Idea:**
  Drag-and-drop or one-click priority reordering directly within NetBoost.
* **How It Will Be Implemented:**
  * Uses `networksetup -listnetworkserviceorder` to fetch current rankings.
  * Allows re-ordering via `networksetup -ordernetworkservices "USB 10/100 LAN" "Wi-Fi" ...` with instant visual confirmation.

---

## 2. UI Paradigm: Native Liquid Glass macOS Architecture

### Design Philosophy
* Built 100% in native SwiftUI for macOS Sonoma/Sequoia.
* **Window Styling:** Hidden title bar, integrated window controls, full-window `.ultraThinMaterial` translucency reflecting desktop wallpaper colors.
* **Accents & Visual Feedback:**
  * Cyan / Sapphire blue glowing indicators for Wired Ethernet.
  * Emerald green pulsing indicators for Active Hotspot Sharing.
  * Deep amber status indicators for VPN active/inactive warnings.
  * Violet animated bars for multi-stream download chunks.

### Screen Layouts
1. **Header Bar:**
   * Live aggregate throughput gauge (Upload / Download in Mbps).
   * One-click "⚡ Auto-Fix Campus Net" button.
2. **Tab 1: Hotspot & Sharing (iPad Hub):**
   * Big frosted toggle: "Share Ethernet to Wi-Fi".
   * SSID and Password configuration fields.
   * "Connected Devices" card listing iPad name, IP address, connection time, and live traffic.
3. **Tab 2: Smart Routing & VPN Rules:**
   * Visual routing map: Ethernet <-> Wi-Fi <-> VPN.
   * Auto-toggle switch: "Auto-disable VPN on Campus LAN".
   * Service priority reorder list with drag-and-drop handles.
4. **Tab 3: Per-App & Task Dispatcher:**
   * "Add Application / CLI Task" selector.
   * Bind options: Force LAN (`en10`), Force Wi-Fi (`en0`), or Automatic.
   * Quick-copy shell snippet generator for terminal jobs (`ALL_PROXY=...`).
5. **Tab 4: Download Accelerator:**
   * URL input bar with clipboard auto-detect.
   * Chunk count selector (4, 8, 16 connections).
   * Active segmented download visualizer (colored progress lanes for each chunk).
6. **Tab 5: Campus Doctor Diagnostics:**
   * Real-time RTT dials for Gateway, Turing HPC, and Google.
   * Detailed diagnostic log output with one-click export.
7. **Menu Bar Status Item:**
   * Compact menu bar widget displaying current DL/UL speeds, with quick switches for Hotspot On/Off and Priority toggle.

---

## 3. Engineering Implementation Roadmap

| Phase | Milestone | Deliverable |
|---|---|---|
| Phase 1 | Core Network Engine | Swift modules for HotspotController, PFManager, DHCPService, CampusDoctor. |
| Phase 2 | Proxy & Routing Engine | InterfaceProxyDispatcher (per-interface sockets), VPNRuleEngine (path monitoring). |
| Phase 3 | Download Accelerator | Multi-threaded range request engine, file assembler, benchmark validation. |
| Phase 4 | SwiftUI Liquid Glass UI | Complete macOS window, sidebar tabs, live speedometer views, and menu bar item. |
| Phase 5 | Multi-Agent Verification | Automated end-to-end tests: hotspot forwarding check, latency benchmarks, chunk assembly tests. |
