# NetBoost: Native macOS Network Controller & Accelerator Architecture

**Target Location:** `/Users/va/NetBoost`  
**Platform:** macOS 15+ / 26+ (Apple Silicon & Intel)  
**UI Paradigm:** Liquid Glass Native macOS UI (SwiftUI with vibrancy, frosted glass material, ultra-thin vibrancy, dynamic gradients, SF Symbols 6)

---

## 1. Feature Specifications & Requirements

### A. 802.1X Hotspot Sharing for iPad & Secondary Devices
* **Core Problem:** Campus 802.1X (PEAP-MSCHAPv2 / RADIUS) requires individual credentials, periodic re-authentication, and often fails or is unsupported on streaming devices, micro-controllers, or secondary tablets.
* **Feature:**
  * One-click AP Hotspot broadcast on internal Wi-Fi (\`en0\`) while consuming incoming authenticated Internet from Wired Ethernet (\`en10\`).
  * Dedicated NAT subnet forwarding (\`192.168.2.1/24\`) with DHCP and DNS forwarding.
  * Real-time client discovery table showing connected iPads/devices, assigned IP, MAC address, and active throughput.

### B. Network-Aware .ovpn Profiles (Context-Sensitive VPN Rule Engine)
* **Core Problem:** Running campus split-VPNs (\`iiit-split.ovpn\`) while physically plugged into campus Ethernet (\`10.1.36.0/22\`) corrupts routing tables, duplicates routes, and creates conflicts with the local gateway. However, when switching to external Wi-Fi / iPhone hotspot, the VPN is necessary to reach \`turing\` and campus intranet.
* **Feature:**
  * **Network Trigger Automation:**
    * **Campus Wired (\`en10\` active with \`10.1.x.x\`):** Automatically disengage / disable \`iiit-split.ovpn\`.
    * **External Wi-Fi / Hotspot (\`en0\` / \`en9\` active with \`172.20.10.x\` or public IP):** Automatically activate \`iiit-split.ovpn\` or \`macos.ovpn\`.
  * Integrated OpenVPN control engine to connect/disconnect profiles without manual Passepartout intervention.

### C. Per-App and Per-Job Routing (Intelligent Dispatcher)
* **Core Problem:** Computational tasks (e.g., HPC jobs on \`turing.iiit.ac.in\`, Claude coding sessions, SSH clusters) require the low-latency direct LAN path (\`en10\`), while general web browsing or media streaming might need the phone hotspot or a bonded channel.
* **Feature:**
  * **Destination-Based Pinned Routes:** Pinned rules for subnets (\`10.8.0.0/16\` for Turing/HPC, \`10.4.0.0/16\` for Campus servers) forced through \`en10\`.
  * **Local Multi-Interface Proxy (SOCKS5/HTTP):**
    * Port \`1080\` (Direct Wired LAN bound)
    * Port \`1081\` (Direct Mobile Hotspot bound)
    * Port \`1082\` (Bonded / Load-Balanced multi-interface)
  * Any CLI tool, Python script, or AI assistant session can be assigned to an interface via environment variable: \`ALL_PROXY=socks5://127.0.0.1:1080 <command>\`.

### D. Multi-Connection Download Accelerator
* **Core Problem:** Campus traffic shapers enforce a ~40 Mbps limit *per TCP stream*.
* **Feature:**
  * High-performance segmented download manager splitting target files into 8–16 simultaneous TCP chunks.
  * Native Swift concurrency (\`async/await\`, \`URLSession\` range requests \`bytes=start-end\`).
  * Real-time per-chunk progress meters, automatic file assembly, and clipboard download monitor.

### E. Campus Network Diagnostics & Auto-Repair
* **Core Problem:** Frequent issues on college networks: stale DNS caches, hardcoded public DNS breaking intranet lookups, IPv6 timeout hangs ("Happy Eyeballs" fallback adding 500ms delay), and gateway drops.
* **Feature:**
  * One-click "Doctor / Auto-Fix":
    * Flushes mDNSResponder cache.
    * Sets campus DNS (\`10.4.20.21\`, \`10.4.20.222\`) first and cleans corrupted overrides.
    * Disables unrouted IPv6 stack on LAN to eliminate the 500ms connection delay.
    * Verifies reachability to \`turing.iiit.ac.in\`, gateway, and external WAN.

### F. Network Preference Ordering & Dynamic Failover
* **Feature:**
  * In-app drag-and-drop or one-click service order prioritization (e.g., Wired LAN #1, Wi-Fi #2, etc.).
  * Real-time interface watcher (\`NWPathMonitor\`) detecting cable plugging/unplugging and instantaneously adjusting routing rules.

---

## 2. Liquid Glass UI Design Specs

* **Window Material:** Full-size content view with \`.background(.ultraThinMaterial)\` and \`.windowStyle(.hiddenTitleBar)\`.
* **Visual Palette:** Deep dark mode with subtle neon accent glows (sapphire blue for LAN, emerald green for Active Hotspot, purple for Accelerator).
* **Components:**
  1. **Top Glass Header:** Live aggregated throughput (DL/UL speedometers) + quick "Auto-Fix Campus Network" button.
  2. **Sidebar Glass Tabs:**
     * **Dashboard / Status:** Live topology graph (Mac -> Wired / Wi-Fi -> Hotspot -> iPad).
     * **Hotspot Sharing:** Broadcast toggle, SSID, Password, Connected Clients list.
     * **Accelerator:** Multi-thread download queue, segmented chunk visualizers.
     * **Smart Routing & VPN:** Per-app rules, \`.ovpn\` automation rules, interface priority reordering.
     * **Campus Diagnostics:** Latency meters to Turing, Gateway, and Internet.
  3. **Menu Bar Extra:** Sleek mini-menu with one-click Hotspot toggle and live bandwidth rate in the macOS status bar.

---

## 3. Implementation Breakdown & Subagent Workflow

### Subagent Responsibilities:
1. **Subagent 1 (Network & NAT Sharing):**
   * Implement hotspot bridging scripts and Swift wrappers using \`sysctl\`, \`pfctl\`, \`nat\`, and \`scutil\`.
   * Create network health & DNS diagnostic repair utilities.
2. **Subagent 2 (Download Accelerator Engine):**
   * Write high-performance parallel chunk downloading module in Swift with byte-range requests and checksum verification.
3. **Subagent 3 (Proxy Dispatcher & VPN Automator):**
   * Implement the local multi-interface SOCKS5/HTTP dispatcher (\`NWParameters.requiredInterface\`) and \`.ovpn\` condition engine.
4. **Subagent 4 (Liquid Glass Native UI):**
   * Build the complete SwiftUI app with glassmorphism materials, custom cards, live gauges, and menu bar accessory.
5. **Subagent 5 (Build & Verification):**
   * Compile the project using \`swiftc\` / Swift Package Manager, test runtime commands, test hotspot NAT routing tables, and verify accelerator throughput.
