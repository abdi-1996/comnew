import SwiftUI
import PhotosUI
import UIKit

struct SettingsView: View {
    @EnvironmentObject var settings: ConnectionSettings
    @Environment(\.dismiss) private var dismiss
    @State private var statusText = ""
    @State private var relayText = ""
    @State private var selectedWallpaper: PhotosPickerItem?

    private var client: APIClient? {
        guard let device = settings.currentDevice else { return nil }
        return APIClient(device: device)
    }

    var body: some View {
        NavigationStack {
            Form {
                Section {
                    HStack(spacing: 14) {
                        RoundedRectangle(cornerRadius: 15, style: .continuous)
                            .fill(LinearGradient(colors: [.cyan, .blue], startPoint: .topLeading, endPoint: .bottomTrailing))
                            .frame(width: 54, height: 54)
                            .overlay(Image(systemName: "desktopcomputer").font(.title2).foregroundStyle(.white))
                        VStack(alignment: .leading, spacing: 3) {
                            Text(settings.currentDevice?.name ?? "PC Remote")
                                .font(.headline)
                            Text(settings.currentStatus?.locked == true ? "Windows заблокирован" : "Подключено")
                                .font(.subheadline)
                                .foregroundStyle(.secondary)
                        }
                        Spacer()
                        Circle()
                            .fill(settings.currentStatus?.locked == true ? Color.orange : Color.green)
                            .frame(width: 10, height: 10)
                    }
                    .padding(.vertical, 3)
                }

                Section("Подключение") {
                    Picker(selection: $settings.connectionRouteRaw) {
                        ForEach(ConnectionRouteMode.allCases) { mode in
                            Text(mode.title).tag(mode.rawValue)
                        }
                    } label: {
                        SettingsRowLabel("Маршрут", system: "network", color: .blue)
                    }

                    if let device = settings.currentDevice {
                        LabeledContent {
                            Text("\(device.host):\(device.port)").foregroundStyle(.secondary)
                        } label: { SettingsRowLabel("LAN", system: "wifi", color: .blue) }
                        if let zero = device.zerotierHost, !zero.isEmpty {
                            LabeledContent {
                                Text("\(zero):\(device.port)").foregroundStyle(.secondary)
                            } label: { SettingsRowLabel("ZeroTier", system: "circle.grid.cross", color: .purple) }
                        }
                        if let tail = device.tailscaleHost, !tail.isEmpty {
                            LabeledContent {
                                Text("\(tail):\(device.port)").foregroundStyle(.secondary)
                            } label: { SettingsRowLabel("Tailscale", system: "network.badge.shield.half.filled", color: .indigo) }
                        }
                        if let transport = settings.currentStatus?.transport {
                            LabeledContent("Сейчас", value: transportLabel(transport))
                        }
                    }

                    Button { Task { await test() } } label: {
                        SettingsRowLabel("Проверить соединение", system: "wave.3.right.circle.fill", color: .green)
                    }
                }

                Section("Обои") {
                    wallpaperPreview

                    PhotosPicker(selection: $selectedWallpaper, matching: .images) {
                        SettingsRowLabel("Выбрать из Фото", system: "photo.on.rectangle.angled", color: .blue)
                    }

                    if !settings.wallpaperPath.isEmpty {
                        Button(role: .destructive) {
                            removeWallpaper()
                        } label: {
                            SettingsRowLabel("Вернуть стандартные обои", system: "arrow.counterclockwise", color: .red)
                        }
                    }

                    HStack {
                        SettingsRowLabel("Затемнение", system: "circle.lefthalf.filled", color: .gray)
                        Slider(value: $settings.wallpaperDim, in: 0...0.45, step: 0.01)
                            .frame(maxWidth: 150)
                    }
                }
                .onChange(of: selectedWallpaper) { item in
                    guard let item else { return }
                    Task { await saveWallpaper(item) }
                }

                Section("Главный экран") {
                    Picker(selection: $settings.iconStyleRaw) {
                        Text("Стиль PC Remote").tag("styled")
                        Text("Оригинальные").tag("original")
                    } label: {
                        SettingsRowLabel("Иконки", system: "app.fill", color: .blue)
                    }

                    HStack(alignment: .top, spacing: 12) {
                        Image(systemName: "bolt.fill")
                            .foregroundStyle(.blue)
                            .frame(width: 28)
                        Text("Лёгкий режим Home: 4×6, обычные страницы без тяжёлой Библиотеки программ и live drag-анимаций. Это снижает нагрузку и делает Home заметно плавнее.")
                            .font(.footnote)
                            .foregroundStyle(.secondary)
                    }
                }

                Section("Оформление") {
                    Picker(selection: $settings.appearanceRaw) {
                        ForEach(AppearanceMode.allCases) { mode in
                            Text(mode.title).tag(mode.rawValue)
                        }
                    } label: {
                        SettingsRowLabel("Внешний вид", system: "circle.lefthalf.filled", color: .gray)
                    }

                    Picker(selection: $settings.themeStyleRaw) {
                        ForEach(ThemeStyle.allCases) { theme in
                            Text(theme.title).tag(theme.rawValue)
                        }
                    } label: {
                        SettingsRowLabel("Стандартные обои", system: "paintpalette.fill", color: .purple)
                    }
                }

                Section("Удалённый экран") {
                    Picker(selection: $settings.remoteQualityRaw) {
                        ForEach(RemoteQualityMode.allCases) { mode in
                            Text(mode.title).tag(mode.rawValue)
                        }
                    } label: {
                        SettingsRowLabel("Качество", system: "display", color: .blue)
                    }
                    Text(remoteModeDescription)
                        .font(.footnote)
                        .foregroundStyle(.secondary)
                }

                Section("Пробуждение ПК вне дома") {
                    TextField("Tailscale IP Mi Pad", text: $settings.wolRelayHost)
                        .textInputAutocapitalization(.never)
                        .autocorrectionDisabled()
                    TextField("Порт Relay", text: $settings.wolRelayPortText)
                        .keyboardType(.numberPad)
                    SecureField("Relay token", text: $settings.wolRelayToken)

                    Button { Task { await testRelay() } } label: {
                        SettingsRowLabel("Проверить Mi Pad Relay", system: "antenna.radiowaves.left.and.right", color: .indigo)
                    }
                    Button { Task { await wakeRelay() } } label: {
                        SettingsRowLabel("Разбудить ПК через Mi Pad", system: "power.circle.fill", color: .green)
                    }
                    if !relayText.isEmpty {
                        Text(relayText).font(.footnote).foregroundStyle(.secondary)
                    }
                }

                Section("Питание") {
                    if let device = settings.currentDevice, device.macAddress != nil, device.broadcastAddress != nil {
                        Button {
                            do {
                                try WakeOnLAN.send(device: device)
                                statusText = "Локальный Wake-on-LAN пакет отправлен."
                            } catch { statusText = error.localizedDescription }
                        } label: {
                            SettingsRowLabel("Wake-on-LAN в домашней сети", system: "bolt.horizontal.circle.fill", color: .green)
                        }
                    }
                    Button { Task { await power("lock") } } label: {
                        SettingsRowLabel("Заблокировать Windows", system: "lock.fill", color: .gray)
                    }
                    Button { Task { await power("sleep") } } label: {
                        SettingsRowLabel("Спящий режим", system: "moon.zzz.fill", color: .indigo)
                    }
                    Button(role: .destructive) { Task { await power("restart") } } label: {
                        SettingsRowLabel("Перезагрузить ПК", system: "arrow.clockwise", color: .orange)
                    }
                    Button(role: .destructive) { Task { await power("shutdown") } } label: {
                        SettingsRowLabel("Выключить ПК", system: "power", color: .red)
                    }
                }

                Section("О приложении") {
                    LabeledContent("Версия", value: "5.2.1")
                    LabeledContent("Home Screen", value: "iPhone Style")
                }

                Section {
                    if !statusText.isEmpty {
                        Text(statusText).foregroundStyle(.secondary)
                    }
                    Button(role: .destructive) {
                        settings.disconnect()
                        dismiss()
                    } label: {
                        SettingsRowLabel("Отключиться от ПК", system: "rectangle.portrait.and.arrow.right", color: .red)
                    }
                }
            }
            .navigationTitle("Настройки")
            .navigationBarTitleDisplayMode(.large)
            .toolbar {
                ToolbarItem(placement: .topBarTrailing) {
                    Button("Готово") { dismiss() }.fontWeight(.semibold)
                }
            }
        }
    }

    @ViewBuilder
    private var wallpaperPreview: some View {
        ZStack {
            RoundedRectangle(cornerRadius: 18, style: .continuous)
                .fill(Color.secondary.opacity(0.12))
            if let image = UIImage(contentsOfFile: settings.wallpaperPath), !settings.wallpaperPath.isEmpty {
                Image(uiImage: image)
                    .resizable()
                    .scaledToFill()
            } else {
                LinearGradient(colors: [.cyan, .blue, .indigo], startPoint: .topLeading, endPoint: .bottomTrailing)
            }
        }
        .frame(height: 150)
        .clipShape(RoundedRectangle(cornerRadius: 18, style: .continuous))
        .overlay(RoundedRectangle(cornerRadius: 18).stroke(Color.secondary.opacity(0.16), lineWidth: 1))
    }

    private func transportLabel(_ transport: String) -> String {
        switch transport.lowercased() {
        case "tailscale": return "Tailscale"
        case "zerotier": return "ZeroTier"
        default: return "LAN"
        }
    }

    private var remoteModeDescription: String {
        switch settings.remoteQualityMode {
        case .quality: return "Максимальная чёткость; задержка немного выше."
        case .balanced: return "Баланс качества, плавности и нагрузки."
        case .latency: return "Минимальная задержка с более сильным сжатием."
        }
    }

    @MainActor
    private func power(_ action: String) async {
        guard let client else { return }
        do {
            try await client.powerAction(action)
            statusText = "Команда отправлена."
        } catch { statusText = error.localizedDescription }
    }

    @MainActor
    private func test() async {
        guard let client else { return }
        do {
            let status = try await client.status()
            statusText = "Подключено к \(status.computer) • \(transportLabel(status.transport ?? "lan"))"
        } catch { statusText = error.localizedDescription }
    }

    @MainActor
    private func testRelay() async {
        do {
            let ok = try await APIClient.pingRelay(host: settings.wolRelayHost, port: settings.wolRelayPort)
            relayText = ok ? "Mi Pad Relay доступен." : "Relay не ответил."
        } catch { relayText = error.localizedDescription }
    }

    @MainActor
    private func wakeRelay() async {
        do {
            try await APIClient.wakeViaRelay(host: settings.wolRelayHost, port: settings.wolRelayPort, token: settings.wolRelayToken)
            relayText = "Команда пробуждения отправлена через Mi Pad."
        } catch { relayText = error.localizedDescription }
    }

    @MainActor
    private func saveWallpaper(_ item: PhotosPickerItem) async {
        do {
            guard let data = try await item.loadTransferable(type: Data.self), let image = UIImage(data: data) else { return }
            let root = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask).first!
                .appendingPathComponent("PCRemote", isDirectory: true)
            try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
            let url = root.appendingPathComponent("wallpaper.jpg")
            guard let jpeg = image.jpegData(compressionQuality: 0.92) else { return }
            try jpeg.write(to: url, options: .atomic)
            settings.wallpaperPath = url.path
        } catch {
            statusText = "Не удалось сохранить обои: \(error.localizedDescription)"
        }
    }

    private func removeWallpaper() {
        if !settings.wallpaperPath.isEmpty {
            try? FileManager.default.removeItem(atPath: settings.wallpaperPath)
        }
        settings.wallpaperPath = ""
    }
}

private struct SettingsRowLabel: View {
    let title: String
    let system: String
    let color: Color

    init(_ title: String, system: String, color: Color) {
        self.title = title
        self.system = system
        self.color = color
    }

    var body: some View {
        Label {
            Text(title)
        } icon: {
            RoundedRectangle(cornerRadius: 7, style: .continuous)
                .fill(color)
                .frame(width: 29, height: 29)
                .overlay(Image(systemName: system).font(.system(size: 14, weight: .semibold)).foregroundStyle(.white))
        }
    }
}
