import Foundation
import AppKit
import Combine
import Darwin
import ServiceManagement
import UniformTypeIdentifiers
import UserNotifications

@MainActor
final class TunnelController: ObservableObject {
    @Published var isActive = false
    @Published var isBusy = false
    @Published var statusText = "Tap Connect All — starts official Kerio client, then split"
    @Published var log = ""
    @Published var config = AppConfig.default
    @Published var jsonText = ""
    @Published var jsonError: String?
    @Published var helperReady = false
    @Published var helperDetail = "Install the route helper once so Connect All does not ask for a password."
    @Published var processSteps: [FlowStep] = TunnelController.connectTimeline(helperReady: false)
    @Published var sessionPhase: SessionPhase = .idle
    @Published var newVpnRoute = ""
    @Published var newBypassRoute = ""
    @Published var newDns = ""
    @Published var inputError: String?
    @Published var showDisconnectConfirm = false
    @Published var kerioTunnelSeen = false
    @Published var tunnelInterfaces: [String] = []
    @Published var fullTunnelHijackSeen = false
    @Published var kerioClientInstalled = KerioLauncher.isInstalled
    @Published var isWaitingForKerio = false
    @Published var isTearingDown = false
    @Published var canClickKerio = KerioLauncher.isAccessibilityTrusted
    @Published var kerioSaved = KerioSavedConnection.empty
    @Published var standardVPN = StandardVPNStatus.empty
    /// Connect All paused until Accessibility is granted; then it resumes automatically.
    @Published var waitingForAccessibility = false
    @Published var networkSnapshot = NetworkSnapshot()
    @Published var scenario = ScenarioPresentation(
        scenario: .idleReady,
        title: "Ready",
        detail: "Install the helper, then Connect All.",
        tone: .neutral,
        actions: []
    )
    @Published var connectivity = ConnectivityReport()
    @Published var networkEvents: [NetworkEvent] = []
    @Published var outboundStore = OutboundStore.default
    @Published var outboundConnected = false
    @Published var outboundConnecting = false
    @Published var outboundError: String?
    @Published var outboundBinaryPath: String?
    @Published var outboundStatusDetail = "Not connected"
    @Published var outboundEngineBusy = false
    @Published var outboundEngineProgress = ""
    @Published var outboundConnectedAt: Date?
    @Published var outboundActiveName = ""
    @Published var outboundLatencies: [String: Int] = [:]
    @Published var outboundPinging = false
    @Published var outboundAutoSelecting = false
    @Published var diagnosticReport = DiagnosticReport()
    @Published var kerioSessionConnected = false
    @Published var kerioSessionLabel = ""

    private static let resumeConnectKey = "kerioSplit.resumeConnectAfterRelaunch"
    private lazy var outboundManager: OutboundManager = {
        let root = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("KerioSplit", isDirectory: true)
        return OutboundManager(supportRoot: root)
    }()
    private let eventLog = NetworkEventLog()
    private var lastConflictDetail = ""
    private var guardInFlight = false

    static func connectTimeline(helperReady: Bool) -> [FlowStep] {
        [
            FlowStep(
                id: "allow",
                title: "Helper",
                detail: helperReady ? "Passwordless helper is ready." : "Install once — one Mac password.",
                state: helperReady ? .done : .pending
            ),
            FlowStep(id: "kerio", title: "Kerio session", detail: "Starts the official client, then split.", state: .pending),
            FlowStep(id: "tunnel", title: "Tunnel", detail: "Wait for the VPN tunnel.", state: .pending),
            FlowStep(id: "split", title: "Split routes", detail: "Only configured IPs use the VPN.", state: .pending)
        ]
    }

    static func disconnectTimeline() -> [FlowStep] {
        [
            FlowStep(id: "split", title: "Restore split", detail: "Put LAN routes back.", state: .pending),
            FlowStep(id: "kerio", title: "Stop Kerio", detail: "Click Disconnect in the official client.", state: .pending),
            FlowStep(id: "tunnel", title: "Tunnel down", detail: "Confirm the VPN session has dropped.", state: .pending)
        ]
    }

    var canConnectAll: Bool {
        helperReady && !isActive && !isBusy && sessionPhase != .disconnecting
    }

    var canDisconnectAll: Bool {
        (isActive || kerioTunnelSeen || kerioSessionConnected || outboundConnected || sessionPhase == .connected)
            && !isBusy
            && sessionPhase != .connecting
            && sessionPhase != .waitingForPermission
    }

    /// Seconds to wait for Kerio tunnel during Connect All.
    private let kerioConnectWaitSeconds: TimeInterval = 90

    var configPathDisplay: String { configURL.path }

    var appVersion: String {
        Bundle.main.infoDictionary?["CFBundleShortVersionString"] as? String ?? "1.2.9"
    }

    var menuBarSubtitle: String {
        var parts: [String] = []
        parts.append(helperReady ? "Helper ready" : "Install helper")
        if kerioTunnelSeen {
            parts.append("VPN up")
        } else {
            parts.append("No VPN tunnel")
        }
        if kerioSaved.persistent {
            parts.append("persistent")
        }
        return parts.joined(separator: " · ")
    }

    var menuBarSymbol: String {
        if isActive { return "bolt.horizontal.circle.fill" }
        if kerioTunnelSeen { return "bolt.horizontal.circle" }
        return "circle.dashed"
    }

    private let fileManager = FileManager.default
    private var pollTimer: Timer?
    private var monitorTick = 0
    private var busyWatchdog: Timer?
    private var didBootstrap = false
    private var notificationsAuthorized = false
    private var statusPinnedUntil: Date?
    private var kerioWasSeen = false
    private var autoApplyTriggered = false
    private var connectAllTask: DispatchWorkItem?
    private var lastLoggedDiagnosis: String?
    private var lastNetFingerprint = ""
    /// After Disconnect All, block auto Connect All / auto-apply so we don't bounce back online.
    private var suppressAutoApplyUntil: Date?
    private var kerioDownStreak = 0

    private var supportRoot: URL {
        fileManager.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("KerioSplit", isDirectory: true)
    }

    private var configURL: URL {
        supportRoot.appendingPathComponent("Config/config.json")
    }

    /// Scripts shipped inside the app bundle (or dev checkout). Never Application Support.
    private var bundledRoot: URL? {
        if let env = ProcessInfo.processInfo.environment["KERIOSPLIT_ROOT"], !env.isEmpty {
            let root = URL(fileURLWithPath: env)
            if fileManager.fileExists(atPath: root.appendingPathComponent("Scripts/split-tunnel.sh").path) {
                return root
            }
        }
        if let res = Bundle.main.resourceURL {
            let bundled = res.appendingPathComponent("KerioSplitBundle", isDirectory: true)
            if fileManager.fileExists(atPath: bundled.appendingPathComponent("Scripts/split-tunnel.sh").path) {
                return bundled
            }
        }
        let downloads = fileManager.homeDirectoryForCurrentUser
            .appendingPathComponent("Downloads/KerioSplit", isDirectory: true)
        if fileManager.fileExists(atPath: downloads.appendingPathComponent("Scripts/split-tunnel.sh").path) {
            return downloads
        }
        return nil
    }

    private var bundleRoot: URL {
        bundledRoot ?? supportRoot
    }

    private var scriptsDir: URL { supportRoot.appendingPathComponent("Scripts", isDirectory: true) }
    private var scriptURL: URL { scriptsDir.appendingPathComponent("split-tunnel.sh") }

    func onAppear() {
        guard !didBootstrap else {
            detectApplied()
            // Defer background work so first paint stays responsive.
            DispatchQueue.main.async { [weak self] in
                self?.probeNetwork()
                self?.refreshHelperStatus()
            }
            return
        }
        didBootstrap = true
        isBusy = false
        FlightRecorder.bootstrap(version: appVersion)
        ensureWritableSupport()
        loadConfig()
        detectApplied()
        requestNotificationsIfNeeded()
        startMonitoring()
        observeAppActivation()

        // Everything that might talk to the system goes after the first frame.
        DispatchQueue.main.async { [weak self] in
            guard let self else { return }
            FlightRecorder.log("boot", "post_frame", [
                "helperReady": self.helperReady ? "1" : "0",
                "isActive": self.isActive ? "1" : "0",
                "ax": KerioLauncher.isAccessibilityTrusted ? "1" : "0"
            ])
            FlightRecorder.log("boot", "env_dump", [
                "dump": KerioLauncher.environmentDump().replacingOccurrences(of: "\n", with: " || ")
            ])
            self.syncLaunchAtLoginFromSystem()
            self.syncScriptsToSupport()
            self.refreshHelperStatus()
            self.probeNetwork()
            self.refreshVPNHelpers()
            self.refreshClickPermission()
            self.syncTimelineFromReality()
            self.reloadOutboundStore()
            self.refreshScenario()
            let resumeConnect = UserDefaults.standard.bool(forKey: Self.resumeConnectKey)
            if resumeConnect {
                UserDefaults.standard.set(false, forKey: Self.resumeConnectKey)
            }
            if resumeConnect, self.helperReady, !self.isActive {
                FlightRecorder.log("boot", "auto_resume_connect", [:])
                self.connectAll()
            } else if self.config.options.autoApplyOnLaunch, self.helperReady, !self.isActive {
                FlightRecorder.log("boot", "auto_apply_on_launch", ["kerioSeen": self.kerioTunnelSeen ? "1" : "0"])
                if self.kerioTunnelSeen {
                    self.apply()
                } else {
                    self.connectAll()
                }
            }
        }
    }

    private func observeAppActivation() {
        NotificationCenter.default.addObserver(
            forName: NSApplication.didBecomeActiveNotification,
            object: nil,
            queue: .main
        ) { [weak self] _ in
            Task { @MainActor in
                self?.handleAppBecameActive()
            }
        }
    }

    private func handleAppBecameActive() {
        let trusted = KerioLauncher.isAccessibilityTrusted
        canClickKerio = trusted
        guard waitingForAccessibility || sessionPhase == .waitingForPermission else { return }
        if trusted {
            pinStatus("Accessibility on — continuing Connect All…")
            updateStep("kerio", .running, "Permission granted — starting Kerio session…")
        } else {
            refreshClickPermission()
        }
    }

    func startMonitoring() {
        guard pollTimer == nil else { return }
        // 2s cadence; heavy work is staggered so the UI stays responsive.
        let timer = Timer(timeInterval: 2.0, repeats: true) { [weak self] _ in
            DispatchQueue.main.async {
                guard let self else { return }
                self.monitorTick &+= 1
                let tick = self.monitorTick
                self.detectApplied()
                self.probeNetwork()
                // Connectivity ~every 4s
                if tick % 2 == 0 {
                    self.refreshConnectivity()
                }
                // Route guard ~every 10s
                if tick % 5 == 0 {
                    self.runRouteGuardIfNeeded()
                }
                // Helper sudo check is expensive — ~every 30s
                if tick == 1 || tick % 15 == 0 {
                    self.refreshHelperStatus()
                }
            }
        }
        RunLoop.main.add(timer, forMode: .common)
        pollTimer = timer
    }

    private func syncLaunchAtLoginFromSystem() {
        DispatchQueue.global(qos: .utility).async { [weak self] in
            let enabled = SMAppService.mainApp.status == .enabled
            DispatchQueue.main.async {
                guard let self else { return }
                if self.config.options.launchAtLogin != enabled {
                    self.config.options.launchAtLogin = enabled
                    try? self.config.save(to: self.configURL)
                    self.syncJsonFromConfig()
                }
            }
        }
    }

    func refreshHelperStatus(forceLog: Bool = false) {
        DispatchQueue.global(qos: .utility).async { [weak self] in
            let ready = HelperService.canRunPasswordless()
            let diagnosis = ready ? "" : HelperService.diagnose()
            DispatchQueue.main.async {
                guard let self else { return }
                self.helperReady = ready
                if ready {
                    self.helperDetail = "Route helper is active. Connect All will not ask for a password."
                    self.updateStep("allow", .done, "Passwordless helper verified.")
                    self.lastLoggedDiagnosis = nil
                    guard self.shouldUpdateStatusText() else { return }
                    self.statusText = self.isActive
                        ? "Split ON — passwordless helper active"
                        : "Ready — tap Connect All"
                } else {
                    self.helperDetail = HelperService.filesPresent
                        ? "Helper files exist but still need a password. Install the route helper again."
                        : "Install the route helper with your Mac password. After that, Connect All stays silent."
                    self.updateStep("allow", .pending, self.helperDetail)
                    if !diagnosis.isEmpty, forceLog || diagnosis != self.lastLoggedDiagnosis {
                        self.appendLog(diagnosis)
                        self.lastLoggedDiagnosis = diagnosis
                    }
                    guard self.shouldUpdateStatusText() else { return }
                    self.statusText = "Step 1 of 2 — install route helper, then Connect All"
                }
            }
        }
    }

    private func pinStatus(_ text: String, seconds: TimeInterval = 8) {
        statusText = text
        statusPinnedUntil = Date().addingTimeInterval(seconds)
    }

    private func shouldUpdateStatusText() -> Bool {
        guard let until = statusPinnedUntil else { return true }
        return Date() >= until
    }

    private func setBusy(_ value: Bool, watchdogSeconds: TimeInterval = 20) {
        if isBusy != value {
            FlightRecorder.log("ui", "busy", [
                "from": isBusy ? "1" : "0",
                "to": value ? "1" : "0",
                "watchdog": "\(Int(watchdogSeconds))",
                "phase": sessionPhase.rawValue
            ])
        }
        isBusy = value
        busyWatchdog?.invalidate()
        busyWatchdog = nil
        guard value else { return }
        // Safety valve: never leave the Connect button spinning forever.
        busyWatchdog = Timer(timeInterval: watchdogSeconds, repeats: false) { [weak self] _ in
            Task { @MainActor in
                guard let self, self.isBusy else { return }
                FlightRecorder.log("ui", "busy_watchdog_fire", [
                    "phase": self.sessionPhase.rawValue,
                    "waitingKerio": self.isWaitingForKerio ? "1" : "0"
                ])
                self.isBusy = false
                self.isWaitingForKerio = false
                self.resetToIdleTimeline(status: "Timed out — see Activity")
            }
        }
        if let busyWatchdog {
            RunLoop.main.add(busyWatchdog, forMode: .common)
        }
    }

    func installHelper() {
        guard !isBusy else { return }
        setBusy(true)
        updateStep("allow", .running, "macOS will ask for your password once…")
        pinStatus("Install route helper — enter your Mac password in the system dialog")
        syncScriptsToSupport()

        let installScript = scriptsDir.appendingPathComponent("install-helper.sh")
        let userName = NSUserName()

        guard fileManager.isReadableFile(atPath: installScript.path) else {
            setBusy(false)
            let bundlePath = bundledRoot?.path ?? "unknown"
            appendLog("Installer missing at \(installScript.path)\nApp bundle scripts: \(bundlePath)")
            updateStep("allow", .failed, "Installer missing — reinstall from KerioSplit.pkg")
            pinStatus("Installer missing — reinstall the app from the DMG", seconds: 12)
            return
        }

        Task { @MainActor [weak self] in
            guard let self else { return }
            let result = HelperService.installOnMainThread(
                scriptPath: installScript.path,
                userName: userName
            )
            let ready = result.ok && HelperService.canRunPasswordless()
            self.setBusy(false)
            self.appendLog(result.text.isEmpty ? (result.ok ? "Helper installed" : "Route helper install failed") : result.text)
            self.helperReady = ready
            if ready {
                self.updateStep("allow", .done, "Passwordless helper verified for \(userName).")
                self.helperDetail = "Route helper is active. Connect All will not ask for a password."
                self.lastLoggedDiagnosis = nil
                self.pinStatus("Route helper ready — Connect All will not ask for a password")
                self.notify(title: "Setup complete", body: "Connect All can now apply split routes without a password.")
            } else {
                self.updateStep("allow", .failed, "Route helper did not verify. See Activity.")
                self.helperDetail = result.text.isEmpty
                    ? "Route helper install did not finish."
                    : String(result.text.prefix(180))
                self.pinStatus("Route helper install failed — see Activity", seconds: 12)
            }
        }
    }

    func uninstallHelper() {
        guard !isBusy else { return }
        setBusy(true)
        Task { @MainActor [weak self] in
            guard let self else { return }
            let result = HelperService.uninstallOnMainThread()
            self.setBusy(false)
            self.appendLog(result.text)
            self.helperReady = false
            self.lastLoggedDiagnosis = nil
            self.updateStep("allow", .pending, "Helper removed. Install the route helper again.")
            self.helperDetail = "Install the route helper with your Mac password. After that, Connect All stays silent."
            self.pinStatus("Helper removed")
        }
    }

    func toggle() {
        if isActive {
            if config.options.confirmBeforeDisconnect {
                showDisconnectConfirm = true
            } else {
                disconnectAll()
            }
        } else if helperReady {
            connectAll()
        } else {
            installHelper()
        }
    }

    /// Menu bar / quick actions — still respect disconnect confirm.
    func toggleFromMenuBar() {
        if isActive {
            requestDisconnect()
        } else if helperReady {
            connectAll()
        } else {
            installHelper()
        }
    }

    /// Disconnect with optional confirm; focuses the main window when a dialog is needed.
    func requestDisconnect() {
        if config.options.confirmBeforeDisconnect {
            showDisconnectConfirm = true
            NSApp.activate(ignoringOtherApps: true)
            for window in NSApp.windows where window.title.contains("Kerio Split") {
                window.makeKeyAndOrderFront(nil)
            }
        } else {
            disconnectAll()
        }
    }

    func refreshVPNHelpers() {
        DispatchQueue.global(qos: .utility).async { [weak self] in
            let saved = KerioClientConfig.snapshot()
            let standard = StandardVPN.probe()
            let click = KerioLauncher.isAccessibilityTrusted
            DispatchQueue.main.async {
                guard let self else { return }
                self.kerioSaved = saved
                self.standardVPN = standard
                self.kerioClientInstalled = KerioLauncher.isInstalled
                self.canClickKerio = click
            }
        }
    }

    func refreshClickPermission() {
        canClickKerio = KerioLauncher.isAccessibilityTrusted
    }

    func grantClickKerio() {
        _ = KerioLauncher.ensureControlPermissions()
        canClickKerio = KerioLauncher.isAccessibilityTrusted
        pinStatus(
            canClickKerio
                ? "Accessibility is on for this Kerio Split copy"
                : "Enable Kerio Split in Accessibility, then tap Relaunch. Path: \(KerioLauncher.runningAppPath)",
            seconds: 12
        )
    }

    func relaunchApp() {
        KerioLauncher.relaunchApp()
    }

    func setKerioPersistent(_ enabled: Bool) {
        guard !isBusy else { return }
        setBusy(true)
        DispatchQueue.global(qos: .userInitiated).async { [weak self] in
            let result = KerioClientConfig.setPersistent(enabled)
            let saved = KerioClientConfig.snapshot()
            DispatchQueue.main.async {
                guard let self else { return }
                self.kerioSaved = saved
                self.setBusy(false)
                self.appendLog(result.message)
                self.pinStatus(result.message, seconds: 12)
                if result.ok {
                    _ = KerioLauncher.openClient()
                }
            }
        }
    }

    func pickOpenVPNProfile() {
        let panel = NSOpenPanel()
        panel.allowedContentTypes = [UTType(filenameExtension: "ovpn") ?? .data]
        panel.allowsMultipleSelection = false
        panel.canChooseDirectories = false
        panel.message = "Kerio Control 9.5+ user portal serves this file (port 4081). This is OpenVPN, not Kerio protocol."
        guard panel.runModal() == .OK, let url = panel.url else { return }
        config.options.openvpnConfigPath = url.path
        config.options.connectBackend = .openvpnProfile
        saveConfig()
        pinStatus("OpenVPN profile: \(url.lastPathComponent)", seconds: 6)
    }

    func setConnectBackend(_ backend: ConnectBackend) {
        guard config.options.connectBackend != backend else { return }
        config.options.connectBackend = backend
        saveConfig(quiet: true)
    }

    /// Open Kerio / start a real standard VPN, wait for tunnel, then apply split routes.
    func connectAll() {
        if isActive {
            pinStatus("Split already ON", seconds: 4)
            return
        }
        guard !isBusy else { return }
        guard helperReady else {
            pinStatus("Install the route helper first — that is the only password prompt", seconds: 10)
            updateStep("allow", .failed, "Connect All is locked until the route helper is installed.")
            return
        }
        // Manual / intentional connect clears the post-disconnect suppress window.
        suppressAutoApplyUntil = nil

        connectAllTask?.cancel()
        isWaitingForKerio = true
        waitingForAccessibility = false
        sessionPhase = .connecting
        setBusy(true, watchdogSeconds: kerioConnectWaitSeconds + 120)
        saveConfig(quiet: true)
        syncScriptsToSupport()

        let backend = config.options.connectBackend
        let systemVPNName = config.options.systemVPNName
        let openvpnPath = config.options.openvpnConfigPath
        let persistentHint = kerioSaved.persistent
        let kerioServer = kerioSaved.server
        let pinIf = config.options.kerioInterface
        let pinGw = config.options.kerioGateway
        let ignoreIfaces = config.options.ignoreInterfaces
        let vpnRoutes = config.vpnRoutes

        let finishingOnly = kerioSessionConnected || kerioTunnelSeen
        pinStatus(finishingOnly
            ? "Apply Split — waiting for tunnel address, then applying…"
            : "Connect All — starting official Kerio client, then split…")
        loadConnectTimeline()
        updateStep("allow", .done, "Passwordless helper ready.")
        updateStep("kerio", .running, finishingOnly
            ? "Kerio session already up — finishing split…"
            : "Checking whether a tunnel is already up…")
        updateStep("tunnel", .pending, "Waiting for tunnel interface + IPv4.")
        updateStep("split", .pending, "Split applies after the tunnel address is ready.")

        FlightRecorder.log("connect", "start", [
            "finishingOnly": finishingOnly ? "1" : "0",
            "helperReady": helperReady ? "1" : "0",
            "canClick": canClickKerio ? "1" : "0",
            "backend": "\(backend)",
            "preferredServer": kerioServer.isEmpty ? "(none)" : kerioServer
        ])
        FlightRecorder.log("connect", "env_dump", ["dump": KerioLauncher.environmentDump().replacingOccurrences(of: "\n", with: " || ")])

        var work: DispatchWorkItem!
        work = DispatchWorkItem { [weak self] in
            guard let self else { return }

            var snap = Self.scanNetworkFull(
                pinnedInterface: pinIf,
                pinnedGateway: pinGw,
                ignoreInterfaces: ignoreIfaces,
                vpnRoutes: vpnRoutes
            )
            DispatchQueue.main.async {
                self.probeNetwork()
            }

            var lastClickRetry = Date.distantPast
            var clickAttempts = 0

            if !snap.hasKerioTunnel {
                DispatchQueue.main.async {
                    self.updateStep("kerio", .running, Self.bringUpDetail(backend, persistent: persistentHint))
                    self.pinStatus(Self.bringUpStatus(backend, persistent: persistentHint))
                }

                var launch = Self.bringUpVPN(
                    backend: backend,
                    systemVPNName: systemVPNName,
                    openvpnPath: openvpnPath,
                    kerioServer: kerioServer
                )
                clickAttempts += 1
                lastClickRetry = Date()
                FlightRecorder.log("connect", "bring_up", [
                    "ok": launch.ok ? "1" : "0",
                    "needsAX": launch.needsAccessibility ? "1" : "0",
                    "msg": launch.message
                ])

                if launch.needsAccessibility {
                    launch = self.waitForAccessibilityAndRetryBringUp(
                        work: work,
                        backend: backend,
                        systemVPNName: systemVPNName,
                        openvpnPath: openvpnPath,
                        kerioServer: kerioServer,
                        firstMessage: launch.message
                    )
                    if work.isCancelled { return }
                    if launch.needsAccessibility {
                        DispatchQueue.main.async {
                            self.finishConnectBlockedOnAccessibility(message: launch.message)
                        }
                        return
                    }
                    clickAttempts += 1
                    lastClickRetry = Date()
                }

                DispatchQueue.main.async {
                    self.waitingForAccessibility = false
                    if self.sessionPhase == .waitingForPermission {
                        self.sessionPhase = .connecting
                    }
                    self.appendLog(launch.message)
                    if launch.ok {
                        self.updateStep("kerio", .done, launch.message)
                        self.updateStep("tunnel", .running, "Waiting for VPN tunnel…")
                        self.pinStatus(launch.message)
                        self.notify(
                            title: backend == .kerioClient ? "Official Kerio client" : "Connect VPN",
                            body: launch.message
                        )
                    } else {
                        self.updateStep("kerio", .failed, launch.message)
                        self.updateStep("tunnel", .running, "Will keep retrying Connect click while waiting…")
                        self.pinStatus("Could not click Connect yet — retrying. Or Connect from Kerio menu bar.", seconds: 10)
                    }
                }
            } else {
                DispatchQueue.main.async {
                    self.updateStep("kerio", .done, "VPN session already up.")
                    self.updateStep("tunnel", .running, snap.readyForSplitApply
                        ? "Tunnel address ready."
                        : "Session up — waiting for tunnel IPv4…")
                }
            }

            // Wait until Kerio has a real utun + IPv4 (session Connected alone is not enough for apply).
            // While waiting, re-click Connect every ~8s if still disconnected (diag + reliability).
            let deadline = Date().addingTimeInterval(self.kerioConnectWaitSeconds)
            while Date() < deadline {
                if work.isCancelled {
                    DispatchQueue.main.async {
                        self.isWaitingForKerio = false
                        self.waitingForAccessibility = false
                        self.setBusy(false)
                        FlightRecorder.log("connect", "cancelled", [:])
                    }
                    return
                }
                snap = Self.scanNetworkFull(
                    pinnedInterface: pinIf,
                    pinnedGateway: pinGw,
                    ignoreInterfaces: ignoreIfaces,
                    vpnRoutes: vpnRoutes
                )
                if snap.readyForSplitApply { break }

                if !snap.hasKerioTunnel,
                   backend == .kerioClient,
                   Date().timeIntervalSince(lastClickRetry) >= 8 {
                    lastClickRetry = Date()
                    clickAttempts += 1
                    let retry = KerioLauncher.startOfficialSession(preferredServer: kerioServer)
                    FlightRecorder.log("connect", "click_retry", [
                        "attempt": "\(clickAttempts)",
                        "ok": retry.ok ? "1" : "0",
                        "needsAX": retry.needsAccessibility ? "1" : "0",
                        "msg": retry.message
                    ])
                    DispatchQueue.main.async {
                        self.appendLog("Connect click retry #\(clickAttempts): \(retry.message)")
                        if retry.needsAccessibility {
                            self.canClickKerio = false
                        } else if retry.ok {
                            self.updateStep("kerio", .done, retry.message)
                        }
                    }
                    if retry.needsAccessibility {
                        DispatchQueue.main.async {
                            self.finishConnectBlockedOnAccessibility(message: retry.message)
                        }
                        return
                    }
                }

                let remaining = max(0, Int(deadline.timeIntervalSinceNow))
                DispatchQueue.main.async {
                    if snap.hasKerioTunnel {
                        self.updateStep("kerio", .done, "VPN session reachable.")
                        self.updateStep(
                            "tunnel",
                            .running,
                            "Session up — waiting for tunnel IPv4 (\(remaining)s)"
                        )
                        self.pinStatus("Kerio Connected — waiting for tunnel address before split…")
                    } else {
                        self.updateStep("tunnel", .running, "Still waiting for VPN tunnel (\(remaining)s) · clicks=\(clickAttempts)")
                        self.pinStatus(Self.waitStatus(backend, remaining: remaining, persistent: persistentHint))
                    }
                }
                if remaining % 10 == 0 {
                    FlightRecorder.log("connect", "wait_tick", [
                        "remaining": "\(remaining)",
                        "hasKerio": snap.hasKerioTunnel ? "1" : "0",
                        "session": snap.kerioSessionConnected ? "1" : "0",
                        "iface": snap.kerioInterface,
                        "addr": snap.kerioTunnelAddress,
                        "clicks": "\(clickAttempts)",
                        "evidence": snap.tunnelEvidence.joined(separator: ";")
                    ])
                }
                Thread.sleep(forTimeInterval: 1)
            }

            if work.isCancelled { return }

            guard snap.readyForSplitApply else {
                DispatchQueue.main.async {
                    self.isWaitingForKerio = false
                    self.waitingForAccessibility = false
                    self.setBusy(false)
                    self.sessionPhase = .idle
                    if snap.hasKerioTunnel {
                        self.updateStep("tunnel", .failed, "Session up but no tunnel IPv4 in time.")
                        self.updateStep("split", .failed, "Tap Apply Split once the tunnel address appears.")
                        self.pinStatus("Kerio session up — tap Apply Split again when the tunnel is ready", seconds: 14)
                    } else {
                        self.updateStep("tunnel", .failed, "No tunnel in \(Int(self.kerioConnectWaitSeconds))s.")
                        self.updateStep("split", .skipped, "Split waits until a VPN tunnel is connected.")
                        self.pinStatus(Self.timeoutStatus(backend), seconds: 14)
                        self.notify(title: "VPN not connected", body: Self.timeoutStatus(backend))
                    }
                    self.probeNetwork()
                }
                return
            }

            DispatchQueue.main.async {
                self.updateStep("kerio", .done, "VPN tunnel reachable.")
                self.updateStep(
                    "tunnel",
                    .done,
                    "\(snap.kerioInterface) · \(snap.kerioTunnelAddress)"
                )
                self.updateStep("split", .running, "Applying split routes without a password…")
                self.pinStatus("Tunnel ready — applying split…")
            }

            // Retry apply: first attempt often races Kerio route install.
            let maxAttempts = 6
            var lastOutput = ""
            var applied = false
            for attempt in 1...maxAttempts {
                if work.isCancelled { return }
                if attempt > 1 {
                    DispatchQueue.main.async {
                        self.updateStep("split", .running, "Retrying split apply (\(attempt)/\(maxAttempts))…")
                        self.pinStatus("Retrying split apply (\(attempt)/\(maxAttempts))…")
                    }
                    Thread.sleep(forTimeInterval: 1.2)
                }
                let result = HelperService.runCtl(["apply"])
                lastOutput = result.text
                if result.ok
                    || result.text.contains("split tunnel applied")
                    || result.text.contains("hijack") {
                    applied = true
                    break
                }
                if result.text.contains("helper is not active") || result.text.contains("Passwordless helper") {
                    break
                }
            }

            DispatchQueue.main.async {
                if work.isCancelled { return }
                self.isWaitingForKerio = false
                self.waitingForAccessibility = false
                self.appendLog(lastOutput.isEmpty ? (applied ? "OK" : "Failed") : lastOutput)
                self.setBusy(false)
                self.detectApplied()
                if applied || self.isActive {
                    self.isActive = true
                    self.sessionPhase = .connected
                    self.updateStep("split", .done, "Split ON — only VPN routes use the tunnel.")
                    self.pinStatus("Connect All complete — split ON")
                    FlightRecorder.log("connect", "complete_ok", [
                        "iface": snap.kerioInterface,
                        "addr": snap.kerioTunnelAddress
                    ])
                    self.notify(
                        title: "Connect All",
                        body: "VPN tunnel ready and split routes applied."
                    )
                    self.learnPinFromSnapshot()
                    self.loadConnectedTimeline()
                } else {
                    self.sessionPhase = .idle
                    self.autoApplyTriggered = false
                    self.updateStep("split", .failed, "Split apply failed. See Activity, then tap Apply Split.")
                    self.pinStatus("Split not applied — tap Apply Split once more", seconds: 12)
                    FlightRecorder.log("connect", "complete_fail_apply", ["out": lastOutput])
                    self.syncTimelineFromReality()
                }
                self.probeNetwork()
            }
        }

        connectAllTask = work
        DispatchQueue.global(qos: .userInitiated).async(execute: work)
    }

    /// Pause Connect All until Accessibility is granted, then retry bringing Kerio up.
    private nonisolated func waitForAccessibilityAndRetryBringUp(
        work: DispatchWorkItem,
        backend: ConnectBackend,
        systemVPNName: String,
        openvpnPath: String,
        kerioServer: String,
        firstMessage: String
    ) -> KerioLauncher.BringUpResult {
        DispatchQueue.main.async {
            self.waitingForAccessibility = true
            self.sessionPhase = .waitingForPermission
            self.canClickKerio = false
            self.appendLog(firstMessage)
            self.updateStep(
                "kerio",
                .running,
                "Enable Accessibility for Kerio Split — Connect All continues automatically."
            )
            self.pinStatus("Waiting for Accessibility — turn it on, then return here")
            KerioLauncher.openAccessibilitySettings()
            self.notify(
                title: "Accessibility needed",
                body: "Enable Kerio Split in Privacy → Accessibility. Connect All will continue by itself."
            )
        }

        // macOS often applies the toggle only after the Settings window loses focus / app returns.
        let deadline = Date().addingTimeInterval(5 * 60)
        var promptedRelaunch = false
        while Date() < deadline {
            if work.isCancelled { return KerioLauncher.BringUpResult(ok: false, needsAccessibility: true, message: "Cancelled") }

            if KerioLauncher.isAccessibilityTrusted {
                DispatchQueue.main.async {
                    self.canClickKerio = true
                    self.waitingForAccessibility = false
                    self.sessionPhase = .connecting
                    self.updateStep("kerio", .running, "Permission granted — starting Kerio…")
                    self.pinStatus("Accessibility on — continuing Connect All…")
                }
                Thread.sleep(forTimeInterval: 0.4)
                let retry = Self.bringUpVPN(
                    backend: backend,
                    systemVPNName: systemVPNName,
                    openvpnPath: openvpnPath,
                    kerioServer: kerioServer
                )
                if !retry.needsAccessibility {
                    return retry
                }
                // Trusted but click still blocked — common until relaunch.
                if !promptedRelaunch {
                    promptedRelaunch = true
                    DispatchQueue.main.async {
                        self.waitingForAccessibility = true
                        self.sessionPhase = .waitingForPermission
                        self.updateStep(
                            "kerio",
                            .running,
                            "macOS needs a relaunch after Accessibility. Tap Relaunch — Connect All resumes."
                        )
                        self.pinStatus("Relaunch Kerio Split to finish Connect All")
                        UserDefaults.standard.set(true, forKey: Self.resumeConnectKey)
                    }
                }
            }

            Thread.sleep(forTimeInterval: 0.7)
        }

        return KerioLauncher.BringUpResult(
            ok: false,
            needsAccessibility: true,
            message: "Accessibility was not enabled in time. Enable it, then tap Connect All again."
        )
    }

    private func finishConnectBlockedOnAccessibility(message: String) {
        isWaitingForKerio = false
        waitingForAccessibility = false
        setBusy(false)
        sessionPhase = .idle
        updateStep("kerio", .failed, message)
        updateStep("tunnel", .skipped, "Tunnel waits until Kerio can be started.")
        updateStep("split", .skipped, "Split waits until a VPN tunnel is connected.")
        pinStatus(message, seconds: 14)
    }

    func cancelConnectAll() {
        connectAllTask?.cancel()
        connectAllTask = nil
        isWaitingForKerio = false
        waitingForAccessibility = false
        UserDefaults.standard.set(false, forKey: Self.resumeConnectKey)
        setBusy(false)
        resetToIdleTimeline(status: "Cancelled — connect the VPN first, then Connect All")
    }

    /// After Accessibility is toggled, macOS may require a relaunch before AX clicks work.
    func relaunchToContinueConnect() {
        UserDefaults.standard.set(true, forKey: Self.resumeConnectKey)
        KerioLauncher.relaunchApp()
    }

    func openKerioClient() {
        kerioClientInstalled = KerioLauncher.isInstalled
        let result = KerioLauncher.openClient()
        appendLog(result.message)
        pinStatus(result.message, seconds: 6)
    }

    func confirmDisconnect() {
        showDisconnectConfirm = false
        disconnectAll()
    }

    func apply() {
        guard helperReady else {
            pinStatus("Install the route helper first — that is the only password prompt", seconds: 10)
            return
        }
        saveConfig(quiet: true)
        syncScriptsToSupport()
        updateStep("split", .running, "Applying split routes…")
        runEngine(arguments: ["apply"]) { [weak self] ok, output in
            guard let self else { return }
            if ok || output.contains("split tunnel applied") || output.contains("hijack") {
                self.isActive = true
                self.sessionPhase = .connected
                self.updateStep("split", .done, "Split ON — only VPN routes use Kerio.")
                self.pinStatus("Split ON — VPN routes + bypass applied")
                self.notify(title: "Split tunneling ON", body: "VPN routes applied. General traffic uses LAN.")
                self.recordEvent("Split applied")
                self.learnPinFromSnapshot()
            } else {
                self.updateStep("split", .failed, "Split apply failed. See Activity.")
                self.recordEvent("Split apply failed")
            }
            self.probeNetwork()
        }
    }

    func repairRoutes() {
        guard helperReady else {
            pinStatus("Install the route helper first", seconds: 8)
            return
        }
        recordEvent("Repair routes requested")
        runEngine(arguments: ["guard"]) { [weak self] ok, output in
            guard let self else { return }
            if ok || output.contains("guard=") {
                self.pinStatus(output.contains("repaired") ? "Kerio routes repaired" : "Kerio routes OK", seconds: 6)
                self.recordEvent(output.trimmingCharacters(in: .whitespacesAndNewlines))
            } else {
                // Fall back to full apply
                self.apply()
            }
            self.probeNetwork()
        }
    }

    /// Restore split routes, then click Disconnect in the official VPN client (or stop L2TP/OpenVPN).
    func disconnectAll() {
        guard !isBusy else { return }
        // Built-in outbound must drop with Disconnect All
        if outboundConnected {
            disconnectOutbound()
        }
        connectAllTask?.cancel()
        connectAllTask = nil
        isWaitingForKerio = false
        waitingForAccessibility = false
        isTearingDown = true
        // Critical: flight log showed Disconnect → immediately Connect All via auto-apply.
        suppressAutoApplyUntil = Date().addingTimeInterval(90)
        autoApplyTriggered = true
        sessionPhase = .disconnecting
        setBusy(true, watchdogSeconds: 70)
        FlightRecorder.log("disconnect", "start", [
            "suppressAutoApplySec": "90",
            "sessionWas": kerioSessionConnected ? "1" : "0"
        ])

        let backend = config.options.connectBackend
        let systemVPNName = config.options.systemVPNName
        pinStatus("Disconnect All — restoring routes, then stopping VPN…")
        loadDisconnectTimeline()
        updateStep("split", .running, "Removing split routes…")
        updateStep("kerio", .pending, "Then disconnect the official VPN session.")
        updateStep("tunnel", .pending, "Tunnel should drop after Disconnect.")

        runEngine(arguments: ["restore"], keepBusy: true) { [weak self] ok, _ in
            guard let self else { return }
            if ok {
                self.isActive = false
                self.clearAppliedMarkerLocally()
                self.updateStep("split", .done, "Split OFF — LAN default restored.")
            } else {
                self.updateStep("split", .failed, "Split restore failed. See Activity.")
            }

            self.updateStep("kerio", .running, Self.bringDownDetail(backend))
            self.pinStatus("Split off — disconnecting VPN…")

            DispatchQueue.global(qos: .userInitiated).async {
                var stop = Self.bringDownVPN(backend: backend, systemVPNName: systemVPNName)
                // Wait until scutil shows Disconnected — otherwise auto-apply reconnects instantly.
                let deadline = Date().addingTimeInterval(20)
                var stillUp = true
                var clicks = 1
                var lastRetry = Date()
                while Date() < deadline {
                    let snap = Self.scanNetworkFull(
                        pinnedInterface: "",
                        pinnedGateway: "",
                        ignoreInterfaces: [],
                        vpnRoutes: []
                    )
                    if !snap.kerioSessionConnected {
                        stillUp = false
                        break
                    }
                    if Date().timeIntervalSince(lastRetry) >= 5, clicks < 3 {
                        lastRetry = Date()
                        clicks += 1
                        stop = Self.bringDownVPN(backend: backend, systemVPNName: systemVPNName)
                        FlightRecorder.log("disconnect", "retry_click", [
                            "n": "\(clicks)",
                            "ok": stop.ok ? "1" : "0",
                            "msg": stop.message
                        ])
                    }
                    Thread.sleep(forTimeInterval: 1)
                }
                FlightRecorder.log("disconnect", "wait_done", [
                    "stillUp": stillUp ? "1" : "0",
                    "clicks": "\(clicks)",
                    "stopOk": stop.ok ? "1" : "0"
                ])
                DispatchQueue.main.async {
                    self.appendLog(stop.message)
                    if !stillUp {
                        self.updateStep("kerio", .done, stop.message)
                        self.updateStep("tunnel", .done, "VPN session stopped.")
                        self.pinStatus("Disconnect All complete")
                        self.notify(
                            title: "Disconnect All",
                            body: "Split routes restored and VPN session stopped."
                        )
                        self.finishDisconnect(success: true)
                    } else {
                        self.updateStep("kerio", .failed, stop.message)
                        self.updateStep("tunnel", .skipped, "Kerio session still Connected — click Disconnect in the menu bar if needed.")
                        self.pinStatus("Split OFF — Kerio still Connected. Auto Connect is paused for 90s.", seconds: 14)
                        self.notify(title: "VPN still connected?", body: stop.message)
                        self.finishDisconnect(success: false)
                    }
                }
            }
        }
    }

    func restore() {
        runEngine(arguments: ["restore"]) { [weak self] ok, _ in
            guard let self else { return }
            if ok {
                self.isActive = false
                self.clearAppliedMarkerLocally()
                self.updateStep("split", .done, "Split OFF — routes restored.")
                self.pinStatus("Split OFF — Kerio session unchanged")
                self.notify(title: "Split tunneling OFF", body: "Routes restored. Kerio session left alone.")
            }
            self.probeNetwork()
        }
    }

    func refreshStatus() {
        runEngine(arguments: ["status"], preferUser: true) { [weak self] _, output in
            self?.appendLog(output)
            self?.pinStatus("Status refreshed", seconds: 4)
            self?.probeNetwork()
        }
    }

    func probeNetwork() {
        let opts = config.options
        let routes = config.vpnRoutes
        let active = isActive
        DispatchQueue.global(qos: .utility).async { [weak self] in
            let snap = NetworkSense.scan(
                pinnedInterface: opts.kerioInterface,
                pinnedGateway: opts.kerioGateway,
                ignoreInterfaces: opts.ignoreInterfaces,
                vpnRoutes: routes,
                splitActive: active
            )
            DispatchQueue.main.async {
                guard let self else { return }
                self.applyNetworkSnapshot(snap)
                self.maybeAutoApplySplit()
                self.refreshScenario()
                if !self.isBusy, self.sessionPhase == .idle || self.sessionPhase == .connected {
                    self.syncTimelineFromReality()
                }
            }
        }
        refreshVPNHelpers()
    }

    private func applyNetworkSnapshot(_ snap: NetworkSnapshot) {
        let wasSeen = kerioWasSeen
        let wasSession = kerioSessionConnected
        networkSnapshot = snap
        kerioTunnelSeen = snap.hasKerioTunnel
        kerioSessionConnected = snap.kerioSessionConnected
        kerioSessionLabel = snap.kerioSessionLabel
        tunnelInterfaces = snap.allUtuns
        fullTunnelHijackSeen = snap.fullTunnelHijack
        kerioClientInstalled = KerioLauncher.isInstalled

        if snap.hasKerioTunnel && !wasSeen {
            kerioWasSeen = true
            kerioDownStreak = 0
            let evidence = snap.tunnelEvidence.isEmpty
                ? (snap.kerioInterface.isEmpty ? "session/routes" : snap.kerioInterface)
                : snap.tunnelEvidence.joined(separator: "; ")
            recordEvent("Kerio tunnel UP — \(evidence)")
        } else if !snap.hasKerioTunnel && wasSeen {
            kerioDownStreak += 1
            // Require 3 consecutive downs before treating as real down (scutil flickers).
            if kerioDownStreak >= 3 {
                kerioWasSeen = false
                kerioDownStreak = 0
                // Do not clear autoApplyTriggered here if we are in post-disconnect suppress window.
                if suppressAutoApplyUntil == nil || Date() >= (suppressAutoApplyUntil ?? .distantPast) {
                    autoApplyTriggered = false
                }
                recordEvent("Kerio tunnel DOWN")
            } else {
                FlightRecorder.log("net", "kerio_down_debounce", ["streak": "\(kerioDownStreak)"])
            }
        } else if snap.hasKerioTunnel {
            kerioDownStreak = 0
        } else if !snap.hasKerioTunnel {
            // Keep autoApply suppressed after intentional disconnect.
            if suppressAutoApplyUntil == nil || Date() >= (suppressAutoApplyUntil ?? .distantPast) {
                // leave autoApplyTriggered as-is unless we never connected
            }
        }

        // Drop false "Outbound Connected" only when the engine is truly gone.
        // Do NOT treat a missing TUN probe alone as death — and never mistake
        // EPERM on a root-owned sing-box pid for "exited" (that auto-killed sessions).
        if outboundConnected, !outboundConnecting {
            let alive = outboundManager.isEngineAlive()
            let hasTun = !snap.outboundInterface.isEmpty
            let age = Date().timeIntervalSince(outboundConnectedAt ?? .distantPast)
            if !alive, age > 6, !hasTun {
                outboundManager.disconnect()
                outboundConnected = false
                outboundConnecting = false
                outboundConnectedAt = nil
                outboundActiveName = ""
                outboundStatusDetail = "Disconnected — engine stopped"
                outboundError = "Outbound engine exited"
                recordEvent("Outbound marked down — engine exited")
            }
        }

        if snap.kerioSessionConnected && !wasSession {
            recordEvent("Kerio session Connected — \(snap.kerioSessionLabel)")
        } else if !snap.kerioSessionConnected && wasSession {
            recordEvent("Kerio session Disconnected")
        }

        let fp = [
            "sess=\(snap.kerioSessionConnected ? 1 : 0)",
            "iface=\(snap.kerioInterface)",
            "addr=\(snap.kerioTunnelAddress)",
            "hijack=\(snap.fullTunnelHijack ? 1 : 0)",
            "split=\(isActive ? 1 : 0)",
            "out=\(outboundConnected ? 1 : 0)",
            "outIf=\(snap.outboundInterface)",
            "def=\(snap.defaultInterface)",
            "phase=\(sessionPhase.rawValue)",
            "busy=\(isBusy ? 1 : 0)"
        ].joined(separator: ",")
        if fp != lastNetFingerprint {
            FlightRecorder.log("net", "state_change", [
                "from": lastNetFingerprint.isEmpty ? "(boot)" : lastNetFingerprint,
                "to": fp,
                "evidence": snap.tunnelEvidence.joined(separator: ";")
            ])
            lastNetFingerprint = fp
        }

        // Drop stale pin when Kerio is fully down (iface gone) so we don't
        // treat a leftover gateway as an active tunnel on the next probe.
        if !snap.hasKerioTunnel,
           !config.options.kerioInterface.isEmpty || !config.options.kerioGateway.isEmpty {
            let oldIf = config.options.kerioInterface
            config.options.kerioInterface = ""
            config.options.kerioGateway = ""
            saveConfig(quiet: true)
            if !oldIf.isEmpty {
                recordEvent("Cleared stale Kerio pin (\(oldIf)) — reconnect to re-learn")
            }
        }

        if snap.conflict, snap.conflictDetail != lastConflictDetail {
            lastConflictDetail = snap.conflictDetail
            recordEvent("Conflict: \(snap.conflictDetail)")
        } else if !snap.conflict {
            lastConflictDetail = ""
        }

        if isActive, !snap.kerioInterface.isEmpty, config.options.kerioInterface.isEmpty {
            config.options.kerioInterface = snap.kerioInterface
            if !snap.kerioGateway.isEmpty { config.options.kerioGateway = snap.kerioGateway }
            saveConfig(quiet: true)
            recordEvent("Auto-pinned Kerio \(snap.kerioInterface)")
        }

        refreshDiagnostics()
    }

    private func maybeAutoApplySplit() {
        if let until = suppressAutoApplyUntil, Date() < until {
            return
        }
        if let until = suppressAutoApplyUntil, Date() >= until {
            suppressAutoApplyUntil = nil
        }
        guard config.options.autoApplyWhenKerioConnects,
              networkSnapshot.readyForSplitApply,
              !isActive,
              !isBusy,
              !isTearingDown,
              helperReady,
              !autoApplyTriggered,
              sessionPhase != .connecting,
              sessionPhase != .waitingForPermission,
              sessionPhase != .disconnecting else { return }
        autoApplyTriggered = true
        pinStatus("Kerio ready — auto-applying split…")
        FlightRecorder.log("connect", "auto_apply", [
            "iface": networkSnapshot.kerioInterface,
            "addr": networkSnapshot.kerioTunnelAddress
        ])
        // Reuse Connect All path so we get retries + iface wait consistency.
        connectAll()
    }

    private func applyNetworkScan(_ result: (hasKerio: Bool, utuns: [String], hasHijack: Bool)) {
        // Kept for binary compatibility of older call sites — redirect.
        _ = result
        probeNetwork()
    }

    private nonisolated static func scanNetwork() -> (hasKerio: Bool, utuns: [String], hasHijack: Bool) {
        let snap = scanNetworkFull(
            pinnedInterface: "",
            pinnedGateway: "",
            ignoreInterfaces: [],
            vpnRoutes: []
        )
        return (snap.hasKerioTunnel, snap.allUtuns, snap.fullTunnelHijack)
    }

    private nonisolated static func scanNetworkFull(
        pinnedInterface: String,
        pinnedGateway: String,
        ignoreInterfaces: [String],
        vpnRoutes: [String]
    ) -> NetworkSnapshot {
        NetworkSense.scan(
            pinnedInterface: pinnedInterface,
            pinnedGateway: pinnedGateway,
            ignoreInterfaces: ignoreInterfaces,
            vpnRoutes: vpnRoutes,
            splitActive: false
        )
    }

    private func requestNotificationsIfNeeded() {
        guard config.options.notifyOnChange else { return }
        UNUserNotificationCenter.current().requestAuthorization(options: [.alert, .sound]) { granted, _ in
            Task { @MainActor in
                self.notificationsAuthorized = granted
            }
        }
    }

    private func notify(title: String, body: String) {
        guard config.options.notifyOnChange else { return }
        let content = UNMutableNotificationContent()
        content.title = title
        content.body = body
        content.sound = .default
        let request = UNNotificationRequest(
            identifier: "keriosplit-\(UUID().uuidString)",
            content: content,
            trigger: nil
        )
        UNUserNotificationCenter.current().add(request)
    }

    // MARK: - Config mutations

    func addVpnRoute() {
        guard let value = validatedHostOrCIDR(newVpnRoute, into: config.vpnRoutes) else { return }
        config.vpnRoutes.append(value)
        newVpnRoute = ""
        inputError = nil
        saveConfig()
    }

    func addBypassRoute() {
        guard let value = validatedHostOrCIDR(newBypassRoute, into: config.bypassRoutes) else { return }
        config.bypassRoutes.append(value)
        newBypassRoute = ""
        inputError = nil
        saveConfig()
    }

    func addDns() {
        guard let value = validatedHostOrCIDR(newDns, into: config.options.customDns, dnsOnly: true) else { return }
        config.options.customDns.append(value)
        newDns = ""
        inputError = nil
        saveConfig()
    }

    func setAppearance(_ mode: AppearanceMode) {
        guard config.appearance != mode else { return }
        config.appearance = mode
        saveConfig(quiet: true)
    }

    func setShowMenuBar(_ enabled: Bool) {
        guard config.options.showMenuBar != enabled else { return }
        config.options.showMenuBar = enabled
        saveConfig(quiet: true)
    }

    func setLaunchAtLogin(_ enabled: Bool) {
        do {
            if enabled {
                try SMAppService.mainApp.register()
            } else {
                try SMAppService.mainApp.unregister()
            }
            config.options.launchAtLogin = enabled
            saveConfig()
            appendLog(enabled ? "Launch at login enabled" : "Launch at login disabled")
        } catch {
            appendLog("Launch at login: \(error.localizedDescription)")
            statusText = "Launch at login needs a signed app in Applications"
            // Keep UI honest if registration failed.
            config.options.launchAtLogin = SMAppService.mainApp.status == .enabled
            saveConfig()
        }
    }

    func clearLog() {
        log = ""
    }

    func copyConfigPath() {
        NSPasteboard.general.clearContents()
        NSPasteboard.general.setString(configURL.path, forType: .string)
        statusText = "Config path copied"
    }

    func exportConfig() {
        saveConfig()
        let panel = NSSavePanel()
        panel.allowedContentTypes = [.json]
        panel.nameFieldStringValue = "keriosplit-config.json"
        panel.canCreateDirectories = true
        guard panel.runModal() == .OK, let url = panel.url else { return }
        do {
            try config.prettyJSON().write(to: url, atomically: true, encoding: .utf8)
            appendLog("Exported config → \(url.path)")
            statusText = "Config exported"
        } catch {
            appendLog("Export failed: \(error.localizedDescription)")
        }
    }

    func importConfig() {
        let panel = NSOpenPanel()
        panel.allowedContentTypes = [.json]
        panel.allowsMultipleSelection = false
        panel.canChooseDirectories = false
        guard panel.runModal() == .OK, let url = panel.url else { return }
        do {
            var imported = AppConfig.load(from: url)
            imported.sanitize()
            config = imported
            try config.save(to: configURL)
            syncJsonFromConfig()
            appendLog("Imported config ← \(url.path)")
            statusText = "Config imported"
        } catch {
            appendLog("Import failed: \(error.localizedDescription)")
        }
    }

    private func validatedHostOrCIDR(_ raw: String, into existing: [String], dnsOnly: Bool = false) -> String? {
        let value = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !value.isEmpty else {
            inputError = "Enter an IP or CIDR"
            return nil
        }
        if dnsOnly {
            // DNS: host only, no CIDR
            guard AppConfig.isValidHostOrCIDR(value), !value.contains("/") else {
                inputError = "DNS must be an IPv4 address (no CIDR)"
                return nil
            }
        } else {
            guard AppConfig.isValidHostOrCIDR(value) else {
                inputError = "Use IPv4 or CIDR, e.g. 192.168.70.0/24"
                return nil
            }
        }
        guard !existing.contains(value) else {
            inputError = "Already in the list"
            return nil
        }
        return value
    }

    func removeVpnRoute(_ route: String) {
        config.vpnRoutes.removeAll { $0 == route }
        saveConfig()
    }

    func removeBypassRoute(_ route: String) {
        config.bypassRoutes.removeAll { $0 == route }
        saveConfig()
    }

    func removeDns(_ dns: String) {
        config.options.customDns.removeAll { $0 == dns }
        saveConfig()
    }

    func saveConfig(quiet: Bool = false) {
        ensureWritableSupport()
        config.sanitize()
        do {
            try config.save(to: configURL)
            let pretty = (try? config.prettyJSON()) ?? jsonText
            if jsonText != pretty {
                jsonText = pretty
            }
            jsonError = nil
            if !quiet {
                appendLog("Config saved → \(configURL.path)")
            }
        } catch {
            appendLog("Save failed: \(error.localizedDescription)")
        }
    }

    func reloadFromDisk() {
        ensureWritableSupport()
        loadConfig()
        appendLog("Reloaded from disk")
        statusText = "Config reloaded from JSON"
    }

    /// Apply JSON editor → model → disk (UI ↔ JSON both ways).
    func applyJsonEditor() {
        do {
            var parsed = try AppConfig.parse(json: jsonText)
            parsed.sanitize()
            config = parsed
            try config.save(to: configURL)
            syncJsonFromConfig()
            jsonError = nil
            appendLog("JSON applied and saved")
            statusText = "JSON config applied"
        } catch {
            jsonError = error.localizedDescription
            appendLog("JSON error: \(error.localizedDescription)")
        }
    }

    func revealConfigInFinder() {
        NSWorkspace.shared.activateFileViewerSelecting([configURL])
    }

    private func syncJsonFromConfig() {
        jsonText = (try? config.prettyJSON()) ?? jsonText
    }

    private func loadConfig() {
        if fileManager.fileExists(atPath: configURL.path) {
            config = AppConfig.load(from: configURL)
        } else {
            let example = bundleRoot.appendingPathComponent("Config/config.example.json")
            if fileManager.fileExists(atPath: example.path) {
                config = AppConfig.load(from: example)
            } else {
                config = .default
            }
            try? config.save(to: configURL)
        }
        syncJsonFromConfig()
    }

    private func detectApplied() {
        let state = supportRoot.appendingPathComponent("saved-routes.env")
        guard fileManager.fileExists(atPath: state.path),
              let data = try? String(contentsOf: state, encoding: .utf8) else {
            isActive = false
            return
        }
        isActive = data.contains("APPLIED_AT=")
    }

    private func clearAppliedMarkerLocally() {
        let state = supportRoot.appendingPathComponent("saved-routes.env")
        guard let data = try? String(contentsOf: state, encoding: .utf8) else { return }
        let filtered = data
            .split(separator: "\n", omittingEmptySubsequences: false)
            .filter { !$0.hasPrefix("APPLIED_AT=") }
            .joined(separator: "\n")
        // May fail if root-owned; restore script also clears this when helper works.
        try? filtered.write(to: state, atomically: true, encoding: .utf8)
        isActive = false
    }

    private func ensureWritableSupport() {
        let root = supportRoot
        let configDir = root.appendingPathComponent("Config", isDirectory: true)
        try? fileManager.createDirectory(at: configDir, withIntermediateDirectories: true)
        // Never raise an admin password dialog during launch — that freezes the mouse cursor.
    }

    private func isWritable(_ url: URL) -> Bool {
        do {
            try fileManager.createDirectory(at: url, withIntermediateDirectories: true)
            let probe = url.appendingPathComponent(".write_test")
            try "ok".write(to: probe, atomically: true, encoding: .utf8)
            try fileManager.removeItem(at: probe)
            return true
        } catch {
            return false
        }
    }

    private func syncScriptsToSupport() {
        let dest = supportRoot.appendingPathComponent("Scripts", isDirectory: true)
        try? fileManager.createDirectory(at: dest, withIntermediateDirectories: true)

        guard let sourceRoot = bundledRoot else { return }
        let srcDir = sourceRoot.appendingPathComponent("Scripts", isDirectory: true)
        let files = ["split-tunnel.sh", "keriosplit-ctl", "install-helper.sh"]
        for name in files {
            let src = srcDir.appendingPathComponent(name)
            let dst = dest.appendingPathComponent(name)
            guard fileManager.fileExists(atPath: src.path) else { continue }
            if src.path == dst.path { continue }
            try? fileManager.removeItem(at: dst)
            do {
                try fileManager.copyItem(at: src, to: dst)
                try fileManager.setAttributes([.posixPermissions: 0o755], ofItemAtPath: dst.path)
            } catch {
                appendLog("Script sync failed for \(name): \(error.localizedDescription)")
            }
        }

        let cfgSrc = sourceRoot.appendingPathComponent("Config/config.example.json")
        let cfgDstDir = supportRoot.appendingPathComponent("Config", isDirectory: true)
        try? fileManager.createDirectory(at: cfgDstDir, withIntermediateDirectories: true)
        if fileManager.fileExists(atPath: cfgSrc.path) {
            let exampleDst = cfgDstDir.appendingPathComponent("config.example.json")
            if cfgSrc.path != exampleDst.path {
                try? fileManager.removeItem(at: exampleDst)
                try? fileManager.copyItem(at: cfgSrc, to: exampleDst)
            }
        }
    }

    private func runEngine(
        arguments: [String],
        preferUser: Bool = false,
        keepBusy: Bool = false,
        completion: ((Bool, String) -> Void)? = nil
    ) {
        if !keepBusy {
            setBusy(true)
        }
        let script = scriptURL.path
        let useHelper = !preferUser && helperReady

        DispatchQueue.global(qos: .userInitiated).async { [weak self] in
            let result: (ok: Bool, text: String)
            if useHelper {
                result = HelperService.runCtl(arguments)
            } else if preferUser || arguments.first == "status" {
                result = HelperService.runProcess("/bin/bash", [script] + arguments, timeoutSeconds: 20)
            } else {
                let msg = """
                Passwordless helper is not active.
                Install the route helper first — that is the only password prompt.
                \(HelperService.diagnose())
                """
                result = (false, msg)
            }

            DispatchQueue.main.async {
                guard let self else { return }
                if !keepBusy {
                    self.setBusy(false)
                }
                self.appendLog(result.text.isEmpty ? (result.ok ? "OK" : "Failed") : result.text)
                if !result.ok, !keepBusy {
                    self.pinStatus("Action failed — see Activity", seconds: 10)
                }
                completion?(result.ok, result.text)
            }
        }
    }

    private func updateStep(_ id: String, _ state: FlowStepState, _ detail: String) {
        guard let idx = processSteps.firstIndex(where: { $0.id == id }) else { return }
        processSteps[idx].state = state
        processSteps[idx].detail = detail
    }

    private func loadConnectTimeline() {
        processSteps = Self.connectTimeline(helperReady: helperReady)
    }

    private func loadDisconnectTimeline() {
        processSteps = Self.disconnectTimeline()
    }

    private func loadConnectedTimeline() {
        processSteps = [
            FlowStep(id: "allow", title: "Helper", detail: "Passwordless helper is active.", state: helperReady ? .done : .failed),
            FlowStep(id: "kerio", title: "Kerio session", detail: "Official VPN client is connected.", state: .done),
            FlowStep(id: "tunnel", title: "Tunnel", detail: tunnelInterfaces.isEmpty ? "VPN tunnel detected" : "VPN tunnel up", state: kerioTunnelSeen ? .done : .running),
            FlowStep(id: "split", title: "Split routes", detail: "Only VPN routes use the tunnel.", state: .done)
        ]
    }

    private func resetToIdleTimeline(status: String? = nil) {
        isTearingDown = false
        isWaitingForKerio = false
        sessionPhase = isActive ? .connected : .idle
        if isActive {
            loadConnectedTimeline()
        } else {
            loadConnectTimeline()
        }
        if let status {
            pinStatus(status, seconds: 10)
            appendLog(status)
        }
    }

    private func finishDisconnect(success: Bool) {
        isTearingDown = false
        isActive = false
        if success {
            kerioTunnelSeen = false
            tunnelInterfaces = []
            fullTunnelHijackSeen = false
        }
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.32) { [weak self] in
            guard let self else { return }
            self.setBusy(false)
            self.resetToIdleTimeline(status: success ? "All off — LAN only" : nil)
            self.probeNetwork()
        }
    }

    func syncTimelineFromReality() {
        guard !isBusy else { return }
        if isActive {
            sessionPhase = .connected
            loadConnectedTimeline()
        } else {
            sessionPhase = .idle
            loadConnectTimeline()
            if kerioTunnelSeen || kerioSessionConnected {
                updateStep("kerio", .done, kerioSessionConnected
                    ? "Kerio session Connected — split still OFF."
                    : "VPN tunnel is up — split still OFF.")
                if networkSnapshot.readyForSplitApply {
                    updateStep("tunnel", .done, "\(networkSnapshot.kerioInterface) · \(networkSnapshot.kerioTunnelAddress)")
                    updateStep("split", .pending, "Tap Apply Split once to finish.")
                } else {
                    updateStep("tunnel", .running, "Waiting for tunnel IPv4 before split can apply.")
                    updateStep("split", .pending, "Split waits for a tunnel address.")
                }
            }
        }
    }

    private nonisolated static func bringDownVPN(
        backend: ConnectBackend,
        systemVPNName: String
    ) -> (ok: Bool, message: String) {
        switch backend {
        case .kerioClient:
            return KerioLauncher.stopOfficialSession()
        case .systemVPN:
            return StandardVPN.stopSystemVPN(named: systemVPNName)
        case .openvpnProfile:
            return StandardVPN.stopOpenVPN()
        }
    }

    private nonisolated static func bringDownDetail(_ backend: ConnectBackend) -> String {
        switch backend {
        case .kerioClient:
            return "Clicking Disconnect in the official Kerio client…"
        case .systemVPN:
            return "Stopping the macOS L2TP/IPsec profile…"
        case .openvpnProfile:
            return "Disconnecting Tunnelblick/Viscosity…"
        }
    }

    private nonisolated static func bringUpVPN(
        backend: ConnectBackend,
        systemVPNName: String,
        openvpnPath: String,
        kerioServer: String
    ) -> KerioLauncher.BringUpResult {
        switch backend {
        case .kerioClient:
            return KerioLauncher.startOfficialSession(preferredServer: kerioServer)
        case .systemVPN:
            let result = StandardVPN.connectSystemVPN(named: systemVPNName)
            return KerioLauncher.BringUpResult(ok: result.ok, needsAccessibility: false, message: result.message)
        case .openvpnProfile:
            let result = StandardVPN.openOpenVPNProfile(openvpnPath, status: StandardVPN.probe())
            return KerioLauncher.BringUpResult(ok: result.ok, needsAccessibility: false, message: result.message)
        }
    }

    private nonisolated static func bringUpDetail(_ backend: ConnectBackend, persistent _: Bool) -> String {
        switch backend {
        case .kerioClient:
            return "Starting official Kerio client, then split. Click Connect in Kerio if the session does not start."
        case .systemVPN:
            return "Starting macOS L2TP/IPsec VPN via scutil (never the Kerio NE profile)."
        case .openvpnProfile:
            return "Opening the OpenVPN profile in Tunnelblick/Viscosity."
        }
    }

    private nonisolated static func bringUpStatus(_ backend: ConnectBackend, persistent _: Bool) -> String {
        switch backend {
        case .kerioClient:
            return "Starting official Kerio client, then split…"
        case .systemVPN:
            return "Starting macOS VPN profile…"
        case .openvpnProfile:
            return "Opening OpenVPN profile…"
        }
    }

    private nonisolated static func waitStatus(_ backend: ConnectBackend, remaining: Int, persistent _: Bool) -> String {
        switch backend {
        case .kerioClient:
            return "Waiting for official Kerio tunnel — click Connect in Kerio if needed (\(remaining)s)"
        case .systemVPN:
            return "Waiting for macOS VPN tunnel (\(remaining)s)"
        case .openvpnProfile:
            return "Waiting for OpenVPN tunnel (\(remaining)s)"
        }
    }

    private nonisolated static func timeoutStatus(_ backend: ConnectBackend) -> String {
        switch backend {
        case .kerioClient:
            return "Kerio Split cannot log in; click Connect in Kerio"
        case .systemVPN:
            return "macOS VPN did not come up — add L2TP over IPsec in System Settings (GFI 118441)"
        case .openvpnProfile:
            return "OpenVPN did not come up — connect in Tunnelblick, then tap Connect All again"
        }
    }

    private nonisolated static func tunnelDetail(_ network: (hasKerio: Bool, utuns: [String], hasHijack: Bool)) -> String {
        if network.hasHijack {
            return "VPN tunnel up · full-tunnel routes present"
        }
        return "VPN tunnel detected"
    }

    // MARK: - Smart network / outbound

    func refreshScenario() {
        let activeName = outboundStore.profiles.first(where: { $0.id == outboundStore.activeProfileId })?.name ?? ""
        scenario = ScenarioEngine.evaluate(
            helperReady: helperReady,
            canClickKerio: canClickKerio,
            sessionPhase: sessionPhase,
            waitingForAccessibility: waitingForAccessibility,
            isActive: isActive,
            snapshot: networkSnapshot,
            outboundMode: config.options.outboundMode,
            outboundConnected: outboundConnected,
            outboundProfileName: activeName
        )
        networkEvents = eventLog.events
        outboundConnected = outboundManager.isConnected
        outboundBinaryPath = outboundManager.binaryPath
        outboundError = outboundManager.lastError
        outboundStatusDetail = outboundManager.statusDetail
        outboundConnectedAt = outboundManager.connectedAt
        outboundActiveName = outboundManager.activeProfileName
        refreshDiagnostics()
    }

    func refreshDiagnostics() {
        diagnosticReport = NetworkSense.diagnose(
            helperReady: helperReady,
            canClickKerio: canClickKerio,
            isActive: isActive,
            snapshot: networkSnapshot,
            vpnRoutes: config.vpnRoutes,
            connectivity: connectivity,
            kerioInstalled: kerioClientInstalled
        )
    }

    func copyDiagnostics() {
        refreshDiagnostics()
        NSPasteboard.general.clearContents()
        NSPasteboard.general.setString(diagnosticReport.plainText, forType: .string)
        pinStatus("Diagnostics copied", seconds: 4)
        recordEvent("Diagnostics copied to clipboard")
    }

    /// Full flight recorder + diagnostics + engine log — paste this into chat for analysis.
    func copyFlightLog() {
        refreshDiagnostics()
        probeNetwork()
        let extra = [
            diagnosticReport.plainText,
            "",
            "=== scenario ===",
            "\(scenario.title) — \(scenario.detail)",
            "",
            "=== engine log ===",
            log.isEmpty ? "(empty)" : log,
            "",
            "=== kerio env ===",
            KerioLauncher.environmentDump()
        ].joined(separator: "\n")
        let text = FlightRecorder.exportText(extra: extra)
        NSPasteboard.general.clearContents()
        NSPasteboard.general.setString(text, forType: .string)
        pinStatus("Flight log copied — paste it in chat", seconds: 8)
        recordEvent("Flight log copied (\(FlightRecorder.filePath))")
        FlightRecorder.log("ui", "flight_copied", ["chars": "\(text.count)"])
    }

    func revealFlightLog() {
        let url = URL(fileURLWithPath: FlightRecorder.filePath)
        NSWorkspace.shared.activateFileViewerSelecting([url])
        pinStatus("Revealed flight log in Finder", seconds: 4)
    }

    func performScenarioAction(_ action: ScenarioAction) {
        switch action.kind {
        case .installHelper: installHelper()
        case .openAccessibility: grantClickKerio()
        case .connectAll: connectAll()
        case .disconnectAll: requestDisconnect()
        case .openKerio: openKerioClient()
        case .repairRoutes: repairRoutes()
        case .openOutbound:
            NotificationCenter.default.post(name: .kerioSplitNavigate, object: AppSection.outbound)
        case .openSettings:
            NotificationCenter.default.post(name: .kerioSplitNavigate, object: AppSection.settings)
        case .cancelConnect: cancelConnectAll()
        }
    }

    func pinDetectedKerioTunnel() {
        let snap = networkSnapshot
        guard !snap.kerioInterface.isEmpty else { return }
        config.options.kerioInterface = snap.kerioInterface
        if !snap.kerioGateway.isEmpty {
            config.options.kerioGateway = snap.kerioGateway
        }
        saveConfig()
        recordEvent("Pinned Kerio \(snap.kerioInterface) / \(snap.kerioGateway)")
        probeNetwork()
    }

    func setOutboundMode(_ mode: OutboundMode) {
        config.options.outboundMode = mode
        if mode != .builtIn, outboundConnected {
            disconnectOutbound()
        }
        saveConfig()
        refreshScenario()
    }

    func addIgnoreInterface(_ raw: String) {
        let s = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !s.isEmpty else { return }
        if !config.options.ignoreInterfaces.contains(s) {
            config.options.ignoreInterfaces.append(s)
            saveConfig()
            recordEvent("Ignore iface \(s)")
            probeNetwork()
        }
    }

    func removeIgnoreInterface(_ iface: String) {
        config.options.ignoreInterfaces.removeAll { $0 == iface }
        saveConfig()
        probeNetwork()
    }

    func reloadOutboundStore() {
        outboundManager.refreshBinary()
        outboundStore = outboundManager.loadStore()
        outboundBinaryPath = outboundManager.binaryPath
        outboundConnected = outboundManager.isConnected
        outboundStatusDetail = outboundManager.statusDetail
        outboundError = outboundManager.lastError
        outboundConnectedAt = outboundManager.connectedAt
        outboundActiveName = outboundManager.activeProfileName
        refreshScenario()
    }

    func installOutboundEngine() async {
        outboundEngineBusy = true
        outboundEngineProgress = "Starting…"
        outboundError = nil
        // Mirror progress while downloading
        let progressTask = Task { @MainActor in
            while !Task.isCancelled {
                outboundEngineProgress = outboundManager.engineProgress.isEmpty
                    ? outboundEngineProgress
                    : outboundManager.engineProgress
                try? await Task.sleep(nanoseconds: 200_000_000)
            }
        }
        let ok = await outboundManager.installEngine()
        progressTask.cancel()
        outboundBinaryPath = outboundManager.binaryPath
        outboundError = outboundManager.lastError
        outboundStatusDetail = outboundManager.statusDetail
        outboundEngineBusy = false
        outboundEngineProgress = ""
        if ok {
            recordEvent("Outbound engine installed")
            pinStatus("Outbound engine ready", seconds: 5)
        } else {
            recordEvent("Outbound engine install failed — \(outboundError ?? "?")")
        }
        refreshScenario()
    }

    func importOutboundLinks(_ raw: String) {
        let profiles = SubscriptionParser.parseImport(raw)
        guard !profiles.isEmpty else {
            outboundError = "No share links found"
            refreshScenario()
            return
        }
        outboundStore.profiles.append(contentsOf: profiles)
        if outboundStore.activeProfileId == nil {
            outboundStore.activeProfileId = profiles.first?.id
        }
        try? outboundManager.saveStore(outboundStore)
        recordEvent("Imported \(profiles.count) outbound profile(s)")
        outboundError = nil
        pinStatus("Imported \(profiles.count) profile(s)", seconds: 4)
        refreshScenario()
    }

    func removeOutboundProfile(_ id: String) {
        outboundStore.profiles.removeAll { $0.id == id }
        if outboundStore.activeProfileId == id {
            outboundStore.activeProfileId = outboundStore.profiles.first?.id
        }
        try? outboundManager.saveStore(outboundStore)
        refreshScenario()
    }

    func fetchOutboundSubscription(url: String, name: String) async {
        setBusy(true, watchdogSeconds: 40)
        do {
            let profiles = try await outboundManager.fetchSubscription(urlString: url, name: name)
            let sub = OutboundSubscription(name: name, url: url, lastFetchedAt: Date(), profileIds: profiles.map(\.id))
            outboundStore.subscriptions.append(sub)
            outboundStore.profiles.append(contentsOf: profiles)
            if outboundStore.activeProfileId == nil {
                outboundStore.activeProfileId = profiles.first?.id
            }
            try outboundManager.saveStore(outboundStore)
            recordEvent("Fetched subscription “\(name)” — \(profiles.count) node(s)")
            outboundError = nil
            pinStatus("Subscription imported — \(profiles.count) nodes", seconds: 6)
        } catch {
            outboundError = error.localizedDescription
            recordEvent("Subscription fetch failed: \(error.localizedDescription)")
            pinStatus("Subscription fetch failed", seconds: 6)
        }
        setBusy(false)
        refreshScenario()
    }

    func connectOutbound(profileId: String) async {
        guard config.options.outboundMode == .builtIn else {
            outboundError = "Switch mode to Built-in first"
            refreshScenario()
            return
        }
        guard outboundBinaryPath != nil || outboundManager.hasEngine else {
            outboundError = "Install the outbound engine first"
            refreshScenario()
            return
        }
        guard let profile = outboundStore.profiles.first(where: { $0.id == profileId }) else { return }
        outboundConnecting = true
        outboundStatusDetail = "Connecting — \(profile.name)…"
        outboundError = nil
        setBusy(true, watchdogSeconds: 30)
        outboundStore.activeProfileId = profileId
        try? outboundManager.saveStore(outboundStore)
        // Ensure helper scripts (outbound-start) are current before connect
        syncScriptsToSupport()
        // Bind ONLY to physical LAN (en0/…) — never dial the share-link VPN through Kerio.
        probeNetwork()
        try? await Task.sleep(nanoseconds: 150_000_000)
        let snap = networkSnapshot
        let bindIface: String = {
            if snap.lanInterface.hasPrefix("en") { return snap.lanInterface }
            if snap.defaultInterface.hasPrefix("en") { return snap.defaultInterface }
            return ""
        }()
        var exclude: [String] = []
        // Exclude real Kerio utun only (never our 172.19 outbound TUN).
        if !snap.kerioInterface.isEmpty,
           !snap.kerioTunnelAddress.hasPrefix("172.19.0."),
           snap.kerioInterface != snap.outboundInterface {
            exclude.append(snap.kerioInterface)
        }

        // If Kerio full-tunnel is eating the default route, peel it back first so
        // outbound can dial on LAN. Outbound itself never rides inside Kerio.
        // Only when Kerio session is actually up — outbound's own 0/1 is not Kerio.
        if helperReady, !isActive, snap.fullTunnelHijack, snap.kerioSessionConnected {
            await ensureSplitAppliedForOutbound()
        }

        let ok = await outboundManager.connect(
            profile: profile,
            bindInterface: bindIface,
            excludeInterfaces: exclude,
            kerioCIDRs: config.vpnRoutes
        )
        outboundConnected = outboundManager.isConnected
        outboundStatusDetail = outboundManager.statusDetail
        outboundError = outboundManager.lastError
        outboundConnecting = false
        outboundConnectedAt = outboundManager.connectedAt
        outboundActiveName = outboundManager.activeProfileName
        if ok {
            let via = bindIface.isEmpty ? "auto" : bindIface
            recordEvent("Outbound connected — \(profile.name) (dial via \(via), separate from Kerio)")
            pinStatus("Connected via \(via) — not through Kerio", seconds: 6)
            probeNetwork()
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.5) { [weak self] in
                self?.autoIgnoreSecondaryTuns()
            }
        } else {
            recordEvent("Outbound failed — \(outboundError ?? "?")")
            pinStatus("Outbound failed", seconds: 5)
        }
        setBusy(false)
        refreshScenario()
    }

    func pingOutboundProfiles() async {
        guard !outboundStore.profiles.isEmpty else { return }
        outboundPinging = true
        outboundStatusDetail = "Pinging \(outboundStore.profiles.count) profile(s)…"
        let profiles = outboundStore.profiles
        let results = await OutboundProbe.pingAll(profiles: profiles)
        outboundLatencies = results
        outboundPinging = false
        let okCount = results.count
        let best = profiles
            .compactMap { p -> (OutboundProfile, Int)? in
                guard let ms = results[p.id] else { return nil }
                return (p, ms)
            }
            .min(by: { $0.1 < $1.1 })
        if let best {
            outboundStatusDetail = "Ping done — best \(best.0.name) · \(best.1) ms (\(okCount)/\(profiles.count) up)"
            pinStatus("Best: \(best.0.name) · \(best.1) ms", seconds: 5)
        } else {
            outboundStatusDetail = "Ping done — no reachable profiles"
            pinStatus("Ping: no reachable nodes", seconds: 5)
        }
        recordEvent("Outbound ping — \(okCount)/\(profiles.count) reachable")
    }

    func autoSelectOutbound() async {
        guard config.options.outboundMode == .builtIn else {
            outboundError = "Switch mode to Built-in first"
            refreshScenario()
            return
        }
        guard !outboundStore.profiles.isEmpty else {
            outboundError = "Import a profile first"
            refreshScenario()
            return
        }
        outboundAutoSelecting = true
        await pingOutboundProfiles()
        let best = outboundStore.profiles
            .compactMap { p -> (OutboundProfile, Int)? in
                guard let ms = outboundLatencies[p.id] else { return nil }
                return (p, ms)
            }
            .min(by: { $0.1 < $1.1 })
        guard let best else {
            outboundAutoSelecting = false
            outboundError = "Auto-select failed — no reachable profile"
            pinStatus("Auto-select failed", seconds: 5)
            refreshScenario()
            return
        }
        pinStatus("Auto-select → \(best.0.name) · \(best.1) ms", seconds: 5)
        recordEvent("Outbound auto-select — \(best.0.name) (\(best.1) ms)")
        await connectOutbound(profileId: best.0.id)
        outboundAutoSelecting = false
    }

    /// Apply split quickly before Built-in outbound so Kerio 0/1 hijack does not swallow internet.
    private func ensureSplitAppliedForOutbound() async {
        pinStatus("Applying split before outbound…", seconds: 4)
        saveConfig(quiet: true)
        syncScriptsToSupport()
        let result = await Task.detached(priority: .userInitiated) {
            HelperService.runCtl(["apply"])
        }.value
        if result.ok
            || result.text.contains("split tunnel applied")
            || result.text.contains("hijack") {
            isActive = true
            sessionPhase = .connected
            updateStep("split", .done, "Split ON — only VPN routes use Kerio.")
            recordEvent("Split auto-applied before outbound")
            learnPinFromSnapshot()
            probeNetwork()
            try? await Task.sleep(nanoseconds: 200_000_000)
        } else {
            pinStatus("Split apply failed — outbound may be slow until you Apply", seconds: 6)
            recordEvent("Split auto-apply before outbound failed")
        }
    }

    func disconnectOutbound() {
        outboundManager.disconnect()
        outboundConnected = false
        outboundConnecting = false
        outboundStatusDetail = outboundManager.statusDetail
        outboundConnectedAt = nil
        outboundActiveName = ""
        outboundError = nil
        recordEvent("Outbound disconnected")
        pinStatus("Outbound disconnected", seconds: 4)
        probeNetwork()
        refreshScenario()
    }

    private func autoIgnoreSecondaryTuns() {
        let kerio = networkSnapshot.kerioInterface
        let pinned = config.options.kerioInterface
        // Always ignore built-in outbound TUN so it never becomes "Kerio"
        if !networkSnapshot.outboundInterface.isEmpty,
           !config.options.ignoreInterfaces.contains(networkSnapshot.outboundInterface) {
            config.options.ignoreInterfaces.append(networkSnapshot.outboundInterface)
        }
        for iface in networkSnapshot.secondaryTuns {
            if iface == kerio || iface == pinned { continue }
            if !config.options.ignoreInterfaces.contains(iface) {
                config.options.ignoreInterfaces.append(iface)
            }
        }
        if !kerio.isEmpty {
            config.options.ignoreInterfaces.removeAll { $0 == kerio }
        }
        if !pinned.isEmpty {
            config.options.ignoreInterfaces.removeAll { $0 == pinned }
        }
        if !networkSnapshot.outboundInterface.isEmpty,
           !config.options.ignoreInterfaces.contains(networkSnapshot.outboundInterface) {
            config.options.ignoreInterfaces.append(networkSnapshot.outboundInterface)
        }
        saveConfig(quiet: true)
        probeNetwork()
    }

    private func runRouteGuardIfNeeded() {
        guard config.options.routeGuardEnabled, isActive, helperReady, !isBusy, !guardInFlight else { return }
        guard networkSnapshot.conflict || !networkSnapshot.managedRoutesMissing.isEmpty else { return }
        guardInFlight = true
        // keepBusy: true so we don't flicker the Connect/Disconnect buttons every guard tick.
        runEngine(arguments: ["guard"], keepBusy: true) { [weak self] ok, output in
            guard let self else { return }
            self.guardInFlight = false
            if ok || output.contains("guard=") {
                self.recordEvent("Guard: \(output.trimmingCharacters(in: .whitespacesAndNewlines))")
            }
            self.probeNetwork()
        }
    }

    private func refreshConnectivity() {
        let gw = networkSnapshot.lanGateway
        let sample = config.vpnRoutes.first ?? ""
        let kerioGw = networkSnapshot.kerioGateway
        DispatchQueue.global(qos: .utility).async { [weak self] in
            let report = ConnectivityProbe.probe(
                lanGateway: gw,
                sampleKerioHost: sample,
                kerioGateway: kerioGw
            )
            DispatchQueue.main.async {
                guard let self else { return }
                self.connectivity = report
                self.refreshDiagnostics()
            }
        }
    }

    private func learnPinFromSnapshot() {
        let snap = networkSnapshot
        if config.options.kerioInterface.isEmpty, !snap.kerioInterface.isEmpty {
            config.options.kerioInterface = snap.kerioInterface
        }
        if config.options.kerioGateway.isEmpty, !snap.kerioGateway.isEmpty {
            config.options.kerioGateway = snap.kerioGateway
        }
        saveConfig(quiet: true)
    }

    private func recordEvent(_ message: String) {
        eventLog.record(message)
        networkEvents = eventLog.events
        appendLog(message)
    }

    private func appendLog(_ text: String) {
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return }
        log = log.isEmpty ? trimmed : log + "\n———\n" + trimmed
    }
}
