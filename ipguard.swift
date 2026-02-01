import Foundation
import SystemConfiguration

// ─── Configuration ────────────────────────────────────────────────────────────
let TRUSTED_IP = ProcessInfo.processInfo.environment["TRUSTED_IP"] ?? "0.0.0.0"
let MANAGED_INTERFACES = ProcessInfo.processInfo.environment["MANAGED_INTERFACES"]?.split(separator: ",").map(String.init) ?? []
let SOCKET_PATH = (NSHomeDirectory() as NSString).appendingPathComponent(".config/ipguard/ipguard.sock")

// ─── State ───────────────────────────────────────────────────────────────────
enum State: String {
    case protected = "PROTECTED"
    case isolated = "ISOLATED"
    case unprotected = "UNPROTECTED"
}

var currentState: State = .protected
var currentIP: String = ""
var isAcked: Bool = false

// Maps device name (e.g. "en9") to service name (e.g. "Targus USB-C Quad 4K Dock with ")
// Populated at startup, read-only after that.
var deviceToService: [String: String] = [:]

// ─── Logging ─────────────────────────────────────────────────────────────────
func log(_ message: String) {
    let formatter = DateFormatter()
    formatter.dateFormat = "yyyy-MM-dd HH:mm:ss"
    let timestamp = formatter.string(from: Date())
    fputs("[\(timestamp)] \(message)\n", stderr)
}

// ─── State Response ──────────────────────────────────────────────────────────
func stateResponse() -> String {
    switch currentState {
    case .isolated:
        return "ISOLATED\n"
    case .protected:
        return "PROTECTED:\(currentIP)\n"
    case .unprotected:
        return "UNPROTECTED:\(currentIP)\n"
    }
}

// ─── Network Control ─────────────────────────────────────────────────────────

/// Parses -listallhardwareports output into a device -> service name map.
/// Handles trailing spaces and other quirks in service names.
func buildDeviceToServiceMap() -> [String: String] {
    let output = runNetworkSetupCapture(["-listallhardwareports"])
    guard let output = output else { return [:] }

    var map: [String: String] = [:]
    var currentPort: String? = nil

    for line in output.components(separatedBy: .newlines) {
        if line.hasPrefix("Hardware Port: ") {
            // Don't trim — service names can have trailing spaces (yes, really)
            currentPort = String(line.dropFirst("Hardware Port: ".count))
        } else if line.hasPrefix("Device: "), let port = currentPort {
            let device = String(line.dropFirst("Device: ".count)).trimmingCharacters(in: .whitespaces)
            if !device.isEmpty {
                map[device] = port
            }
            currentPort = nil
        }
    }
    return map
}

func killInterfaces() {
    for device in MANAGED_INTERFACES {
        if device == "en0" {
            log("Killing WiFi (en0)")
            runNetworkSetup(["-setairportpower", "en0", "off"])
        } else if let service = deviceToService[device] {
            log("Killing \(device) (\(service))")
            runNetworkSetup(["-setnetworkserviceenabled", service, "off"])
        } else {
            log("No service name found for \(device) - skipping")
        }
    }
}

func restoreInterfaces() {
    for device in MANAGED_INTERFACES {
        if device == "en0" {
            log("Skipping WiFi restore (en0) - user managed")
            continue
        } else if let service = deviceToService[device] {
            log("Restoring \(device) (\(service))")
            runNetworkSetup(["-setnetworkserviceenabled", service, "on"])
        } else {
            log("No service name found for \(device) - skipping")
        }
    }
}

func runNetworkSetup(_ args: [String]) {
    let process = Process()
    process.executableURL = URL(fileURLWithPath: "/usr/sbin/networksetup")
    process.arguments = args
    let stderrPipe = Pipe()
    process.standardOutput = FileHandle.nullDevice
    process.standardError = stderrPipe
    do {
        try process.run()
        process.waitUntilExit()
        if process.terminationStatus != 0 {
            let errData = stderrPipe.fileHandleForReading.readDataToEndOfFile()
            let errMsg = String(data: errData, encoding: .utf8)?.trimmingCharacters(in: .whitespacesAndNewlines) ?? "unknown error"
            log("networksetup \(args.joined(separator: " ")) failed (exit \(process.terminationStatus)): \(errMsg)")
        }
    } catch {
        log("networksetup \(args.joined(separator: " ")) failed: \(error)")
    }
}

/// Runs networksetup and returns stdout as a string. Used for parsing output.
func runNetworkSetupCapture(_ args: [String]) -> String? {
    let process = Process()
    process.executableURL = URL(fileURLWithPath: "/usr/sbin/networksetup")
    process.arguments = args
    let pipe = Pipe()
    process.standardOutput = pipe
    process.standardError = FileHandle.nullDevice
    do {
        try process.run()
        process.waitUntilExit()
    } catch {
        log("Failed to run networksetup \(args.joined(separator: " ")): \(error)")
        return nil
    }
    let data = pipe.fileHandleForReading.readDataToEndOfFile()
    return String(data: data, encoding: .utf8)
}

// ─── IP Check ────────────────────────────────────────────────────────────────
func getPublicIP() async -> String? {
    let sources = [
        "https://api.ipify.org",
        "https://ifconfig.me/ip"
    ]
    for source in sources {
        guard let url = URL(string: source) else { continue }
        do {
            let session = URLSession.shared
            let (data, response) = try await session.data(from: url)
            guard let httpResponse = response as? HTTPURLResponse,
                  httpResponse.statusCode == 200,
                  let ip = String(data: data, encoding: .utf8)?.trimmingCharacters(in: .whitespacesAndNewlines),
                  !ip.isEmpty else { continue }
            return ip
        } catch {
            log("IP check failed for \(source): \(error)")
            continue
        }
    }
    return nil
}

// ─── State Machine ───────────────────────────────────────────────────────────
func evaluateState(ip: String) {
    let isGood = (ip == TRUSTED_IP)
    log("Evaluating: state=\(currentState.rawValue) ip=\(ip) isGood=\(isGood)")

    switch (currentState, isGood) {     
      case (.protected, false):
          // IP drifted -> kill
          killInterfaces()
          currentState = .isolated
          currentIP = ""
          log("Transition: PROTECTED -> ISOLATED")

      case (.isolated, true):
          // Back home -> restore
          restoreInterfaces()
          currentState = .protected
          currentIP = ip
          log("Transition: ISOLATED -> PROTECTED")

      case (.unprotected, true):
          // Back home -> restore, clear ack
          restoreInterfaces()
          currentState = .protected
          currentIP = ip
          isAcked = false
          log("Transition: UNPROTECTED -> PROTECTED (ack cleared)")

      case (.isolated, false):
          // We have an IP (but it's bad) so network is alive - transition to UNPROTECTED
          restoreInterfaces()
          currentState = .unprotected        
          currentIP = ip
          log("Transition: ISOLATED -> UNPROTECTED (network recovered)")

      default:
          // No transition needed, just update IP if we have one
          if !ip.isEmpty {
              currentIP = ip
          }
          log("No transition from \(currentState.rawValue)")
    }
}

func processAck() {
    guard currentState == .isolated else {
        log("ACK received in \(currentState.rawValue) state - ignored")
        return
    }
    isAcked = true
    currentState = .unprotected
    restoreInterfaces()
    // We don't have an IP right now (network was dead), fetch it after restore
    Task {
        // Give network a moment to come up
        try? await Task.sleep(nanoseconds: 2_000_000_000)
        if let ip = await getPublicIP() {
            currentIP = ip
            log("Post-ack IP: \(ip)")
        }
    }
    log("Transition: ISOLATED -> UNPROTECTED (ack)")
}

// ─── Network Change Watcher ──────────────────────────────────────────────────
func startNetworkWatcher() {

    guard let store = SCDynamicStoreCreate(
        nil,
        "ipguard" as CFString,
        { store, keys, context in
            log("SCDynamicStore event fired")
            Task {
                var ip: String? = nil
                for attempt in 1...3 {
                    ip = await getPublicIP()
                    log("IP check attempt \(attempt) of 3...")
                    // if ip != nil { break } - stops the loop, but can miss IP changes
                    if let ip = ip {
                      evaluateState(ip: ip)
                    }
                    try? await Task.sleep(nanoseconds: 2_000_000_000)
                }
                if ip == nil {
                    log("Could not determine IP after 3 attempts - no action taken")
                }
            }
        },
        nil
    ) else {
        log("Failed to create SCDynamicStore")
        return
    }

    // Watch all network-related keys
    let watchKeys: [String] = []
    let watchPatterns: [String] = [
        "State:/Network/Interface/.+/Link",
        "State:/Network/Service/.+/IPv4",
        "State:/Network/Service/.+/IPv6",
        "State:/Network/Global/IPv4"
    ]

    guard SCDynamicStoreSetNotificationKeys(
        store,
        watchKeys as CFArray,
        watchPatterns as CFArray
    ) else {
        log("Failed to set notification keys")
        return
    }

    guard let source = SCDynamicStoreCreateRunLoopSource(nil, store, 0) else {
        log("Failed to create run loop source")
        return
    }

    CFRunLoopAddSource(
        CFRunLoopGetCurrent(),
        source,
        CFRunLoopMode.defaultMode
    )
    log("Network watcher started")
}

// ─── Unix Domain Socket Server ───────────────────────────────────────────────
func startSocketServer() {
    // Clean up any stale socket
    unlink(SOCKET_PATH)

    // Ensure directory exists
    let dir = (SOCKET_PATH as NSString).deletingLastPathComponent
    try? FileManager.default.createDirectory(atPath: dir, withIntermediateDirectories: true)

    let serverFd = socket(AF_UNIX, SOCK_STREAM, 0)
    guard serverFd >= 0 else {
        log("Failed to create socket: \(String(cString: strerror(errno)))")
        return
    }

    var addr = sockaddr_un()
    addr.sun_family = UInt8(AF_UNIX)
    SOCKET_PATH.withCString { src in
        withUnsafeMutablePointer(to: &addr.sun_path) { dest in
            let dest = UnsafeMutableRawPointer(dest).assumingMemoryBound(to: CChar.self)
            strcpy(dest, src)
        }
    }

    let bindResult = withUnsafePointer(to: &addr) { ptr in
        let sockPtr = UnsafeRawPointer(ptr).assumingMemoryBound(to: sockaddr.self)
        return bind(serverFd, sockPtr, socklen_t(MemoryLayout<sockaddr_un>.size))
    }
    guard bindResult == 0 else {
        log("Failed to bind socket: \(String(cString: strerror(errno)))")
        close(serverFd)
        return
    }

    guard listen(serverFd, 5) == 0 else {
        log("Failed to listen on socket: \(String(cString: strerror(errno)))")
        close(serverFd)
        return
    }

    log("Socket server listening at \(SOCKET_PATH)")

    // Handle connections on a background thread so we don't block the run loop
    DispatchQueue.global(qos: .userInitiated).async {
        while true {
            let clientFd = accept(serverFd, nil, nil)
            guard clientFd >= 0 else {
                log("accept() failed: \(String(cString: strerror(errno)))")
                continue
            }

            // Handle each client on its own thread
            DispatchQueue.global(qos: .userInitiated).async {
                handleClient(clientFd)
            }
        }
    }
}

func handleClient(_ clientFd: Int32) {
    defer { close(clientFd) }

    // Read command
    var buffer = [CChar](repeating: 0, count: 256)
    let bytesRead = read(clientFd, &buffer, buffer.count - 1)
    guard bytesRead > 0 else { return }

    let command = String(cString: buffer).trimmingCharacters(in: .whitespacesAndNewlines)
    log("Received command: \(command)")

    switch command {
      case _ where command.hasPrefix("TEST:"):
          let testIP = String(command.dropFirst("TEST:".count)).trimmingCharacters(in: .whitespaces)
          log("TEST: synthetic IP \(testIP)")
          evaluateState(ip: testIP)
      case "ACK":
          processAck()
      case "STATE":
          break  // No action needed, we respond with state below
      default:
          log("Unknown command: \(command) - responding with state")
    }

    // Always respond with current state
    let response = stateResponse()
    response.withCString { ptr in
        _ = write(clientFd, ptr, strlen(ptr))
    }
}

// ─── Startup ─────────────────────────────────────────────────────────────────
func startup() {
    log("ipguard starting (PID: \(ProcessInfo.processInfo.processIdentifier))")
    log("TRUSTED_IP: \(TRUSTED_IP)")
    log("MANAGED_INTERFACES: \(MANAGED_INTERFACES)")
    log("Socket: \(SOCKET_PATH)")

    // Build device -> service name map
    deviceToService = buildDeviceToServiceMap()
    for device in MANAGED_INTERFACES {
        if device == "en0" {
            log("  \(device) -> (WiFi, uses -setairportpower)")
        } else if let service = deviceToService[device] {
            log("  \(device) -> \"\(service)\"")
        } else {
            log("  \(device) -> WARNING: not found in hardware ports")
        }
    }

    // Check IP and enforce state
    let semaphore = DispatchSemaphore(value: 0)
    Task {
        if let ip = await getPublicIP() {
            log("Startup IP check: \(ip)")
            if ip == TRUSTED_IP {
                currentState = .protected
                currentIP = ip
                log("Startup: PROTECTED")
            } else {
                killInterfaces()
                currentState = .isolated
                currentIP = ""
                log("Startup: ISOLATED (IP \(ip) != TRUSTED_IP \(TRUSTED_IP))")
            }
        } else {
            log("Startup: could not determine public IP - defaulting to PROTECTED")
            currentState = .protected
        }
        semaphore.signal()
    }
    semaphore.wait()

    // Start watchers and server
    startSocketServer()
    startNetworkWatcher()
}

// ─── Main ────────────────────────────────────────────────────────────────────
startup()
CFRunLoopRun()