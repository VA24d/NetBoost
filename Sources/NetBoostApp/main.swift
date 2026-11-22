import Foundation
import NetBoostCore

@main
struct NetBoostApp {
    static func main() async {
        print("=== NetBoost macOS Network Controller ===")
        print("Version: 1.0.0 (Milestone 1 Foundation)")
        print("Running as root: \(PrivilegeHelper.isRoot)")
        
        if let helper = PrivilegeHelper.locateHelperScript() {
            print("Privileged Helper: Found at \(helper)")
        } else {
            print("Privileged Helper: Not found in standard locations")
        }
        
        if let loIndex = DarwinSocketHelper.getInterfaceIndex(for: "lo0") {
            print("Loopback interface index: \(loIndex)")
        }
        
        print("NetBoostCore initialized successfully.")
    }
}
