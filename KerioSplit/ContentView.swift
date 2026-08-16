import SwiftUI

struct ContentView: View {
    @EnvironmentObject private var controller: TunnelController
    @State private var showTargets = false

    var body: some View {
        VStack(spacing: 0) {
            header
            Divider().opacity(0.35)
            main
            footer
        }
        .frame(width: 400, height: showTargets || !controller.log.isEmpty ? 580 : 460)
        .background(Brand.mist)
        .onAppear { controller.onAppear() }
    }

    private var header: some View {
        HStack(spacing: 14) {
            ZStack {
                RoundedRectangle(cornerRadius: 12, style: .continuous)
                    .fill(Brand.heroGradient)
                    .frame(width: 48, height: 48)
                Image(nsImage: Brand.logoImage)
                    .resizable()
                    .scaledToFit()
                    .frame(width: 28, height: 28)
            }
            VStack(alignment: .leading, spacing: 2) {
                Text("Kerio Split")
                    .font(.system(size: 18, weight: .semibold))
                    .foregroundStyle(Brand.ink)
                Text("Split tunneling for Kerio Control")
                    .font(.system(size: 12))
                    .foregroundStyle(Brand.deep.opacity(0.75))
            }
            Spacer()
        }
        .padding(20)
        .background(Brand.deep.opacity(0.06))
    }

    private var main: some View {
        VStack(alignment: .leading, spacing: 14) {
            HStack(spacing: 8) {
                Circle()
                    .fill(controller.isActive ? Brand.success : Brand.primary.opacity(0.4))
                    .frame(width: 8, height: 8)
                Text(controller.statusText)
                    .font(.system(size: 12, weight: .medium))
                    .foregroundStyle(Brand.ink.opacity(0.9))
                    .fixedSize(horizontal: false, vertical: true)
            }
            .padding(12)
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(
                RoundedRectangle(cornerRadius: 10, style: .continuous)
                    .fill(Color.white.opacity(0.85))
            )

            Button(action: { controller.toggle() }) {
                HStack {
                    if controller.isBusy {
                        ProgressView().controlSize(.small).tint(.white)
                    }
                    Text(controller.isActive ? "Disconnect Split" : "Connect Split")
                        .font(.system(size: 14, weight: .semibold))
                }
                .frame(maxWidth: .infinity)
                .padding(.vertical, 12)
                .foregroundStyle(.white)
                .background(
                    RoundedRectangle(cornerRadius: 10, style: .continuous)
                        .fill(controller.isActive ? Brand.danger : Brand.primary)
                )
            }
            .buttonStyle(.plain)
            .disabled(controller.isBusy)

            DisclosureGroup(isExpanded: $showTargets) {
                TextEditor(text: $controller.targetsText)
                    .font(.system(size: 12, design: .monospaced))
                    .scrollContentBackground(.hidden)
                    .frame(height: 90)
                    .padding(8)
                    .background(RoundedRectangle(cornerRadius: 8).fill(Color.white))

                HStack {
                    Button("Save") { controller.saveTargets() }
                    Button("Status") { controller.refreshStatus() }
                    Spacer()
                }
                .disabled(controller.isBusy)
            } label: {
                Text("Destinations")
                    .font(.system(size: 13, weight: .semibold))
                    .foregroundStyle(Brand.deep)
            }

            if !controller.log.isEmpty {
                ScrollView {
                    Text(controller.log)
                        .font(.system(size: 10, design: .monospaced))
                        .foregroundStyle(Brand.ink.opacity(0.7))
                        .frame(maxWidth: .infinity, alignment: .leading)
                        .textSelection(.enabled)
                }
                .frame(height: 80)
                .padding(8)
                .background(RoundedRectangle(cornerRadius: 8).fill(Brand.deep.opacity(0.06)))
            }
        }
        .padding(20)
    }

    private var footer: some View {
        Text("Mehrad Technical Team")
            .font(.system(size: 11, weight: .medium))
            .foregroundStyle(Brand.deep.opacity(0.7))
            .frame(maxWidth: .infinity)
            .padding(.bottom, 14)
    }
}
