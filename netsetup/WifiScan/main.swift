// WifiScan: lists nearby Wi-Fi networks and joins one. Runs in the logged-in user's session,
// because macOS hides network names from anything without Location Services permission
// (granted once, by clicking Allow on the Mac's screen).
//   WifiScan --status [--out <file>]       permission status as {"status": ...}
//   WifiScan --out <file>                  scan, write JSON [{ssid, rssi, open}] to <file>
//   WifiScan --join <ssid> <password-file> --out <file>
//                                          join, write {"ok": bool, "error": str} to <file>
// The password is read from a file and deleted, so it never shows up in a process listing.
import CoreLocation
import CoreWLAN
import Foundation

let args = CommandLine.arguments
func arg(_ name: String, _ offset: Int = 1) -> String? {
    guard let i = args.firstIndex(of: name), i + offset < args.count else { return nil }
    return args[i + offset]
}

func write(_ obj: Any) -> Never {
    let data = try! JSONSerialization.data(withJSONObject: obj)
    if let out = arg("--out") { try? data.write(to: URL(fileURLWithPath: out)) }
    else { print(String(data: data, encoding: .utf8)!) }
    exit(0)
}

func scan(_ iface: CWInterface) -> [CWNetwork] {
    var seen: [String: CWNetwork] = [:]
    for _ in 0..<2 {  // two passes catch networks a single scan misses
        for n in (try? iface.scanForNetworks(withName: nil)) ?? [] {
            guard let ssid = n.ssid, !ssid.isEmpty else { continue }
            if (seen[ssid]?.rssiValue ?? -999) < n.rssiValue { seen[ssid] = n }
        }
    }
    return seen.values.sorted { $0.rssiValue > $1.rssiValue }
}

final class Runner: NSObject, CLLocationManagerDelegate {
    let manager = CLLocationManager()

    func start() {
        manager.delegate = self
        if manager.authorizationStatus == .notDetermined { manager.requestWhenInUseAuthorization() }
        else { run() }
    }

    func locationManagerDidChangeAuthorization(_ m: CLLocationManager) {
        if m.authorizationStatus != .notDetermined { run() }
    }

    func run() {
        let s = manager.authorizationStatus
        if args.contains("--status") {
            let names: [Int32: String] = [0: "notDetermined", 1: "restricted", 2: "denied", 3: "authorized", 4: "authorized"]
            write(["status": names[s.rawValue] ?? "unknown"])
        }
        guard let iface = CWWiFiClient.shared().interface() else { write(["ok": false, "error": "No Wi-Fi hardware"]) }
        if iface.powerOn() == false { try? iface.setPower(true) }

        if let ssid = arg("--join"), let pwFile = arg("--join", 2) {
            let pw = (try? String(contentsOfFile: pwFile, encoding: .utf8)) ?? ""
            try? FileManager.default.removeItem(atPath: pwFile)
            let found = scan(iface).first(where: { $0.ssid == ssid })
                ?? (try? iface.scanForNetworks(withName: ssid))?.first  // hidden networks answer by name only
            guard let net = found else {
                write(["ok": false, "error": "\(ssid) isn't in range any more"])
            }
            do {
                try iface.associate(to: net, password: net.supportsSecurity(.none) ? nil : pw)
                write(["ok": true, "error": ""])
            } catch {
                let code = (error as NSError).code
                // -3924/-3905 are CoreWLAN's wrong-password / authentication-timeout codes
                let msg = [-3924, -3905].contains(code) ? "Wrong password" : "Couldn't join (\(code))"
                write(["ok": false, "error": msg])
            }
        }
        write(scan(iface).map { ["ssid": $0.ssid!, "rssi": $0.rssiValue, "open": $0.supportsSecurity(.none)] })
    }
}

let runner = Runner()
runner.start()
DispatchQueue.main.asyncAfter(deadline: .now() + 90) { write(["ok": false, "error": "Timed out"]) }  // never hang
RunLoop.main.run()
