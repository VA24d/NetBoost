import Testing

extension Tag {
    // MARK: - Test Tiers
    @Tag public static var tier1: Self
    @Tag public static var tier2: Self
    @Tag public static var tier3: Self
    @Tag public static var tier4: Self
    @Tag public static var tier5: Self

    // MARK: - Milestones
    @Tag public static var m1_foundation: Self
    @Tag public static var m2_proxy: Self
    @Tag public static var m3_vpn: Self
    @Tag public static var m4_downloader: Self
    @Tag public static var m5_doctor: Self
    @Tag public static var m6_ui: Self

    // MARK: - Subsystems & Components
    @Tag public static var mock: Self
    @Tag public static var range_206: Self
    @Tag public static var captive_portal: Self
    @Tag public static var socks5: Self
    @Tag public static var llm_bridge: Self
    @Tag public static var process_runner: Self
    @Tag public static var network_env: Self
    @Tag public static var accelerator: Self
    @Tag public static var diagnostics: Self
    @Tag public static var hotspot: Self
}
