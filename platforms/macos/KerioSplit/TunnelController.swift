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

    private static let resumeConnectKey = "kerioSplit.resumeConnectAfterRelaunch"

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
        (isActive || kerioTunnelSeen || sessionPhase == .connected)
            && !isBusy
            && sessionPhase != .connecting
            && sessionPhase != .waitingForPermission
    }

    /// Seconds to wait for Kerio tunnel during Connect All.
    private let kerioConnectWaitSeconds: TimeInterval = 90

    var configPathDisplay: String { configURL.path }

    var appVersion: String {
        Bundle.main.infoDictionary?["CFBundleShortVersionString"] as? String ?? "1.1.0"
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
    private var busyWatchdog: Timer?
    private var didBootstrap = false
    private var notificationsAuthorized = false
    private var statusPinnedUntil: Date?
    private var kerioWasSeen = false
    private var autoApplyTriggered = false
    private var connectAllTask: DispatchWorkItem?
    private var lastLoggedDiagnosis: String?

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
        ensureWritableSupport()
        loadConfig()
        detectApplied()
        requestNotificationsIfNeeded()
        startMonitoring()
        observeAppActivation()

        // Everything that might talk to the system goes after the first frame.
        DispatchQueue.main.async { [weak self] in
            guard let self else { return }
            self.syncLaunchAtLoginFromSystem()
            self.syncScriptsToSupport()
            self.refreshHelperStatus()
            self.probeNetwork()
            self.refreshVPNHelpers()
            self.refreshClickPermission()
            self.syncTimelineFromReality()
            let resumeConnect = UserDefaults.standard.bool(forKey: Self.resumeConnectKey)
            if resumeConnect {
                UserDefaults.standard.set(false, forKey: Self.resumeConnectKey)
            }
            if resumeConnect, self.helperReady, !self.isActive {
                self.connectAll()
            } else if self.config.options.autoApplyOnLaunch, self.helperReady, !self.isActive {
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
        let timer = Timer(timeInterval: 45, repeats: true) { [weak self] _ in
            DispatchQueue.main.async {
                self?.detectApplied()
                self?.probeNetwork()
                self?.refreshHelperStatus()
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
        isBusy = value
        busyWatchdog?.invalidate()
        busyWatchdog = nil
        guard value else { return }
        // Safety valve: never leave the Connect button spinning forever.
        busyWatchdog = Timer(timeInterval: watchdogSeconds, repeats: false) { [weak self] _ in
            Task { @MainActor in
                guard let self, self.isBusy else { return }
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

        connectAllTask?.cancel()
        isWaitingForKerio = true
        waitingForAccessibility = false
        sessionPhase = .connecting
        setBusy(true, watchdogSeconds: kerioConnectWaitSeconds + 120)
        let backend = config.options.connectBackend
        let systemVPNName = config.options.systemVPNName
        let openvpnPath = config.options.openvpnConfigPath
        let persistentHint = kerioSaved.persistent
        let kerioServer = kerioSaved.server
        pinStatus("Connect All — starting official Kerio client, then split…")
        loadConnectTimeline()
        updateStep("allow", .done, "Passwordless helper ready.")
        updateStep("kerio", .running, "Checking whether a tunnel is already up…")
        updateStep("tunnel", .pending, "Waiting for the VPN tunnel.")
        updateStep("split", .pending, "Split applies after the tunnel is up.")

        var work: DispatchWorkItem!
        work = DispatchWorkItem { [weak self] in
            guard let self else { return }

            var network = Self.scanNetwork()
            DispatchQueue.main.async {
                self.applyNetworkScan(network)
            }

            if !network.hasKerio {
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
                    }
                }

                let deadline = Date().addingTimeInterval(self.kerioConnectWaitSeconds)
                while Date() < deadline {
                    if work.isCancelled {
                        DispatchQueue.main.async {
                            self.isWaitingForKerio = false
                            self.waitingForAccessibility = false
                            self.setBusy(false)
                        }
                        return
                    }
                    Thread.sleep(forTimeInterval: 1)
                    network = Self.scanNetwork()
                    if network.hasKerio { break }
                    let remaining = max(0, Int(deadline.timeIntervalSinceNow))
                    DispatchQueue.main.async {
                        self.updateStep("tunnel", .running, "Still waiting for VPN tunnel (\(remaining)s)")
                        self.pinStatus(Self.waitStatus(backend, remaining: remaining, persistent: persistentHint))
                    }
                }
            } else {
                DispatchQueue.main.async {
                    self.updateStep("kerio", .done, "VPN tunnel already up.")
                }
            }

            DispatchQueue.main.async {
                if work.isCancelled { return }
                self.isWaitingForKerio = false
                self.waitingForAccessibility = false
                self.applyNetworkScan(network)

                if network.hasKerio {
                    self.updateStep("kerio", .done, "VPN tunnel reachable.")
                    self.updateStep("tunnel", .done, Self.tunnelDetail(network))
                    self.updateStep("split", .running, "Applying split routes without a password…")
                    self.pinStatus("Tunnel up — applying split…")
                    self.runEngine(arguments: ["apply"]) { ok, output in
                        if ok || output.contains("split tunnel applied") || output.contains("hijack") {
                            self.isActive = true
                            self.sessionPhase = .connected
                            self.updateStep("split", .done, "Split ON — only VPN routes use the tunnel.")
                            self.pinStatus("Connect All complete — split ON")
                            self.notify(
                                title: "Connect All",
                                body: "VPN tunnel detected and split routes applied."
                            )
                        } else {
                            self.sessionPhase = .idle
                            self.updateStep("split", .failed, "Split apply failed. See Activity.")
                        }
                        self.probeNetwork()
                    }
                } else {
                    self.setBusy(false)
                    self.sessionPhase = .idle
                    self.updateStep("tunnel", .failed, "No tunnel in \(Int(self.kerioConnectWaitSeconds))s.")
                    self.updateStep("split", .skipped, "Split waits until a VPN tunnel is connected.")
                    self.pinStatus(Self.timeoutStatus(backend), seconds: 14)
                    self.notify(
                        title: "VPN not connected",
                        body: Self.timeoutStatus(backend)
                    )
                }
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
            } else {
                self.updateStep("split", .failed, "Split apply failed. See Activity.")
            }
            self.probeNetwork()
        }
    }

    /// Restore split routes, then click Disconnect in the official VPN client (or stop L2TP/OpenVPN).
    func disconnectAll() {
        guard !isBusy else { return }
        connectAllTask?.cancel()
        connectAllTask = nil
        isWaitingForKerio = false
        waitingForAccessibility = false
        isTearingDown = true
        sessionPhase = .disconnecting
        setBusy(true, watchdogSeconds: 50)

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
                let stop = Self.bringDownVPN(backend: backend, systemVPNName: systemVPNName)
                DispatchQueue.main.async {
                    self.appendLog(stop.message)
                    if stop.ok {
                        self.updateStep("kerio", .done, stop.message)
                        self.updateStep("tunnel", .done, "VPN session stopped.")
                        self.pinStatus("Disconnect All complete")
                        self.notify(
                            title: "Disconnect All",
                            body: "Split routes restored and VPN session stopped."
                        )
                    } else {
                        self.updateStep("kerio", .failed, stop.message)
                        self.updateStep("tunnel", .skipped, "Click Disconnect in Kerio if the tunnel is still up.")
                        self.pinStatus(stop.message, seconds: 14)
                        self.notify(title: "VPN still connected?", body: stop.message)
                    }
                    self.finishDisconnect(success: stop.ok)
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
        DispatchQueue.global(qos: .utility).async { [weak self] in
            let result = Self.scanNetwork()
            DispatchQueue.main.async {
                guard let self else { return }
                self.applyNetworkScan(result)
                self.maybeAutoApplySplit()
                if !self.isBusy, self.sessionPhase == .idle || self.sessionPhase == .connected {
                    self.syncTimelineFromReality()
                }
            }
        }
        refreshVPNHelpers()
    }

    private func applyNetworkScan(_ result: (hasKerio: Bool, utuns: [String], hasHijack: Bool)) {
        let wasSeen = kerioWasSeen
        kerioTunnelSeen = result.hasKerio
        tunnelInterfaces = result.utuns
        fullTunnelHijackSeen = result.hasHijack
        kerioClientInstalled = KerioLauncher.isInstalled

        if result.hasKerio && !wasSeen {
            kerioWasSeen = true
        } else if !result.hasKerio {
            kerioWasSeen = false
            autoApplyTriggered = false
        }
    }

    private func maybeAutoApplySplit() {
        guard config.options.autoApplyWhenKerioConnects,
              kerioTunnelSeen,
              !isActive,
              !isBusy,
              helperReady,
              !autoApplyTriggered else { return }
        autoApplyTriggered = true
        pinStatus("Kerio connected — auto-applying split…")
        apply()
    }

    private nonisolated static func scanNetwork() -> (hasKerio: Bool, utuns: [String], hasHijack: Bool) {
        let routes = HelperService.runProcess("/usr/sbin/netstat", ["-rn", "-f", "inet"], timeoutSeconds: 3).text
        let hijack = routes.contains("0/1") || routes.contains("128.0/1")

        var utunsFromRoutes = Set<String>()
        for line in routes.split(separator: "\n") {
            let parts = line.split(whereSeparator: \.isWhitespace).map(String.init)
            guard let iface = parts.last, iface.hasPrefix("utun") else { continue }
            utunsFromRoutes.insert(iface)
        }

        let ifconfig = HelperService.runProcess("/sbin/ifconfig", [], timeoutSeconds: 3).text
        var candidates: [String] = []
        var current: String?
        for raw in ifconfig.split(separator: "\n") {
            let line = String(raw)
            if line.hasPrefix("utun"), let name = line.split(separator: ":").first {
                current = String(name)
                continue
            }
            guard let iface = current else { continue }
            if line.hasPrefix("\t") || line.hasPrefix(" ") {
                // Match split-tunnel.sh: any IPv4 on utun (not only 10.x / 172.x)
                if line.range(of: #"inet \d+\.\d+\.\d+\.\d+"#, options: .regularExpression) != nil {
                    candidates.append(iface)
                    current = nil
                }
            } else if !line.isEmpty {
                current = nil
            }
        }

        let list = Array(Set(candidates + utunsFromRoutes)).sorted()
        let hasKerio = !list.isEmpty || hijack
        return (hasKerio, list, hijack)
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
            if kerioTunnelSeen {
                updateStep("kerio", .running, "VPN tunnel is up — Connect All applies split, or Disconnect All stops it.")
                updateStep("tunnel", .done, tunnelInterfaces.isEmpty ? "VPN tunnel detected" : "VPN tunnel up")
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

    private func appendLog(_ text: String) {
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return }
        log = log.isEmpty ? trimmed : log + "\n———\n" + trimmed
    }
}
