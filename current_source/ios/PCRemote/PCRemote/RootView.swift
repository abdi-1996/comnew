import SwiftUI

struct RootView: View {
    @EnvironmentObject var settings: ConnectionSettings

    var body: some View {
        Group {
            if settings.isConnected {
                ModuleHubView()
            } else {
                SetupView()
            }
        }
        .preferredColorScheme(settings.preferredColorScheme)
    }
}

private enum HubDestination: String, Identifiable {
    case comfy
    case aitoolkit
    case corel

    var id: String { rawValue }
}

private struct ModuleHubView: View {
    @EnvironmentObject var settings: ConnectionSettings
    @State private var destination: HubDestination?
    @State private var comfyModel: ComfyUIModel?
    @State private var aitoolkitModel: AIToolkitModel?
    @State private var corelModel: CorelDrawModel?
    @State private var capabilities: ServerCapabilitiesResponse?
    @State private var capabilityMessage = ""
    @State private var showSettings = false
    @State private var refreshing = false

    private var device: SavedDevice? { settings.currentDevice }

    var body: some View {
        NavigationStack {
            ZStack {
                HubBackground().ignoresSafeArea()

                ScrollView(showsIndicators: false) {
                    VStack(spacing: 18) {
                        header
                        connectionSummaryCard
                        modules
                        serverCard
                    }
                    .padding(.horizontal, 18)
                    .padding(.top, 8)
                    .padding(.bottom, 34)
                }
            }
            .toolbar(.hidden, for: .navigationBar)
        }
        .task(id: settings.currentDevice?.storageKey) {
            await prepareForCurrentDevice()
        }
        .fullScreenCover(item: $destination) { destination in
            switch destination {
            case .comfy:
                if let comfyModel {
                    ComfyUIView(model: comfyModel, standalone: false)
                } else {
                    HubLoadingView(title: "Подключаем ComfyUI…")
                }

            case .aitoolkit:
                if let aitoolkitModel {
                    AIToolkitView(model: aitoolkitModel)
                } else {
                    HubLoadingView(title: "Подключаем AI Toolkit…")
                }

            case .corel:
                if let corelModel {
                    CorelDrawView(model: corelModel)
                } else {
                    HubLoadingView(title: "Подключаем CorelDRAW…")
                }
            }
        }
        .sheet(isPresented: $showSettings) {
            HubSettingsView()
                .environmentObject(settings)
        }
    }

    private var header: some View {
        HStack(alignment: .top, spacing: 14) {
            VStack(alignment: .leading, spacing: 5) {
                Text("Comfy Remote")
                    .font(.system(size: 31, weight: .bold, design: .rounded))
                    .foregroundStyle(.white)
                Text("Remote Studio · 2.1")
                    .font(.system(size: 14, weight: .semibold))
                    .foregroundStyle(.white.opacity(0.58))
            }

            Spacer()

            Button {
                showSettings = true
            } label: {
                Image(systemName: "gearshape.fill")
                    .font(.system(size: 18, weight: .semibold))
                    .foregroundStyle(.white)
                    .frame(width: 44, height: 44)
                    .background(.ultraThinMaterial, in: RoundedRectangle(cornerRadius: 15, style: .continuous))
                    .overlay(
                        RoundedRectangle(cornerRadius: 15, style: .continuous)
                            .stroke(Color.white.opacity(0.12), lineWidth: 1)
                    )
            }
            .buttonStyle(.plain)
        }
        .padding(.top, 8)
    }

    private var connectionSummaryCard: some View {
        HStack(spacing: 13) {
            ZStack {
                RoundedRectangle(cornerRadius: 17, style: .continuous)
                    .fill(Color.green.opacity(0.15))
                Image(systemName: "desktopcomputer")
                    .font(.system(size: 22, weight: .semibold))
                    .foregroundStyle(.green)
            }
            .frame(width: 54, height: 54)

            VStack(alignment: .leading, spacing: 4) {
                HStack(spacing: 7) {
                    Circle().fill(Color.green).frame(width: 8, height: 8)
                    Text(settings.currentStatus?.computer ?? device?.name ?? "Windows PC")
                        .font(.system(size: 17, weight: .bold))
                        .foregroundStyle(.white)
                        .lineLimit(1)
                }
                Text(connectionDetail)
                    .font(.system(size: 12, weight: .medium, design: .monospaced))
                    .foregroundStyle(.white.opacity(0.56))
                    .lineLimit(1)
            }

            Spacer()

            Button {
                Task { await refreshCapabilities() }
            } label: {
                if refreshing {
                    ProgressView().tint(.white)
                } else {
                    Image(systemName: "arrow.clockwise")
                        .font(.system(size: 16, weight: .semibold))
                        .foregroundStyle(.white.opacity(0.8))
                }
            }
            .buttonStyle(.plain)
            .disabled(refreshing)
        }
        .padding(15)
        .background(.ultraThinMaterial, in: RoundedRectangle(cornerRadius: 24, style: .continuous))
        .overlay(
            RoundedRectangle(cornerRadius: 24, style: .continuous)
                .stroke(Color.white.opacity(0.11), lineWidth: 1)
        )
    }

    private var modules: some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack {
                Text("Модули")
                    .font(.system(size: 20, weight: .bold))
                    .foregroundStyle(.white)
                Spacer()
                Text("Один сервер")
                    .font(.system(size: 12, weight: .semibold))
                    .foregroundStyle(.white.opacity(0.5))
            }

            HubModuleCard(
                title: "ComfyUI",
                subtitle: "Generate · Workflows · Node Editor",
                icon: "sparkles.rectangle.stack.fill",
                accent: .cyan,
                badge: moduleBadge("comfyui", fallback: "ГОТОВО"),
                badgeColor: .green,
                enabled: true
            ) {
                destination = .comfy
            }

            HubModuleCard(
                title: "AI Toolkit",
                subtitle: "LoRA Training · Datasets · Checkpoints",
                icon: "brain.head.profile",
                accent: .purple,
                badge: moduleBadge("aitoolkit", fallback: "AI TOOLKIT"),
                badgeColor: .purple,
                enabled: capabilities?.module("aitoolkit")?.supported ?? true
            ) {
                destination = .aitoolkit
            }

            HubModuleCard(
                title: "CorelDRAW",
                subtitle: "Trace · Converter · Workspaces",
                icon: "scribble.variable",
                accent: .green,
                badge: moduleBadge("coreldraw", fallback: "BETA"),
                badgeColor: .green,
                enabled: true
            ) {
                destination = .corel
            }
        }
    }

    private var serverCard: some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack {
                Label("Stable Server", systemImage: "server.rack")
                    .font(.system(size: 15, weight: .bold))
                    .foregroundStyle(.white)
                Spacer()
                Text(serverVersionText)
                    .font(.system(size: 12, weight: .bold, design: .monospaced))
                    .foregroundStyle(.cyan)
            }

            HStack(spacing: 8) {
                HubFeaturePill(text: "ComfyUI")
                HubFeaturePill(text: "AI Toolkit")
                HubFeaturePill(text: "Corel")
                HubFeaturePill(text: "Files")
                HubFeaturePill(text: "API \(capabilities?.apiVersion ?? settings.currentStatus?.api_version ?? 6)")
            }

            if !capabilityMessage.isEmpty {
                Text(capabilityMessage)
                    .font(.system(size: 12))
                    .foregroundStyle(.white.opacity(0.55))
            }
        }
        .padding(16)
        .background(Color.black.opacity(0.18), in: RoundedRectangle(cornerRadius: 22, style: .continuous))
        .overlay(
            RoundedRectangle(cornerRadius: 22, style: .continuous)
                .stroke(Color.white.opacity(0.08), lineWidth: 1)
        )
    }

    private var connectionDetail: String {
        guard let device else { return "Нет подключения" }
        let transport = settings.currentStatus?.transport?.uppercased() ?? "AUTO"
        return "\(transport) · \(device.host):\(device.port)"
    }

    private var serverVersionText: String {
        if let capabilities { return "v\(capabilities.serverVersion)" }
        if let version = settings.currentStatus?.server_version { return "v\(version)" }
        return "v6.x"
    }

    private func moduleBadge(_ key: String, fallback: String) -> String {
        guard let module = capabilities?.module(key) else { return fallback }
        if key == "aitoolkit" && module.enabled { return "ГОТОВО" }
        if key == "aitoolkit" && module.supported { return "НАСТРОЙКА" }
        if key == "coreldraw" && module.enabled { return "BETA" }
        if module.enabled { return "ГОТОВО" }
        return fallback
    }

    @MainActor
    private func prepareForCurrentDevice() async {
        guard let device else {
            comfyModel = nil
            aitoolkitModel = nil
            corelModel = nil
            capabilities = nil
            return
        }

        if comfyModel?.device.storageKey != device.storageKey {
            comfyModel = ComfyUIModel(device: device)
        }

        if aitoolkitModel?.device.storageKey != device.storageKey {
            aitoolkitModel = AIToolkitModel(device: device)
        }

        if corelModel?.device.storageKey != device.storageKey {
            let corelApp = RemoteApp(
                id: "coreldraw",
                name: "CorelDRAW",
                icon: "scribble.variable",
                integration: "coreldraw",
                aliases: ["Corel", "CorelDRAW"]
            )
            corelModel = CorelDrawModel(device: device, app: corelApp)
        }

        await refreshCapabilities()
    }

    @MainActor
    private func refreshCapabilities() async {
        guard let device else { return }
        refreshing = true
        defer { refreshing = false }

        do {
            capabilities = try await APIClient(device: device).capabilities()
            capabilityMessage = "Hub API подключён. ComfyUI, AI Toolkit и CorelDRAW работают через единый сервер."
        } catch {
            capabilities = nil
            capabilityMessage = "Режим совместимости с предыдущим сервером. ComfyUI продолжит работать; для AI Toolkit установите Server 6.2."
        }
    }
}

private struct HubModuleCard: View {
    let title: String
    let subtitle: String
    let icon: String
    let accent: Color
    let badge: String
    let badgeColor: Color
    let enabled: Bool
    let action: () -> Void

    var body: some View {
        Button(action: action) {
            HStack(spacing: 15) {
                RoundedRectangle(cornerRadius: 20, style: .continuous)
                    .fill(accent.opacity(0.16))
                    .frame(width: 66, height: 66)
                    .overlay(
                        Image(systemName: icon)
                            .font(.system(size: 27, weight: .semibold))
                            .foregroundStyle(accent)
                    )

                VStack(alignment: .leading, spacing: 6) {
                    HStack(spacing: 8) {
                        Text(title)
                            .font(.system(size: 21, weight: .bold))
                            .foregroundStyle(.white)
                        Text(badge)
                            .font(.system(size: 9, weight: .heavy, design: .rounded))
                            .foregroundStyle(badgeColor)
                            .padding(.horizontal, 7)
                            .padding(.vertical, 4)
                            .background(badgeColor.opacity(0.13), in: Capsule())
                    }
                    Text(subtitle)
                        .font(.system(size: 13, weight: .medium))
                        .foregroundStyle(.white.opacity(0.54))
                        .lineLimit(2)
                }

                Spacer(minLength: 8)

                Image(systemName: "chevron.right")
                    .font(.system(size: 15, weight: .bold))
                    .foregroundStyle(.white.opacity(0.36))
            }
            .padding(15)
            .background(.ultraThinMaterial, in: RoundedRectangle(cornerRadius: 27, style: .continuous))
            .overlay(
                RoundedRectangle(cornerRadius: 27, style: .continuous)
                    .stroke(accent.opacity(0.23), lineWidth: 1)
            )
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .disabled(!enabled)
        .opacity(enabled ? 1 : 0.55)
    }
}

private struct HubFeaturePill: View {
    let text: String

    var body: some View {
        Text(text)
            .font(.system(size: 10, weight: .bold, design: .rounded))
            .foregroundStyle(.white.opacity(0.68))
            .padding(.horizontal, 8)
            .padding(.vertical, 5)
            .background(Color.white.opacity(0.07), in: Capsule())
    }
}

private struct HubBackground: View {
    var body: some View {
        ZStack {
            LinearGradient(
                colors: [Color.black, Color(red: 0.03, green: 0.07, blue: 0.12), Color.black],
                startPoint: .topLeading,
                endPoint: .bottomTrailing
            )
            Circle()
                .fill(Color.cyan.opacity(0.12))
                .frame(width: 310, height: 310)
                .blur(radius: 70)
                .offset(x: 150, y: -270)
            Circle()
                .fill(Color.purple.opacity(0.10))
                .frame(width: 280, height: 280)
                .blur(radius: 75)
                .offset(x: -150, y: 280)
        }
    }
}

private struct HubLoadingView: View {
    let title: String

    var body: some View {
        ZStack {
            HubBackground().ignoresSafeArea()
            ProgressView(title)
                .tint(.white)
                .foregroundStyle(.white)
        }
    }
}

private struct StagePlaceholderView: View {
    @Environment(\.dismiss) private var dismiss
    let title: String
    let subtitle: String
    let icon: String
    let stage: String
    let detail: String

    var body: some View {
        NavigationStack {
            ZStack {
                HubBackground().ignoresSafeArea()
                VStack(spacing: 20) {
                    RoundedRectangle(cornerRadius: 28, style: .continuous)
                        .fill(Color.purple.opacity(0.15))
                        .frame(width: 96, height: 96)
                        .overlay(
                            Image(systemName: icon)
                                .font(.system(size: 40, weight: .semibold))
                                .foregroundStyle(.purple)
                        )
                    Text(title)
                        .font(.system(size: 30, weight: .bold))
                        .foregroundStyle(.white)
                    Text(subtitle)
                        .font(.headline)
                        .foregroundStyle(.white.opacity(0.55))
                    Text(stage)
                        .font(.system(size: 12, weight: .heavy, design: .rounded))
                        .foregroundStyle(.orange)
                        .padding(.horizontal, 12)
                        .padding(.vertical, 7)
                        .background(Color.orange.opacity(0.12), in: Capsule())
                    Text(detail)
                        .font(.system(size: 15))
                        .foregroundStyle(.white.opacity(0.68))
                        .multilineTextAlignment(.center)
                        .padding(.horizontal, 26)
                        .padding(.top, 4)
                    Spacer()
                }
                .padding(.top, 90)
            }
            .toolbar {
                ToolbarItem(placement: .topBarLeading) {
                    Button("Назад") { dismiss() }
                        .foregroundStyle(.white)
                }
            }
            .toolbarBackground(.hidden, for: .navigationBar)
        }
    }
}

private struct HubSettingsView: View {
    @EnvironmentObject var settings: ConnectionSettings
    @Environment(\.dismiss) private var dismiss
    @State private var statusText = ""
    @State private var capabilitiesText = ""

    private var client: APIClient? {
        guard let device = settings.currentDevice else { return nil }
        return APIClient(device: device)
    }

    var body: some View {
        NavigationStack {
            Form {
                Section("Remote Studio") {
                    HStack(spacing: 12) {
                        Image(systemName: "square.grid.2x2.fill")
                            .font(.title2)
                            .foregroundStyle(.cyan)
                            .frame(width: 42, height: 42)
                            .background(Color.cyan.opacity(0.12), in: RoundedRectangle(cornerRadius: 12))
                        VStack(alignment: .leading, spacing: 2) {
                            Text("Comfy Remote 2.0").font(.headline)
                            Text(settings.currentDevice?.name ?? "Windows PC")
                                .font(.subheadline)
                                .foregroundStyle(.secondary)
                        }
                    }
                    LabeledContent("Модули", value: "ComfyUI · AI Toolkit · CorelDRAW")
                }

                Section("Подключение") {
                    Picker("Маршрут", selection: $settings.connectionRouteRaw) {
                        ForEach(ConnectionRouteMode.allCases) { mode in
                            Text(mode.title).tag(mode.rawValue)
                        }
                    }
                    if let device = settings.currentDevice {
                        LabeledContent("LAN", value: "\(device.host):\(device.port)")
                        if let zero = device.zerotierHost, !zero.isEmpty {
                            LabeledContent("ZeroTier", value: "\(zero):\(device.port)")
                        }
                        if let tail = device.tailscaleHost, !tail.isEmpty {
                            LabeledContent("Tailscale", value: "\(tail):\(device.port)")
                        }
                    }
                    Button("Проверить соединение") {
                        Task { await testConnection() }
                    }
                    if !statusText.isEmpty {
                        Text(statusText).font(.footnote).foregroundStyle(.secondary)
                    }
                }

                Section("Сервер") {
                    LabeledContent("Текущая версия", value: settings.currentStatus?.server_version ?? "—")
                    Button("Проверить Hub API") {
                        Task { await testCapabilities() }
                    }
                    if !capabilitiesText.isEmpty {
                        Text(capabilitiesText).font(.footnote).foregroundStyle(.secondary)
                    }
                    Text("Tailscale ON/OFF находится только на экране входа.")
                        .font(.footnote)
                        .foregroundStyle(.secondary)
                }

                Section("Оформление") {
                    Picker("Внешний вид", selection: $settings.appearanceRaw) {
                        ForEach(AppearanceMode.allCases) { mode in
                            Text(mode.title).tag(mode.rawValue)
                        }
                    }
                }

                Section("О приложении") {
                    LabeledContent("Версия", value: "2.1.1")
                    LabeledContent("Build", value: "13")
                    LabeledContent("Архитектура", value: "Module Hub")
                }

                Section {
                    Button("Отключиться от ПК", role: .destructive) {
                        settings.disconnect()
                        dismiss()
                    }
                }
            }
            .navigationTitle("Настройки")
            .toolbar {
                ToolbarItem(placement: .topBarTrailing) {
                    Button("Готово") { dismiss() }
                }
            }
        }
    }

    @MainActor
    private func testConnection() async {
        guard let client else { return }
        do {
            let value = try await client.status()
            statusText = "Подключено: \(value.computer) · Server \(value.server_version ?? "—")"
        } catch {
            statusText = error.localizedDescription
        }
    }

    @MainActor
    private func testCapabilities() async {
        guard let client else { return }
        do {
            let value = try await client.capabilities()
            capabilitiesText = "Server \(value.serverVersion) · API \(value.apiVersion) · Hub готов"
        } catch {
            capabilitiesText = "Hub API недоступен. Установите PCRemoteServer 6.2."
        }
    }
}
