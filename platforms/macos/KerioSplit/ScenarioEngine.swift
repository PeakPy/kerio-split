import Foundation

enum AppScenario: String, Equatable {
    case helperMissing
    case accessibilityNeeded
    case kerioDown
    case connecting
    case waitingPermission
    case disconnecting
    case splitHealthy
    case splitWithExternalOutbound
    case conflict
    case outboundBuiltIn
    case offlineHint
    case idleReady
}

struct ScenarioAction: Identifiable, Equatable {
    let id: String
    let title: String
    let kind: Kind

    enum Kind: Equatable {
        case installHelper
        case openAccessibility
        case connectAll
        case disconnectAll
        case openKerio
        case repairRoutes
        case openOutbound
        case openSettings
        case cancelConnect
    }
}

struct ScenarioPresentation: Equatable {
    var scenario: AppScenario
    var title: String
    var detail: String
    var tone: Tone
    var actions: [ScenarioAction]

    enum Tone: Equatable {
        case neutral
        case good
        case warn
        case danger
        case info
    }
}

enum ScenarioEngine {
    static func evaluate(
        helperReady: Bool,
        canClickKerio: Bool,
        sessionPhase: SessionPhase,
        waitingForAccessibility: Bool,
        isActive: Bool,
        snapshot: NetworkSnapshot,
        outboundMode: OutboundMode,
        outboundConnected: Bool,
        outboundProfileName: String
    ) -> ScenarioPresentation {
        if !helperReady {
            return ScenarioPresentation(
                scenario: .helperMissing,
                title: "Setup needed",
                detail: "Install the route helper once — that is the only Mac password prompt.",
                tone: .warn,
                actions: [.init(id: "helper", title: "Install route helper", kind: .installHelper)]
            )
        }

        if sessionPhase == .waitingForPermission || waitingForAccessibility {
            return ScenarioPresentation(
                scenario: .waitingPermission,
                title: "Waiting for Accessibility",
                detail: "Enable Kerio Split in Privacy → Accessibility. Connect All continues automatically.",
                tone: .warn,
                actions: [
                    .init(id: "ax", title: "Open Accessibility", kind: .openAccessibility),
                    .init(id: "cancel", title: "Cancel", kind: .cancelConnect)
                ]
            )
        }

        if sessionPhase == .connecting {
            return ScenarioPresentation(
                scenario: .connecting,
                title: "Connecting",
                detail: "Starting Kerio, waiting for the tunnel, then applying split.",
                tone: .info,
                actions: [.init(id: "cancel", title: "Cancel", kind: .cancelConnect)]
            )
        }

        if sessionPhase == .disconnecting {
            return ScenarioPresentation(
                scenario: .disconnecting,
                title: "Disconnecting",
                detail: "Restoring LAN routes, then stopping the VPN session.",
                tone: .info,
                actions: []
            )
        }

        if snapshot.conflict && isActive {
            return ScenarioPresentation(
                scenario: .conflict,
                title: "Route conflict",
                detail: snapshot.conflictDetail.isEmpty
                    ? "Something changed the routing table. Repair re-asserts Kerio CIDRs only."
                    : snapshot.conflictDetail,
                tone: .danger,
                actions: [
                    .init(id: "repair", title: "Repair routes", kind: .repairRoutes),
                    .init(id: "settings", title: "Network settings", kind: .openSettings)
                ]
            )
        }

        if outboundMode == .builtIn && outboundConnected {
            let name = outboundProfileName.isEmpty ? "profile" : outboundProfileName
            if isActive {
                return ScenarioPresentation(
                    scenario: .outboundBuiltIn,
                    title: "Kerio + outbound",
                    detail: "Split ON · outbound “\(name)” up. Corporate CIDRs on Kerio · internet via outbound.",
                    tone: .good,
                    actions: [
                        .init(id: "disc", title: "Disconnect All", kind: .disconnectAll)
                    ]
                )
            }
            if snapshot.hasKerioTunnel {
                return ScenarioPresentation(
                    scenario: .outboundBuiltIn,
                    title: "Outbound up · apply Kerio split",
                    detail: "Outbound “\(name)” is connected. Kerio tunnel is up — Connect All applies split routes.",
                    tone: .info,
                    actions: [
                        .init(id: "connect", title: "Connect All", kind: .connectAll),
                        .init(id: "disc", title: "Disconnect All", kind: .disconnectAll)
                    ]
                )
            }
            return ScenarioPresentation(
                scenario: .outboundBuiltIn,
                title: "Outbound up · Kerio needed",
                detail: "Outbound “\(name)” is connected. Connect Kerio (or Connect All) for corporate CIDRs.",
                tone: .warn,
                actions: [
                    .init(id: "connect", title: "Connect All", kind: .connectAll),
                    .init(id: "kerio", title: "Open Kerio", kind: .openKerio)
                ]
            )
        }

        if isActive && snapshot.hasExternalOutbound {
            let def = snapshot.defaultInterface
            let viaExternal = !snapshot.defaultOnLAN && def.hasPrefix("utun")
            return ScenarioPresentation(
                scenario: .splitWithExternalOutbound,
                title: "Split ON · dual VPN",
                detail: viaExternal
                    ? "Kerio CIDRs on \(snapshot.kerioInterface.isEmpty ? "Kerio" : snapshot.kerioInterface). Internet via \(def). This is expected coexistence — not a conflict."
                    : "Another tun (\(snapshot.secondaryTuns.joined(separator: ", "))) is up. Kerio CIDRs stay guarded.",
                tone: .good,
                actions: [
                    .init(id: "disc", title: "Disconnect All", kind: .disconnectAll)
                ]
            )
        }

        if isActive {
            return ScenarioPresentation(
                scenario: .splitHealthy,
                title: "All good",
                detail: "Split ON — only configured networks use Kerio. Internet stays on \(snapshot.lanInterface.isEmpty ? "LAN" : snapshot.lanInterface).",
                tone: .good,
                actions: [.init(id: "disc", title: "Disconnect All", kind: .disconnectAll)]
            )
        }

        if !snapshot.hasKerioTunnel {
            if !canClickKerio {
                return ScenarioPresentation(
                    scenario: .accessibilityNeeded,
                    title: "Ready when Accessibility is on",
                    detail: "Helper is installed. Enable Accessibility so Connect All can click Kerio, or open Kerio yourself.",
                    tone: .warn,
                    actions: [
                        .init(id: "ax", title: "Open Accessibility", kind: .openAccessibility),
                        .init(id: "kerio", title: "Open Kerio", kind: .openKerio),
                        .init(id: "connect", title: "Connect All", kind: .connectAll)
                    ]
                )
            }
            return ScenarioPresentation(
                scenario: .kerioDown,
                title: snapshot.kerioDaemonRunning ? "Kerio not connected" : "Kerio tunnel down",
                detail: snapshot.kerioDaemonRunning
                    ? "Kerio daemon is running but scutil shows Disconnected. Connect from the Kerio menu bar, then come back."
                    : "Connect All starts the official client, waits for the tunnel, then applies split.",
                tone: .neutral,
                actions: [
                    .init(id: "connect", title: "Connect All", kind: .connectAll),
                    .init(id: "kerio", title: "Open Kerio", kind: .openKerio)
                ]
            )
        }

        // Tunnel / session up but split off
        let sessionNote = snapshot.kerioSessionConnected
            ? "Kerio session Connected\(snapshot.kerioSessionLabel.isEmpty ? "" : " (\(snapshot.kerioSessionLabel))"). "
            : ""
        return ScenarioPresentation(
            scenario: .idleReady,
            title: "Kerio up — apply split",
            detail: snapshot.fullTunnelHijack
                ? "\(sessionNote)Kerio is full-tunnel right now. Connect All restores LAN for everything except your VPN routes."
                : "\(sessionNote)Tunnel \(snapshot.kerioInterface.isEmpty ? "detected" : snapshot.kerioInterface). Apply split to pin only your configured CIDRs.",
            tone: .info,
            actions: [
                .init(id: "connect", title: "Connect All", kind: .connectAll),
                .init(id: "out", title: "Outbound", kind: .openOutbound)
            ]
        )
    }
}
