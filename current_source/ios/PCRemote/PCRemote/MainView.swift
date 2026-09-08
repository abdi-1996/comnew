import SwiftUI
import UIKit
import CoreTransferable
import UniformTypeIdentifiers
import AVKit
import PhotosUI

// PC Remote 5.1 uses the lighter Home UI from the stable early builds.
// The Home screen intentionally avoids App Library, live drag/drop, wallpaper blur,
// and other expensive effects so opening/scrolling the launcher stays responsive.
struct MainView: View {
    @EnvironmentObject var settings: ConnectionSettings

    @State private var desktopApps: [RemoteApp] = []
    @State private var allApps: [RemoteApp] = []
    @State private var recentApps: [RemoteApp] = []
    @State private var loading = true
    @State private var error = ""
    @State private var showExplorer = false
    @State private var showSettings = false
    @State private var showStart = false
    @State private var showRemoteScreen = false
    @State private var remoteSession: RemoteScreenModel?
    @State private var showTaskManager = false
    @State private var showComfyUI = false
    @State private var comfyApp: RemoteApp?
    @State private var comfySession: ComfyUIModel?
    @State private var showCorelDRAW = false
    @State private var corelApp: RemoteApp?
    @State private var corelSession: CorelDrawModel?
    @State private var currentPage = 0

    private let appsPerPage = 24

    private var client: APIClient? {
        guard let device = settings.currentDevice else { return nil }
        return APIClient(device: device)
    }

    private var desktopIDs: Set<String> { Set(desktopApps.map(\.id)) }

    private var homeApps: [RemoteApp] {
        let pinned = settings.pinnedIDs(for: settings.currentDevice).compactMap { id in
            allApps.first(where: { $0.id == id })
        }
        return deduplicatedApps(desktopApps + pinned)
    }

    private var homePages: [[RemoteApp]] {
        let apps = homeApps
        guard !apps.isEmpty else { return [[]] }
        return stride(from: 0, to: apps.count, by: appsPerPage).map { start in
            Array(apps[start..<min(start + appsPerPage, apps.count)])
        }
    }

    var body: some View {
        ZStack {
            LightweightDesktopBackground().ignoresSafeArea()

            if loading {
                ProgressView("Загружаем программы…")
                    .tint(.white)
                    .foregroundStyle(.white)
            } else if homeApps.isEmpty {
                VStack(spacing: 12) {
                    Image(systemName: "rectangle.grid.2x2")
                        .font(.system(size: 38, weight: .light))
                    Text("На рабочем столе пока нет программ")
                        .font(.system(size: 15, weight: .semibold))
                }
                .foregroundStyle(.white.opacity(0.82))
            } else {
                TabView(selection: $currentPage) {
                    ForEach(homePages.indices, id: \.self) { index in
                        LightweightHomePage(
                            apps: homePages[index],
                            device: settings.currentDevice,
                            onLaunch: { app in Task { await launch(app) } }
                        )
                        .tag(index)
                    }
                }
                .tabViewStyle(.page(indexDisplayMode: .never))
            }

            topBar

            if showStart {
                StartMenuOverlay(
                    apps: allApps,
                    recentApps: recentApps,
                    desktopIDs: desktopIDs,
                    device: settings.currentDevice,
                    onLaunch: { app in
                        showStart = false
                        Task { await launch(app); await reloadRecents() }
                    },
                    onClose: { showStart = false },
                    onDropToHome: { app in
                        settings.pin(app, for: settings.currentDevice)
                    },
                    onPower: { action in
                        showStart = false
                        Task { await performPower(action) }
                    }
                )
                .environmentObject(settings)
                .transition(.move(edge: .bottom).combined(with: .opacity))
                .zIndex(20)
            }
        }
        .safeAreaInset(edge: .bottom, spacing: 0) {
            if !showStart { lightweightDock }
        }
        .task { await loadApps() }
        .task { await monitorStatusLoop() }
        .fullScreenCover(isPresented: $showExplorer) {
            ExplorerRootsView().environmentObject(settings)
        }
        .sheet(isPresented: $showSettings) {
            SettingsView().environmentObject(settings)
        }
        .fullScreenCover(isPresented: $showTaskManager) {
            if let device = settings.currentDevice { TaskManagerView(device: device) }
        }
        .fullScreenCover(isPresented: $showRemoteScreen) {
            if let remoteSession {
                RemoteScreenView(model: remoteSession)
                    .environmentObject(settings)
            }
        }
        .fullScreenCover(isPresented: $showComfyUI) {
            if let comfySession {
                ComfyUIView(model: comfySession)
            }
        }
        .fullScreenCover(isPresented: $showCorelDRAW) {
            if let corelSession {
                CorelDrawView(model: corelSession)
            }
        }
        .alert("PC Remote", isPresented: Binding(
            get: { !error.isEmpty },
            set: { if !$0 { error = "" } }
        )) {
            Button("OK", role: .cancel) { error = "" }
        } message: {
            Text(error)
        }
        .onChange(of: homePages.count) { count in
            currentPage = min(currentPage, max(0, count - 1))
        }
    }

    private var topBar: some View {
        VStack {
            HStack(spacing: 10) {
                VStack(alignment: .leading, spacing: 2) {
                    Text(settings.currentDevice?.name ?? "PC Remote")
                        .font(.system(size: 19, weight: .bold, design: .rounded))
                    HStack(spacing: 6) {
                        Circle()
                            .fill(settings.currentStatus?.locked == true ? Color.orange : Color.green)
                            .frame(width: 7, height: 7)
                        Text(settings.currentStatus?.locked == true ? "Заблокирован" : "Подключено")
                            .font(.system(size: 11, weight: .semibold))
                            .foregroundStyle(.white.opacity(0.68))
                    }
                }
                .foregroundStyle(.white)

                Spacer()

                Button { showSettings = true } label: {
                    Image(systemName: "gearshape.fill")
                        .font(.system(size: 16, weight: .semibold))
                        .foregroundStyle(.white)
                        .frame(width: 38, height: 38)
                        .background(Color.black.opacity(0.24), in: Circle())
                }
                .buttonStyle(.plain)
            }
            .padding(.horizontal, 17)
            .padding(.top, 5)
            Spacer()
        }
        .zIndex(5)
    }

    private var lightweightDock: some View {
        VStack(spacing: 8) {
            if homePages.count > 1 {
                HStack(spacing: 6) {
                    ForEach(homePages.indices, id: \.self) { index in
                        Circle()
                            .fill(index == currentPage ? Color.white : Color.white.opacity(0.32))
                            .frame(width: 6, height: 6)
                    }
                }
                .frame(height: 8)
            }

            HStack(spacing: 7) {
                LightweightDockButton(system: "square.grid.2x2.fill", label: "Пуск") {
                    showStart = true
                }
                LightweightDockButton(system: "folder.fill", label: "Проводник") {
                    showExplorer = true
                }
                LightweightDockButton(system: "display", label: "Удалённый экран") {
                    if let device = settings.currentDevice {
                        if remoteSession == nil || remoteSession?.device.storageKey != device.storageKey {
                            remoteSession = RemoteScreenModel(device: device, mode: settings.remoteQualityMode)
                        }
                    }
                    showRemoteScreen = true
                }
                LightweightDockButton(system: "chart.bar.xaxis", label: "Диспетчер задач") {
                    showTaskManager = true
                }
            }
            .padding(.horizontal, 10)
            .padding(.vertical, 9)
            .background(Color.black.opacity(0.30), in: RoundedRectangle(cornerRadius: 24, style: .continuous))
            .overlay(RoundedRectangle(cornerRadius: 24, style: .continuous).stroke(Color.white.opacity(0.10), lineWidth: 1))
            .padding(.horizontal, 14)
        }
        .padding(.top, 4)
        .padding(.bottom, 4)
    }

    @MainActor
    private func loadApps() async {
        loading = true
        error = ""
        guard let client else { settings.disconnect(); return }
        do {
            // The Home screen only needs Desktop shortcuts. Show it immediately;
            // Start/Recent data can arrive afterwards without blocking Home.
            desktopApps = deduplicatedApps(try await client.desktopApps())
            loading = false

            Task {
                async let allRequest = client.allApps()
                async let recentRequest = client.recentApps()
                do {
                    let (allResult, recentResult) = try await (allRequest, recentRequest)
                    await MainActor.run {
                        allApps = deduplicatedApps(allResult)
                        recentApps = deduplicatedApps(recentResult)
                    }
                } catch {
                    // Desktop remains usable even if Start discovery temporarily fails.
                }
            }
        } catch {
            self.error = error.localizedDescription
            loading = false
        }
    }

    private func deduplicatedApps(_ apps: [RemoteApp]) -> [RemoteApp] {
        var seen = Set<String>()
        return apps.filter { seen.insert($0.id).inserted }
    }

    private func launch(_ app: RemoteApp) async {
        if app.isComfyUI {
            await MainActor.run {
                comfyApp = app
                if let device = settings.currentDevice {
                    if comfySession == nil || comfySession?.device.storageKey != device.storageKey || comfySession?.app?.id != app.id {
                        comfySession = ComfyUIModel(device: device, app: app)
                    }
                }
                showComfyUI = true
                showStart = false
            }
            return
        }
        guard let client else { return }
        if app.isCorelDRAW {
            do {
                // Corel bridge attaches to an existing CorelDRAW first and launches only when needed.
                try await client.corelLaunch()
                await reloadRecents()
                await MainActor.run {
                    corelApp = app
                    if let device = settings.currentDevice {
                        if corelSession == nil || corelSession?.device.storageKey != device.storageKey || corelSession?.app.id != app.id {
                            corelSession = CorelDrawModel(device: device, app: app)
                        }
                    }
                    showCorelDRAW = true
                    showStart = false
                }
            } catch { await MainActor.run { self.error = error.localizedDescription } }
            return
        }
        do {
            try await client.launch(app: app)
            await reloadRecents()
        } catch { await MainActor.run { self.error = error.localizedDescription } }
    }

    @MainActor
    private func reloadRecents() async {
        guard let client else { return }
        if let result = try? await client.recentApps() { recentApps = deduplicatedApps(result) }
    }

    @MainActor
    private func performPower(_ action: String) async {
        guard let client else { return }
        do { try await client.powerAction(action) }
        catch { self.error = error.localizedDescription }
    }

    private func monitorStatusLoop() async {
        while !Task.isCancelled {
            guard let client else { return }
            if let status = try? await client.status() {
                await MainActor.run { settings.currentStatus = status }
            }
            do { try await Task.sleep(nanoseconds: 5_000_000_000) }
            catch { return }
        }
    }
}

private struct LightweightDesktopBackground: View {
    @AppStorage("custom_wallpaper_path") private var wallpaperPath: String = ""
    @AppStorage("wallpaper_dim") private var wallpaperDim: Double = 0.10
    @AppStorage("theme_style") private var themeStyleRaw: String = ThemeStyle.windowsBlue.rawValue
    @State private var wallpaper: UIImage?

    private var gradient: LinearGradient {
        let style = ThemeStyle(rawValue: themeStyleRaw) ?? .windowsBlue
        switch style {
        case .glass:
            return LinearGradient(colors: [Color(red: 0.08, green: 0.10, blue: 0.22), Color(red: 0.16, green: 0.28, blue: 0.50), Color(red: 0.05, green: 0.08, blue: 0.16)], startPoint: .topLeading, endPoint: .bottomTrailing)
        case .graphite:
            return LinearGradient(colors: [Color(red: 0.16, green: 0.17, blue: 0.20), Color(red: 0.06, green: 0.07, blue: 0.09), Color.black], startPoint: .topLeading, endPoint: .bottomTrailing)
        case .aurora:
            return LinearGradient(colors: [Color(red: 0.03, green: 0.22, blue: 0.24), Color(red: 0.16, green: 0.09, blue: 0.34), Color(red: 0.04, green: 0.07, blue: 0.16)], startPoint: .topLeading, endPoint: .bottomTrailing)
        case .windowsBlue:
            return LinearGradient(colors: [Color(red: 0.035, green: 0.08, blue: 0.16), Color(red: 0.05, green: 0.20, blue: 0.38), Color(red: 0.04, green: 0.10, blue: 0.23)], startPoint: .topLeading, endPoint: .bottomTrailing)
        }
    }

    var body: some View {
        GeometryReader { proxy in
            ZStack {
                gradient

                if let wallpaper {
                    Image(uiImage: wallpaper)
                        .resizable()
                        .scaledToFill()
                        .frame(width: proxy.size.width, height: proxy.size.height)
                        .clipped()
                    Color.black.opacity(max(0, min(0.45, wallpaperDim)))
                }
            }
            .frame(width: proxy.size.width, height: proxy.size.height)
            .clipped()
        }
        .task(id: wallpaperPath) {
            guard !wallpaperPath.isEmpty else {
                wallpaper = nil
                return
            }
            wallpaper = UIImage(contentsOfFile: wallpaperPath)
        }
    }
}

private struct LightweightHomePage: View {
    let apps: [RemoteApp]
    let device: SavedDevice?
    let onLaunch: (RemoteApp) -> Void

    private let columns = Array(repeating: GridItem(.flexible(), spacing: 10), count: 4)

    var body: some View {
        GeometryReader { proxy in
            let top = max(76, proxy.safeAreaInsets.top + 62)
            VStack(spacing: 0) {
                LazyVGrid(columns: columns, spacing: 13) {
                    ForEach(apps) { app in
                        Button { onLaunch(app) } label: {
                            VStack(spacing: 5) {
                                AppGlyphView(app: app, device: device, size: 55)
                                Text(app.displayName)
                                    .font(.system(size: 10.5, weight: .medium))
                                    .foregroundStyle(.white)
                                    .multilineTextAlignment(.center)
                                    .lineLimit(2)
                                    .minimumScaleFactor(0.68)
                                    .frame(height: 27)
                            }
                            .frame(maxWidth: .infinity)
                        }
                        .buttonStyle(.plain)
                    }
                }
                .padding(.horizontal, 13)
                .padding(.top, top)
                Spacer(minLength: 6)
            }
            .frame(width: proxy.size.width, height: proxy.size.height)
        }
    }
}

private struct LightweightDockButton: View {
    let system: String
    let label: String
    let action: () -> Void

    var body: some View {
        Button(action: action) {
            VStack(spacing: 4) {
                Image(systemName: system)
                    .font(.system(size: 21, weight: .semibold))
                    .frame(height: 24)
                Text(label)
                    .font(.system(size: 9.5, weight: .semibold))
                    .lineLimit(1)
                    .minimumScaleFactor(0.68)
            }
            .foregroundStyle(.white)
            .frame(maxWidth: .infinity)
            .padding(.vertical, 5)
        }
        .buttonStyle(.plain)
    }
}

private struct HomePageGrid: View {
    let slots: [String?]
    let pageIndex: Int
    let apps: [String: RemoteApp]
    let device: SavedDevice?
    let isEditing: Bool
    let onLaunch: (RemoteApp) -> Void
    let onBeginDrag: (RemoteApp) -> Void
    let onDropApp: (String, Int) -> Void
    let onRemove: (RemoteApp) -> Void
    let onMovePage: (Int) -> Void

    var body: some View {
        GeometryReader { proxy in
            let horizontalPadding: CGFloat = 13
            let columnSpacing: CGFloat = 10
            let rowSpacing: CGFloat = 5
            let usableWidth = max(0, proxy.size.width - horizontalPadding * 2 - columnSpacing * 3)
            let cellWidth = floor(usableWidth / 4)
            let usableHeight = max(0, proxy.size.height - 16 - rowSpacing * 5)
            let cellHeight = floor(usableHeight / 6)
            let iconSize = min(66, max(48, cellWidth * 0.70))
            let columns = Array(repeating: GridItem(.fixed(cellWidth), spacing: columnSpacing), count: 4)

            ZStack {
                LazyVGrid(columns: columns, alignment: .center, spacing: rowSpacing) {
                    ForEach(0..<24, id: \.self) { slotIndex in
                        HomeSlotView(
                            app: slotIndex < slots.count ? slots[slotIndex].flatMap { apps[$0] } : nil,
                            device: device,
                            cellWidth: cellWidth,
                            cellHeight: cellHeight,
                            iconSize: iconSize,
                            isEditing: isEditing,
                            slotIndex: slotIndex,
                            onLaunch: onLaunch,
                            onBeginDrag: onBeginDrag,
                            onRemove: onRemove
                        )
                        .onDrop(of: [.text], delegate: HomeCellDropDelegate(slotIndex: slotIndex, onDrop: onDropApp))
                    }
                }
                .padding(.horizontal, horizontalPadding)
                .padding(.top, 8)
                .frame(width: proxy.size.width, height: proxy.size.height, alignment: .top)

                if isEditing {
                    HStack(spacing: 0) {
                        Color.clear
                            .frame(width: 34)
                            .contentShape(Rectangle())
                            .onDrop(of: [.text], delegate: HomeEdgeDropDelegate { onMovePage(-1) })
                        Spacer()
                        Color.clear
                            .frame(width: 34)
                            .contentShape(Rectangle())
                            .onDrop(of: [.text], delegate: HomeEdgeDropDelegate { onMovePage(1) })
                    }
                }
            }
        }
    }
}

private struct HomeSlotView: View {
    let app: RemoteApp?
    let device: SavedDevice?
    let cellWidth: CGFloat
    let cellHeight: CGFloat
    let iconSize: CGFloat
    let isEditing: Bool
    let slotIndex: Int
    let onLaunch: (RemoteApp) -> Void
    let onBeginDrag: (RemoteApp) -> Void
    let onRemove: (RemoteApp) -> Void

    @State private var jiggle = false

    var body: some View {
        Group {
            if let app {
                VStack(spacing: 4) {
                        ZStack(alignment: .topLeading) {
                            AppGlyphView(app: app, device: device, size: iconSize)
                            if isEditing {
                                Button { onRemove(app) } label: {
                                    Image(systemName: "minus")
                                        .font(.system(size: 11, weight: .bold))
                                        .foregroundStyle(.black)
                                        .frame(width: 22, height: 22)
                                        .background(Color.white, in: Circle())
                                        .shadow(color: .black.opacity(0.2), radius: 3, y: 1)
                                }
                                .buttonStyle(.plain)
                                .offset(x: -6, y: -6)
                            }
                        }
                        Text(app.displayName)
                            .font(.system(size: 11, weight: .medium))
                            .foregroundStyle(.white)
                            .shadow(color: .black.opacity(0.65), radius: 2, y: 1)
                            .lineLimit(2)
                            .minimumScaleFactor(0.70)
                            .multilineTextAlignment(.center)
                            .frame(width: cellWidth, height: 29)
                    }
                    .frame(width: cellWidth, height: cellHeight)
                    .rotationEffect(isEditing ? .degrees(jiggle ? 1.2 : -1.2) : .zero)
                .contentShape(Rectangle())
                .onTapGesture { if !isEditing { onLaunch(app) } }
                .onLongPressGesture(minimumDuration: 0.42) { onBeginDrag(app) }
                .onDrag {
                    onBeginDrag(app)
                    return NSItemProvider(object: app.id as NSString)
                }
                .onAppear { updateJiggle() }
                .onChange(of: isEditing) { _ in updateJiggle() }
            } else {
                Color.clear.frame(width: cellWidth, height: cellHeight).contentShape(Rectangle())
            }
        }
    }

    private func updateJiggle() {
        guard isEditing else { jiggle = false; return }
        jiggle.toggle()
        withAnimation(.easeInOut(duration: 0.14).repeatForever(autoreverses: true)) { jiggle.toggle() }
    }
}

private struct HomeCellDropDelegate: DropDelegate {
    let slotIndex: Int
    let onDrop: (String, Int) -> Void

    func performDrop(info: DropInfo) -> Bool {
        guard let provider = info.itemProviders(for: [.text]).first else { return false }
        provider.loadObject(ofClass: NSString.self) { object, _ in
            guard let id = object as? NSString else { return }
            DispatchQueue.main.async { onDrop(id as String, slotIndex) }
        }
        return true
    }
}

private struct HomeEdgeDropDelegate: DropDelegate {
    let onEnter: () -> Void
    func dropEntered(info: DropInfo) { DispatchQueue.main.async { onEnter() } }
    func performDrop(info: DropInfo) -> Bool { false }
}

private struct HomeDockButton: View {
    let system: String
    let colors: [Color]
    let label: String
    let action: () -> Void

    var body: some View {
        Button(action: action) {
            RoundedRectangle(cornerRadius: 16, style: .continuous)
                .fill(LinearGradient(colors: colors, startPoint: .topLeading, endPoint: .bottomTrailing))
                .frame(maxWidth: .infinity)
                .aspectRatio(1, contentMode: .fit)
                .overlay(Image(systemName: system).font(.system(size: 25, weight: .semibold)).foregroundStyle(.white))
                .overlay(RoundedRectangle(cornerRadius: 16).stroke(Color.white.opacity(0.15), lineWidth: 1))
                .shadow(color: .black.opacity(0.16), radius: 6, y: 3)
        }
        .buttonStyle(.plain)
        .accessibilityLabel(label)
    }
}

private struct AppLibraryPage: View {
    let apps: [RemoteApp]
    let recentApps: [RemoteApp]
    let device: SavedDevice?
    let onLaunch: (RemoteApp) -> Void
    let onAddToHome: (RemoteApp) -> Void
    let onBeginDrag: (RemoteApp) -> Void
    let onDragBackToHome: () -> Void

    @State private var search = ""

    private var filtered: [RemoteApp] {
        let q = search.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        guard !q.isEmpty else { return apps }
        return apps.filter { $0.searchableText.contains(q) }.sorted { $0.displayName < $1.displayName }
    }

    private var categories: [(String, [RemoteApp])] {
        let suggestions = Array((recentApps + apps).uniquedByID().prefix(8))
        let graphics = apps.filter { app in
            let s = app.searchableText
            return app.isComfyUI || app.isCorelDRAW || s.contains("photo") || s.contains("design") || s.contains("adobe") || s.contains("image")
        }
        let internet = apps.filter { app in
            let s = app.searchableText
            return s.contains("chrome") || s.contains("browser") || s.contains("telegram") || s.contains("discord") || app.icon == "browser" || app.icon == "chat"
        }
        let media = apps.filter { ["music", "video"].contains($0.icon) || $0.searchableText.contains("spotify") }
        let games = apps.filter { $0.icon == "game" || $0.searchableText.contains("steam") }
        let utilities = apps.filter { app in
            let s = app.searchableText
            return s.contains("nvidia") || s.contains("winrar") || s.contains("7-zip") || s.contains("terminal") || app.icon == "settings" || app.icon == "dev"
        }
        return [
            ("Предложения", suggestions),
            ("Недавно добавленные", Array(apps.suffix(8))),
            ("Графика и творчество", graphics),
            ("Интернет", internet),
            ("Медиа", media),
            ("Игры", games),
            ("Утилиты", utilities),
            ("Все программы", apps)
        ].filter { !$0.1.isEmpty }
    }

    var body: some View {
        GeometryReader { proxy in
            ZStack {
                Color.black.opacity(0.12)
                VStack(spacing: 12) {
                    Text("Библиотека программ")
                        .font(.system(size: 28, weight: .bold))
                        .foregroundStyle(.white)
                        .frame(maxWidth: .infinity, alignment: .leading)

                    HStack(spacing: 10) {
                        Image(systemName: "magnifyingglass").foregroundStyle(.white.opacity(0.72))
                        TextField("Поиск", text: $search)
                            .textInputAutocapitalization(.never)
                            .autocorrectionDisabled()
                            .foregroundStyle(.white)
                    }
                    .padding(.horizontal, 14)
                    .frame(height: 42)
                    .background(.ultraThinMaterial, in: RoundedRectangle(cornerRadius: 14, style: .continuous))

                    if search.isEmpty {
                        ScrollView(showsIndicators: false) {
                            LazyVGrid(columns: [GridItem(.flexible(), spacing: 12), GridItem(.flexible(), spacing: 12)], spacing: 12) {
                                ForEach(Array(categories.enumerated()), id: \.offset) { _, category in
                                    LibraryCategoryCard(title: category.0, apps: Array(category.1.prefix(4)), device: device, onLaunch: onLaunch, onAdd: onAddToHome, onBeginDrag: onBeginDrag)
                                }
                            }
                            .padding(.bottom, 18)
                        }
                    } else {
                        ScrollView(showsIndicators: false) {
                            LazyVGrid(columns: Array(repeating: GridItem(.flexible(), spacing: 9), count: 4), spacing: 14) {
                                ForEach(filtered) { app in
                                    LibraryAppIcon(app: app, device: device, onLaunch: onLaunch, onAdd: onAddToHome, onBeginDrag: onBeginDrag)
                                }
                            }
                            .padding(.top, 6)
                            .padding(.bottom, 18)
                        }
                    }
                }
                .padding(.horizontal, 15)
                .padding(.top, 52)

                HStack {
                    Color.clear
                        .frame(width: 36)
                        .contentShape(Rectangle())
                        .onDrop(of: [.text], delegate: HomeEdgeDropDelegate(onEnter: onDragBackToHome))
                    Spacer()
                }
            }
            .frame(width: proxy.size.width, height: proxy.size.height)
        }
    }
}

private struct LibraryCategoryCard: View {
    let title: String
    let apps: [RemoteApp]
    let device: SavedDevice?
    let onLaunch: (RemoteApp) -> Void
    let onAdd: (RemoteApp) -> Void
    let onBeginDrag: (RemoteApp) -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: 9) {
            Text(title)
                .font(.system(size: 14, weight: .bold))
                .foregroundStyle(.white)
                .lineLimit(1)
            LazyVGrid(columns: [GridItem(.flexible()), GridItem(.flexible())], spacing: 9) {
                ForEach(apps) { app in
                    Button { onLaunch(app) } label: {
                        AppGlyphView(app: app, device: device, size: 57)
                    }
                    .buttonStyle(.plain)
                    .onDrag {
                        onBeginDrag(app)
                        return NSItemProvider(object: app.id as NSString)
                    }
                    .contextMenu {
                        Button { onAdd(app) } label: { Label("На экран Домой", systemImage: "plus.square.on.square") }
                        Button { onLaunch(app) } label: { Label("Открыть", systemImage: "play.fill") }
                    }
                }
            }
            Spacer(minLength: 0)
        }
        .padding(12)
        .frame(maxWidth: .infinity, minHeight: 173, alignment: .topLeading)
        .background(.ultraThinMaterial, in: RoundedRectangle(cornerRadius: 24, style: .continuous))
        .overlay(RoundedRectangle(cornerRadius: 24).stroke(Color.white.opacity(0.13), lineWidth: 1))
    }
}

private struct LibraryAppIcon: View {
    let app: RemoteApp
    let device: SavedDevice?
    let onLaunch: (RemoteApp) -> Void
    let onAdd: (RemoteApp) -> Void
    let onBeginDrag: (RemoteApp) -> Void

    var body: some View {
        Button { onLaunch(app) } label: {
            VStack(spacing: 5) {
                AppGlyphView(app: app, device: device, size: 58)
                Text(app.displayName)
                    .font(.system(size: 10.5, weight: .medium))
                    .foregroundStyle(.white)
                    .lineLimit(2)
                    .minimumScaleFactor(0.7)
                    .frame(height: 26)
            }
        }
        .buttonStyle(.plain)
        .onDrag {
            onBeginDrag(app)
            return NSItemProvider(object: app.id as NSString)
        }
        .contextMenu {
            Button { onAdd(app) } label: { Label("На экран Домой", systemImage: "plus.square.on.square") }
            Button { onLaunch(app) } label: { Label("Открыть", systemImage: "play.fill") }
        }
    }
}

private struct TaskManagerView: View {
    @Environment(\.dismiss) private var dismiss
    let device: SavedDevice

    private enum Tab: String, CaseIterable, Identifiable {
        case open = "Открытые"
        case processes = "Все процессы"
        case performance = "Производительность"
        var id: String { rawValue }
    }

    @State private var snapshot: TaskManagerSnapshot?
    @State private var selectedTab: Tab = .open
    @State private var search = ""
    @State private var error = ""
    @State private var pendingTerminate: TaskProcess?

    private var client: APIClient { APIClient(device: device) }

    private var visibleProcesses: [TaskProcess] {
        let q = search.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        guard !q.isEmpty else { return snapshot?.processes ?? [] }
        return (snapshot?.processes ?? []).filter { $0.name.lowercased().contains(q) || String($0.pid).contains(q) }
    }

    private var visibleWindows: [TaskWindow] {
        let values = snapshot?.openWindows ?? []
        let q = search.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        guard !q.isEmpty else { return values }
        return values.filter {
            $0.title.lowercased().contains(q) || $0.processName.lowercased().contains(q) || String($0.pid).contains(q)
        }
    }

    var body: some View {
        NavigationStack {
            VStack(spacing: 0) {
                Picker("Раздел", selection: $selectedTab) {
                    ForEach(Tab.allCases) { tab in Text(tab.rawValue).tag(tab) }
                }
                .pickerStyle(.segmented)
                .padding(.horizontal, 14)
                .padding(.vertical, 10)

                List {
                    if selectedTab == .performance {
                        performanceSection
                    } else if selectedTab == .open {
                        openWindowsSection
                    } else {
                        processesSection
                    }

                    if !error.isEmpty {
                        Section { Text(error).foregroundStyle(.red) }
                    }
                }
                .listStyle(.insetGrouped)
                .scrollDismissesKeyboard(.interactively)
            }
            .searchable(text: $search, prompt: selectedTab == .open ? "Поиск открытого окна" : "Поиск процесса")
            .navigationTitle("Диспетчер задач")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .topBarLeading) { Button("Готово") { dismiss() } }
                ToolbarItem(placement: .topBarTrailing) {
                    Button { Task { await refresh() } } label: { Image(systemName: "arrow.clockwise") }
                }
            }
            .task { await refreshLoop() }
            .alert("Завершить процесс?", isPresented: Binding(
                get: { pendingTerminate != nil },
                set: { if !$0 { pendingTerminate = nil } }
            )) {
                Button("Отмена", role: .cancel) { pendingTerminate = nil }
                Button("Завершить", role: .destructive) {
                    if let process = pendingTerminate { Task { await terminate(process) } }
                    pendingTerminate = nil
                }
            } message: {
                Text(pendingTerminate?.name ?? "")
            }
        }
    }

    @ViewBuilder
    private var openWindowsSection: some View {
        Section("Открытые задачи") {
            if visibleWindows.isEmpty {
                HStack(spacing: 10) {
                    Image(systemName: "macwindow")
                        .foregroundStyle(.secondary)
                    Text("Нет открытых окон")
                        .foregroundStyle(.secondary)
                }
                .padding(.vertical, 8)
            } else {
                ForEach(visibleWindows) { window in
                    HStack(spacing: 12) {
                        RoundedRectangle(cornerRadius: 11, style: .continuous)
                            .fill(window.responding ? Color.blue.opacity(0.13) : Color.orange.opacity(0.15))
                            .frame(width: 42, height: 42)
                            .overlay(Image(systemName: window.responding ? "macwindow" : "exclamationmark.triangle.fill").foregroundStyle(window.responding ? .blue : .orange))

                        VStack(alignment: .leading, spacing: 3) {
                            Text(window.title)
                                .font(.system(size: 14.5, weight: .semibold))
                                .lineLimit(2)
                            Text("\(window.processName) • PID \(window.pid)" + (window.minimized ? " • свёрнуто" : "") + (!window.responding ? " • не отвечает" : ""))
                                .font(.caption2)
                                .foregroundStyle(.secondary)
                                .lineLimit(1)
                        }
                        Spacer(minLength: 4)

                        Menu {
                            Button { Task { await windowAction(window, "focus") } } label: { Label("Переключиться", systemImage: "arrow.up.forward.app") }
                            Button { Task { await windowAction(window, "minimize") } } label: { Label("Свернуть", systemImage: "minus.rectangle") }
                            Button { Task { await windowAction(window, window.maximized ? "restore" : "maximize") } } label: {
                                Label(window.maximized ? "Восстановить" : "Развернуть", systemImage: window.maximized ? "rectangle.compress.vertical" : "rectangle.expand.vertical")
                            }
                            Divider()
                            Button(role: .destructive) { Task { await windowAction(window, "close") } } label: { Label("Закрыть окно", systemImage: "xmark") }
                        } label: {
                            Image(systemName: "ellipsis.circle")
                                .font(.system(size: 19))
                                .foregroundStyle(.secondary)
                        }
                    }
                    .contentShape(Rectangle())
                    .onTapGesture { Task { await windowAction(window, "focus") } }
                    .swipeActions(edge: .trailing, allowsFullSwipe: false) {
                        Button(role: .destructive) { Task { await windowAction(window, "close") } } label: {
                            Label("Закрыть", systemImage: "xmark")
                        }
                    }
                }
            }
        }
    }

    @ViewBuilder
    private var processesSection: some View {
        Section("Все процессы") {
            ForEach(visibleProcesses) { process in
                HStack(spacing: 12) {
                    RoundedRectangle(cornerRadius: 10, style: .continuous)
                        .fill(Color.secondary.opacity(0.10))
                        .frame(width: 40, height: 40)
                        .overlay(Image(systemName: "gearshape.2.fill").foregroundStyle(.blue))
                    VStack(alignment: .leading, spacing: 3) {
                        Text(process.name).font(.system(size: 14.5, weight: .semibold)).lineLimit(1)
                        Text("PID \(process.pid) • CPU \(String(format: "%.1f", process.cpu))% • \(String(format: "%.0f", process.memory_mb)) MB")
                            .font(.caption2)
                            .foregroundStyle(.secondary)
                    }
                    Spacer()
                }
                .swipeActions(edge: .trailing, allowsFullSwipe: false) {
                    Button(role: .destructive) { pendingTerminate = process } label: {
                        Label("Завершить", systemImage: "xmark.circle")
                    }
                }
            }
        }
    }

    @ViewBuilder
    private var performanceSection: some View {
        if let snapshot {
            Section("Система") {
                HStack(spacing: 10) {
                    MetricCard(title: "CPU", value: "\(Int(snapshot.cpu_percent))%", system: "cpu")
                    MetricCard(title: "RAM", value: "\(Int(snapshot.memory_percent))%", system: "memorychip")
                }
                .listRowInsets(EdgeInsets())
                .listRowBackground(Color.clear)

                HStack {
                    Label("Использовано памяти", systemImage: "chart.bar.fill")
                    Spacer()
                    Text(String(format: "%.1f / %.1f GB", snapshot.memory_used_gb, snapshot.memory_total_gb))
                        .foregroundStyle(.secondary)
                }
            }
        } else {
            Section { ProgressView("Загружаем показатели…") }
        }
    }

    @MainActor
    private func refresh() async {
        do { snapshot = try await client.taskManagerSnapshot(); error = "" }
        catch { self.error = error.localizedDescription }
    }

    private func refreshLoop() async {
        while !Task.isCancelled {
            await refresh()
            do { try await Task.sleep(nanoseconds: 1_800_000_000) } catch { return }
        }
    }

    @MainActor
    private func terminate(_ process: TaskProcess) async {
        do { try await client.terminateProcess(pid: process.pid); await refresh() }
        catch { self.error = error.localizedDescription }
    }

    @MainActor
    private func windowAction(_ window: TaskWindow, _ action: String) async {
        do {
            try await client.taskWindowAction(hwnd: window.hwnd, actionName: action)
            try? await Task.sleep(nanoseconds: 180_000_000)
            await refresh()
        } catch {
            self.error = error.localizedDescription
        }
    }
}

private struct MetricCard: View {
    let title: String
    let value: String
    let system: String
    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            Image(systemName: system).foregroundStyle(.blue)
            Text(value).font(.system(size: 15, weight: .bold)).minimumScaleFactor(0.7).lineLimit(1)
            Text(title).font(.caption).foregroundStyle(.secondary)
        }
        .padding(11)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(Color.secondary.opacity(0.08), in: RoundedRectangle(cornerRadius: 14, style: .continuous))
    }
}

private extension Array where Element == RemoteApp {
    func uniquedByID() -> [RemoteApp] {
        var seen = Set<String>()
        return filter { seen.insert($0.id).inserted }
    }
}


private struct StartMenuOverlay: View {
    @EnvironmentObject var settings: ConnectionSettings

    let apps: [RemoteApp]
    let recentApps: [RemoteApp]
    let desktopIDs: Set<String>
    let device: SavedDevice?
    let onLaunch: (RemoteApp) -> Void
    let onClose: () -> Void
    let onDropToHome: (RemoteApp) -> Void
    let onPower: (String) -> Void

    @State private var search = ""
    @State private var showAllApps = false
    @State private var dropTargeted = false
    @State private var showPower = false

    private var filtered: [RemoteApp] {
        let value = search.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        guard !value.isEmpty else { return apps }
        let tokens = value.split(whereSeparator: { $0.isWhitespace }).map(String.init)

        return apps
            .filter { app in
                let haystack = app.searchableText
                return tokens.allSatisfy { token in
                    haystack.localizedCaseInsensitiveContains(token)
                }
            }
            .sorted { lhs, rhs in
                let l = searchRank(lhs, query: value)
                let r = searchRank(rhs, query: value)
                if l != r { return l < r }
                return lhs.displayName.localizedCaseInsensitiveCompare(rhs.displayName) == .orderedAscending
            }
    }

    private func searchRank(_ app: RemoteApp, query: String) -> Int {
        let name = app.displayName.lowercased()
        if name == query { return 0 }
        if name.hasPrefix(query) { return 1 }
        if name.split(separator: " ").contains(where: { $0.hasPrefix(query) }) { return 2 }
        if (app.aliases ?? []).contains(where: { $0.lowercased().hasPrefix(query) }) { return 3 }
        return 4
    }

    private var displayedRecent: [RemoteApp] {
        if search.isEmpty { return Array(recentApps.prefix(8)) }
        return Array(filtered.prefix(12))
    }

    var body: some View {
        GeometryReader { proxy in
            let width = max(1, proxy.size.width)
            let panelWidth = max(0, width - 20)

            ZStack(alignment: .bottom) {
                Color.black.opacity(0.18)
                    .ignoresSafeArea()
                    .onTapGesture { onClose() }

                VStack(spacing: 0) {
                    Capsule()
                        .fill(Color.secondary.opacity(0.42))
                        .frame(width: 42, height: 5)
                        .padding(.top, 9)
                        .padding(.bottom, 12)

                    HStack(spacing: 10) {
                        Image(systemName: "magnifyingglass")
                            .foregroundStyle(.secondary)
                        TextField("Поиск приложений", text: $search)
                            .textInputAutocapitalization(.never)
                            .autocorrectionDisabled()
                    }
                    .padding(.horizontal, 14)
                    .padding(.vertical, 12)
                    .background(Color.secondary.opacity(0.12), in: RoundedRectangle(cornerRadius: 16))
                    .padding(.horizontal, 16)

                    if !showAllApps {
                        HStack {
                            Text(search.isEmpty ? "Недавние" : "Результаты")
                                .font(.system(size: 18, weight: .bold))
                            Spacer()
                            if search.isEmpty {
                                Button("Все приложения") { showAllApps = true }
                                    .font(.system(size: 13, weight: .semibold))
                            }
                        }
                        .padding(.horizontal, 18)
                        .padding(.top, 17)
                        .padding(.bottom, 8)

                        if displayedRecent.isEmpty {
                            VStack(spacing: 8) {
                                Image(systemName: "clock")
                                    .font(.system(size: 26))
                                    .foregroundStyle(.secondary)
                                Text(search.isEmpty ? "Недавно запущенных программ пока нет" : "Ничего не найдено")
                                    .font(.system(size: 13))
                                    .foregroundStyle(.secondary)
                            }
                            .frame(maxWidth: .infinity, minHeight: 120)
                        } else {
                            StartAppsGrid(
                                apps: displayedRecent,
                                device: device,
                                desktopIDs: desktopIDs,
                                onLaunch: onLaunch,
                                onDropToHome: onDropToHome
                            )
                            .environmentObject(settings)
                            .frame(maxHeight: 245)
                        }
                    } else {
                        HStack {
                            Button {
                                showAllApps = false
                            } label: {
                                Label("Назад", systemImage: "chevron.left")
                            }
                            .font(.system(size: 13, weight: .semibold))
                            Spacer()
                            Text("Все приложения")
                                .font(.system(size: 18, weight: .bold))
                        }
                        .padding(.horizontal, 18)
                        .padding(.top, 17)
                        .padding(.bottom, 8)

                        ScrollView(showsIndicators: false) {
                            StartAppsGrid(
                                apps: filtered,
                                device: device,
                                desktopIDs: desktopIDs,
                                onLaunch: onLaunch,
                                onDropToHome: onDropToHome
                            )
                            .environmentObject(settings)
                            .padding(.bottom, 12)
                        }
                    }

                    Spacer(minLength: 8)

                    HStack(spacing: 12) {
                        RoundedRectangle(cornerRadius: 12, style: .continuous)
                            .fill(Color.blue.opacity(0.20))
                            .frame(width: 38, height: 38)
                            .overlay(Image(systemName: "desktopcomputer").foregroundStyle(.blue))

                        Text(device?.name ?? "ПК")
                            .font(.system(size: 14, weight: .semibold))
                            .lineLimit(1)
                        Spacer()

                        Button {
                            showPower = true
                        } label: {
                            Image(systemName: "power")
                                .font(.system(size: 18, weight: .semibold))
                                .frame(width: 42, height: 42)
                                .background(Color.secondary.opacity(0.12), in: Circle())
                        }
                        .buttonStyle(.plain)
                    }
                    .padding(.horizontal, 18)
                    .padding(.vertical, 12)
                    .background(Color.secondary.opacity(0.06))
                }
                .frame(width: panelWidth, height: min(proxy.size.height * 0.72, 610))
                .background(.ultraThickMaterial, in: RoundedRectangle(cornerRadius: 30, style: .continuous))
                .overlay(
                    RoundedRectangle(cornerRadius: 30, style: .continuous)
                        .stroke(Color.white.opacity(0.14), lineWidth: 1)
                )
                .padding(.bottom, 8)

                VStack(spacing: 7) {
                    Image(systemName: dropTargeted ? "plus.circle.fill" : "hand.draw")
                        .font(.system(size: 20, weight: .semibold))
                    Text(dropTargeted ? "Отпустите — программа появится на главном экране" : "Удерживайте иконку и перетащите сюда")
                        .font(.system(size: 12, weight: .semibold))
                        .multilineTextAlignment(.center)
                        .lineLimit(2)
                }
                .foregroundStyle(.white)
                .frame(width: max(0, width - 48), height: 70)
                .background(
                    RoundedRectangle(cornerRadius: 20, style: .continuous)
                        .fill(dropTargeted ? Color.blue.opacity(0.9) : Color.black.opacity(0.32))
                        .overlay(
                            RoundedRectangle(cornerRadius: 20, style: .continuous)
                                .stroke(Color.white.opacity(dropTargeted ? 0.6 : 0.16), lineWidth: 1)
                        )
                )
                .position(x: width / 2, y: 54)
                .dropDestination(for: String.self) { values, _ in
                    guard let id = values.first,
                          let app = apps.first(where: { $0.id == id }) else { return false }
                    onDropToHome(app)
                    return true
                } isTargeted: { targeted in
                    dropTargeted = targeted
                }
            }
            .frame(width: width, height: proxy.size.height)
            .clipped()
            .confirmationDialog("Питание ПК", isPresented: $showPower, titleVisibility: .visible) {
                Button("Заблокировать") { onPower("lock") }
                Button("Спящий режим") { onPower("sleep") }
                Button("Перезагрузить", role: .destructive) { onPower("restart") }
                Button("Выключить", role: .destructive) { onPower("shutdown") }
                Button("Отмена", role: .cancel) { }
            }
        }
    }
}

private struct StartAppsGrid: View {
    @EnvironmentObject var settings: ConnectionSettings
    let apps: [RemoteApp]
    let device: SavedDevice?
    let desktopIDs: Set<String>
    let onLaunch: (RemoteApp) -> Void
    let onDropToHome: (RemoteApp) -> Void

    private let columns = Array(repeating: GridItem(.flexible(), spacing: 8), count: 4)

    var body: some View {
        LazyVGrid(columns: columns, spacing: 12) {
            ForEach(apps) { app in
                Button {
                    onLaunch(app)
                } label: {
                    VStack(spacing: 6) {
                        AppGlyphView(app: app, device: device, size: 52)
                        Text(app.displayName)
                            .font(.system(size: 10.5, weight: .medium))
                            .foregroundStyle(.primary)
                            .multilineTextAlignment(.center)
                            .lineLimit(2)
                            .minimumScaleFactor(0.7)
                            .frame(height: 26)
                    }
                    .frame(maxWidth: .infinity)
                }
                .buttonStyle(.plain)
                .draggable(app.id)
                .contextMenu {
                    Button {
                        onLaunch(app)
                    } label: {
                        Label("Запустить", systemImage: "play.fill")
                    }
                    if !desktopIDs.contains(app.id) {
                        Button {
                            onDropToHome(app)
                        } label: {
                            Label("Добавить на главный экран", systemImage: "plus.circle")
                        }
                    }
                }
            }
        }
        .padding(.horizontal, 12)
    }
}

private struct DockMainButton: View {
    let system: String
    let title: String
    let action: () -> Void

    var body: some View {
        Button(action: action) {
            VStack(spacing: 5) {
                Image(systemName: system)
                    .font(.system(size: 22, weight: .semibold))
                    .foregroundStyle(title == "Проводник" ? Color.yellow : Color.white)
                Text(title)
                    .font(.system(size: 11, weight: .medium))
                    .foregroundStyle(.white)
                    .lineLimit(1)
                    .minimumScaleFactor(0.70)
            }
            .frame(maxWidth: .infinity)
            .padding(.vertical, 8)
        }
        .buttonStyle(.plain)
    }
}

// MARK: - Remote screen

private final class RemoteScreenModel: ObservableObject {
    let device: SavedDevice
    @Published var image: UIImage?
    @Published var info: RemoteScreenInfo?
    @Published var errorMessage: String = ""
    @Published var mode: RemoteQualityMode
    @Published var isReceiving = false

    private let client: APIClient
    private var loopTask: Task<Void, Never>?

    init(device: SavedDevice, mode: RemoteQualityMode) {
        self.device = device
        self.client = APIClient(device: device)
        self.mode = mode
    }

    func start() {
        guard loopTask == nil else { return }
        loopTask = Task { [weak self] in
            guard let self else { return }
            do {
                let info = try await self.client.remoteInfo()
                await MainActor.run {
                    self.info = info
                    self.errorMessage = ""
                }
            } catch {
                await MainActor.run { self.errorMessage = error.localizedDescription }
            }

            while !Task.isCancelled {
                let currentMode = self.mode
                do {
                    let data = try await self.client.remoteFrame(mode: currentMode)
                    if let image = UIImage(data: data) {
                        await MainActor.run {
                            self.image = image
                            self.isReceiving = true
                            self.errorMessage = ""
                        }
                    }
                } catch {
                    await MainActor.run {
                        self.isReceiving = false
                        self.errorMessage = error.localizedDescription
                    }
                }

                do {
                    try await Task.sleep(nanoseconds: currentMode.intervalNanoseconds)
                } catch {
                    break
                }
            }
        }
    }

    func stop() {
        loopTask?.cancel()
        loopTask = nil
    }

    deinit { loopTask?.cancel() }
}

private struct RemoteScreenView: View {
    @EnvironmentObject var settings: ConnectionSettings
    @Environment(\.dismiss) private var dismiss

    @ObservedObject var model: RemoteScreenModel
    @State private var keyboardActive = false

    init(model: RemoteScreenModel) {
        self.model = model
    }

    private var device: SavedDevice { model.device }
    private var client: APIClient { APIClient(device: device) }

    var body: some View {
        NavigationStack {
            ZStack {
                Color.black.ignoresSafeArea()

                VStack(spacing: 0) {
                    Picker("Качество", selection: modeBinding) {
                        ForEach(RemoteQualityMode.allCases) { mode in
                            Text(mode.shortTitle).tag(mode)
                        }
                    }
                    .pickerStyle(.segmented)
                    .padding(.horizontal, 12)
                    .padding(.vertical, 7)

                    ZStack {
                        if let image = model.image {
                            RemoteDisplaySurface(
                                image: image,
                                info: model.info,
                                device: device,
                                requestKeyboard: {
                                    keyboardActive = true
                                }
                            )
                        } else {
                            VStack(spacing: 12) {
                                ProgressView().tint(.white)
                                Text("Подключаем трансляцию...")
                                    .foregroundStyle(.white.opacity(0.75))
                            }
                        }

                        if !model.errorMessage.isEmpty {
                            VStack {
                                Spacer()
                                Text(model.errorMessage)
                                    .font(.footnote)
                                    .foregroundStyle(.white)
                                    .padding(.horizontal, 14)
                                    .padding(.vertical, 10)
                                    .background(Color.red.opacity(0.78), in: Capsule())
                                    .padding(.bottom, 10)
                            }
                        }
                    }
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
                    .clipped()

                    HStack(spacing: 8) {
                        Label("Тап", systemImage: "hand.tap")
                        Text("•")
                        Text("свайп — как касание Windows")
                        Spacer(minLength: 4)
                        Button {
                            keyboardActive.toggle()
                        } label: {
                            Image(systemName: keyboardActive ? "keyboard.chevron.compact.down" : "keyboard")
                                .font(.system(size: 18, weight: .semibold))
                                .frame(width: 40, height: 34)
                                .background(Color.white.opacity(0.10), in: RoundedRectangle(cornerRadius: 10))
                        }
                        .buttonStyle(.plain)
                    }
                    .font(.system(size: 11.5, weight: .medium))
                    .foregroundStyle(.white.opacity(0.72))
                    .padding(.horizontal, 12)
                    .padding(.vertical, 6)
                }

                RemoteKeyboardBridge(
                    active: $keyboardActive,
                    onText: { text in
                        Task { try? await client.remoteText(text) }
                    },
                    onBackspace: {
                        Task { try? await client.remoteKey("backspace") }
                    },
                    onReturn: {
                        Task { try? await client.remoteKey("enter") }
                    },
                    onDismiss: {
                        keyboardActive = false
                    }
                )
                .frame(width: 1, height: 1)
                .opacity(0.01)
                .allowsHitTesting(false)
            }
            .navigationTitle("Удалённый экран")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .navigationBarLeading) {
                    Button {
                        keyboardActive = false
                        dismiss()
                    } label: {
                        Label("Назад", systemImage: "chevron.left")
                    }
                }

                ToolbarItem(placement: .navigationBarTrailing) {
                    Menu {
                        Button {
                            Task { try? await client.remoteKey("esc") }
                        } label: {
                            Label("Esc", systemImage: "escape")
                        }
                        Button {
                            Task { try? await client.remoteKey("tab") }
                        } label: {
                            Label("Tab", systemImage: "arrow.right.to.line")
                        }
                        Button {
                            Task { try? await client.remoteKey("win") }
                        } label: {
                            Label("Win", systemImage: "square.grid.2x2")
                        }
                    } label: {
                        Image(systemName: "ellipsis.circle")
                    }
                }
            }
        }
        .task { model.start() }
        .onDisappear { model.stop() }
    }

    private var modeBinding: Binding<RemoteQualityMode> {
        Binding(
            get: { model.mode },
            set: { newMode in
                model.mode = newMode
                settings.remoteQualityRaw = newMode.rawValue
            }
        )
    }
}

private struct RemoteDisplaySurface: View {
    let image: UIImage
    let info: RemoteScreenInfo?
    let device: SavedDevice
    let requestKeyboard: () -> Void

    @State private var lastTouchLocation: CGPoint = .zero
    @State private var dragStartedAt: Date?
    @State private var longPressTriggered = false

    private var client: APIClient { APIClient(device: device) }

    var body: some View {
        GeometryReader { proxy in
            let rect = fittedRect(in: proxy.size)

            ZStack {
                Color.black

                Image(uiImage: image)
                    .resizable()
                    .interpolation(.medium)
                    .frame(width: rect.width, height: rect.height)
                    .position(x: rect.midX, y: rect.midY)

                Rectangle()
                    .fill(Color.clear)
                    .contentShape(Rectangle())
                    .frame(width: rect.width, height: rect.height)
                    .position(x: rect.midX, y: rect.midY)
                    .gesture(
                        DragGesture(minimumDistance: 0, coordinateSpace: .local)
                            .onChanged { value in
                                lastTouchLocation = value.location
                                if dragStartedAt == nil { dragStartedAt = Date() }
                            }
                            .onEnded { value in
                                defer {
                                    dragStartedAt = nil
                                    longPressTriggered = false
                                }
                                if longPressTriggered { return }

                                let start = normalized(value.startLocation, size: rect.size)
                                let end = normalized(value.location, size: rect.size)
                                let distance = hypot(value.translation.width, value.translation.height)
                                let duration = min(1.2, max(0.08, Date().timeIntervalSince(dragStartedAt ?? Date())))

                                if distance < 12 {
                                    sendTouch(kind: "tap", start: end, end: nil, duration: 0.04, checkTextFocus: true)
                                } else {
                                    sendTouch(kind: "swipe", start: start, end: end, duration: duration, checkTextFocus: false)
                                }
                            }
                    )
                    .simultaneousGesture(
                        LongPressGesture(minimumDuration: 0.58, maximumDistance: 14)
                            .onEnded { _ in
                                longPressTriggered = true
                                let point = normalized(lastTouchLocation, size: rect.size)
                                sendTouch(kind: "long", start: point, end: nil, duration: 0.65, checkTextFocus: false)
                            }
                    )
            }
            .frame(width: proxy.size.width, height: proxy.size.height)
            .clipped()
        }
    }

    private func fittedRect(in size: CGSize) -> CGRect {
        let sourceWidth = CGFloat(info?.width ?? Int(image.size.width))
        let sourceHeight = CGFloat(info?.height ?? Int(image.size.height))
        guard sourceWidth > 0, sourceHeight > 0, size.width > 0, size.height > 0 else {
            return CGRect(origin: .zero, size: size)
        }

        let scale = min(size.width / sourceWidth, size.height / sourceHeight)
        let width = sourceWidth * scale
        let height = sourceHeight * scale
        return CGRect(
            x: (size.width - width) / 2,
            y: (size.height - height) / 2,
            width: width,
            height: height
        )
    }

    private func normalized(_ point: CGPoint, size: CGSize) -> CGPoint {
        guard size.width > 0, size.height > 0 else { return CGPoint(x: 0.5, y: 0.5) }
        return CGPoint(
            x: max(0, min(1, point.x / size.width)),
            y: max(0, min(1, point.y / size.height))
        )
    }

    private func sendTouch(kind: String, start: CGPoint, end: CGPoint?, duration: Double, checkTextFocus: Bool) {
        Task {
            try? await client.remoteTouch(
                kind: kind,
                x1: Double(start.x),
                y1: Double(start.y),
                x2: end.map { Double($0.x) },
                y2: end.map { Double($0.y) },
                duration: duration
            )

            if checkTextFocus {
                try? await Task.sleep(nanoseconds: 160_000_000)
                if let focus = try? await client.remoteFocusInfo(), focus.text_input {
                    await MainActor.run { requestKeyboard() }
                }
            }
        }
    }
}

private struct RemoteKeyboardBridge: UIViewRepresentable {
    @Binding var active: Bool
    let onText: (String) -> Void
    let onBackspace: () -> Void
    let onReturn: () -> Void
    let onDismiss: () -> Void

    func makeCoordinator() -> Coordinator {
        Coordinator(onText: onText, onBackspace: onBackspace, onReturn: onReturn, onDismiss: onDismiss)
    }

    func makeUIView(context: Context) -> InstantRemoteTextField {
        let field = InstantRemoteTextField(frame: .zero)
        field.delegate = context.coordinator
        field.onInsertText = context.coordinator.onText
        field.onDeleteBackward = context.coordinator.onBackspace
        field.onReturn = context.coordinator.onReturn
        field.autocorrectionType = .no
        field.spellCheckingType = .no
        field.smartQuotesType = .no
        field.smartDashesType = .no
        field.smartInsertDeleteType = .no
        field.textContentType = nil
        field.returnKeyType = .done
        field.keyboardType = .default
        field.backgroundColor = .clear
        field.textColor = .clear
        field.tintColor = .clear
        field.accessibilityLabel = "Клавиатура удалённого ПК"
        let toolbar = UIToolbar()
        toolbar.sizeToFit()
        let spacer = UIBarButtonItem(systemItem: .flexibleSpace)
        let done = UIBarButtonItem(title: "Готово", style: .done, target: context.coordinator, action: #selector(Coordinator.donePressed))
        toolbar.items = [spacer, done]
        field.inputAccessoryView = toolbar
        context.coordinator.field = field
        return field
    }

    func updateUIView(_ uiView: InstantRemoteTextField, context: Context) {
        uiView.onInsertText = onText
        uiView.onDeleteBackward = onBackspace
        uiView.onReturn = onReturn
        context.coordinator.onText = onText
        context.coordinator.onBackspace = onBackspace
        context.coordinator.onReturn = onReturn
        context.coordinator.onDismiss = onDismiss

        if active && !uiView.isFirstResponder {
            DispatchQueue.main.async { uiView.becomeFirstResponder() }
        } else if !active && uiView.isFirstResponder {
            DispatchQueue.main.async { uiView.resignFirstResponder() }
        }
    }

    final class Coordinator: NSObject, UITextFieldDelegate {
        var onText: (String) -> Void
        var onBackspace: () -> Void
        var onReturn: () -> Void
        var onDismiss: () -> Void
        weak var field: UITextField?

        init(onText: @escaping (String) -> Void, onBackspace: @escaping () -> Void, onReturn: @escaping () -> Void, onDismiss: @escaping () -> Void) {
            self.onText = onText
            self.onBackspace = onBackspace
            self.onReturn = onReturn
            self.onDismiss = onDismiss
        }

        @objc func donePressed() {
            field?.resignFirstResponder()
            onDismiss()
        }

        func textFieldDidEndEditing(_ textField: UITextField) {
            onDismiss()
        }

        func textFieldShouldReturn(_ textField: UITextField) -> Bool {
            onReturn()
            return false
        }
    }
}

private final class InstantRemoteTextField: UITextField {
    var onInsertText: ((String) -> Void)?
    var onDeleteBackward: (() -> Void)?
    var onReturn: (() -> Void)?

    override func insertText(_ text: String) {
        if text == "\n" {
            onReturn?()
        } else if !text.isEmpty {
            onInsertText?(text)
        }
        self.text = ""
    }

    override func deleteBackward() {
        onDeleteBackward?()
        self.text = ""
    }
}

// MARK: - ComfyUI native module

@MainActor
private enum ComfyAdvancedDraftStore {
    private static var drafts: [String: [String: ComfyNodeInfo]] = [:]

    static func stage(workflowID: String, node: ComfyNodeInfo) {
        var workflow = drafts[workflowID] ?? [:]
        workflow[node.id] = node
        drafts[workflowID] = workflow
    }

    static func stagedNodes(workflowID: String) -> [ComfyNodeInfo] {
        Array((drafts[workflowID] ?? [:]).values)
    }

    static func synchronizeSeed(workflowID: String, seed: Int64) {
        guard var workflow = drafts[workflowID] else { return }
        for (id, var node) in workflow {
            var changed = false
            for idx in node.inputs.indices where !node.inputs[idx].isConnection {
                let name = node.inputs[idx].name.lowercased()
                if name == "seed" || name == "noise_seed" {
                    node.inputs[idx].value = String(seed)
                    changed = true
                }
            }
            if changed { workflow[id] = node }
        }
        drafts[workflowID] = workflow
    }

    static func clear(workflowID: String) {
        drafts.removeValue(forKey: workflowID)
    }
}

@MainActor
final class ComfyUIModel: ObservableObject {
    @Published var dashboard: ComfyDashboardResponse?
    @Published var parameters = ComfyParameters(
        positive: "", negative: "", steps: 20, cfg: 7.0, seed: 0,
        sampler: "", scheduler: "", width: 512, height: 512,
        checkpoint: "", lora: "", vae: ""
    )
    @Published var selectedWorkflowID = ""
    @Published var errorMessage = ""
    @Published var busy = false
    @Published var savedMessage = ""
    @Published var workflowDetails: ComfyWorkflowDetailsResponse?
    @Published var selectedOutputNodeID = ""
    @Published var generateOnlySelectedOutput = false

    let device: SavedDevice
    @Published var app: RemoteApp?
    private let client: APIClient
    private var pollTask: Task<Void, Never>?
    private var positivePromptNodeIDs = Set<String>()
    private var negativePromptNodeIDs = Set<String>()
    private var promptSyncTask: Task<Void, Never>?

    init(device: SavedDevice, app: RemoteApp? = nil) {
        self.device = device
        self.app = app
        self.client = APIClient(device: device)
    }

    var available: Bool { dashboard?.available == true }
    var running: Bool { dashboard?.running == true }
    var workflows: [ComfyWorkflow] { dashboard?.workflows ?? [] }
    var images: [ComfyImageItem] { dashboard?.images ?? [] }

    var selectedWorkflow: ComfyWorkflow? {
        workflows.first(where: { $0.id == selectedWorkflowID })
    }

    private func isAudioInputNode(_ node: ComfyNodeInfo) -> Bool {
        let className = node.classType.lowercased().replacingOccurrences(of: "_", with: "")
        let title = node.title.lowercased().replacingOccurrences(of: "_", with: "")
        if className.contains("audio") || className.contains("sound") || title.contains("audio") || title.contains("sound") { return true }
        let scalarNames = Set(node.inputs.filter { !$0.isConnection }.map { $0.name.lowercased() })
        let audioNames = ["audio", "audio_file", "input_audio", "source_audio", "sound", "sound_file", "wav", "wave"]
        return audioNames.contains(where: { scalarNames.contains($0) })
    }

    private func isVideoInputNode(_ node: ComfyNodeInfo) -> Bool {
        guard !isAudioInputNode(node) else { return false }
        let className = node.classType.lowercased().replacingOccurrences(of: "_", with: "")
        let title = node.title.lowercased().replacingOccurrences(of: "_", with: "")
        if className.contains("video") || title.contains("video") { return true }
        let scalarNames = Set(node.inputs.filter { !$0.isConnection }.map { $0.name.lowercased() })
        let videoNames = ["video", "video_file", "input_video", "source_video", "video_path", "movie", "movie_file"]
        return videoNames.contains(where: { scalarNames.contains($0) })
    }

    private func isImageInputNode(_ node: ComfyNodeInfo) -> Bool {
        guard !isAudioInputNode(node), !isVideoInputNode(node) else { return false }
        let className = node.classType.lowercased().replacingOccurrences(of: "_", with: "")
        let title = node.title.lowercased().replacingOccurrences(of: "_", with: "")
        if className.contains("loadimage") || className.contains("imageinput") || title.contains("loadimage") { return true }
        let scalarNames = Set(node.inputs.filter { !$0.isConnection }.map { $0.name.lowercased() })
        let imageNames = ["image", "input_image", "start_image", "first_frame", "init_image", "source_image"]
        return imageNames.contains(where: { scalarNames.contains($0) }) && (className.contains("load") || className.contains("input"))
    }

    var audioInputNodes: [ComfyNodeInfo] {
        guard workflowDetails?.workflowID == selectedWorkflowID else { return [] }
        return (workflowDetails?.nodes ?? []).filter(isAudioInputNode)
    }

    var videoInputNodes: [ComfyNodeInfo] {
        guard workflowDetails?.workflowID == selectedWorkflowID else { return [] }
        return (workflowDetails?.nodes ?? []).filter(isVideoInputNode)
    }

    var imageInputNodes: [ComfyNodeInfo] {
        guard workflowDetails?.workflowID == selectedWorkflowID else { return [] }
        return (workflowDetails?.nodes ?? []).filter(isImageInputNode)
    }

    private func isOutputNode(_ node: ComfyNodeInfo) -> Bool {
        let identity = (node.classType + " " + node.title).lowercased().replacingOccurrences(of: "_", with: "")
        if identity.contains("saveimage") || identity.contains("previewimage") || identity.contains("savevideo") || identity.contains("saveanimated") || identity.contains("videocombine") || identity.contains("saveaudio") || identity.contains("previewaudio") || identity.contains("audiooutput") { return true }
        if identity.contains("save") && (identity.contains("image") || identity.contains("video") || identity.contains("audio") || identity.contains("sound") || identity.contains("wav") || identity.contains("mp3") || identity.contains("flac") || identity.contains("ogg") || identity.contains("webp") || identity.contains("gif") || identity.contains("mp4")) { return true }
        return false
    }

    var outputNodes: [ComfyNodeInfo] {
        guard workflowDetails?.workflowID == selectedWorkflowID else { return [] }
        return (workflowDetails?.nodes ?? []).filter(isOutputNode)
    }

    var selectedOutputNode: ComfyNodeInfo? {
        outputNodes.first(where: { $0.id == selectedOutputNodeID })
    }

    func outputNodeDisplayName(_ node: ComfyNodeInfo) -> String {
        let title = node.title.trimmingCharacters(in: .whitespacesAndNewlines)
        let base = title.isEmpty ? node.classType : title
        return "\(base) (#\(node.id))"
    }

    private func outputSelectionKey(for workflowID: String) -> String {
        "comfy.output.selection.\(device.storageKey).\(workflowID)"
    }

    private func outputOnlyKey(for workflowID: String) -> String {
        "comfy.output.only.\(device.storageKey).\(workflowID)"
    }

    func selectOutputNode(_ nodeID: String) {
        selectedOutputNodeID = nodeID
        guard !selectedWorkflowID.isEmpty else { return }
        UserDefaults.standard.set(nodeID, forKey: outputSelectionKey(for: selectedWorkflowID))
    }

    func setGenerateOnlySelectedOutput(_ enabled: Bool) {
        generateOnlySelectedOutput = enabled
        guard !selectedWorkflowID.isEmpty else { return }
        UserDefaults.standard.set(enabled, forKey: outputOnlyKey(for: selectedWorkflowID))
    }

    func schedulePromptSync() {
        guard available, !selectedWorkflowID.isEmpty else { return }
        promptSyncTask?.cancel()
        let workflowID = selectedWorkflowID
        let positive = parameters.positive
        let negative = parameters.negative
        promptSyncTask = Task { [weak self] in
            do {
                try await Task.sleep(nanoseconds: 450_000_000)
                guard !Task.isCancelled, let self else { return }
                try await self.client.comfySetMainPrompts(
                    workflowID: workflowID,
                    positive: positive,
                    negative: negative
                )
                if self.selectedWorkflowID == workflowID {
                    await self.loadWorkflowDetails()
                }
            } catch is CancellationError {
                return
            } catch {
                guard !Task.isCancelled else { return }
                self?.errorMessage = error.localizedDescription
            }
        }
    }

    var currentNodeDisplayName: String {
        guard let nodeID = dashboard?.currentNode, !nodeID.isEmpty else { return "" }
        if let node = workflowDetails?.nodes.first(where: { $0.id == nodeID }) {
            let title = node.title.trimmingCharacters(in: .whitespacesAndNewlines)
            return title.isEmpty ? "\(node.classType) #\(nodeID)" : "\(title) #\(nodeID)"
        }
        return "Node #\(nodeID)"
    }

    var generationStageTitle: String {
        if !available { return "Offline" }
        switch dashboard?.generationStage ?? (running ? "executing" : "idle") {
        case "queued": return "Queued"
        case "starting": return "Starting…"
        case "sampling": return "Sampling…"
        case "executing": return "Executing…"
        case "saving": return "Saving…"
        case "complete": return "Complete"
        case "stopped": return "Stopped"
        case "error": return "Error"
        case "offline": return "Offline"
        default: return (dashboard?.queueRemaining ?? 0) > 0 ? "Queued" : "Ready"
        }
    }

    var generationElapsedText: String {
        guard let started = dashboard?.startedAt, started > 0 else { return "" }
        let end = dashboard?.finishedAt ?? Date().timeIntervalSince1970
        let total = max(0, Int(end - started))
        if total >= 3600 { return String(format: "%d:%02d:%02d", total / 3600, (total / 60) % 60, total % 60) }
        return String(format: "%d:%02d", total / 60, total % 60)
    }

    func start() {
        guard pollTask == nil else { return }
        let needsInitialParameters = dashboard == nil
        pollTask = Task { [weak self] in
            guard let self else { return }
            await self.refresh(loadParameters: needsInitialParameters)
            while !Task.isCancelled {
                // Dedicated Comfy Remote stays light while idle. During generation
                // it refreshes quickly enough for progress, otherwise it avoids
                // hammering the PC server and ComfyUI with full dashboard requests.
                let interval: UInt64
                if self.running { interval = 900_000_000 }
                else if self.available { interval = 2_500_000_000 }
                else { interval = 3_500_000_000 }
                do { try await Task.sleep(nanoseconds: interval) }
                catch { return }
                await self.refresh(loadParameters: false)
            }
        }
    }

    func stop() {
        pollTask?.cancel()
        pollTask = nil
    }

    func refresh(loadParameters: Bool) async {
        do {
            let requested = selectedWorkflowID.isEmpty ? nil : selectedWorkflowID
            let value = try await client.comfyDashboard(workflowID: requested)
            let oldSelection = selectedWorkflowID
            dashboard = value
            errorMessage = value.error ?? ""

            if selectedWorkflowID.isEmpty, let selected = value.selectedWorkflow {
                selectedWorkflowID = selected
            }

            if loadParameters || (oldSelection.isEmpty && !selectedWorkflowID.isEmpty) {
                parameters = value.parameters
            }
            if !selectedWorkflowID.isEmpty, workflowDetails?.workflowID != selectedWorkflowID {
                await loadWorkflowDetails()
            }
        } catch {
            errorMessage = error.localizedDescription
        }
    }

    func selectWorkflow(_ workflow: ComfyWorkflow) async {
        promptSyncTask?.cancel()
        selectedWorkflowID = workflow.id
        workflowDetails = nil
        await refresh(loadParameters: true)
        await loadWorkflowDetails()
    }

    func loadWorkflowDetails() async {
        guard !selectedWorkflowID.isEmpty else {
            workflowDetails = nil
            positivePromptNodeIDs.removeAll()
            negativePromptNodeIDs.removeAll()
            return
        }
        do {
            let details = try await client.comfyWorkflowDetails(workflowID: selectedWorkflowID)
            workflowDetails = details
            resolveMainPromptBindings(in: details)
            if !outputNodes.isEmpty {
                let savedOutput = UserDefaults.standard.string(forKey: outputSelectionKey(for: selectedWorkflowID)) ?? ""
                if !savedOutput.isEmpty, outputNodes.contains(where: { $0.id == savedOutput }) {
                    selectedOutputNodeID = savedOutput
                } else if selectedOutputNodeID.isEmpty || !outputNodes.contains(where: { $0.id == selectedOutputNodeID }) {
                    selectedOutputNodeID = outputNodes.first?.id ?? ""
                }
                if UserDefaults.standard.object(forKey: outputOnlyKey(for: selectedWorkflowID)) != nil {
                    generateOnlySelectedOutput = UserDefaults.standard.bool(forKey: outputOnlyKey(for: selectedWorkflowID))
                }
            } else {
                selectedOutputNodeID = ""
                generateOnlySelectedOutput = false
            }
        } catch {
            errorMessage = error.localizedDescription
        }
    }

    private func normalizedPrompt(_ value: String) -> String {
        value.trimmingCharacters(in: .whitespacesAndNewlines)
    }

    private func isPromptTextInput(_ input: ComfyNodeInput) -> Bool {
        guard !input.isConnection else { return false }
        let name = input.name.lowercased()
        let known = Set([
            "text", "prompt", "positive", "negative", "caption", "description", "instruction",
            "text_g", "text_l", "prompt_text", "text_prompt", "positive_prompt", "negative_prompt",
            "positive_text", "negative_text", "text_positive", "text_negative"
        ])
        let looksTextual = input.valueType == "string" || input.valueType == "json" || input.inputType.uppercased() == "STRING"
        return known.contains(name) && looksTextual
    }

    private func isPromptTextNode(_ node: ComfyNodeInfo) -> Bool {
        let identity = (node.classType + " " + node.title).lowercased()
        let looksLikeEncoder = identity.contains("clip") || identity.contains("text") || identity.contains("encode") || identity.contains("prompt") || identity.contains("conditioning")
        let hasPromptInput = node.inputs.contains(where: isPromptTextInput)
        return hasPromptInput && (looksLikeEncoder || node.inputs.contains { ["prompt", "positive", "negative", "positive_prompt", "negative_prompt"].contains($0.name.lowercased()) })
    }

    private func upstreamNodeIDs(from startIDs: Set<String>, details: ComfyWorkflowDetailsResponse) -> Set<String> {
        var result = startIDs
        var queue = Array(startIDs)
        while let current = queue.first {
            queue.removeFirst()
            for connection in details.connections where connection.to == current {
                if result.insert(connection.from).inserted {
                    queue.append(connection.from)
                }
            }
        }
        return result
    }

    private func resolveMainPromptBindings(in details: ComfyWorkflowDetailsResponse) {
        let positiveStarts = Set(details.connections.compactMap { connection -> String? in
            let input = (connection.inputName ?? connection.label ?? "").lowercased()
            return input.contains("positive") ? connection.from : nil
        })
        let negativeStarts = Set(details.connections.compactMap { connection -> String? in
            let input = (connection.inputName ?? connection.label ?? "").lowercased()
            return input.contains("negative") ? connection.from : nil
        })

        var positive = upstreamNodeIDs(from: positiveStarts, details: details)
        var negative = upstreamNodeIDs(from: negativeStarts, details: details)
        let loadedPositive = normalizedPrompt(parameters.positive)
        let loadedNegative = normalizedPrompt(parameters.negative)

        for node in details.nodes where isPromptTextNode(node) {
            let identity = (node.title + " " + node.classType).lowercased()
            if identity.contains("negative") { negative.insert(node.id) }
            if identity.contains("positive") { positive.insert(node.id) }

            let scalarTexts = node.inputs.filter(isPromptTextInput).map { normalizedPrompt($0.value) }.filter { !$0.isEmpty }
            if !loadedNegative.isEmpty, scalarTexts.contains(loadedNegative) { negative.insert(node.id) }
            if !loadedPositive.isEmpty, scalarTexts.contains(loadedPositive) { positive.insert(node.id) }
        }

        // SamplerCustom + BasicGuider workflows often have only a generic
        // "conditioning" connection and no field literally named "positive".
        // In that case every prompt encoder that is not known-negative is the
        // main positive prompt target.
        if positive.isEmpty {
            for node in details.nodes where isPromptTextNode(node) && !negative.contains(node.id) {
                positive.insert(node.id)
            }
        }

        positive.subtract(negative)
        positivePromptNodeIDs = positive
        negativePromptNodeIDs = negative
    }

    private func synchronizeMainScreenIntoWorkflow() async throws {
        guard !selectedWorkflowID.isEmpty else { return }
        let details: ComfyWorkflowDetailsResponse
        if let current = workflowDetails, current.workflowID == selectedWorkflowID {
            details = current
        } else {
            details = try await client.comfyWorkflowDetails(workflowID: selectedWorkflowID)
            workflowDetails = details
            resolveMainPromptBindings(in: details)
        }

        // Resolve again in case a workflow was edited since the last refresh.
        if positivePromptNodeIDs.isEmpty && negativePromptNodeIDs.isEmpty {
            resolveMainPromptBindings(in: details)
        }

        let positiveText = parameters.positive
        let negativeText = parameters.negative
        let seedText = String(parameters.seed)

        for original in details.nodes {
            var node = original
            var changed = false
            let nodeIsPositive = positivePromptNodeIDs.contains(node.id)
            let nodeIsNegative = negativePromptNodeIDs.contains(node.id)

            for index in node.inputs.indices where !node.inputs[index].isConnection {
                let inputName = node.inputs[index].name.lowercased()

                if isPromptTextInput(node.inputs[index]) {
                    let replacement: String?
                    if inputName.contains("negative") {
                        replacement = negativeText
                    } else if inputName.contains("positive") {
                        replacement = positiveText
                    } else if nodeIsNegative {
                        replacement = negativeText
                    } else if nodeIsPositive {
                        replacement = positiveText
                    } else {
                        replacement = nil
                    }
                    if let replacement, node.inputs[index].value != replacement {
                        node.inputs[index].value = replacement
                        changed = true
                    }
                }

                if ["seed", "noise_seed", "random_seed"].contains(inputName), node.inputs[index].value != seedText {
                    node.inputs[index].value = seedText
                    changed = true
                }
            }

            if changed {
                try await client.comfyUpdateNode(workflowID: selectedWorkflowID, node: node)
            }
        }
    }

    func setImageInputFromIPhone(node: ComfyNodeInfo, input: ComfyNodeInput, filename: String, data: Data) async {
        guard !selectedWorkflowID.isEmpty else { return }
        busy = true
        defer { busy = false }
        do {
            _ = try await client.comfySetInputFromIPhone(workflowID: selectedWorkflowID, nodeID: node.id, inputName: input.name, filename: filename, data: data)
            await loadWorkflowDetails()
            savedMessage = "Медиа загружено в ComfyUI"
            try? await Task.sleep(nanoseconds: 1_100_000_000)
            savedMessage = ""
        } catch { errorMessage = error.localizedDescription }
    }

    func setImageInputFromPC(node: ComfyNodeInfo, input: ComfyNodeInput, path: String) async {
        guard !selectedWorkflowID.isEmpty else { return }
        busy = true
        defer { busy = false }
        do {
            _ = try await client.comfySetInputFromPC(workflowID: selectedWorkflowID, nodeID: node.id, inputName: input.name, path: path)
            await loadWorkflowDetails()
            savedMessage = "Файл с ПК выбран"
            try? await Task.sleep(nanoseconds: 1_100_000_000)
            savedMessage = ""
        } catch { errorMessage = error.localizedDescription }
    }

    func startComfyUI() async {
        busy = true
        defer { busy = false }
        do {
            var launcher = app
            if launcher == nil {
                if let apps = try? await client.allApps() {
                    launcher = apps.first(where: { $0.isComfyUI })
                    app = launcher
                }
            }
            guard let launcher else {
                throw APIError.server("Лаунчер ComfyUI не найден на ПК. Добавьте ярлык/батник ComfyUI в доступные программы сервера или запустите ComfyUI вручную.")
            }
            try await client.launch(app: launcher)
            try? await Task.sleep(nanoseconds: 2_200_000_000)
            await refresh(loadParameters: true)
        } catch {
            errorMessage = error.localizedDescription
        }
    }

    func generate() async {
        guard available else {
            errorMessage = "Сначала запустите ComfyUI на ПК."
            return
        }
        guard !selectedWorkflowID.isEmpty else {
            errorMessage = "Сначала выберите workflow."
            return
        }
        busy = true
        errorMessage = ""
        defer { busy = false }
        do {
            // Advanced fields edit real node inputs. Flush the latest local draft
            // immediately before Generate so a quick tap cannot race a debounced save.
            let staged = ComfyAdvancedDraftStore.stagedNodes(workflowID: selectedWorkflowID)
            for node in staged {
                try await client.comfyUpdateNode(workflowID: selectedWorkflowID, node: node)
            }
            if !staged.isEmpty { ComfyAdvancedDraftStore.clear(workflowID: selectedWorkflowID) }

            // Flush Prompt immediately through the server-side normalized node
            // resolver. This covers API and UI-format/custom prompt nodes and
            // avoids racing the 450 ms live-sync debounce when Generate is tapped.
            promptSyncTask?.cancel()
            try await client.comfySetMainPrompts(
                workflowID: selectedWorkflowID,
                positive: parameters.positive,
                negative: parameters.negative
            )
            let outputNodeID = (generateOnlySelectedOutput && !selectedOutputNodeID.isEmpty) ? selectedOutputNodeID : nil
            _ = try await client.comfyGenerate(workflowID: selectedWorkflowID, parameters: parameters, outputNodeID: outputNodeID)
            await refresh(loadParameters: false)
        } catch {
            errorMessage = error.localizedDescription
        }
    }

    func randomizeSeed() {
        parameters.seed = Int64.random(in: 1...9_000_000_000_000_000_000)
        if !selectedWorkflowID.isEmpty {
            ComfyAdvancedDraftStore.synchronizeSeed(workflowID: selectedWorkflowID, seed: parameters.seed)
        }
    }

    func generateWithNewSeed() async {
        randomizeSeed()
        await generate()
    }

    func interrupt() async {
        do {
            try await client.comfyInterrupt()
            await refresh(loadParameters: false)
        } catch {
            errorMessage = error.localizedDescription
        }
    }

    func clearQueue() async {
        do {
            try await client.comfyClearQueue()
            await refresh(loadParameters: false)
        } catch {
            errorMessage = error.localizedDescription
        }
    }

    func stopGeneration() async {
        do {
            try await client.comfyInterrupt()
            try? await client.comfyClearQueue()
            await refresh(loadParameters: false)
        } catch { errorMessage = error.localizedDescription }
    }

    func reuseResult(_ item: ComfyImageItem) async {
        if !item.workflowID.isEmpty, let workflow = workflows.first(where: { $0.id == item.workflowID }) {
            await selectWorkflow(workflow)
        }
        if let value = item.positive { parameters.positive = value }
        if let value = item.negative { parameters.negative = value }
        if let value = item.steps { parameters.steps = value }
        if let value = item.cfg { parameters.cfg = value }
        if let value = item.seed { parameters.seed = value }
        if let value = item.sampler { parameters.sampler = value }
        if let value = item.scheduler { parameters.scheduler = value }
        if let value = item.width { parameters.width = value }
        if let value = item.height { parameters.height = value }
        if let value = item.checkpoint { parameters.checkpoint = value }
        if let value = item.lora { parameters.lora = value }
        if let value = item.vae { parameters.vae = value }
        if !selectedWorkflowID.isEmpty {
            ComfyAdvancedDraftStore.synchronizeSeed(workflowID: selectedWorkflowID, seed: parameters.seed)
        }
        savedMessage = "Исходные параметры восстановлены"
        try? await Task.sleep(nanoseconds: 1_200_000_000)
        savedMessage = ""
    }

    func openFullUIOnPC() async {
        do { try await client.comfyOpenFullUIOnPC() }
        catch { errorMessage = error.localizedDescription }
    }

    func openImageOnPC(_ item: ComfyImageItem) async {
        do { try await client.comfyOpenImageOnPC(item) }
        catch { errorMessage = error.localizedDescription }
    }

    func deleteImage(_ item: ComfyImageItem) async {
        do {
            try await client.comfyDeleteImage(item)
            await refresh(loadParameters: false)
        } catch {
            errorMessage = error.localizedDescription
        }
    }

    func saveImage(_ item: ComfyImageItem) async {
        do {
            let data = try await client.comfyImageData(item)
            guard let image = UIImage(data: data) else { throw APIError.badResponse }
            UIImageWriteToSavedPhotosAlbum(image, nil, nil, nil)
            savedMessage = "Сохранено в Фото"
            try? await Task.sleep(nanoseconds: 1_500_000_000)
            savedMessage = ""
        } catch {
            errorMessage = error.localizedDescription
        }
    }
}

private struct ComfyInputTarget: Identifiable {
    let node: ComfyNodeInfo
    let input: ComfyNodeInput
    var id: String { "\(node.id)|\(input.name)" }
}

struct ComfyUIView: View {
    @Environment(\.dismiss) private var dismiss
    @Environment(\.scenePhase) private var scenePhase
    @ObservedObject var model: ComfyUIModel
    @State private var showWorkflowPicker = false
    @State private var selectedImage: ComfyImageItem?
    @State private var editWorkflow: ComfyWorkflow?
    @State private var showTemplates = false
    @State private var showSaveTemplate = false
    @State private var showPromptEnhancer = false
    @State private var pendingDeleteResult: ComfyImageItem?
    @State private var pcInputTarget: ComfyInputTarget?
    @State private var imageInputsExpanded = true
    @State private var videoInputsExpanded = true
    @State private var audioInputsExpanded = true
    @FocusState private var promptEditorFocused: Bool
    private let standalone: Bool
    private let onSettings: (() -> Void)?

    init(model: ComfyUIModel, standalone: Bool = false, onSettings: (() -> Void)? = nil) {
        self.model = model
        self.standalone = standalone
        self.onSettings = onSettings
    }

    var body: some View {
        ZStack {
            ComfyBackground()

            ScrollView(showsIndicators: false) {
                VStack(spacing: 14) {
                    header
                        .padding(.top, 6)

                    if model.available {
                        systemStatusBar
                    }

                    if let message = model.dashboard?.message, !model.available {
                        unavailableCard(message: message)
                    } else if model.dashboard == nil {
                        ProgressView("Подключаемся к ComfyUI…")
                            .tint(.white)
                            .foregroundStyle(.white)
                            .frame(maxWidth: .infinity, minHeight: 280)
                    } else {
                        workflowCard
                        if !model.audioInputNodes.isEmpty {
                            audioInputsSection
                        }
                        if !model.videoInputNodes.isEmpty {
                            videoInputsSection
                        }
                        if !model.imageInputNodes.isEmpty {
                            imageInputsSection
                        }
                        if !model.outputNodes.isEmpty {
                            outputTargetSection
                        }
                        promptCard(
                            title: "Positive Prompt",
                            systemImage: "sparkles",
                            text: Binding(
                                get: { model.parameters.positive },
                                set: { value in
                                    model.parameters.positive = value
                                    model.schedulePromptSync()
                                }
                            ),
                            withTemplates: true
                        )
                        promptCard(
                            title: "Negative Prompt",
                            systemImage: "minus.circle",
                            text: Binding(
                                get: { model.parameters.negative },
                                set: { value in
                                    model.parameters.negative = value
                                    model.schedulePromptSync()
                                }
                            ),
                            withTemplates: false
                        )

                        if !model.selectedWorkflowID.isEmpty {
                            ComfyAdvancedPanel(device: model.device, workflowID: model.selectedWorkflowID)
                                .id(model.selectedWorkflowID)
                        }

                        queueSection
                        resultsSection
                    }

                    if !model.errorMessage.isEmpty {
                        HStack(alignment: .top, spacing: 9) {
                            Image(systemName: "exclamationmark.triangle.fill")
                            Text(model.errorMessage)
                                .font(.system(size: 13, weight: .medium))
                                .fixedSize(horizontal: false, vertical: true)
                            Spacer(minLength: 0)
                        }
                        .foregroundStyle(Color.orange)
                        .padding(14)
                        .background(Color.orange.opacity(0.10), in: RoundedRectangle(cornerRadius: 18, style: .continuous))
                    }

                    if !model.savedMessage.isEmpty {
                        Label(model.savedMessage, systemImage: "checkmark.circle.fill")
                            .font(.system(size: 13, weight: .semibold))
                            .foregroundStyle(.green)
                            .padding(.vertical, 8)
                    }

                    Color.clear.frame(height: 12)
                }
                .padding(.horizontal, 16)
                .frame(maxWidth: 720)
                .frame(maxWidth: .infinity)
            }
            .scrollDismissesKeyboard(.interactively)
            .onTapGesture { hideKeyboard() }
        }
        .preferredColorScheme(.dark)
        .toolbar {
            ToolbarItemGroup(placement: .keyboard) {
                Button("Готово") {
                    promptEditorFocused = false
                    hideKeyboard()
                }
                Spacer()
                Button("🎲 Generate") {
                    promptEditorFocused = false
                    hideKeyboard()
                    Task { await model.generateWithNewSeed() }
                }
                .font(.system(size: 13, weight: .bold))
            }
        }
        .safeAreaInset(edge: .bottom, spacing: 0) { actionBar }
        .sheet(isPresented: $showWorkflowPicker) {
            ComfyWorkflowPicker(
                device: model.device,
                workflows: model.workflows,
                selectedID: model.selectedWorkflowID,
                onSelect: { workflow in
                    showWorkflowPicker = false
                    Task { await model.selectWorkflow(workflow) }
                },
                onEdit: { workflow in
                    showWorkflowPicker = false
                    editWorkflow = workflow
                },
                onReload: { Task { await model.refresh(loadParameters: false) } }
            )
            .preferredColorScheme(.dark)
        }
        .sheet(isPresented: $showTemplates) {
            ComfyPromptTemplatesView(
                profile: model.dashboard?.modelProfile ?? "generic_image",
                mediaType: model.dashboard?.mediaType ?? "image",
                checkpoint: model.parameters.checkpoint,
                prompt: $model.parameters.positive
            )
            .preferredColorScheme(.dark)
        }
        .sheet(isPresented: $showSaveTemplate) {
            ComfySaveTemplateView(
                profile: ComfyPromptTemplateLibrary.normalizedProfile(
                    model.dashboard?.modelProfile ?? "generic_image",
                    checkpoint: model.parameters.checkpoint,
                    mediaType: model.dashboard?.mediaType ?? "image"
                ),
                initialText: model.parameters.positive
            )
            .preferredColorScheme(.dark)
        }
        .sheet(isPresented: $showPromptEnhancer) {
            PromptEnhancerSheet(
                profile: model.dashboard?.modelProfile ?? "generic_image",
                mediaType: model.dashboard?.mediaType ?? "image",
                checkpoint: model.parameters.checkpoint,
                lora: model.parameters.lora,
                prompt: $model.parameters.positive
            )
            .preferredColorScheme(.dark)
        }
        .fullScreenCover(item: $editWorkflow, onDismiss: {
            Task {
                await model.loadWorkflowDetails()
                await model.refresh(loadParameters: true)
            }
        }) { workflow in
            ComfyNodeEditorView(device: model.device, workflow: workflow)
                .preferredColorScheme(.dark)
        }
        .fullScreenCover(item: $selectedImage) { item in
            ComfyResultViewer(
                device: model.device,
                items: model.images,
                initialItem: item,
                onEdit: { selected in
                    selectedImage = nil
                    Task { await model.reuseResult(selected) }
                }
            )
            .preferredColorScheme(.dark)
        }
        .sheet(item: $pcInputTarget) { target in
            ComfyPCMediaPicker(device: model.device) { path in
                pcInputTarget = nil
                Task { await model.setImageInputFromPC(node: target.node, input: target.input, path: path) }
            }
            .preferredColorScheme(.dark)
        }
        .alert("Удалить результат?", isPresented: Binding(
            get: { pendingDeleteResult != nil },
            set: { if !$0 { pendingDeleteResult = nil } }
        )) {
            Button("Отмена", role: .cancel) { pendingDeleteResult = nil }
            Button("Удалить", role: .destructive) {
                if let item = pendingDeleteResult {
                    Task { await model.deleteImage(item) }
                }
                pendingDeleteResult = nil
            }
        } message: {
            Text("Результат исчезнет из галереи. Если файл найден в папке ComfyUI output, он также будет удалён с ПК.")
        }
        .onAppear { model.start() }
        .onChange(of: scenePhase) { phase in
            switch phase {
            case .active:
                model.start()
                Task { await model.refresh(loadParameters: false) }
            case .background:
                model.stop()
            default:
                break
            }
        }
        .onDisappear { model.stop() }
    }

    private var header: some View {
        HStack(spacing: 12) {
            Button {
                if standalone { onSettings?() } else { dismiss() }
            } label: {
                Image(systemName: standalone ? "gearshape.fill" : "chevron.left")
                    .font(.system(size: 18, weight: .bold))
                    .frame(width: 44, height: 44)
                    .background(.ultraThinMaterial, in: Circle())
            }
            .buttonStyle(.plain)

            VStack(alignment: .leading, spacing: 3) {
                Text("ComfyUI")
                    .font(.system(size: 25, weight: .bold, design: .rounded))
                HStack(spacing: 6) {
                    Circle()
                        .fill(model.available ? Color.green : Color.orange)
                        .frame(width: 8, height: 8)
                    Text(model.available ? "Connected" : "Offline")
                        .font(.system(size: 12, weight: .semibold))
                        .foregroundStyle(.white.opacity(0.65))
                    if model.available {
                        Text("•")
                            .foregroundStyle(.white.opacity(0.30))
                        Text(profileTitle)
                            .font(.system(size: 11, weight: .semibold))
                            .foregroundStyle(.cyan.opacity(0.76))
                    }
                }
            }
            .frame(maxWidth: .infinity, alignment: .leading)

            Menu {
                if model.available {
                    Button { Task { await model.openFullUIOnPC() } } label: {
                        Label("Полный интерфейс на ПК", systemImage: "macwindow")
                    }
                    Button { Task { await model.clearQueue() } } label: {
                        Label("Очистить очередь", systemImage: "trash")
                    }
                }
                Button { Task { await model.refresh(loadParameters: false) } } label: {
                    Label("Обновить", systemImage: "arrow.clockwise")
                }
            } label: {
                Image(systemName: "ellipsis")
                    .font(.system(size: 19, weight: .bold))
                    .frame(width: 44, height: 44)
                    .background(.ultraThinMaterial, in: Circle())
            }
            .buttonStyle(.plain)
        }
        .foregroundStyle(.white)
    }

    private var profileTitle: String {
        switch model.dashboard?.modelProfile ?? "generic_image" {
        case "wan22": return "WAN 2.2 • Video"
        case "wan": return "WAN • Video"
        case "zimage_turbo": return "Z-Image Turbo • Image"
        case "zimage": return "Z-Image • Image"
        case "sdxl": return "SDXL • Image"
        case "generic_video": return "Video workflow"
        case "generic_audio": return "Audio workflow"
        default: return model.dashboard?.mediaType == "audio" ? "Audio workflow" : "Image workflow"
        }
    }

    private var systemStatusBar: some View {
        ScrollView(.horizontal, showsIndicators: false) {
            HStack(spacing: 8) {
                if let stats = model.dashboard?.system {
                    if let gpu = stats.gpuPercent {
                        ComfyStatusChip(
                            icon: "memorychip.fill",
                            title: "GPU",
                            value: "\(Int(gpu))%" + (stats.gpuTemperature.map { "  \(Int($0))°" } ?? ""),
                            tint: .cyan
                        )
                    }
                    ComfyStatusChip(
                        icon: "cpu.fill",
                        title: "CPU",
                        value: "\(Int(stats.cpuPercent))%",
                        tint: .blue
                    )
                    ComfyStatusChip(
                        icon: "memorychip",
                        title: "RAM",
                        value: String(format: "%.1f/%.1f GB", stats.ramUsedGB, stats.ramTotalGB),
                        tint: .purple
                    )
                    if let used = stats.vramUsedGB, let total = stats.vramTotalGB {
                        ComfyStatusChip(
                            icon: "rectangle.stack.fill",
                            title: "VRAM",
                            value: String(format: "%.1f/%.1f GB", used, total),
                            tint: .green
                        )
                    }
                } else if let vram = model.dashboard?.vram {
                    ComfyStatusChip(icon: "memorychip", title: "VRAM", value: vram, tint: .cyan)
                }
            }
        }
    }

    private func unavailableCard(message: String) -> some View {
        ComfyGlassCard {
            VStack(spacing: 16) {
                ZStack {
                    Circle().fill(Color.blue.opacity(0.18)).frame(width: 82, height: 82)
                    Image(systemName: "circle.hexagongrid.fill")
                        .font(.system(size: 35, weight: .semibold))
                        .foregroundStyle(.cyan)
                }
                Text("ComfyUI не запущен")
                    .font(.system(size: 21, weight: .bold, design: .rounded))
                Text(message)
                    .font(.system(size: 13))
                    .foregroundStyle(.white.opacity(0.62))
                    .multilineTextAlignment(.center)
                Button {
                    Task { await model.startComfyUI() }
                } label: {
                    HStack(spacing: 8) {
                        if model.busy { ProgressView().tint(.white) }
                        Image(systemName: "play.fill")
                        Text("Запустить ComfyUI")
                    }
                    .font(.system(size: 16, weight: .bold))
                    .frame(maxWidth: .infinity)
                    .padding(.vertical, 14)
                    .background(
                        LinearGradient(colors: [.blue, .cyan.opacity(0.85)], startPoint: .leading, endPoint: .trailing),
                        in: RoundedRectangle(cornerRadius: 16, style: .continuous)
                    )
                }
                .buttonStyle(.plain)
                .disabled(model.busy)
            }
            .foregroundStyle(.white)
            .padding(.vertical, 16)
        }
    }

    private var workflowCard: some View {
        HStack(spacing: 9) {
            Button { showWorkflowPicker = true } label: {
                HStack(spacing: 13) {
                    ZStack {
                        RoundedRectangle(cornerRadius: 16, style: .continuous)
                            .fill(LinearGradient(colors: [.blue.opacity(0.92), .purple.opacity(0.86)], startPoint: .topLeading, endPoint: .bottomTrailing))
                        Image(systemName: "circle.hexagongrid.fill")
                            .font(.system(size: 22, weight: .bold))
                            .foregroundStyle(.white)
                    }
                    .frame(width: 52, height: 52)

                    VStack(alignment: .leading, spacing: 4) {
                        Text("WORKFLOW")
                            .font(.system(size: 10.5, weight: .bold))
                            .foregroundStyle(.cyan.opacity(0.86))
                        Text(model.selectedWorkflow?.name ?? "Выберите workflow")
                            .font(.system(size: 17, weight: .bold, design: .rounded))
                            .foregroundStyle(.white)
                            .lineLimit(1)
                        if let workflow = model.selectedWorkflow {
                            Text("\(workflow.nodeCount) нод • \(workflow.source)")
                                .font(.system(size: 10.5, weight: .medium))
                                .foregroundStyle(.white.opacity(0.48))
                                .lineLimit(1)
                        }
                    }
                    Spacer(minLength: 6)
                    Image(systemName: "chevron.up.chevron.down")
                        .font(.system(size: 12, weight: .bold))
                        .foregroundStyle(.white.opacity(0.52))
                }
                .padding(12)
                .background(Color.white.opacity(0.075), in: RoundedRectangle(cornerRadius: 22, style: .continuous))
                .overlay(RoundedRectangle(cornerRadius: 22, style: .continuous).stroke(Color.white.opacity(0.10), lineWidth: 1))
            }
            .buttonStyle(.plain)

            Button {
                if let workflow = model.selectedWorkflow { editWorkflow = workflow }
            } label: {
                Image(systemName: "pencil")
                    .font(.system(size: 18, weight: .bold))
                    .foregroundStyle(.white)
                    .frame(width: 50, height: 76)
                    .background(Color.white.opacity(0.075), in: RoundedRectangle(cornerRadius: 20, style: .continuous))
                    .overlay(RoundedRectangle(cornerRadius: 20, style: .continuous).stroke(Color.white.opacity(0.10), lineWidth: 1))
            }
            .buttonStyle(.plain)
            .disabled(model.selectedWorkflow == nil)
            .opacity(model.selectedWorkflow == nil ? 0.4 : 1)
            .accessibilityLabel("Открыть редактор нод")
        }
    }

    private var audioInputsSection: some View {
        mediaInputsSection(
            title: "Audio Input",
            symbol: "waveform.badge.plus",
            nodes: model.audioInputNodes,
            expanded: $audioInputsExpanded
        )
    }

    private var videoInputsSection: some View {
        mediaInputsSection(
            title: "Video Input",
            symbol: "video.badge.plus",
            nodes: model.videoInputNodes,
            expanded: $videoInputsExpanded
        )
    }

    private var imageInputsSection: some View {
        mediaInputsSection(
            title: "Image Input",
            symbol: "photo.badge.plus",
            nodes: model.imageInputNodes,
            expanded: $imageInputsExpanded
        )
    }

    private var outputTargetSection: some View {
        ComfyGlassCard {
            VStack(alignment: .leading, spacing: 12) {
                HStack(spacing: 8) {
                    Image(systemName: "square.and.arrow.down")
                        .font(.system(size: 14, weight: .bold))
                        .foregroundStyle(.cyan)
                    Text("Generate Target")
                        .font(.system(size: 15, weight: .bold, design: .rounded))
                        .foregroundStyle(.white)
                    Spacer()
                    Text("\(model.outputNodes.count) output")
                        .font(.system(size: 10.5, weight: .bold))
                        .foregroundStyle(.white.opacity(0.56))
                }

                Toggle(isOn: Binding(
                    get: { model.generateOnlySelectedOutput },
                    set: { model.setGenerateOnlySelectedOutput($0) }
                )) {
                    VStack(alignment: .leading, spacing: 3) {
                        Text("Generate only selected output")
                            .font(.system(size: 13, weight: .bold))
                            .foregroundStyle(.white)
                        Text(model.generateOnlySelectedOutput ? "Будет запущена только выбранная output-нода." : "По умолчанию будут работать все output-ноды workflow.")
                            .font(.system(size: 11, weight: .medium))
                            .foregroundStyle(.white.opacity(0.58))
                    }
                }
                .tint(.cyan)

                if model.generateOnlySelectedOutput {
                    VStack(spacing: 8) {
                        ForEach(model.outputNodes) { node in
                            Button { model.selectOutputNode(node.id) } label: {
                                HStack(spacing: 10) {
                                    ZStack {
                                        Circle()
                                            .fill(model.selectedOutputNodeID == node.id ? Color.cyan : Color.white.opacity(0.08))
                                            .frame(width: 22, height: 22)
                                        if model.selectedOutputNodeID == node.id {
                                            Image(systemName: "checkmark")
                                                .font(.system(size: 11, weight: .bold))
                                                .foregroundStyle(.black)
                                        }
                                    }
                                    VStack(alignment: .leading, spacing: 3) {
                                        Text(model.outputNodeDisplayName(node))
                                            .font(.system(size: 13.5, weight: .bold))
                                            .foregroundStyle(.white)
                                            .lineLimit(1)
                                        Text(node.classType)
                                            .font(.system(size: 11, weight: .medium))
                                            .foregroundStyle(.white.opacity(0.52))
                                    }
                                    Spacer()
                                }
                                .padding(.horizontal, 12)
                                .padding(.vertical, 10)
                                .background(Color.white.opacity(model.selectedOutputNodeID == node.id ? 0.11 : 0.06), in: RoundedRectangle(cornerRadius: 14, style: .continuous))
                                .overlay(RoundedRectangle(cornerRadius: 14, style: .continuous).stroke(model.selectedOutputNodeID == node.id ? Color.cyan.opacity(0.55) : Color.white.opacity(0.08), lineWidth: 1))
                            }
                            .buttonStyle(.plain)
                        }
                    }
                }
            }
        }
    }

    private func mediaInputsSection(
        title: String,
        symbol: String,
        nodes: [ComfyNodeInfo],
        expanded: Binding<Bool>
    ) -> some View {
        VStack(alignment: .leading, spacing: 10) {
            Button {
                withAnimation(.spring(response: 0.26, dampingFraction: 0.88)) {
                    expanded.wrappedValue.toggle()
                }
            } label: {
                HStack(spacing: 10) {
                    Image(systemName: symbol)
                        .font(.system(size: 15, weight: .bold))
                        .foregroundStyle(.cyan)
                    Text(title)
                        .font(.system(size: 15, weight: .bold, design: .rounded))
                    Text("\(nodes.count)")
                        .font(.system(size: 10, weight: .bold))
                        .foregroundStyle(.white.opacity(0.58))
                        .padding(.horizontal, 8)
                        .padding(.vertical, 4)
                        .background(Color.white.opacity(0.08), in: Capsule())
                    Spacer()
                    Text(expanded.wrappedValue ? "Свернуть" : "Развернуть")
                        .font(.system(size: 10.5, weight: .bold))
                        .foregroundStyle(.white.opacity(0.48))
                    Image(systemName: "chevron.down")
                        .font(.system(size: 12, weight: .bold))
                        .rotationEffect(.degrees(expanded.wrappedValue ? 180 : 0))
                        .foregroundStyle(.white.opacity(0.58))
                }
                .foregroundStyle(.white)
                .padding(.horizontal, 14)
                .padding(.vertical, 12)
                .background(Color.white.opacity(0.07), in: RoundedRectangle(cornerRadius: 16, style: .continuous))
                .overlay(RoundedRectangle(cornerRadius: 16, style: .continuous).stroke(Color.white.opacity(0.09), lineWidth: 1))
            }
            .buttonStyle(.plain)

            if expanded.wrappedValue {
                VStack(spacing: 10) {
                    ForEach(nodes) { node in
                        if let input = imagePickerInput(for: node) {
                            ComfyImageInputCard(
                                device: model.device,
                                node: node,
                                input: input,
                                busy: model.busy,
                                onIPhoneImage: { filename, data in
                                    Task { await model.setImageInputFromIPhone(node: node, input: input, filename: filename, data: data) }
                                },
                                onPickPC: {
                                    pcInputTarget = ComfyInputTarget(node: node, input: input)
                                }
                            )
                        }
                    }
                }
                .transition(.opacity.combined(with: .move(edge: .top)))
            }
        }
    }

    private func imagePickerInput(for node: ComfyNodeInfo) -> ComfyNodeInput? {
        let scalar = node.inputs.filter { !$0.isConnection }
        let className = node.classType.lowercased().replacingOccurrences(of: "_", with: "")
        let audioPreferred = ["audio", "file", "audio_file", "input_audio", "source_audio", "sound", "path", "filename", "media", "input"]
        let videoPreferred = ["video", "file", "video_file", "input_video", "source_video", "path", "filename", "media", "input"]
        let imagePreferred = ["image", "input_image", "start_image", "first_frame", "file", "path", "filename", "media", "input"]
        let preferred = (className.contains("audio") || className.contains("sound")) ? audioPreferred : (className.contains("video") ? videoPreferred : imagePreferred)
        for name in preferred {
            if let found = scalar.first(where: { $0.name.lowercased() == name }) { return found }
        }
        return scalar.first(where: { input in
            let low = input.name.lowercased()
            return low.contains("image") || low.contains("frame") || low.contains("video") || low.contains("audio") || low.contains("sound") || low == "file" || low.hasSuffix("_file") || low.contains("media")
        }) ?? scalar.first
    }

    private func promptCard(title: String, systemImage: String, text: Binding<String>, withTemplates: Bool) -> some View {
        ComfyGlassCard {
            VStack(alignment: .leading, spacing: 9) {
                HStack(spacing: 8) {
                    Label(title, systemImage: systemImage)
                        .font(.system(size: 14, weight: .bold))
                        .foregroundStyle(.white.opacity(0.88))
                    Spacer(minLength: 4)
                    if withTemplates {
                        Button { showPromptEnhancer = true } label: {
                            Label("Enhance", systemImage: "wand.and.stars")
                                .font(.system(size: 10.5, weight: .bold))
                                .padding(.horizontal, 10)
                                .padding(.vertical, 7)
                                .background(Color.purple.opacity(0.18), in: Capsule())
                        }
                        .buttonStyle(.plain)
                        Button { showTemplates = true } label: {
                            Text("Templates")
                                .font(.system(size: 11, weight: .bold))
                                .padding(.horizontal, 10)
                                .padding(.vertical, 7)
                                .background(Color.cyan.opacity(0.12), in: Capsule())
                        }
                        .buttonStyle(.plain)
                        Button { showSaveTemplate = true } label: {
                            Image(systemName: "plus")
                                .font(.system(size: 12, weight: .bold))
                                .frame(width: 30, height: 30)
                                .background(Color.white.opacity(0.08), in: Circle())
                        }
                        .buttonStyle(.plain)
                    }
                }

                ComfyPromptTextView(
                    text: text,
                    onFocusChanged: { promptEditorFocused = $0 },
                    onReturnGenerate: {
                        promptEditorFocused = false
                        hideKeyboard()
                        Task { await model.generateWithNewSeed() }
                    }
                )
                .frame(minHeight: 82, maxHeight: 116)
                .padding(5)
                .background(Color.black.opacity(0.20), in: RoundedRectangle(cornerRadius: 14, style: .continuous))
                .overlay(
                    RoundedRectangle(cornerRadius: 14, style: .continuous)
                        .stroke(Color.white.opacity(0.07), lineWidth: 1)
                )
            }
        }
    }

    private var queueSection: some View {
        VStack(alignment: .leading, spacing: 10) {
            sectionTitle("Queue Status", symbol: "clock.arrow.2.circlepath")
            ComfyGlassCard {
                VStack(spacing: 12) {
                    HStack {
                        VStack(alignment: .leading, spacing: 4) {
                            Text(model.generationStageTitle)
                                .font(.system(size: 16, weight: .bold))
                            Text(queueSubtitle)
                                .font(.system(size: 11, weight: .medium))
                                .foregroundStyle(.white.opacity(0.54))
                        }
                        Spacer()
                        VStack(alignment: .trailing, spacing: 3) {
                            Text(model.running ? "\(Int((model.dashboard?.progress ?? 0) * 100))%" : (model.dashboard?.generationStage == "complete" ? "100%" : "Idle"))
                                .font(.system(size: 14, weight: .bold, design: .rounded))
                                .foregroundStyle(model.running ? Color.cyan : Color.green)
                            if !model.generationElapsedText.isEmpty {
                                Label(model.generationElapsedText, systemImage: "timer")
                                    .font(.system(size: 10.5, weight: .semibold, design: .monospaced))
                                    .foregroundStyle(.white.opacity(0.48))
                            }
                        }
                    }

                    GeometryReader { proxy in
                        ZStack(alignment: .leading) {
                            Capsule().fill(Color.white.opacity(0.09))
                            Capsule()
                                .fill(LinearGradient(colors: [.blue, .cyan], startPoint: .leading, endPoint: .trailing))
                                .frame(width: proxy.size.width * CGFloat(max(0, min(1, model.dashboard?.progress ?? 0))))
                        }
                    }
                    .frame(height: 9)
                    .animation(.easeOut(duration: 0.25), value: model.dashboard?.progress)
                }
            }
        }
    }

    private var queueSubtitle: String {
        let remaining = model.dashboard?.queueRemaining ?? 0
        if model.running, !model.currentNodeDisplayName.isEmpty {
            return "\(model.currentNodeDisplayName) • Queue: \(remaining)"
        }
        if model.dashboard?.generationStage == "complete" { return "Результат сохранён • Queue: \(remaining)" }
        if model.dashboard?.generationStage == "stopped" { return "Генерация остановлена • Queue: \(remaining)" }
        if model.dashboard?.generationStage == "error", let message = model.dashboard?.error, !message.isEmpty { return message }
        return remaining > 0 ? "В очереди: \(remaining)" : "Очередь пуста"
    }

    private var resultsSection: some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack {
                sectionTitle(model.dashboard?.mediaType == "audio" ? "Audio Results" : "Results", symbol: model.dashboard?.mediaType == "audio" ? "waveform" : "photo.on.rectangle.angled")
                Spacer()
                if !model.images.isEmpty {
                    Text("\(model.images.count)")
                        .font(.system(size: 11, weight: .bold))
                        .foregroundStyle(.white.opacity(0.55))
                        .padding(.horizontal, 9)
                        .padding(.vertical, 4)
                        .background(Color.white.opacity(0.08), in: Capsule())
                }
            }

            if model.images.isEmpty {
                ComfyGlassCard {
                    VStack(spacing: 9) {
                        Image(systemName: model.dashboard?.mediaType == "audio" ? "waveform.circle" : "photo.stack")
                            .font(.system(size: 30))
                            .foregroundStyle(.white.opacity(0.30))
                        Text(model.dashboard?.mediaType == "audio" ? "Аудио появится здесь после генерации" : "Результаты появятся здесь")
                            .font(.system(size: 13, weight: .semibold))
                            .foregroundStyle(.white.opacity(0.50))
                    }
                    .frame(maxWidth: .infinity)
                    .padding(.vertical, 22)
                }
            } else {
                LazyVGrid(columns: [GridItem(.flexible(), spacing: 10), GridItem(.flexible(), spacing: 10)], spacing: 10) {
                    ForEach(model.images) { item in
                        Button { selectedImage = item } label: {
                            ZStack {
                                RoundedRectangle(cornerRadius: 16, style: .continuous)
                                    .fill(Color.white.opacity(0.045))
                                ComfyRemoteImage(device: model.device, item: item)
                                    .frame(maxWidth: .infinity, maxHeight: .infinity)
                                    .clipped()
                                if item.isVideo {
                                    Circle()
                                        .fill(Color.black.opacity(0.56))
                                        .frame(width: 44, height: 44)
                                        .overlay(Image(systemName: "play.fill").foregroundStyle(.white).offset(x: 1))
                                } else if item.isAudio {
                                    Circle()
                                        .fill(Color.black.opacity(0.52))
                                        .frame(width: 44, height: 44)
                                        .overlay(Image(systemName: "play.fill").foregroundStyle(.white).offset(x: 1))
                                }
                            }
                            .aspectRatio(1, contentMode: .fit)
                            .clipShape(RoundedRectangle(cornerRadius: 16, style: .continuous))
                            .overlay(
                                RoundedRectangle(cornerRadius: 16, style: .continuous)
                                    .stroke(Color.white.opacity(0.10), lineWidth: 1)
                            )
                        }
                        .buttonStyle(.plain)
                        .contextMenu {
                            if !item.isVideo && !item.isAudio {
                                Button { Task { await model.saveImage(item) } } label: {
                                    Label("Сохранить в Фото", systemImage: "square.and.arrow.down")
                                }
                            }
                            Button { Task { await model.openImageOnPC(item) } } label: {
                                Label("Открыть на ПК", systemImage: "display")
                            }
                            Button(role: .destructive) { pendingDeleteResult = item } label: {
                                Label("Удалить", systemImage: "trash")
                            }
                        }
                    }
                }
            }
        }
    }

    private var actionBar: some View {
        HStack(spacing: 9) {
            Button { Task { await model.stopGeneration() } } label: {
                Label("Stop", systemImage: "stop.fill")
                    .frame(maxWidth: .infinity)
                    .padding(.vertical, 13)
                    .background(Color.red.opacity(0.18), in: RoundedRectangle(cornerRadius: 16, style: .continuous))
            }
            .disabled(!model.running && (model.dashboard?.queueRemaining ?? 0) == 0)
            .opacity((model.running || (model.dashboard?.queueRemaining ?? 0) > 0) ? 1 : 0.45)

            Button { Task { await model.generateWithNewSeed() } } label: {
                Label("Random Seed", systemImage: "dice.fill")
                    .frame(maxWidth: .infinity)
                    .padding(.vertical, 13)
                    .background(Color.white.opacity(0.08), in: RoundedRectangle(cornerRadius: 16, style: .continuous))
            }
            .disabled(!model.available || model.selectedWorkflowID.isEmpty || model.busy || model.selectedWorkflow?.canExecute == false)

            Button { Task { await model.generate() } } label: {
                HStack(spacing: 7) {
                    if model.busy { ProgressView().tint(.white) }
                    Image(systemName: "sparkles")
                    Text("Generate")
                }
                .frame(maxWidth: .infinity)
                .padding(.vertical, 13)
                .background(
                    LinearGradient(colors: [.blue, .cyan.opacity(0.88)], startPoint: .leading, endPoint: .trailing),
                    in: RoundedRectangle(cornerRadius: 16, style: .continuous)
                )
            }
            .disabled(!model.available || model.selectedWorkflowID.isEmpty || model.busy || model.selectedWorkflow?.canExecute == false)
        }
        .font(.system(size: 13, weight: .bold))
        .foregroundStyle(.white)
        .padding(.horizontal, 12)
        .padding(.top, 9)
        .padding(.bottom, 6)
        .background(.ultraThinMaterial)
        .overlay(alignment: .top) {
            Rectangle().fill(Color.white.opacity(0.08)).frame(height: 1)
        }
    }

    private func hideKeyboard() {
        UIApplication.shared.sendAction(#selector(UIResponder.resignFirstResponder), to: nil, from: nil, for: nil)
    }

    private func sectionTitle(_ title: String, symbol: String) -> some View {
        Label(title, systemImage: symbol)
            .font(.system(size: 15, weight: .bold, design: .rounded))
            .foregroundStyle(.white.opacity(0.90))
    }
}

private struct ComfyPickedMovie: Transferable {
    let url: URL

    static var transferRepresentation: some TransferRepresentation {
        FileRepresentation(contentType: .movie) { movie in
            SentTransferredFile(movie.url)
        } importing: { received in
            let source = received.file
            let ext = source.pathExtension.isEmpty ? "mp4" : source.pathExtension.lowercased()
            let destination = FileManager.default.temporaryDirectory
                .appendingPathComponent("ComfyRemote-import-\(UUID().uuidString).\(ext)")
            try? FileManager.default.removeItem(at: destination)
            try FileManager.default.copyItem(at: source, to: destination)
            return ComfyPickedMovie(url: destination)
        }
    }
}

private struct ComfyImageInputCard: View {
    let device: SavedDevice
    let node: ComfyNodeInfo
    let input: ComfyNodeInput
    let busy: Bool
    let onIPhoneImage: (String, Data) -> Void
    let onPickPC: () -> Void

    @State private var photoItem: PhotosPickerItem?
    @State private var showAudioFileImporter = false
    @State private var converting = false
    @State private var localError = ""

    private var previewItem: ComfyImageItem? {
        let clean = input.value
            .replacingOccurrences(of: " [input]", with: "", options: .caseInsensitive)
            .replacingOccurrences(of: "\\", with: "/")
            .trimmingCharacters(in: .whitespacesAndNewlines)
        guard !clean.isEmpty else { return nil }
        let parts = clean.split(separator: "/", omittingEmptySubsequences: true).map(String.init)
        guard let filename = parts.last else { return nil }
        let subfolder = parts.dropLast().joined(separator: "/")
        return ComfyImageItem(id: "input|\(node.id)|\(input.name)|\(clean)", filename: filename, subfolder: subfolder, type: "input", prompt_id: "input")
    }

    private var isAudioInput: Bool {
        let className = node.classType.lowercased().replacingOccurrences(of: "_", with: "")
        let inputName = input.name.lowercased()
        if className.contains("audio") || className.contains("sound") { return true }
        return inputName.contains("audio") || inputName.contains("sound") || inputName == "wav" || inputName == "wave"
    }

    private var isVideoInput: Bool {
        guard !isAudioInput else { return false }
        let className = node.classType.lowercased().replacingOccurrences(of: "_", with: "")
        let inputName = input.name.lowercased()
        if className.contains("video") { return true }
        return inputName.contains("video") || inputName == "file" && className.contains("load") && className.contains("video")
    }

    var body: some View {
        ComfyGlassCard {
            VStack(alignment: .leading, spacing: 11) {
                HStack(spacing: 10) {
                    VStack(alignment: .leading, spacing: 3) {
                        Text(node.title)
                            .font(.system(size: 14, weight: .bold, design: .rounded))
                        Text("\(node.classType) • \(input.name)")
                            .font(.system(size: 10, weight: .semibold))
                            .foregroundStyle(.white.opacity(0.44))
                    }
                    Spacer()
                    if busy || converting { ProgressView().tint(.white) }
                }

                if let previewItem {
                    if isAudioInput {
                        RoundedRectangle(cornerRadius: 14, style: .continuous)
                            .fill(LinearGradient(colors: [Color.purple.opacity(0.28), Color.black.opacity(0.38)], startPoint: .topLeading, endPoint: .bottomTrailing))
                            .frame(height: 118)
                            .overlay {
                                VStack(spacing: 8) {
                                    Image(systemName: "waveform.circle.fill")
                                        .font(.system(size: 34, weight: .semibold))
                                        .foregroundStyle(.cyan)
                                    Text("Аудио выбрано")
                                        .font(.system(size: 12, weight: .bold))
                                    Text(previewItem.filename)
                                        .font(.system(size: 10, weight: .semibold))
                                        .foregroundStyle(.white.opacity(0.55))
                                        .lineLimit(1)
                                        .truncationMode(.middle)
                                }
                            }
                            .overlay(RoundedRectangle(cornerRadius: 14, style: .continuous).stroke(Color.cyan.opacity(0.18), lineWidth: 1))
                    } else if isVideoInput {
                        RoundedRectangle(cornerRadius: 14, style: .continuous)
                            .fill(Color.black.opacity(0.28))
                            .frame(height: 118)
                            .overlay {
                                VStack(spacing: 8) {
                                    Image(systemName: "play.rectangle.fill")
                                        .font(.system(size: 31, weight: .semibold))
                                        .foregroundStyle(.cyan)
                                    Text("Видео выбрано")
                                        .font(.system(size: 12, weight: .bold))
                                    Text(previewItem.filename)
                                        .font(.system(size: 10, weight: .semibold))
                                        .foregroundStyle(.white.opacity(0.55))
                                        .lineLimit(1)
                                        .truncationMode(.middle)
                                }
                            }
                            .overlay(RoundedRectangle(cornerRadius: 14, style: .continuous).stroke(Color.cyan.opacity(0.18), lineWidth: 1))
                    } else {
                        ComfyRemoteImage(device: device, item: previewItem)
                            .frame(maxWidth: .infinity)
                            .aspectRatio(16/10, contentMode: .fit)
                            .clipShape(RoundedRectangle(cornerRadius: 14, style: .continuous))
                    }
                    Text(input.value)
                        .font(.system(size: 9.5, weight: .semibold))
                        .foregroundStyle(.white.opacity(0.52))
                        .lineLimit(1)
                        .truncationMode(.middle)
                } else {
                    RoundedRectangle(cornerRadius: 14, style: .continuous)
                        .fill(Color.white.opacity(0.045))
                        .frame(height: 100)
                        .overlay {
                            VStack(spacing: 6) {
                                Image(systemName: isAudioInput ? "waveform" : (isVideoInput ? "video" : "photo"))
                                    .font(.system(size: 26))
                                Text(isAudioInput ? "Аудио не выбрано" : (isVideoInput ? "Видео не выбрано" : "Изображение не выбрано"))
                                    .font(.system(size: 11, weight: .semibold))
                            }
                            .foregroundStyle(.white.opacity(0.42))
                        }
                }

                HStack(spacing: 8) {
                    if isAudioInput {
                        Button { showAudioFileImporter = true } label: {
                            Label("Аудио iPhone", systemImage: "waveform")
                                .font(.system(size: 12, weight: .bold))
                                .frame(maxWidth: .infinity)
                                .padding(.vertical, 11)
                                .background(Color.blue.opacity(0.18), in: RoundedRectangle(cornerRadius: 13, style: .continuous))
                        }
                        .buttonStyle(.plain)
                        .disabled(busy || converting)
                    } else {
                        PhotosPicker(selection: $photoItem, matching: isVideoInput ? .videos : .images) {
                            Label(isVideoInput ? "Видео iPhone" : "Фото iPhone", systemImage: isVideoInput ? "video.fill" : "photo.on.rectangle")
                                .font(.system(size: 12, weight: .bold))
                                .frame(maxWidth: .infinity)
                                .padding(.vertical, 11)
                                .background(Color.blue.opacity(0.18), in: RoundedRectangle(cornerRadius: 13, style: .continuous))
                        }
                        .buttonStyle(.plain)
                        .disabled(busy || converting)
                    }

                    Button(action: onPickPC) {
                        Label("Файлы ПК", systemImage: "desktopcomputer")
                            .font(.system(size: 12, weight: .bold))
                            .frame(maxWidth: .infinity)
                            .padding(.vertical, 11)
                            .background(Color.white.opacity(0.08), in: RoundedRectangle(cornerRadius: 13, style: .continuous))
                    }
                    .buttonStyle(.plain)
                    .disabled(busy || converting)
                }

                if !localError.isEmpty {
                    Text(localError)
                        .font(.system(size: 10.5, weight: .semibold))
                        .foregroundStyle(.orange)
                }
            }
        }
        .fileImporter(isPresented: $showAudioFileImporter, allowedContentTypes: [.audio], allowsMultipleSelection: false) { result in
            converting = true
            localError = ""
            Task {
                do {
                    guard let url = try result.get().first else { throw APIError.badResponse }
                    let scoped = url.startAccessingSecurityScopedResource()
                    defer { if scoped { url.stopAccessingSecurityScopedResource() } }
                    let payload = try Data(contentsOf: url, options: .mappedIfSafe)
                    guard !payload.isEmpty else { throw APIError.badResponse }
                    var ext = url.pathExtension.lowercased()
                    if ext.isEmpty { ext = "wav" }
                    let name = "iphone-audio-\(UUID().uuidString.prefix(8)).\(ext)"
                    await MainActor.run { onIPhoneImage(name, payload) }
                } catch {
                    await MainActor.run { localError = "Не удалось импортировать аудио: \(error.localizedDescription)" }
                }
                await MainActor.run { converting = false }
            }
        }
        .onChange(of: photoItem) { newValue in
            guard let newValue else { return }
            converting = true
            localError = ""
            Task {
                do {
                    let types = newValue.supportedContentTypes
                    let pickedVideo = types.contains { type in
                        type.conforms(to: .movie) || type.conforms(to: .video) || type.conforms(to: .audiovisualContent)
                    }

                    if pickedVideo {
                        // PhotosPicker often does not vend movie assets reliably as raw Data.
                        // Import through FileRepresentation first, then read the copied local file.
                        if let movie = try await newValue.loadTransferable(type: ComfyPickedMovie.self) {
                            defer { try? FileManager.default.removeItem(at: movie.url) }
                            let payload = try Data(contentsOf: movie.url, options: .mappedIfSafe)
                            guard !payload.isEmpty else { throw APIError.badResponse }
                            var ext = movie.url.pathExtension.lowercased()
                            if ext.isEmpty {
                                let type = types.first { type in
                                    type.conforms(to: .movie) || type.conforms(to: .video) || type.conforms(to: .audiovisualContent)
                                }
                                ext = type?.preferredFilenameExtension?.lowercased() ?? "mp4"
                            }
                            if ext == "quicktime" { ext = "mov" }
                            if ext.isEmpty { ext = "mp4" }
                            let name = "iphone-video-\(UUID().uuidString.prefix(8)).\(ext)"
                            await MainActor.run { onIPhoneImage(name, payload) }
                        } else {
                            guard let raw = try await newValue.loadTransferable(type: Data.self), !raw.isEmpty else {
                                throw APIError.badResponse
                            }
                            let type = types.first { type in
                                type.conforms(to: .movie) || type.conforms(to: .video) || type.conforms(to: .audiovisualContent)
                            }
                            var ext = type?.preferredFilenameExtension?.lowercased() ?? "mp4"
                            if ext == "quicktime" { ext = "mov" }
                            if ext.isEmpty { ext = "mp4" }
                            let name = "iphone-video-\(UUID().uuidString.prefix(8)).\(ext)"
                            await MainActor.run { onIPhoneImage(name, raw) }
                        }
                    } else {
                        guard let raw = try await newValue.loadTransferable(type: Data.self), !raw.isEmpty else {
                            throw APIError.badResponse
                        }
                        guard let uiImage = UIImage(data: raw) else { throw APIError.badResponse }
                        let prefix = Array(raw.prefix(8))
                        let payload: Data
                        let ext: String
                        if prefix.count >= 8 && prefix[0...7].elementsEqual([137, 80, 78, 71, 13, 10, 26, 10]) {
                            payload = raw; ext = "png"
                        } else if prefix.count >= 2 && prefix[0] == 0xFF && prefix[1] == 0xD8 {
                            payload = raw; ext = "jpg"
                        } else {
                            guard let jpeg = uiImage.jpegData(compressionQuality: 0.98) else { throw APIError.badResponse }
                            payload = jpeg; ext = "jpg"
                        }
                        let name = "iphone-image-\(UUID().uuidString.prefix(8)).\(ext)"
                        await MainActor.run { onIPhoneImage(name, payload) }
                    }
                } catch {
                    await MainActor.run { localError = "Не удалось импортировать медиа: \(error.localizedDescription)" }
                }
                await MainActor.run {
                    converting = false
                    photoItem = nil
                }
            }
        }
    }
}

private struct ComfyPCMediaPicker: View {
    @Environment(\.dismiss) private var dismiss
    let device: SavedDevice
    let onPick: (String) -> Void
    @State private var roots: [FileItem] = []
    @State private var loading = true
    @State private var error = ""

    var body: some View {
        NavigationStack {
            ZStack {
                ComfyBackground()
                if loading {
                    ProgressView("Загружаем диски ПК…").tint(.white).foregroundStyle(.white)
                } else {
                    List {
                        if !error.isEmpty { Text(error).foregroundStyle(.orange) }
                        ForEach(roots) { item in
                            NavigationLink {
                                ComfyPCMediaFolder(device: device, folder: item, onPick: onPick)
                            } label: {
                                Label(item.name, systemImage: "externaldrive.fill")
                            }
                        }
                    }
                    .scrollContentBackground(.hidden)
                }
            }
            .navigationTitle("Медиа с ПК")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar { ToolbarItem(placement: .cancellationAction) { Button("Закрыть") { dismiss() } } }
            .task {
                do { roots = try await APIClient(device: device).roots() }
                catch { self.error = error.localizedDescription }
                loading = false
            }
        }
    }
}

private struct ComfyPCMediaFolder: View {
    let device: SavedDevice
    let folder: FileItem
    let onPick: (String) -> Void
    @Environment(\.dismiss) private var dismiss
    @State private var items: [FileItem] = []
    @State private var loading = true
    @State private var error = ""

    private let imageExtensions = Set(["png", "jpg", "jpeg", "webp", "gif", "bmp", "tif", "tiff"])
    private let videoExtensions = Set(["mp4", "mov", "m4v", "webm", "avi", "mkv"])
    private let audioExtensions = Set(["mp3", "wav", "m4a", "aac", "flac", "ogg", "opus", "aiff", "aif", "wma"])

    var body: some View {
        List {
            if loading { ProgressView() }
            if !error.isEmpty { Text(error).foregroundStyle(.orange) }
            ForEach(items) { item in
                if item.isFolder {
                    NavigationLink {
                        ComfyPCMediaFolder(device: device, folder: item, onPick: onPick)
                    } label: {
                        Label(item.name, systemImage: "folder.fill")
                    }
                } else {
                    let ext = URL(fileURLWithPath: item.name).pathExtension.lowercased()
                    if imageExtensions.contains(ext) || videoExtensions.contains(ext) || audioExtensions.contains(ext) {
                        Button {
                            onPick(item.path)
                            dismiss()
                        } label: {
                            HStack {
                                Label(item.name, systemImage: audioExtensions.contains(ext) ? "waveform" : (videoExtensions.contains(ext) ? "film" : "photo"))
                                Spacer()
                                Image(systemName: "checkmark.circle")
                                    .foregroundStyle(.cyan)
                            }
                        }
                        .buttonStyle(.plain)
                    }
                }
            }
        }
        .scrollContentBackground(.hidden)
        .background(ComfyBackground())
        .navigationTitle(folder.name)
        .navigationBarTitleDisplayMode(.inline)
        .task {
            do {
                items = try await APIClient(device: device).list(path: folder.path)
                    .sorted { lhs, rhs in
                        if lhs.isFolder != rhs.isFolder { return lhs.isFolder && !rhs.isFolder }
                        return lhs.name.localizedCaseInsensitiveCompare(rhs.name) == .orderedAscending
                    }
            } catch { self.error = error.localizedDescription }
            loading = false
        }
    }
}

private struct ComfyStatusChip: View {
    let icon: String
    let title: String
    let value: String
    let tint: Color

    var body: some View {
        HStack(spacing: 7) {
            Image(systemName: icon)
                .font(.system(size: 12, weight: .semibold))
                .foregroundStyle(tint)
            VStack(alignment: .leading, spacing: 1) {
                Text(title)
                    .font(.system(size: 8.5, weight: .bold))
                    .foregroundStyle(.white.opacity(0.42))
                Text(value)
                    .font(.system(size: 11.5, weight: .bold, design: .rounded))
                    .foregroundStyle(.white)
            }
        }
        .padding(.horizontal, 11)
        .padding(.vertical, 8)
        .background(.ultraThinMaterial, in: RoundedRectangle(cornerRadius: 14, style: .continuous))
        .overlay(RoundedRectangle(cornerRadius: 14, style: .continuous).stroke(Color.white.opacity(0.09), lineWidth: 1))
    }
}


private struct ComfyPromptTextView: UIViewRepresentable {
    @Binding var text: String
    let onFocusChanged: (Bool) -> Void
    let onReturnGenerate: () -> Void

    func makeCoordinator() -> Coordinator {
        Coordinator(text: $text, onFocusChanged: onFocusChanged, onReturnGenerate: onReturnGenerate)
    }

    func makeUIView(context: Context) -> UITextView {
        let view = UITextView()
        view.delegate = context.coordinator
        view.backgroundColor = .clear
        view.textColor = .white
        view.tintColor = .systemCyan
        view.font = .systemFont(ofSize: 14, weight: .regular)
        view.isScrollEnabled = true
        view.keyboardDismissMode = .interactive
        view.returnKeyType = .go
        view.textContainerInset = UIEdgeInsets(top: 7, left: 6, bottom: 7, right: 6)
        view.textContainer.lineFragmentPadding = 0
        view.text = text
        return view
    }

    func updateUIView(_ uiView: UITextView, context: Context) {
        if uiView.text != text { uiView.text = text }
        context.coordinator.text = $text
        context.coordinator.onFocusChanged = onFocusChanged
        context.coordinator.onReturnGenerate = onReturnGenerate
    }

    final class Coordinator: NSObject, UITextViewDelegate {
        var text: Binding<String>
        var onFocusChanged: (Bool) -> Void
        var onReturnGenerate: () -> Void

        init(text: Binding<String>, onFocusChanged: @escaping (Bool) -> Void, onReturnGenerate: @escaping () -> Void) {
            self.text = text
            self.onFocusChanged = onFocusChanged
            self.onReturnGenerate = onReturnGenerate
        }

        func textViewDidBeginEditing(_ textView: UITextView) { onFocusChanged(true) }
        func textViewDidEndEditing(_ textView: UITextView) { onFocusChanged(false) }
        func textViewDidChange(_ textView: UITextView) { text.wrappedValue = textView.text }

        func textView(_ textView: UITextView, shouldChangeTextIn range: NSRange, replacementText replacement: String) -> Bool {
            guard replacement == "\n" else { return true }
            text.wrappedValue = textView.text
            textView.resignFirstResponder()
            onReturnGenerate()
            return false
        }
    }
}

private struct ComfyPromptTemplate: Codable, Identifiable, Hashable {
    let id: String
    let title: String
    let category: String
    let text: String
    let profile: String
    let custom: Bool
}

private struct ComfyPromptBuilderState: Codable {
    var basePrompt: String
    var selectedSingle: [String: String]
    var selectedMulti: [String]
    var appliedPrompt: String
}

private enum ComfyPromptBuilderStore {
    private static func key(_ profile: String) -> String { "pcremote.comfy.promptbuilder.\(profile)" }

    static func load(profile: String) -> ComfyPromptBuilderState? {
        guard let data = UserDefaults.standard.data(forKey: key(profile)) else { return nil }
        return try? JSONDecoder().decode(ComfyPromptBuilderState.self, from: data)
    }

    static func save(_ state: ComfyPromptBuilderState, profile: String) {
        guard let data = try? JSONEncoder().encode(state) else { return }
        UserDefaults.standard.set(data, forKey: key(profile))
    }
}

private enum ComfyPromptTemplateLibrary {
    static func normalizedProfile(_ profile: String, checkpoint: String, mediaType: String) -> String {
        let blob = "\(profile) \(checkpoint)".lowercased()
        if blob.contains("wan2.2") || blob.contains("wan 2.2") || profile == "wan22" || profile == "wan" { return "wan22" }
        if (blob.contains("z-image") || blob.contains("z_image") || blob.contains("zimage")) && blob.contains("turbo") { return "zimage_turbo" }
        if blob.contains("z-image") || blob.contains("z_image") || blob.contains("zimage") { return "zimage" }
        if blob.contains("sdxl") || blob.contains("stable diffusion xl") || profile == "sdxl" { return "sdxl" }
        if mediaType == "video" { return "wan22" }
        if mediaType == "audio" || profile == "generic_audio" { return "generic_audio" }
        return "generic_image"
    }

    static func profileTitle(_ profile: String) -> String {
        switch profile {
        case "wan22": return "WAN 2.2 · Prompt Builder"
        case "zimage_turbo": return "Z-Image Turbo · Prompt Builder"
        case "zimage": return "Z-Image · Prompt Builder"
        case "sdxl": return "SDXL · Prompt Builder"
        case "generic_audio": return "Audio · Prompt Builder"
        default: return "Image · Prompt Builder"
        }
    }

    static func categoryOrder(profile: String) -> [String] {
        switch profile {
        case "wan22":
            return ["Сцена", "Действие", "План", "Ракурс", "Движение камеры", "Движение", "Освещение", "Настроение", "Стиль"]
        case "zimage", "zimage_turbo":
            return ["Ракурс", "Освещение", "Камера", "Объектив", "Эмоция", "Взгляд", "Поза", "Инста-девушка", "Стиль", "Детали"]
        case "sdxl":
            return ["Стиль", "Ракурс", "Эмоция", "Поза", "Освещение", "Камера", "Объектив", "Инста-девушка", "Детали"]
        case "generic_audio":
            return ["Жанр", "Настроение", "Вокал", "Инструменты", "Продакшн", "Детали"]
        default:
            return ["Ракурс", "Эмоция", "Поза", "Освещение", "Камера", "Объектив", "Стиль", "Детали"]
        }
    }

    static func isExclusive(category: String) -> Bool {
        !["Детали"].contains(category)
    }

    static func builtIns(profile: String, mediaType: String) -> [ComfyPromptTemplate] {
        func t(_ id: String, _ title: String, _ category: String, _ text: String) -> ComfyPromptTemplate {
            ComfyPromptTemplate(id: id, title: title, category: category, text: text, profile: profile, custom: false)
        }

        if profile == "generic_audio" || mediaType == "audio" {
            return [
                t("audio-pop", "Pop", "Жанр", "modern polished pop production with a memorable melodic hook"),
                t("audio-cinematic", "Cinematic", "Жанр", "cinematic soundtrack with evolving dynamics and dramatic musical structure"),
                t("audio-ambient", "Ambient", "Жанр", "spacious ambient soundscape with slow evolving textures"),
                t("audio-electronic", "Electronic", "Жанр", "modern electronic production with detailed synth layers and controlled low end"),
                t("audio-energetic", "Энергично", "Настроение", "energetic uplifting mood with strong forward momentum"),
                t("audio-dark", "Тёмное", "Настроение", "dark atmospheric mood with tension and deep tonal character"),
                t("audio-emotional", "Эмоционально", "Настроение", "emotional expressive mood with a clear musical arc"),
                t("audio-instrumental", "Без вокала", "Вокал", "instrumental only, no vocals"),
                t("audio-female-vocal", "Женский вокал", "Вокал", "expressive female lead vocal with clear diction"),
                t("audio-male-vocal", "Мужской вокал", "Вокал", "expressive male lead vocal with clear diction"),
                t("audio-piano", "Piano", "Инструменты", "prominent acoustic piano with natural dynamics"),
                t("audio-guitar", "Guitar", "Инструменты", "prominent guitar part with natural articulation"),
                t("audio-orchestra", "Orchestra", "Инструменты", "full orchestral arrangement with strings, brass and cinematic percussion"),
                t("audio-clean", "Clean mix", "Продакшн", "clean professional mix, balanced frequency spectrum, controlled dynamics"),
                t("audio-wide", "Wide stereo", "Продакшн", "wide immersive stereo image with a focused center and clear depth"),
                t("audio-hi-fi", "Hi-Fi", "Детали", "high fidelity audio, low noise floor, detailed transients and natural dynamics")
            ]
        }

        let angles = [
            t("angle-eye", "Eye level", "Ракурс", "eye-level camera angle with natural perspective"),
            t("angle-close", "Close-up", "Ракурс", "close-up framing focused on the face and expression"),
            t("angle-waist", "По пояс", "Ракурс", "waist-up portrait framing with balanced negative space"),
            t("angle-full", "Полный рост", "Ракурс", "full-body framing with the complete pose clearly visible"),
            t("angle-low", "Снизу", "Ракурс", "low-angle view with confident perspective"),
            t("angle-high", "Сверху", "Ракурс", "high-angle view looking gently down toward the subject"),
            t("angle-ots", "Over shoulder", "Ракурс", "over-the-shoulder composition with cinematic depth"),
            t("angle-pov", "POV", "Ракурс", "first-person POV composition"),
            t("angle-dutch", "Dutch angle", "Ракурс", "subtle Dutch-angle composition for dynamic visual tension")
        ]
        let lights = [
            t("light-window", "Soft window", "Освещение", "soft directional window light with gentle natural shadow falloff"),
            t("light-golden", "Golden hour", "Освещение", "warm golden-hour sunlight with soft long shadows and natural skin highlights"),
            t("light-blue", "Blue hour", "Освещение", "cool blue-hour ambient light balanced with subtle warm practical lights"),
            t("light-neon", "Neon night", "Освещение", "nighttime neon practical lighting with controlled colored reflections"),
            t("light-softbox", "Studio softbox", "Освещение", "large diffused studio softbox key light with gentle fill"),
            t("light-rim", "Rim light", "Освещение", "controlled key light with a clean rim light separating the subject from the background"),
            t("light-overcast", "Overcast", "Освещение", "soft overcast daylight with low contrast and even skin illumination"),
            t("light-hard", "Hard sun", "Освещение", "hard directional sunlight with crisp graphic shadows"),
            t("light-cinema", "Cinematic", "Освещение", "cinematic key and fill balance with motivated practical lighting")
        ]
        let cameras = [
            t("cam-a7rv", "Sony A7R V", "Камера", "photographed with a Sony A7R V, realistic full-frame color response"),
            t("cam-a1", "Sony A1", "Камера", "photographed with a Sony A1, clean professional full-frame rendering"),
            t("cam-r5", "Canon EOS R5", "Камера", "photographed with a Canon EOS R5, natural full-frame rendering"),
            t("cam-z8", "Nikon Z8", "Камера", "photographed with a Nikon Z8, high-detail full-frame rendering"),
            t("cam-gfx", "Fujifilm GFX100 II", "Камера", "photographed with a Fujifilm GFX100 II, medium-format tonal depth"),
            t("cam-q3", "Leica Q3", "Камера", "photographed with a Leica Q3, refined documentary color and micro-contrast")
        ]
        let lenses = [
            t("lens-24", "24mm", "Объектив", "24mm wide-angle lens with environmental perspective"),
            t("lens-35", "35mm", "Объектив", "35mm lens with natural street-photography perspective"),
            t("lens-50", "50mm", "Объектив", "50mm lens with natural perspective and moderate depth of field"),
            t("lens-85", "85mm", "Объектив", "85mm portrait lens with flattering compression and shallow depth of field"),
            t("lens-105", "105mm", "Объектив", "105mm portrait lens with compressed background and precise facial detail"),
            t("lens-135", "135mm", "Объектив", "135mm telephoto portrait lens with strong background separation")
        ]
        let emotions = [
            t("emo-soft", "Лёгкая улыбка", "Эмоция", "a subtle relaxed smile"),
            t("emo-happy", "Счастливая", "Эмоция", "a genuinely happy expression"),
            t("emo-laugh", "Смеётся", "Эмоция", "a natural candid laugh"),
            t("emo-confident", "Уверенная", "Эмоция", "a calm confident expression"),
            t("emo-serious", "Серьёзная", "Эмоция", "a composed serious expression"),
            t("emo-thought", "Задумчивая", "Эмоция", "a thoughtful introspective expression"),
            t("emo-surprise", "Удивлённая", "Эмоция", "a subtle believable surprised expression"),
            t("emo-flirty", "Кокетливая", "Эмоция", "a playful flirtatious expression"),
            t("emo-calm", "Спокойная", "Эмоция", "a peaceful relaxed expression"),
            t("emo-sad", "Грустная", "Эмоция", "a restrained melancholic expression")
        ]
        let gazes = [
            t("gaze-camera", "В камеру", "Взгляд", "looking directly into the camera"),
            t("gaze-side", "В сторону", "Взгляд", "looking naturally off to the side"),
            t("gaze-down", "Вниз", "Взгляд", "gaze lowered slightly downward"),
            t("gaze-shoulder", "Через плечо", "Взгляд", "looking back over the shoulder toward the camera"),
            t("gaze-closed", "Глаза закрыты", "Взгляд", "eyes gently closed")
        ]
        let poses = [
            t("pose-stand", "Стоит естественно", "Поза", "standing in a relaxed natural pose"),
            t("pose-walk", "Идёт", "Поза", "walking naturally in a candid mid-step pose"),
            t("pose-sit", "Сидит", "Поза", "seated in a relaxed natural pose"),
            t("pose-wall", "У стены", "Поза", "casually leaning against a wall"),
            t("pose-pocket", "Руки в карманах", "Поза", "standing casually with hands in pockets"),
            t("pose-arms", "Скрещённые руки", "Поза", "standing confidently with arms crossed"),
            t("pose-candid", "Candid", "Поза", "an unposed candid moment with natural body language")
        ]
        let insta = [
            t("insta-mirror", "Mirror selfie", "Инста-девушка", "modern fashion mirror-selfie aesthetic in a clean stylish interior"),
            t("insta-cafe", "Café lifestyle", "Инста-девушка", "Instagram lifestyle scene at a stylish café with candid editorial energy"),
            t("insta-street", "Street fashion", "Инста-девушка", "contemporary Instagram street-fashion editorial in an urban setting"),
            t("insta-roof", "Rooftop", "Инста-девушка", "stylish rooftop lifestyle portrait with a city skyline background"),
            t("insta-lux", "Luxury lifestyle", "Инста-девушка", "polished luxury lifestyle editorial with elegant understated surroundings"),
            t("insta-travel", "Travel blogger", "Инста-девушка", "aspirational travel-blogger lifestyle photo in a distinctive destination"),
            t("insta-beach", "Beach lifestyle", "Инста-девушка", "relaxed premium beach-lifestyle editorial"),
            t("insta-night", "Night city", "Инста-девушка", "fashionable Instagram night-city portrait with practical urban lights"),
            t("insta-home", "Casual home", "Инста-девушка", "casual authentic at-home lifestyle portrait with clean natural styling"),
            t("insta-beauty", "Beauty portrait", "Инста-девушка", "premium social-media beauty portrait with refined makeup and clean composition")
        ]
        let styles = [
            t("style-photo", "Photoreal", "Стиль", "photorealistic finish with physically plausible materials and natural color response"),
            t("style-editorial", "Editorial", "Стиль", "premium fashion editorial photography with clean art direction"),
            t("style-film", "35mm film", "Стиль", "analog 35mm film aesthetic with subtle grain and restrained color response"),
            t("style-cinema", "Cinematic", "Стиль", "cinematic still with controlled contrast and filmic color grading"),
            t("style-beauty", "Beauty campaign", "Стиль", "high-end beauty campaign photography with polished but realistic skin"),
            t("style-street", "Street photo", "Стиль", "candid documentary street-photography aesthetic")
        ]
        let details = [
            t("detail-skin", "Natural skin", "Детали", "natural skin texture with visible pores and subtle imperfections"),
            t("detail-hair", "Hair detail", "Детали", "fine individual hair strands and believable hair texture"),
            t("detail-fabric", "Fabric detail", "Детали", "realistic fabric fibers, seams, folds and material response"),
            t("detail-hands", "Natural hands", "Детали", "anatomically coherent natural hands and fingers"),
            t("detail-scene", "Scene texture", "Детали", "rich believable environmental materials and subtle surface texture")
        ]

        let wan = [
            t("wan-scene-city", "Ночной город", "Сцена", "in a believable modern city street at night with clear spatial depth"),
            t("wan-scene-day", "Дневная улица", "Сцена", "on a realistic daylight street with readable foreground, midground and background"),
            t("wan-scene-interior", "Интерьер", "Сцена", "inside a realistic interior with coherent spatial layout and practical details"),
            t("wan-scene-nature", "Природа", "Сцена", "in a natural outdoor landscape with atmospheric depth and environmental motion"),
            t("wan-action-walk", "Идёт", "Действие", "the subject walks naturally through the scene in one continuous readable action"),
            t("wan-action-turn", "Поворачивается", "Действие", "the subject smoothly turns toward the camera in one continuous motion"),
            t("wan-action-look", "Поднимает взгляд", "Действие", "the subject gradually raises their gaze toward the camera"),
            t("wan-action-run", "Бежит", "Действие", "the subject runs with coherent body mechanics and believable momentum"),
            t("wan-shot-wide", "Wide", "План", "wide establishing shot with strong foreground-midground-background separation"),
            t("wan-shot-medium", "Medium", "План", "medium shot keeping body language and environment readable"),
            t("wan-shot-close", "Close-up", "План", "close-up shot focused on facial expression and subtle motion"),
            t("wan-angle-eye", "Eye level", "Ракурс", "eye-level camera angle with natural perspective"),
            t("wan-angle-low", "Low angle", "Ракурс", "low-angle camera perspective"),
            t("wan-angle-high", "High angle", "Ракурс", "high-angle camera perspective"),
            t("wan-cam-static", "Static", "Движение камеры", "the camera remains locked-off and stable throughout the shot"),
            t("wan-cam-push", "Push-in", "Движение камеры", "the camera performs one slow smooth push-in toward the subject"),
            t("wan-cam-pull", "Pull-back", "Движение камеры", "the camera slowly pulls back to reveal more of the environment"),
            t("wan-cam-pan", "Pan", "Движение камеры", "the camera performs a smooth controlled pan following the subject"),
            t("wan-cam-track", "Tracking", "Движение камеры", "the camera smoothly tracks alongside the moving subject"),
            t("wan-cam-orbit", "Orbit", "Движение камеры", "the camera performs a controlled partial orbit around the subject"),
            t("wan-motion-natural", "Natural motion", "Движение", "natural acceleration and deceleration with coherent body, hair and cloth secondary motion"),
            t("wan-motion-wind", "Лёгкий ветер", "Движение", "a gentle breeze creates subtle coherent hair, clothing and environmental motion"),
            t("wan-light-day", "Natural daylight", "Освещение", "consistent natural daylight with stable highlights and shadows across frames"),
            t("wan-light-golden", "Golden hour", "Освещение", "warm golden-hour lighting remains temporally consistent during movement"),
            t("wan-light-neon", "Neon night", "Освещение", "motivated neon practical lighting with stable colored reflections across motion"),
            t("wan-mood-calm", "Спокойно", "Настроение", "calm measured pacing and restrained cinematic mood"),
            t("wan-mood-energy", "Энергично", "Настроение", "energetic pacing with readable controlled motion"),
            t("wan-style-live", "Live action", "Стиль", "realistic live-action cinematic look with natural motion blur and coherent frames"),
            t("wan-style-film", "Film look", "Стиль", "filmic cinematic color response with subtle grain and controlled contrast")
        ]

        if profile == "wan22" { return wan }
        if profile == "sdxl" { return styles + angles + emotions + poses + lights + cameras + lenses + insta + details }
        return angles + lights + cameras + lenses + emotions + gazes + poses + insta + styles + details
    }

    static func custom(profile: String) -> [ComfyPromptTemplate] {
        guard let data = UserDefaults.standard.data(forKey: "pcremote.comfy.templates.\(profile)"),
              let values = try? JSONDecoder().decode([ComfyPromptTemplate].self, from: data) else { return [] }
        return values
    }

    static func saveCustom(_ item: ComfyPromptTemplate, profile: String) {
        var values = custom(profile: profile)
        values.insert(item, at: 0)
        if let data = try? JSONEncoder().encode(Array(values.prefix(100))) {
            UserDefaults.standard.set(data, forKey: "pcremote.comfy.templates.\(profile)")
        }
    }
}

private struct ComfyPromptTemplatesView: View {
    @Environment(\.dismiss) private var dismiss
    let profile: String
    let mediaType: String
    let checkpoint: String
    @Binding var prompt: String

    @State private var search = ""
    @State private var activeCategory = ""
    @State private var selectedSingle: [String: String] = [:]
    @State private var selectedMulti: Set<String> = []
    @State private var basePrompt = ""

    private var resolvedProfile: String {
        ComfyPromptTemplateLibrary.normalizedProfile(profile, checkpoint: checkpoint, mediaType: mediaType)
    }
    private var builtIns: [ComfyPromptTemplate] {
        ComfyPromptTemplateLibrary.builtIns(profile: resolvedProfile, mediaType: mediaType)
    }
    private var customTemplates: [ComfyPromptTemplate] {
        ComfyPromptTemplateLibrary.custom(profile: resolvedProfile)
    }
    private var categories: [String] {
        var values = ComfyPromptTemplateLibrary.categoryOrder(profile: resolvedProfile)
        if !customTemplates.isEmpty { values.append("Мои") }
        return values
    }
    private var shownTemplates: [ComfyPromptTemplate] {
        let source = activeCategory == "Мои" ? customTemplates : builtIns.filter { $0.category == activeCategory }
        guard !search.isEmpty else { return source }
        return source.filter { $0.title.localizedCaseInsensitiveContains(search) || $0.text.localizedCaseInsensitiveContains(search) }
    }
    private var previewText: String {
        var parts: [String] = []
        let clean = basePrompt.trimmingCharacters(in: .whitespacesAndNewlines)
        if !clean.isEmpty { parts.append(clean) }
        for category in categories where category != "Мои" {
            if ComfyPromptTemplateLibrary.isExclusive(category: category) {
                if let id = selectedSingle[category], let item = builtIns.first(where: { $0.id == id }) { parts.append(item.text) }
            } else {
                let values = builtIns.filter { selectedMulti.contains($0.id) && $0.category == category }
                parts.append(contentsOf: values.map(\.text))
            }
        }
        if let customID = selectedSingle["Мои"], let item = customTemplates.first(where: { $0.id == customID }) { parts.append(item.text) }
        return parts.joined(separator: resolvedProfile == "sdxl" ? ", " : ". ")
    }

    var body: some View {
        NavigationStack {
            ZStack {
                ComfyBackground()
                VStack(spacing: 11) {
                    VStack(alignment: .leading, spacing: 3) {
                        Text(ComfyPromptTemplateLibrary.profileTitle(resolvedProfile))
                            .font(.system(size: 15, weight: .bold, design: .rounded))
                        Text("Выбирай по одному пункту — Builder сам переходит к следующему шагу.")
                            .font(.system(size: 10.5, weight: .medium))
                            .foregroundStyle(.white.opacity(0.48))
                    }
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .padding(.horizontal, 14)

                    ScrollView(.horizontal, showsIndicators: false) {
                        HStack(spacing: 7) {
                            ForEach(Array(categories.enumerated()), id: \.element) { index, category in
                                Button { activeCategory = category } label: {
                                    HStack(spacing: 5) {
                                        if isCategoryComplete(category) { Image(systemName: "checkmark.circle.fill") }
                                        else { Text("\(index + 1)") }
                                        Text(category)
                                    }
                                    .font(.system(size: 10.5, weight: .bold))
                                    .foregroundStyle(.white)
                                    .padding(.horizontal, 10)
                                    .padding(.vertical, 8)
                                    .background(activeCategory == category ? Color.blue.opacity(0.75) : Color.white.opacity(0.07), in: Capsule())
                                }
                                .buttonStyle(.plain)
                            }
                        }
                        .padding(.horizontal, 14)
                    }

                    HStack(spacing: 9) {
                        Image(systemName: "magnifyingglass").foregroundStyle(.white.opacity(0.42))
                        TextField("Поиск в разделе", text: $search)
                            .foregroundStyle(.white)
                    }
                    .padding(11)
                    .background(.ultraThinMaterial, in: RoundedRectangle(cornerRadius: 14, style: .continuous))
                    .padding(.horizontal, 14)

                    HStack {
                        Text(activeCategory.isEmpty ? "Шаблоны" : activeCategory)
                            .font(.system(size: 13, weight: .bold))
                        Spacer()
                        Text(activeCategory == "Детали" ? "можно несколько" : "выбери один")
                            .font(.system(size: 9.5, weight: .bold))
                            .foregroundStyle(.cyan.opacity(0.75))
                    }
                    .padding(.horizontal, 16)

                    ScrollView(showsIndicators: false) {
                        LazyVStack(spacing: 8) {
                            ForEach(shownTemplates) { item in
                                Button { select(item) } label: {
                                    HStack(alignment: .top, spacing: 10) {
                                        Image(systemName: isSelected(item) ? "checkmark.circle.fill" : "circle")
                                            .font(.system(size: 18, weight: .semibold))
                                            .foregroundStyle(isSelected(item) ? .cyan : .white.opacity(0.28))
                                        VStack(alignment: .leading, spacing: 5) {
                                            Text(item.title)
                                                .font(.system(size: 13.5, weight: .bold, design: .rounded))
                                            Text(item.text)
                                                .font(.system(size: 10.8, weight: .medium))
                                                .foregroundStyle(.white.opacity(0.55))
                                                .multilineTextAlignment(.leading)
                                                .lineLimit(3)
                                        }
                                        Spacer(minLength: 0)
                                    }
                                    .foregroundStyle(.white)
                                    .frame(maxWidth: .infinity, alignment: .leading)
                                    .padding(12)
                                    .background(isSelected(item) ? Color.cyan.opacity(0.10) : Color.white.opacity(0.045), in: RoundedRectangle(cornerRadius: 15, style: .continuous))
                                    .overlay(RoundedRectangle(cornerRadius: 15, style: .continuous).stroke(isSelected(item) ? Color.cyan.opacity(0.35) : Color.white.opacity(0.07), lineWidth: 1))
                                }
                                .buttonStyle(.plain)
                            }
                        }
                        .padding(.horizontal, 14)
                        .padding(.bottom, 8)
                    }

                    VStack(alignment: .leading, spacing: 6) {
                        HStack {
                            Text("PREVIEW PROMPT")
                                .font(.system(size: 9.5, weight: .heavy))
                                .foregroundStyle(.cyan.opacity(0.72))
                            Spacer()
                            Button("Очистить выбор") { selectedSingle.removeAll(); selectedMulti.removeAll() }
                                .font(.system(size: 9.5, weight: .semibold))
                        }
                        Text(previewText.isEmpty ? "Выбери шаблоны…" : previewText)
                            .font(.system(size: 10.8, weight: .medium))
                            .foregroundStyle(.white.opacity(previewText.isEmpty ? 0.35 : 0.70))
                            .lineLimit(4)
                    }
                    .padding(11)
                    .background(Color.black.opacity(0.20), in: RoundedRectangle(cornerRadius: 14, style: .continuous))
                    .padding(.horizontal, 14)

                    HStack(spacing: 9) {
                        Button { moveCategory(-1) } label: {
                            Label("Назад", systemImage: "chevron.left")
                                .frame(maxWidth: .infinity)
                                .padding(.vertical, 11)
                                .background(Color.white.opacity(0.07), in: RoundedRectangle(cornerRadius: 14, style: .continuous))
                        }
                        .buttonStyle(.plain)
                        Button {
                            if isLastCategory { applyAndClose() } else { moveCategory(1) }
                        } label: {
                            Label(isLastCategory ? "Применить" : "Дальше", systemImage: isLastCategory ? "checkmark" : "chevron.right")
                                .frame(maxWidth: .infinity)
                                .padding(.vertical, 11)
                                .background(Color.blue.opacity(0.75), in: RoundedRectangle(cornerRadius: 14, style: .continuous))
                        }
                        .buttonStyle(.plain)
                    }
                    .font(.system(size: 12, weight: .bold))
                    .foregroundStyle(.white)
                    .padding(.horizontal, 14)
                    .padding(.bottom, 8)
                }
                .padding(.top, 8)
            }
            .navigationTitle("Templates")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar { ToolbarItem(placement: .navigationBarTrailing) { Button("Готово") { applyAndClose() } } }
            .onAppear {
                restoreBuilderState()
                if activeCategory.isEmpty { activeCategory = categories.first ?? "" }
            }
        }
    }

    private var isLastCategory: Bool { categories.last == activeCategory }

    private func isSelected(_ item: ComfyPromptTemplate) -> Bool {
        if item.category == "Детали" { return selectedMulti.contains(item.id) }
        if activeCategory == "Мои" { return selectedSingle["Мои"] == item.id }
        return selectedSingle[item.category] == item.id
    }

    private func isCategoryComplete(_ category: String) -> Bool {
        if category == "Детали" { return !selectedMulti.isEmpty }
        return selectedSingle[category] != nil
    }

    private func select(_ item: ComfyPromptTemplate) {
        if item.category == "Детали" {
            if selectedMulti.contains(item.id) { selectedMulti.remove(item.id) } else { selectedMulti.insert(item.id) }
            return
        }
        let key = activeCategory == "Мои" ? "Мои" : item.category
        selectedSingle[key] = item.id
        if activeCategory != "Мои" {
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.16) { moveCategory(1) }
        }
    }

    private func moveCategory(_ delta: Int) {
        guard let index = categories.firstIndex(of: activeCategory), !categories.isEmpty else { return }
        activeCategory = categories[max(0, min(categories.count - 1, index + delta))]
        search = ""
    }

    private func restoreBuilderState() {
        // If the current prompt is exactly what this builder produced last time, restore
        // the slot selections so changing Lighting/Camera/etc replaces that slot instead
        // of appending a duplicate phrase. If the user edited the prompt manually, start
        // from that edited text as a fresh base prompt.
        if let saved = ComfyPromptBuilderStore.load(profile: resolvedProfile),
           saved.appliedPrompt == prompt {
            basePrompt = saved.basePrompt
            selectedSingle = saved.selectedSingle
            selectedMulti = Set(saved.selectedMulti)
        } else {
            basePrompt = prompt
            selectedSingle.removeAll()
            selectedMulti.removeAll()
        }
    }

    private func applyAndClose() {
        let output = previewText
        prompt = output
        ComfyPromptBuilderStore.save(
            ComfyPromptBuilderState(
                basePrompt: basePrompt,
                selectedSingle: selectedSingle,
                selectedMulti: Array(selectedMulti),
                appliedPrompt: output
            ),
            profile: resolvedProfile
        )
        dismiss()
    }
}

private struct ComfySaveTemplateView: View {
    @Environment(\.dismiss) private var dismiss
    let profile: String
    let initialText: String
    @State private var name = ""
    @State private var category = "Мои"
    @State private var text: String

    init(profile: String, initialText: String) {
        self.profile = profile
        self.initialText = initialText
        _text = State(initialValue: initialText)
    }

    var body: some View {
        NavigationStack {
            Form {
                Section("Шаблон") {
                    TextField("Название", text: $name)
                    TextField("Категория", text: $category)
                    TextEditor(text: $text).frame(minHeight: 150)
                }
            }
            .scrollContentBackground(.hidden)
            .background(ComfyBackground())
            .navigationTitle("Новый template")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) { Button("Отмена") { dismiss() } }
                ToolbarItem(placement: .confirmationAction) {
                    Button("Сохранить") {
                        let item = ComfyPromptTemplate(
                            id: UUID().uuidString,
                            title: name.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty ? "Мой шаблон" : name,
                            category: category.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty ? "Мои" : category,
                            text: text,
                            profile: profile,
                            custom: true
                        )
                        ComfyPromptTemplateLibrary.saveCustom(item, profile: profile)
                        dismiss()
                    }
                    .disabled(text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
                }
            }
        }
    }
}

private struct ComfyAdvancedItem: Codable, Identifiable, Hashable {
    var id: String
    var nodeID: String
    var inputName: String
    var secondInputName: String?
    var label: String
    var kind: String
}

private enum ComfyAdvancedStore {
    static func key(_ workflowID: String) -> String { "pcremote.comfy.advanced.\(workflowID)" }

    static func load(_ workflowID: String) -> [ComfyAdvancedItem]? {
        guard let data = UserDefaults.standard.data(forKey: key(workflowID)) else { return nil }
        return try? JSONDecoder().decode([ComfyAdvancedItem].self, from: data)
    }

    static func save(_ items: [ComfyAdvancedItem], workflowID: String) {
        if let data = try? JSONEncoder().encode(items) {
            UserDefaults.standard.set(data, forKey: key(workflowID))
        }
    }
}

private struct ComfyAdvancedPanel: View {
    let device: SavedDevice
    let workflowID: String
    @State private var expanded = false
    @State private var nodes: [ComfyNodeInfo] = []
    @State private var items: [ComfyAdvancedItem] = []
    @State private var loading = false
    @State private var showPicker = false
    @State private var renameItem: ComfyAdvancedItem?
    @State private var error = ""
    @State private var commitVersions: [String: Int] = [:]
    @State private var appliedIDs: Set<String> = []

    private let client: APIClient

    init(device: SavedDevice, workflowID: String) {
        self.device = device
        self.workflowID = workflowID
        self.client = APIClient(device: device)
    }

    var body: some View {
        VStack(spacing: 9) {
            Button {
                withAnimation(.spring(response: 0.30, dampingFraction: 0.88)) { expanded.toggle() }
                if expanded && nodes.isEmpty { Task { await load() } }
            } label: {
                HStack {
                    Label("Advanced", systemImage: "slider.horizontal.3")
                        .font(.system(size: 15, weight: .bold, design: .rounded))
                    Spacer()
                    Text(items.isEmpty ? "" : "\(items.count)")
                        .font(.system(size: 10, weight: .bold))
                        .foregroundStyle(.white.opacity(0.45))
                    Image(systemName: expanded ? "chevron.up" : "chevron.down")
                        .font(.system(size: 12, weight: .bold))
                }
                .foregroundStyle(.white)
                .padding(14)
                .background(.ultraThinMaterial, in: RoundedRectangle(cornerRadius: 19, style: .continuous))
                .overlay(RoundedRectangle(cornerRadius: 19, style: .continuous).stroke(Color.white.opacity(0.10), lineWidth: 1))
            }
            .buttonStyle(.plain)

            if expanded {
                ComfyGlassCard {
                    VStack(spacing: 10) {
                        if loading {
                            ProgressView().tint(.white).padding(.vertical, 20)
                        } else {
                            ForEach(items) { item in
                                advancedRow(item)
                            }

                            Button { showPicker = true } label: {
                                Label("Добавить параметр", systemImage: "plus")
                                    .font(.system(size: 13, weight: .bold))
                                    .frame(maxWidth: .infinity)
                                    .padding(.vertical, 12)
                                    .background(Color.cyan.opacity(0.10), in: RoundedRectangle(cornerRadius: 14, style: .continuous))
                            }
                            .buttonStyle(.plain)
                        }

                        if !error.isEmpty {
                            Text(error)
                                .font(.system(size: 10.5, weight: .semibold))
                                .foregroundStyle(.orange)
                                .frame(maxWidth: .infinity, alignment: .leading)
                        }
                    }
                }
                .transition(.opacity.combined(with: .move(edge: .top)))
            }
        }
        .task { await load() }
        .sheet(isPresented: $showPicker) {
            ComfyAdvancedPicker(nodes: nodes) { selection in
                add(selection)
                showPicker = false
            }
            .preferredColorScheme(.dark)
        }
        .sheet(item: $renameItem) { item in
            ComfyRenameAdvancedView(initialName: item.label) { newName in
                if let idx = items.firstIndex(where: { $0.id == item.id }) {
                    items[idx].label = newName
                    persistItems()
                }
            }
            .preferredColorScheme(.dark)
        }
    }

    @ViewBuilder
    private func advancedRow(_ item: ComfyAdvancedItem) -> some View {
        if item.kind == "size" {
            HStack(spacing: 10) {
                VStack(alignment: .leading, spacing: 3) {
                    Text(item.label)
                        .font(.system(size: 11, weight: .bold))
                        .foregroundStyle(.white.opacity(0.52))
                    Text(sizeText(item))
                        .font(.system(size: 14, weight: .bold, design: .rounded))
                        .foregroundStyle(.white)
                }
                Spacer()
                Menu {
                    Button("1:1 · 1024×1024") { setSize(item, width: 1024, height: 1024) }
                    Button("4:3 · 1152×864") { setSize(item, width: 1152, height: 864) }
                    Button("3:4 · 864×1152") { setSize(item, width: 864, height: 1152) }
                    Button("16:9 · 1344×768") { setSize(item, width: 1344, height: 768) }
                    Button("9:16 · 768×1344") { setSize(item, width: 768, height: 1344) }
                } label: {
                    Label("Ratio", systemImage: "aspectratio")
                        .font(.system(size: 11, weight: .bold))
                        .padding(.horizontal, 10)
                        .padding(.vertical, 8)
                        .background(Color.white.opacity(0.07), in: Capsule())
                }
                .buttonStyle(.plain)
                if appliedIDs.contains(item.id) {
                    Image(systemName: "checkmark.circle.fill")
                        .font(.system(size: 14, weight: .semibold))
                        .foregroundStyle(.green)
                        .transition(.opacity)
                }
                rowMenu(item)
            }
            .padding(11)
            .background(Color.white.opacity(0.045), in: RoundedRectangle(cornerRadius: 14, style: .continuous))
        } else {
            HStack(spacing: 9) {
                VStack(alignment: .leading, spacing: 3) {
                    Text(item.label)
                        .font(.system(size: 10.5, weight: .bold))
                        .foregroundStyle(.white.opacity(0.48))
                    Text(nodeTitle(item.nodeID))
                        .font(.system(size: 8.5, weight: .semibold))
                        .foregroundStyle(.cyan.opacity(0.55))
                }
                .frame(width: 86, alignment: .leading)

                if let input = input(for: item), let options = input.options, !options.isEmpty {
                    Menu {
                        ForEach(options.prefix(200), id: \.self) { option in
                            Button(option) { setValue(item, option) }
                        }
                    } label: {
                        HStack {
                            Text(input.value.isEmpty ? "—" : input.value)
                                .lineLimit(1)
                                .truncationMode(.middle)
                            Spacer(minLength: 4)
                            Image(systemName: "chevron.down")
                        }
                        .font(.system(size: 11.5, weight: .semibold))
                        .foregroundStyle(.white)
                        .padding(10)
                        .background(Color.white.opacity(0.06), in: RoundedRectangle(cornerRadius: 11, style: .continuous))
                    }
                    .buttonStyle(.plain)
                } else if let input = input(for: item), isNumeric(input) {
                    HStack(spacing: 5) {
                        advancedStepButton(symbol: "minus", item: item, direction: -1)
                        TextField("Значение", text: valueBinding(item))
                            .keyboardType(.numbersAndPunctuation)
                            .multilineTextAlignment(.center)
                            .font(.system(size: 11.5, weight: .bold, design: .rounded))
                            .foregroundStyle(.white)
                            .frame(minWidth: 58)
                            .padding(.vertical, 9)
                            .padding(.horizontal, 4)
                            .background(Color.white.opacity(0.06), in: RoundedRectangle(cornerRadius: 10, style: .continuous))
                            .onSubmit { commit(item) }
                        advancedStepButton(symbol: "plus", item: item, direction: 1)
                    }
                } else {
                    TextField("Значение", text: valueBinding(item))
                        .font(.system(size: 12, weight: .semibold))
                        .foregroundStyle(.white)
                        .padding(10)
                        .background(Color.white.opacity(0.06), in: RoundedRectangle(cornerRadius: 11, style: .continuous))
                        .onSubmit { commit(item) }
                }

                if appliedIDs.contains(item.id) {
                    Image(systemName: "checkmark.circle.fill")
                        .font(.system(size: 14, weight: .semibold))
                        .foregroundStyle(.green)
                        .transition(.opacity)
                }
                rowMenu(item)
            }
            .padding(10)
            .background(Color.white.opacity(0.045), in: RoundedRectangle(cornerRadius: 14, style: .continuous))
        }
    }

    private func isNumeric(_ input: ComfyNodeInput) -> Bool {
        input.valueType == "int" || input.valueType == "float" || Double(input.value.replacingOccurrences(of: ",", with: ".")) != nil
    }

    @ViewBuilder
    private func advancedStepButton(symbol: String, item: ComfyAdvancedItem, direction: Double) -> some View {
        Button { adjustNumeric(item, direction: direction) } label: {
            Image(systemName: symbol)
                .font(.system(size: 12, weight: .heavy))
                .frame(width: 32, height: 36)
                .background(Color.white.opacity(0.075), in: RoundedRectangle(cornerRadius: 10, style: .continuous))
        }
        .buttonStyle(.plain)
        .accessibilityLabel(direction < 0 ? "Уменьшить \(item.label)" : "Увеличить \(item.label)")
    }

    private func numericStep(for item: ComfyAdvancedItem, input: ComfyNodeInput) -> Double {
        let key = "\(item.label) \(item.inputName)".lowercased()
        if key.contains("seed") { return 1 }
        if key.contains("step") || key.contains("batch") { return 1 }
        if key.contains("width") || key.contains("height") { return 64 }
        if key.contains("cfg") { return 0.1 }
        if key.contains("strength") || key.contains("denoise") || key.contains("lora") { return 0.05 }
        return input.valueType == "int" ? 1 : 0.1
    }

    private func adjustNumeric(_ item: ComfyAdvancedItem, direction: Double) {
        guard let input = input(for: item) else { return }
        let current = Double(input.value.replacingOccurrences(of: ",", with: ".")) ?? 0
        let step = numericStep(for: item, input: input)
        var next = current + direction * step
        let key = "\(item.label) \(item.inputName)".lowercased()
        if key.contains("strength") || key.contains("denoise") { next = min(1, max(0, next)) }
        if key.contains("step") || key.contains("batch") || key.contains("width") || key.contains("height") { next = max(1, next) }
        if key.contains("seed") { next = max(0, next) }

        let value: String
        if input.valueType == "int" || step >= 1 {
            value = String(Int64(next.rounded()))
        } else {
            let decimals = step < 0.1 ? 2 : 1
            value = String(format: "%.*f", decimals, next)
        }
        setValue(item, value)
    }

    private func rowMenu(_ item: ComfyAdvancedItem) -> some View {
        Menu {
            Button { renameItem = item } label: { Label("Переименовать", systemImage: "pencil") }
            if let index = items.firstIndex(of: item), index > 0 {
                Button { move(item, offset: -1) } label: { Label("Выше", systemImage: "arrow.up") }
            }
            if let index = items.firstIndex(of: item), index < items.count - 1 {
                Button { move(item, offset: 1) } label: { Label("Ниже", systemImage: "arrow.down") }
            }
            Button(role: .destructive) { remove(item) } label: { Label("Убрать из Advanced", systemImage: "trash") }
        } label: {
            Image(systemName: "ellipsis.circle")
                .font(.system(size: 16, weight: .semibold))
                .foregroundStyle(.white.opacity(0.50))
        }
    }

    @MainActor
    private func load() async {
        loading = true
        defer { loading = false }
        do {
            let details = try await client.comfyWorkflowDetails(workflowID: workflowID)
            nodes = details.nodes
            if let saved = ComfyAdvancedStore.load(workflowID), !saved.isEmpty {
                items = saved.filter { item in nodes.contains(where: { $0.id == item.nodeID }) }
            } else {
                items = defaults(from: nodes)
                persistItems()
            }
        } catch {
            self.error = error.localizedDescription
        }
    }

    private func defaults(from nodes: [ComfyNodeInfo]) -> [ComfyAdvancedItem] {
        var result: [ComfyAdvancedItem] = []
        if let pair = findInput(named: "steps", in: nodes) {
            result.append(.init(id: UUID().uuidString, nodeID: pair.0.id, inputName: pair.1.name, secondInputName: nil, label: "Steps", kind: "value"))
        }
        if let pair = findInput(named: "seed", in: nodes) ?? findInput(named: "noise_seed", in: nodes) {
            result.append(.init(id: UUID().uuidString, nodeID: pair.0.id, inputName: pair.1.name, secondInputName: nil, label: "Seed", kind: "value"))
        }
        if let sizeNode = nodes.first(where: { node in
            node.inputs.contains(where: { $0.name.lowercased() == "width" }) && node.inputs.contains(where: { $0.name.lowercased() == "height" })
        }) {
            result.append(.init(id: UUID().uuidString, nodeID: sizeNode.id, inputName: "width", secondInputName: "height", label: "Size", kind: "size"))
        }
        return result
    }

    private func findInput(named name: String, in nodes: [ComfyNodeInfo]) -> (ComfyNodeInfo, ComfyNodeInput)? {
        for node in nodes {
            if let input = node.inputs.first(where: { $0.name.lowercased() == name.lowercased() && !$0.isConnection }) {
                return (node, input)
            }
        }
        return nil
    }

    private func add(_ selection: ComfyAdvancedSelection) {
        let item = ComfyAdvancedItem(
            id: UUID().uuidString,
            nodeID: selection.node.id,
            inputName: selection.input.name,
            secondInputName: selection.secondInput?.name,
            label: selection.label,
            kind: selection.secondInput == nil ? "value" : "size"
        )
        guard !items.contains(where: { $0.nodeID == item.nodeID && $0.inputName == item.inputName && $0.secondInputName == item.secondInputName }) else { return }
        items.append(item)
        persistItems()
    }

    private func remove(_ item: ComfyAdvancedItem) {
        items.removeAll { $0.id == item.id }
        persistItems()
    }

    private func move(_ item: ComfyAdvancedItem, offset: Int) {
        guard let old = items.firstIndex(of: item) else { return }
        let new = max(0, min(items.count - 1, old + offset))
        guard old != new else { return }
        let value = items.remove(at: old)
        items.insert(value, at: new)
        persistItems()
    }

    private func persistItems() { ComfyAdvancedStore.save(items, workflowID: workflowID) }

    private func nodeTitle(_ id: String) -> String { nodes.first(where: { $0.id == id })?.title ?? "Node \(id)" }

    private func input(for item: ComfyAdvancedItem) -> ComfyNodeInput? {
        nodes.first(where: { $0.id == item.nodeID })?.inputs.first(where: { $0.name == item.inputName })
    }

    private func valueBinding(_ item: ComfyAdvancedItem) -> Binding<String> {
        Binding(
            get: { input(for: item)?.value ?? "" },
            set: { newValue in
                guard let ni = nodes.firstIndex(where: { $0.id == item.nodeID }),
                      let ii = nodes[ni].inputs.firstIndex(where: { $0.name == item.inputName }) else { return }
                nodes[ni].inputs[ii].value = newValue
                ComfyAdvancedDraftStore.stage(workflowID: workflowID, node: nodes[ni])
                scheduleCommit(item)
            }
        )
    }

    private func setValue(_ item: ComfyAdvancedItem, _ value: String) {
        guard let ni = nodes.firstIndex(where: { $0.id == item.nodeID }),
              let ii = nodes[ni].inputs.firstIndex(where: { $0.name == item.inputName }) else { return }
        nodes[ni].inputs[ii].value = value
        ComfyAdvancedDraftStore.stage(workflowID: workflowID, node: nodes[ni])
        commit(item)
    }

    private func scheduleCommit(_ item: ComfyAdvancedItem) {
        let next = (commitVersions[item.id] ?? 0) + 1
        commitVersions[item.id] = next
        Task {
            try? await Task.sleep(nanoseconds: 320_000_000)
            let shouldCommit = await MainActor.run { commitVersions[item.id] == next }
            guard shouldCommit else { return }
            await commitNow(item)
        }
    }

    private func commit(_ item: ComfyAdvancedItem) {
        Task { await commitNow(item) }
    }

    @MainActor
    private func commitNow(_ item: ComfyAdvancedItem) async {
        guard let node = nodes.first(where: { $0.id == item.nodeID }) else { return }
        do {
            try await client.comfyUpdateNode(workflowID: workflowID, node: node)
            error = ""
            withAnimation(.easeInOut(duration: 0.15)) { appliedIDs.insert(item.id) }
            Task {
                try? await Task.sleep(nanoseconds: 900_000_000)
                await MainActor.run { _ = withAnimation(.easeOut(duration: 0.2)) { appliedIDs.remove(item.id) } }
            }
        } catch {
            self.error = error.localizedDescription
        }
    }

    private func sizeText(_ item: ComfyAdvancedItem) -> String {
        guard let node = nodes.first(where: { $0.id == item.nodeID }) else { return "—" }
        let w = node.inputs.first(where: { $0.name == item.inputName })?.value ?? "?"
        let h = node.inputs.first(where: { $0.name == item.secondInputName })?.value ?? "?"
        return "\(w) × \(h)"
    }

    private func setSize(_ item: ComfyAdvancedItem, width: Int, height: Int) {
        guard let ni = nodes.firstIndex(where: { $0.id == item.nodeID }) else { return }
        if let wi = nodes[ni].inputs.firstIndex(where: { $0.name == item.inputName }) { nodes[ni].inputs[wi].value = "\(width)" }
        if let second = item.secondInputName, let hi = nodes[ni].inputs.firstIndex(where: { $0.name == second }) { nodes[ni].inputs[hi].value = "\(height)" }
        ComfyAdvancedDraftStore.stage(workflowID: workflowID, node: nodes[ni])
        commit(item)
    }
}

private struct ComfyAdvancedSelection {
    let node: ComfyNodeInfo
    let input: ComfyNodeInput
    let secondInput: ComfyNodeInput?
    let label: String
}

private struct ComfyAdvancedPicker: View {
    @Environment(\.dismiss) private var dismiss
    let nodes: [ComfyNodeInfo]
    let onSelect: (ComfyAdvancedSelection) -> Void
    @State private var search = ""

    private var filteredNodes: [ComfyNodeInfo] {
        guard !search.isEmpty else { return nodes }
        return nodes.filter { node in
            node.title.localizedCaseInsensitiveContains(search) || node.classType.localizedCaseInsensitiveContains(search) || node.inputs.contains(where: { $0.name.localizedCaseInsensitiveContains(search) })
        }
    }

    var body: some View {
        NavigationStack {
            List {
                ForEach(filteredNodes) { node in
                    Section(node.title) {
                        if let width = node.inputs.first(where: { $0.name.lowercased() == "width" && !$0.isConnection }),
                           let height = node.inputs.first(where: { $0.name.lowercased() == "height" && !$0.isConnection }) {
                            Button {
                                onSelect(.init(node: node, input: width, secondInput: height, label: "Size"))
                            } label: {
                                Label("Size · width + height", systemImage: "aspectratio")
                            }
                        }
                        ForEach(node.inputs.filter { !$0.isConnection }) { input in
                            Button {
                                onSelect(.init(node: node, input: input, secondInput: nil, label: input.name.replacingOccurrences(of: "_", with: " ").capitalized))
                            } label: {
                                HStack {
                                    Text(input.name)
                                    Spacer()
                                    Text(input.value)
                                        .font(.caption2)
                                        .foregroundStyle(.secondary)
                                        .lineLimit(1)
                                }
                            }
                        }
                    }
                }
            }
            .searchable(text: $search, prompt: "Нода или настройка")
            .navigationTitle("Добавить в Advanced")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar { ToolbarItem(placement: .cancellationAction) { Button("Закрыть") { dismiss() } } }
        }
    }
}

private struct ComfyRenameAdvancedView: View {
    @Environment(\.dismiss) private var dismiss
    @State private var name: String
    let onSave: (String) -> Void

    init(initialName: String, onSave: @escaping (String) -> Void) {
        _name = State(initialValue: initialName)
        self.onSave = onSave
    }

    var body: some View {
        NavigationStack {
            Form { TextField("Название", text: $name) }
                .scrollContentBackground(.hidden)
                .background(ComfyBackground())
                .navigationTitle("Переименовать")
                .navigationBarTitleDisplayMode(.inline)
                .toolbar {
                    ToolbarItem(placement: .cancellationAction) { Button("Отмена") { dismiss() } }
                    ToolbarItem(placement: .confirmationAction) {
                        Button("Готово") {
                            let clean = name.trimmingCharacters(in: .whitespacesAndNewlines)
                            onSave(clean.isEmpty ? "Parameter" : clean)
                            dismiss()
                        }
                    }
                }
        }
    }
}


struct ComfyBackground: View {
    var body: some View {
        GeometryReader { proxy in
            ZStack {
                LinearGradient(
                    colors: [
                        Color(red: 0.025, green: 0.035, blue: 0.075),
                        Color(red: 0.035, green: 0.055, blue: 0.13),
                        Color.black,
                    ],
                    startPoint: .topLeading,
                    endPoint: .bottomTrailing
                )
                Circle()
                    .fill(Color.blue.opacity(0.23))
                    .frame(width: proxy.size.width * 0.95)
                    .blur(radius: 70)
                    .offset(x: proxy.size.width * 0.35, y: -proxy.size.height * 0.32)
                Circle()
                    .fill(Color.purple.opacity(0.16))
                    .frame(width: proxy.size.width * 0.85)
                    .blur(radius: 80)
                    .offset(x: -proxy.size.width * 0.42, y: proxy.size.height * 0.15)
            }
            .ignoresSafeArea()
        }
    }
}

struct ComfyGlassCard<Content: View>: View {
    let content: Content

    init(@ViewBuilder content: () -> Content) {
        self.content = content()
    }

    var body: some View {
        content
            .padding(14)
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(
                RoundedRectangle(cornerRadius: 22, style: .continuous)
                    .fill(Color.white.opacity(0.065))
                    .background(.ultraThinMaterial, in: RoundedRectangle(cornerRadius: 22, style: .continuous))
            )
            .overlay(
                RoundedRectangle(cornerRadius: 22, style: .continuous)
                    .stroke(Color.white.opacity(0.11), lineWidth: 1)
            )
            .shadow(color: .black.opacity(0.20), radius: 18, y: 8)
    }
}

private struct ComfyMiniGraph: View {
    var body: some View {
        GeometryReader { proxy in
            let w = proxy.size.width
            let h = proxy.size.height
            ZStack {
                Path { p in
                    p.move(to: CGPoint(x: w * 0.17, y: h * 0.50))
                    p.addCurve(to: CGPoint(x: w * 0.49, y: h * 0.30), control1: CGPoint(x: w * 0.30, y: h * 0.50), control2: CGPoint(x: w * 0.34, y: h * 0.30))
                    p.move(to: CGPoint(x: w * 0.17, y: h * 0.50))
                    p.addCurve(to: CGPoint(x: w * 0.49, y: h * 0.72), control1: CGPoint(x: w * 0.30, y: h * 0.50), control2: CGPoint(x: w * 0.34, y: h * 0.72))
                    p.move(to: CGPoint(x: w * 0.64, y: h * 0.30))
                    p.addCurve(to: CGPoint(x: w * 0.84, y: h * 0.50), control1: CGPoint(x: w * 0.72, y: h * 0.30), control2: CGPoint(x: w * 0.74, y: h * 0.50))
                    p.move(to: CGPoint(x: w * 0.64, y: h * 0.72))
                    p.addCurve(to: CGPoint(x: w * 0.84, y: h * 0.50), control1: CGPoint(x: w * 0.72, y: h * 0.72), control2: CGPoint(x: w * 0.74, y: h * 0.50))
                }
                .stroke(Color.cyan.opacity(0.52), style: StrokeStyle(lineWidth: 2, lineCap: .round))

                graphNode("Load Model", x: 0.16, y: 0.50, tint: .purple, width: w, height: h)
                graphNode("Positive", x: 0.53, y: 0.30, tint: .green, width: w, height: h)
                graphNode("Negative", x: 0.53, y: 0.72, tint: .orange, width: w, height: h)
                graphNode("KSampler", x: 0.85, y: 0.50, tint: .blue, width: w, height: h)
            }
        }
        .background(Color.black.opacity(0.17), in: RoundedRectangle(cornerRadius: 15, style: .continuous))
        .overlay(RoundedRectangle(cornerRadius: 15, style: .continuous).stroke(Color.white.opacity(0.06), lineWidth: 1))
    }

    private func graphNode(_ title: String, x: CGFloat, y: CGFloat, tint: Color, width: CGFloat, height: CGFloat) -> some View {
        HStack(spacing: 5) {
            Circle().fill(tint).frame(width: 6, height: 6)
            Text(title)
                .font(.system(size: 8.5, weight: .bold))
                .foregroundStyle(.white.opacity(0.82))
                .lineLimit(1)
        }
        .padding(.horizontal, 7)
        .padding(.vertical, 6)
        .background(Color.white.opacity(0.07), in: RoundedRectangle(cornerRadius: 8, style: .continuous))
        .position(x: width * x, y: height * y)
    }
}

private struct ComfyValueCardContent: View {
    let title: String
    let value: String
    let systemImage: String
    var trailing: String? = nil

    var body: some View {
        VStack(alignment: .leading, spacing: 7) {
            HStack {
                Label(title, systemImage: systemImage)
                    .font(.system(size: 10.5, weight: .semibold))
                    .foregroundStyle(.white.opacity(0.52))
                Spacer(minLength: 3)
                if let trailing {
                    Image(systemName: trailing)
                        .font(.system(size: 9, weight: .bold))
                        .foregroundStyle(.white.opacity(0.35))
                }
            }
            Text(value)
                .font(.system(size: 14, weight: .bold, design: .rounded))
                .foregroundStyle(.white)
                .lineLimit(1)
                .minimumScaleFactor(0.7)
        }
        .padding(12)
        .frame(maxWidth: .infinity, minHeight: 76, alignment: .leading)
        .background(Color.white.opacity(0.06), in: RoundedRectangle(cornerRadius: 17, style: .continuous))
        .overlay(RoundedRectangle(cornerRadius: 17, style: .continuous).stroke(Color.white.opacity(0.08), lineWidth: 1))
    }
}

private struct ComfyValueCard: View {
    let title: String
    let value: String
    let systemImage: String
    let action: () -> Void

    var body: some View {
        Button(action: action) {
            ComfyValueCardContent(title: title, value: value, systemImage: systemImage, trailing: "arrow.clockwise")
        }
        .buttonStyle(.plain)
    }
}

private struct ComfyStepperCard: View {
    let title: String
    let value: String
    let systemImage: String
    let onMinus: () -> Void
    let onPlus: () -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: 7) {
            Label(title, systemImage: systemImage)
                .font(.system(size: 10.5, weight: .semibold))
                .foregroundStyle(.white.opacity(0.52))
            HStack(spacing: 7) {
                Button(action: onMinus) {
                    Image(systemName: "minus")
                        .frame(width: 28, height: 28)
                        .background(Color.white.opacity(0.07), in: Circle())
                }
                Text(value)
                    .font(.system(size: 14, weight: .bold, design: .rounded))
                    .frame(maxWidth: .infinity)
                Button(action: onPlus) {
                    Image(systemName: "plus")
                        .frame(width: 28, height: 28)
                        .background(Color.white.opacity(0.07), in: Circle())
                }
            }
            .foregroundStyle(.white)
        }
        .padding(12)
        .frame(maxWidth: .infinity, minHeight: 76, alignment: .leading)
        .background(Color.white.opacity(0.06), in: RoundedRectangle(cornerRadius: 17, style: .continuous))
        .overlay(RoundedRectangle(cornerRadius: 17, style: .continuous).stroke(Color.white.opacity(0.08), lineWidth: 1))
    }
}

private enum ComfyWorkflowFilter: String, CaseIterable, Identifiable {
    case recent = "Недавние"
    case favorites = "Избранные"
    case all = "Все"
    var id: String { rawValue }
}

private struct ComfyWorkflowPicker: View {
    @Environment(\.dismiss) private var dismiss
    let device: SavedDevice
    let workflows: [ComfyWorkflow]
    let selectedID: String
    let onSelect: (ComfyWorkflow) -> Void
    let onEdit: (ComfyWorkflow) -> Void
    let onReload: () -> Void

    @State private var search = ""
    @State private var filter: ComfyWorkflowFilter = .recent
    @State private var showIPhoneImporter = false
    @State private var showPCPicker = false
    @State private var importBusy = false
    @State private var importError = ""
    @AppStorage("comfy_favorite_workflows") private var favoriteRaw = ""

    private var favoriteIDs: Set<String> {
        Set(favoriteRaw.split(separator: "\n").map(String.init))
    }

    private var selectedWorkflow: ComfyWorkflow? {
        workflows.first(where: { $0.id == selectedID })
    }

    private var filtered: [ComfyWorkflow] {
        var values: [ComfyWorkflow]
        switch filter {
        case .recent:
            values = workflows.filter(\.isRecent)
            if values.isEmpty { values = Array(workflows.prefix(8)) }
        case .favorites:
            values = workflows.filter { favoriteIDs.contains($0.id) }
        case .all:
            values = workflows
        }
        let query = search.trimmingCharacters(in: .whitespacesAndNewlines)
        if !query.isEmpty {
            values = values.filter {
                $0.name.localizedCaseInsensitiveContains(query)
                || $0.source.localizedCaseInsensitiveContains(query)
            }
        }
        return values
    }

    var body: some View {
        NavigationStack {
            ZStack {
                ComfyBackground()
                VStack(spacing: 12) {
                    filterBar
                        .padding(.horizontal, 14)
                        .padding(.top, 8)

                    if filtered.isEmpty {
                        VStack(spacing: 12) {
                            Image(systemName: "circle.hexagongrid.fill")
                                .font(.system(size: 34, weight: .semibold))
                                .foregroundStyle(.cyan.opacity(0.85))
                            Text(filter == .favorites ? "Нет избранных workflow" : "Workflow не найдены")
                                .font(.system(size: 18, weight: .bold, design: .rounded))
                            Text(filter == .favorites ? "Добавьте workflow в избранное звездой." : "Нажмите +, чтобы импортировать workflow с ПК или iPhone.")
                                .font(.system(size: 12, weight: .medium))
                                .foregroundStyle(.white.opacity(0.52))
                                .multilineTextAlignment(.center)
                        }
                        .foregroundStyle(.white)
                        .padding(28)
                        .frame(maxWidth: .infinity, maxHeight: .infinity)
                    } else {
                        ScrollView(showsIndicators: false) {
                            LazyVStack(spacing: 10) {
                                ForEach(filtered) { workflow in
                                    workflowRow(workflow)
                                }
                            }
                            .padding(.horizontal, 14)
                            .padding(.bottom, 24)
                        }
                    }

                    if !importError.isEmpty {
                        Text(importError)
                            .font(.system(size: 12, weight: .semibold))
                            .foregroundStyle(.orange)
                            .padding(.horizontal, 14)
                            .padding(.bottom, 8)
                    }
                }
            }
            .navigationTitle("Workflows")
            .navigationBarTitleDisplayMode(.inline)
            .searchable(text: $search, prompt: "Найти workflow")
            .toolbar {
                ToolbarItem(placement: .navigationBarLeading) {
                    Button("Готово") { dismiss() }
                }
                ToolbarItem(placement: .navigationBarTrailing) {
                    Menu {
                        Button {
                            showPCPicker = true
                        } label: {
                            Label("Импорт с ПК", systemImage: "desktopcomputer")
                        }
                        Button {
                            showIPhoneImporter = true
                        } label: {
                            Label("Импорт с iPhone", systemImage: "iphone")
                        }
                    } label: {
                        ZStack {
                            Circle().fill(Color.blue.opacity(0.20))
                            if importBusy {
                                ProgressView().tint(.white)
                            } else {
                                Image(systemName: "plus")
                                    .font(.system(size: 17, weight: .bold))
                            }
                        }
                        .frame(width: 34, height: 34)
                    }
                    .disabled(importBusy)
                }
            }
        }
        .fileImporter(
            isPresented: $showIPhoneImporter,
            allowedContentTypes: [.json],
            allowsMultipleSelection: false
        ) { result in
            switch result {
            case .success(let urls):
                guard let url = urls.first else { return }
                importFromIPhone(url)
            case .failure(let error):
                importError = error.localizedDescription
            }
        }
        .sheet(isPresented: $showPCPicker) {
            ComfyPCWorkflowPicker(device: device) { path in
                showPCPicker = false
                importFromPC(path)
            }
            .preferredColorScheme(.dark)
        }
    }

    private var filterBar: some View {
        HStack(spacing: 7) {
            ForEach(ComfyWorkflowFilter.allCases) { item in
                Button {
                    withAnimation(.easeInOut(duration: 0.18)) { filter = item }
                } label: {
                    Text(item.rawValue)
                        .font(.system(size: 12, weight: .bold))
                        .padding(.horizontal, 11)
                        .padding(.vertical, 9)
                        .background(
                            filter == item ? Color.blue.opacity(0.75) : Color.white.opacity(0.07),
                            in: Capsule()
                        )
                }
                .buttonStyle(.plain)
            }

            Spacer(minLength: 4)

            Button {
                if let selectedWorkflow { onEdit(selectedWorkflow) }
            } label: {
                HStack(spacing: 5) {
                    Image(systemName: "slider.horizontal.3")
                    Text("Изменить")
                }
                .font(.system(size: 11, weight: .bold))
                .padding(.horizontal, 10)
                .frame(height: 38)
                .background(Color.white.opacity(0.08), in: Capsule())
            }
            .buttonStyle(.plain)
            .disabled(selectedWorkflow == nil)
            .opacity(selectedWorkflow == nil ? 0.4 : 1)
        }
        .foregroundStyle(.white)
    }

    private func workflowRow(_ workflow: ComfyWorkflow) -> some View {
        HStack(spacing: 12) {
            Button {
                onSelect(workflow)
            } label: {
                HStack(spacing: 12) {
                    ZStack {
                        RoundedRectangle(cornerRadius: 15, style: .continuous)
                            .fill(
                                LinearGradient(
                                    colors: workflow.isRecent ? [.cyan.opacity(0.82), .blue.opacity(0.86)] : [.blue.opacity(0.82), .purple.opacity(0.78)],
                                    startPoint: .topLeading,
                                    endPoint: .bottomTrailing
                                )
                            )
                            .frame(width: 50, height: 50)
                        Image(systemName: "circle.hexagongrid.fill")
                            .font(.system(size: 20, weight: .bold))
                            .foregroundStyle(.white)
                    }

                    VStack(alignment: .leading, spacing: 4) {
                        Text(workflow.name)
                            .font(.system(size: 15, weight: .bold, design: .rounded))
                            .foregroundStyle(.white)
                            .lineLimit(1)
                        HStack(spacing: 5) {
                            Text("\(workflow.nodeCount) нод")
                            Text("•")
                            Text(workflow.source)
                                .lineLimit(1)
                        }
                        .font(.system(size: 10.5, weight: .medium))
                        .foregroundStyle(.white.opacity(0.48))
                        if !workflow.canExecute {
                            Label("Редактор доступен • для запуска нужен API-format", systemImage: "info.circle")
                                .font(.system(size: 9.5, weight: .semibold))
                                .foregroundStyle(.orange.opacity(0.9))
                                .lineLimit(1)
                        }
                    }
                    Spacer(minLength: 0)
                    if workflow.id == selectedID {
                        Image(systemName: "checkmark.circle.fill")
                            .foregroundStyle(.cyan)
                    }
                }
            }
            .buttonStyle(.plain)

            VStack(spacing: 7) {
                Button {
                    toggleFavorite(workflow.id)
                } label: {
                    Image(systemName: favoriteIDs.contains(workflow.id) ? "star.fill" : "star")
                        .font(.system(size: 14, weight: .bold))
                        .foregroundStyle(favoriteIDs.contains(workflow.id) ? .yellow : .white.opacity(0.58))
                }
                .buttonStyle(.plain)

                Button {
                    onEdit(workflow)
                } label: {
                    Image(systemName: "pencil")
                        .font(.system(size: 13, weight: .bold))
                        .foregroundStyle(.white.opacity(0.72))
                }
                .buttonStyle(.plain)
            }
            .frame(width: 30)
        }
        .padding(11)
        .background(.ultraThinMaterial, in: RoundedRectangle(cornerRadius: 20, style: .continuous))
        .overlay(RoundedRectangle(cornerRadius: 20, style: .continuous).stroke(Color.white.opacity(0.09), lineWidth: 1))
    }

    private func toggleFavorite(_ id: String) {
        var values = favoriteIDs
        if values.contains(id) { values.remove(id) } else { values.insert(id) }
        favoriteRaw = values.sorted().joined(separator: "\n")
    }

    private func importFromPC(_ path: String) {
        importBusy = true
        importError = ""
        Task {
            defer { importBusy = false }
            do {
                _ = try await APIClient(device: device).comfyImportWorkflowFromPC(path: path)
                onReload()
                filter = .all
            } catch {
                importError = error.localizedDescription
            }
        }
    }

    private func importFromIPhone(_ url: URL) {
        importBusy = true
        importError = ""
        Task {
            defer { importBusy = false }
            let access = url.startAccessingSecurityScopedResource()
            defer { if access { url.stopAccessingSecurityScopedResource() } }
            do {
                let data = try Data(contentsOf: url)
                _ = try await APIClient(device: device).comfyImportWorkflowFromIPhone(filename: url.lastPathComponent, data: data)
                onReload()
                filter = .all
            } catch {
                importError = error.localizedDescription
            }
        }
    }
}

private struct ComfyPCWorkflowPicker: View {
    @Environment(\.dismiss) private var dismiss
    let device: SavedDevice
    let onPick: (String) -> Void
    @State private var roots: [FileItem] = []
    @State private var error = ""

    var body: some View {
        NavigationStack {
            List(roots) { item in
                NavigationLink(value: item) {
                    Label(item.name, systemImage: item.icon == "drive" ? "externaldrive.fill" : "folder.fill")
                }
            }
            .navigationTitle("Workflow с ПК")
            .navigationBarTitleDisplayMode(.inline)
            .navigationDestination(for: FileItem.self) { item in
                ComfyPCWorkflowFolder(device: device, folder: item, onPick: { path in
                    onPick(path)
                    dismiss()
                })
            }
            .overlay {
                if roots.isEmpty && error.isEmpty { ProgressView() }
            }
            .safeAreaInset(edge: .bottom) {
                if !error.isEmpty {
                    Text(error)
                        .font(.system(size: 12, weight: .semibold))
                        .foregroundStyle(.orange)
                        .padding(10)
                        .frame(maxWidth: .infinity)
                        .background(.ultraThinMaterial)
                }
            }
            .toolbar {
                ToolbarItem(placement: .navigationBarTrailing) {
                    Button("Отмена") { dismiss() }
                }
            }
            .task {
                do { roots = try await APIClient(device: device).roots() }
                catch { self.error = error.localizedDescription }
            }
        }
    }
}

private struct ComfyPCWorkflowFolder: View {
    let device: SavedDevice
    let folder: FileItem
    let onPick: (String) -> Void
    @State private var items: [FileItem] = []
    @State private var error = ""

    private var visibleItems: [FileItem] {
        items.filter { $0.isFolder || URL(fileURLWithPath: $0.name).pathExtension.lowercased() == "json" }
    }

    var body: some View {
        List(visibleItems) { item in
            if item.isFolder {
                NavigationLink(value: item) {
                    Label(item.name, systemImage: "folder.fill")
                }
            } else {
                Button {
                    onPick(item.path)
                } label: {
                    HStack {
                        Label(item.name, systemImage: "doc.text.fill")
                        Spacer()
                        Text("JSON")
                            .font(.caption2.bold())
                            .foregroundStyle(.secondary)
                    }
                }
            }
        }
        .navigationTitle(folder.name)
        .navigationBarTitleDisplayMode(.inline)
        .navigationDestination(for: FileItem.self) { item in
            ComfyPCWorkflowFolder(device: device, folder: item, onPick: onPick)
        }
        .overlay { if items.isEmpty && error.isEmpty { ProgressView() } }
        .safeAreaInset(edge: .bottom) {
            if !error.isEmpty { Text(error).font(.caption).foregroundStyle(.orange).padding(8) }
        }
        .task(id: folder.path) {
            do { items = try await APIClient(device: device).list(path: folder.path) }
            catch { self.error = error.localizedDescription }
        }
    }
}

@MainActor
private final class ComfyNodeEditorModel: ObservableObject {
    struct Snapshot {
        let nodes: [ComfyNodeInfo]
        let connections: [ComfyNodeConnection]
    }

    @Published var nodes: [ComfyNodeInfo] = []
    @Published var connections: [ComfyNodeConnection] = []
    @Published var loading = true
    @Published var error = ""
    @Published var executable = false
    @Published var format = ""
    @Published var catalog: [ComfyNodeCatalogItem] = []

    let device: SavedDevice
    let workflow: ComfyWorkflow
    private let client: APIClient
    private var undoStack: [Snapshot] = []
    private var redoStack: [Snapshot] = []

    init(device: SavedDevice, workflow: ComfyWorkflow) {
        self.device = device
        self.workflow = workflow
        self.client = APIClient(device: device)
    }

    var canUndo: Bool { !undoStack.isEmpty }
    var canRedo: Bool { !redoStack.isEmpty }

    func load() async {
        loading = true
        defer { loading = false }
        do {
            let value = try await client.comfyWorkflowDetails(workflowID: workflow.id)
            nodes = value.nodes
            connections = value.connections
            executable = value.executable
            format = value.format
            error = value.error ?? ""
            if catalog.isEmpty {
                await loadCatalog(force: false)
            }
        } catch {
            self.error = error.localizedDescription
        }
    }

    func refreshCatalog() async { await loadCatalog(force: true) }

    private func loadCatalog(force: Bool) async {
        do {
            let general = try await client.comfyNodeCatalog(refresh: force)
            // Always query LoRA separately. Large custom-node installations can
            // expose thousands of entries; the dedicated query guarantees that
            // the standard LoraLoader is merged into the mobile library.
            let lora = try? await client.comfyNodeCatalog(query: "lora", refresh: force)
            let exact = try? await client.comfyNodeCatalog(query: "LoraLoader", refresh: force)
            var byClass: [String: ComfyNodeCatalogItem] = [:]
            for item in general.nodes + (lora?.nodes ?? []) + (exact?.nodes ?? []) { byClass[item.classType] = item }
            if byClass["LoraLoader"] == nil, !force {
                if let forced = try? await client.comfyNodeCatalog(query: "LoraLoader", refresh: true) {
                    for item in forced.nodes { byClass[item.classType] = item }
                }
            }
            catalog = Array(byClass.values).sorted { lhs, rhs in
                if lhs.classType == "LoraLoader" && rhs.classType != "LoraLoader" { return true }
                if rhs.classType == "LoraLoader" && lhs.classType != "LoraLoader" { return false }
                if lhs.recommended != rhs.recommended { return lhs.recommended && !rhs.recommended }
                return lhs.displayName.localizedCaseInsensitiveCompare(rhs.displayName) == .orderedAscending
            }
            error = general.error ?? ""
        } catch { self.error = error.localizedDescription }
    }

    func refreshGraph() async {
        do {
            let value = try await client.comfyWorkflowDetails(workflowID: workflow.id)
            nodes = value.nodes
            connections = value.connections
            executable = value.executable
            format = value.format
        } catch {
            self.error = error.localizedDescription
        }
    }

    func updatePositionLive(nodeID: String, x: Double, y: Double) {
        guard let idx = nodes.firstIndex(where: { $0.id == nodeID }) else { return }
        nodes[idx].position_x = max(20, x)
        nodes[idx].position_y = max(20, y)
    }

    func commitPosition(nodeID: String, original: ComfyNodeInfo) async {
        guard let node = nodes.first(where: { $0.id == nodeID }) else { return }
        pushUndo(replacingCurrentNodeWith: original)
        do { try await client.comfyUpdateNode(workflowID: workflow.id, node: node) }
        catch { self.error = error.localizedDescription }
    }

    func updateSizeLive(nodeID: String, width: Double, height: Double) {
        guard let idx = nodes.firstIndex(where: { $0.id == nodeID }) else { return }
        nodes[idx].node_width = min(520, max(170, width))
        nodes[idx].node_height = min(520, max(125, height))
    }

    func commitSize(nodeID: String, original: ComfyNodeInfo) async {
        guard let node = nodes.first(where: { $0.id == nodeID }) else { return }
        pushUndo(replacingCurrentNodeWith: original)
        do { try await client.comfyUpdateNode(workflowID: workflow.id, node: node) }
        catch { self.error = error.localizedDescription }
    }

    func update(_ node: ComfyNodeInfo) async {
        guard let idx = nodes.firstIndex(where: { $0.id == node.id }) else { return }
        let old = nodes[idx]
        pushUndo(replacingCurrentNodeWith: old)
        nodes[idx] = node
        do { try await client.comfyUpdateNode(workflowID: workflow.id, node: node) }
        catch { self.error = error.localizedDescription }
    }

    func addNode(_ item: ComfyNodeCatalogItem, at point: CGPoint) async {
        do {
            _ = try await client.comfyAddNode(
                workflowID: workflow.id,
                classType: item.classType,
                x: Double(point.x),
                y: Double(point.y)
            )
            redoStack.removeAll()
            await refreshGraph()
        } catch {
            self.error = error.localizedDescription
        }
    }

    func duplicateNode(_ node: ComfyNodeInfo) async {
        do {
            var copyNode = try await client.comfyAddNode(
                workflowID: workflow.id,
                classType: node.classType,
                x: node.positionX + 42,
                y: node.positionY + 42
            )
            copyNode.title = node.title + " Copy"
            copyNode.color = node.color
            copyNode.widthMode = node.widthMode
            copyNode.muted = node.muted
            copyNode.node_width = node.nodeWidth
            copyNode.node_height = node.nodeHeight
            for idx in copyNode.inputs.indices where !copyNode.inputs[idx].isConnection {
                if let source = node.inputs.first(where: { $0.name == copyNode.inputs[idx].name && !$0.isConnection }) {
                    copyNode.inputs[idx].value = source.value
                }
            }
            try await client.comfyUpdateNode(workflowID: workflow.id, node: copyNode)
            undoStack.removeAll(); redoStack.removeAll()
            await refreshGraph()
        } catch { self.error = error.localizedDescription }
    }

    func deleteNode(_ node: ComfyNodeInfo) async {
        do {
            try await client.comfyDeleteNode(workflowID: workflow.id, nodeID: node.id)
            undoStack.removeAll()
            redoStack.removeAll()
            await refreshGraph()
        } catch {
            self.error = error.localizedDescription
        }
    }

    func connect(from node: ComfyNodeInfo, output: ComfyNodePort, to target: ComfyNodeInfo, input: ComfyNodeInput) async -> Bool {
        let before = Snapshot(nodes: nodes, connections: connections)
        do {
            try await client.comfyConnectNodes(
                workflowID: workflow.id,
                fromNode: node.id,
                fromSlot: output.slot,
                toNode: target.id,
                toInput: input.name,
                toSlot: input.slot ?? 0
            )
            undoStack.append(before)
            if undoStack.count > 80 { undoStack.removeFirst() }
            redoStack.removeAll()
            await refreshGraph()
            return true
        } catch {
            self.error = error.localizedDescription
            return false
        }
    }

    func disconnect(target: ComfyNodeInfo, input: ComfyNodeInput) async -> Bool {
        guard input.connectedFrom != nil else { return false }
        let before = Snapshot(nodes: nodes, connections: connections)
        do {
            try await client.comfyDisconnectNodes(workflowID: workflow.id, toNode: target.id, toInput: input.name)
            undoStack.append(before)
            if undoStack.count > 80 { undoStack.removeFirst() }
            redoStack.removeAll()
            await refreshGraph()
            return true
        } catch {
            self.error = error.localizedDescription
            return false
        }
    }

    func undo() async -> Bool {
        guard let previous = undoStack.popLast() else { return false }
        let current = Snapshot(nodes: nodes, connections: connections)
        redoStack.append(current)
        await applySnapshot(previous, from: current)
        return true
    }

    func redo() async -> Bool {
        guard let next = redoStack.popLast() else { return false }
        let current = Snapshot(nodes: nodes, connections: connections)
        undoStack.append(current)
        await applySnapshot(next, from: current)
        return true
    }

    private func pushUndo(replacingCurrentNodeWith oldNode: ComfyNodeInfo) {
        var previousNodes = nodes
        if let idx = previousNodes.firstIndex(where: { $0.id == oldNode.id }) {
            previousNodes[idx] = oldNode
        }
        undoStack.append(Snapshot(nodes: previousNodes, connections: connections))
        if undoStack.count > 80 { undoStack.removeFirst() }
        redoStack.removeAll()
    }

    private func applySnapshot(_ target: Snapshot, from current: Snapshot) async {
        nodes = target.nodes
        connections = target.connections
        do {
            for node in target.nodes {
                try await client.comfyUpdateNode(workflowID: workflow.id, node: node)
            }

            let currentIDs = Set(current.connections.map(\.id))
            let targetIDs = Set(target.connections.map(\.id))

            for connection in current.connections where !targetIDs.contains(connection.id) {
                if let inputName = connection.inputName {
                    try? await client.comfyDisconnectNodes(workflowID: workflow.id, toNode: connection.to, toInput: inputName)
                }
            }
            for connection in target.connections where !currentIDs.contains(connection.id) {
                guard let inputName = connection.inputName else { continue }
                try? await client.comfyConnectNodes(
                    workflowID: workflow.id,
                    fromNode: connection.from,
                    fromSlot: connection.fromSlot,
                    toNode: connection.to,
                    toInput: inputName,
                    toSlot: connection.toSlot
                )
            }
        } catch {
            self.error = error.localizedDescription
        }
    }
}

private struct ComfyConnectorDraft {
    let nodeID: String
    let port: ComfyNodePort
    var current: CGPoint
}

private struct ComfyNodeEditorView: View {
    @Environment(\.dismiss) private var dismiss
    @StateObject private var model: ComfyNodeEditorModel
    @State private var focusedNode: ComfyNodeInfo?
    @State private var showNodeBrowser = false
    @State private var connectorDraft: ComfyConnectorDraft?
    @State private var highlightedInputID: String?
    @State private var zoom: CGFloat = 1.0
    @State private var panOffset: CGSize = CGSize(width: 36, height: 36)
    @State private var panStart: CGSize = CGSize(width: 36, height: 36)
    @State private var pinchStartZoom: CGFloat?
    @State private var pinchStartPan: CGSize = .zero
    @State private var viewportSize: CGSize = .zero
    @State private var didInitialFit = false
    @State private var gestureToast = ""

    private let baseCanvasWidth: CGFloat = 2600
    private let baseCanvasHeight: CGFloat = 3400

    init(device: SavedDevice, workflow: ComfyWorkflow) {
        _model = StateObject(wrappedValue: ComfyNodeEditorModel(device: device, workflow: workflow))
    }

    private var canvasWidth: CGFloat {
        max(baseCanvasWidth, CGFloat(model.nodes.map { $0.positionX + $0.nodeWidth + 420 }.max() ?? Double(baseCanvasWidth)))
    }

    private var canvasHeight: CGFloat {
        max(baseCanvasHeight, CGFloat(model.nodes.map { $0.positionY + $0.nodeHeight + 480 }.max() ?? Double(baseCanvasHeight)))
    }

    private var visibleInsertPoint: CGPoint {
        let safeZoom = max(0.12, zoom)
        let x = (viewportSize.width * 0.5 - panOffset.width) / safeZoom
        let y = (viewportSize.height * 0.46 - panOffset.height) / safeZoom
        return CGPoint(x: max(40, x), y: max(40, y))
    }

    var body: some View {
        ZStack {
            ComfyBackground()

            if model.loading {
                ProgressView("Загружаем ноды…")
                    .tint(.white)
                    .foregroundStyle(.white)
            } else {
                VStack(spacing: 8) {
                    editorHeader
                        .padding(.horizontal, 12)
                        .padding(.top, 6)

                    GeometryReader { viewport in
                        ZStack(alignment: .topLeading) {
                            // Pan only starts on empty canvas, so moving a node never
                            // drags the whole graph at the same time.
                            Color.black.opacity(0.13)
                                .contentShape(Rectangle())
                                .gesture(
                                    DragGesture(minimumDistance: 1)
                                        .onChanged { value in
                                            panOffset = CGSize(
                                                width: panStart.width + value.translation.width,
                                                height: panStart.height + value.translation.height
                                            )
                                        }
                                        .onEnded { _ in panStart = panOffset }
                                )
                                .onTapGesture(count: 2) {
                                    fitAllNodes(viewport: viewport.size)
                                }

                            nodeCanvas
                                .frame(width: canvasWidth, height: canvasHeight, alignment: .topLeading)
                                .scaleEffect(zoom, anchor: .topLeading)
                                .offset(panOffset)
                        }
                        .coordinateSpace(name: "NodeViewport")
                        .clipShape(RoundedRectangle(cornerRadius: 18, style: .continuous))
                        .overlay(RoundedRectangle(cornerRadius: 18, style: .continuous).stroke(Color.white.opacity(0.08), lineWidth: 1))
                        .simultaneousGesture(
                            MagnificationGesture()
                                .onChanged { value in
                                    if pinchStartZoom == nil {
                                        pinchStartZoom = zoom
                                        pinchStartPan = panOffset
                                    }
                                    guard let baseZoom = pinchStartZoom else { return }
                                    let newZoom = min(2.8, max(0.12, baseZoom * value))
                                    let center = CGPoint(x: viewport.size.width / 2, y: viewport.size.height / 2)
                                    let canvasCenter = CGPoint(
                                        x: (center.x - pinchStartPan.width) / max(0.12, baseZoom),
                                        y: (center.y - pinchStartPan.height) / max(0.12, baseZoom)
                                    )
                                    zoom = newZoom
                                    panOffset = CGSize(
                                        width: center.x - canvasCenter.x * newZoom,
                                        height: center.y - canvasCenter.y * newZoom
                                    )
                                }
                                .onEnded { _ in
                                    pinchStartZoom = nil
                                    panStart = panOffset
                                }
                        )
                        .overlay(alignment: .bottomTrailing) {
                            VStack(spacing: 8) {
                                Button { changeZoom(by: 1.20, viewport: viewport.size) } label: {
                                    Image(systemName: "plus.magnifyingglass")
                                }
                                Button { changeZoom(by: 0.82, viewport: viewport.size) } label: {
                                    Image(systemName: "minus.magnifyingglass")
                                }
                                Button { fitAllNodes(viewport: viewport.size) } label: {
                                    Image(systemName: "viewfinder")
                                }
                            }
                            .font(.system(size: 16, weight: .bold))
                            .foregroundStyle(.white)
                            .padding(9)
                            .background(.ultraThinMaterial, in: RoundedRectangle(cornerRadius: 15, style: .continuous))
                            .padding(13)
                        }
                        .onAppear {
                            viewportSize = viewport.size
                            if !didInitialFit {
                                didInitialFit = true
                                DispatchQueue.main.asyncAfter(deadline: .now() + 0.08) { fitAllNodes(viewport: viewport.size) }
                            }
                        }
                        .onChange(of: viewport.size.width) { _ in viewportSize = viewport.size }
                        .onChange(of: viewport.size.height) { _ in viewportSize = viewport.size }
                    }
                    .padding(.horizontal, 8)
                    .padding(.bottom, 8)
                }
            }

            if let focusedNode {
                Color.black.opacity(0.66)
                    .ignoresSafeArea()
                    .transition(.opacity)
                    .onTapGesture { withAnimation(.spring()) { self.focusedNode = nil } }

                VStack(spacing: 8) {
                    ComfyNodeInspector(node: focusedNode) { saved in
                        Task { await model.update(saved) }
                        withAnimation(.spring(response: 0.28, dampingFraction: 0.86)) { self.focusedNode = nil }
                    } onCancel: {
                        withAnimation(.spring(response: 0.28, dampingFraction: 0.86)) { self.focusedNode = nil }
                    }
                    HStack(spacing: 8) {
                        Button {
                            let source = focusedNode
                            self.focusedNode = nil
                            Task { await model.duplicateNode(source) }
                        } label: {
                            Label("Дублировать", systemImage: "plus.square.on.square")
                                .font(.system(size: 12, weight: .bold))
                                .frame(maxWidth: .infinity)
                                .padding(.vertical, 10)
                                .background(Color.cyan.opacity(0.14), in: Capsule())
                        }
                        .buttonStyle(.plain)

                        Button(role: .destructive) {
                            let deleting = focusedNode
                            self.focusedNode = nil
                            Task { await model.deleteNode(deleting) }
                        } label: {
                            Label("Удалить", systemImage: "trash")
                                .font(.system(size: 12, weight: .bold))
                                .frame(maxWidth: .infinity)
                                .padding(.vertical, 10)
                                .background(Color.red.opacity(0.15), in: Capsule())
                        }
                        .buttonStyle(.plain)
                    }
                }
                .padding(.horizontal, 18)
                .transition(.scale(scale: 0.78).combined(with: .opacity))
                .zIndex(5)
            }

            if !gestureToast.isEmpty {
                Text(gestureToast)
                    .font(.system(size: 13, weight: .bold))
                    .foregroundStyle(.white)
                    .padding(.horizontal, 14)
                    .padding(.vertical, 9)
                    .background(.ultraThinMaterial, in: Capsule())
                    .transition(.scale.combined(with: .opacity))
                    .zIndex(8)
            }
        }
        .preferredColorScheme(.dark)
        .background(
            ComfyUndoRedoGestureLayer(
                onUndo: { Task { await performUndo() } },
                onRedo: { Task { await performRedo() } }
            )
            .frame(width: 0, height: 0)
        )
        .sheet(isPresented: $showNodeBrowser) {
            ComfyNodeBrowser(model: model) { item in
                showNodeBrowser = false
                let point = visibleInsertPoint
                Task { await model.addNode(item, at: point) }
            }
            .preferredColorScheme(.dark)
        }
        .task { await model.load() }
    }

    private var editorHeader: some View {
        HStack(spacing: 8) {
            Button { dismiss() } label: {
                Image(systemName: "chevron.left")
                    .font(.system(size: 17, weight: .bold))
                    .frame(width: 42, height: 42)
                    .background(.ultraThinMaterial, in: Circle())
            }
            .buttonStyle(.plain)

            VStack(alignment: .leading, spacing: 2) {
                Text(model.workflow.name)
                    .font(.system(size: 19, weight: .bold, design: .rounded))
                    .lineLimit(1)
                Text("Comfy graph • \(model.nodes.count) нод • \(Int(zoom * 100))%")
                    .font(.system(size: 10.5, weight: .semibold))
                    .foregroundStyle(.white.opacity(0.48))
            }
            .frame(maxWidth: .infinity, alignment: .leading)

            Button { Task { await performUndo() } } label: {
                Image(systemName: "arrow.uturn.backward")
                    .frame(width: 36, height: 36)
                    .background(Color.white.opacity(0.07), in: Circle())
            }
            .buttonStyle(.plain)
            .opacity(model.canUndo ? 1 : 0.35)

            Button { Task { await performRedo() } } label: {
                Image(systemName: "arrow.uturn.forward")
                    .frame(width: 36, height: 36)
                    .background(Color.white.opacity(0.07), in: Circle())
            }
            .buttonStyle(.plain)
            .opacity(model.canRedo ? 1 : 0.35)

            Button { showNodeBrowser = true } label: {
                Image(systemName: "plus")
                    .font(.system(size: 17, weight: .bold))
                    .frame(width: 42, height: 42)
                    .background(LinearGradient(colors: [.blue, .cyan.opacity(0.84)], startPoint: .topLeading, endPoint: .bottomTrailing), in: Circle())
            }
            .buttonStyle(.plain)
        }
        .foregroundStyle(.white)
        .overlay(alignment: .bottomLeading) {
            if !model.error.isEmpty {
                Text(model.error)
                    .font(.system(size: 9.5, weight: .semibold))
                    .foregroundStyle(.orange)
                    .offset(y: 15)
            }
        }
    }

    private var nodeCanvas: some View {
        ZStack(alignment: .topLeading) {
            ComfyFreeConnectorLayer(nodes: model.nodes, connections: model.connections, draft: connectorDraft)
                .frame(width: canvasWidth, height: canvasHeight)
                .allowsHitTesting(false)

            ForEach(model.nodes) { node in
                ComfyFreeNodeCard(
                    node: node,
                    canvasZoom: zoom,
                    activeConnectorType: connectorDraft?.port.type,
                    highlightedInputID: highlightedInputID,
                    onExpand: {
                        withAnimation(.spring(response: 0.30, dampingFraction: 0.84)) { focusedNode = node }
                    },
                    onMove: { point in
                        model.updatePositionLive(nodeID: node.id, x: Double(point.x), y: Double(point.y))
                    },
                    onMoveEnd: { original in
                        Task { await model.commitPosition(nodeID: node.id, original: original) }
                    },
                    onResize: { width, height in
                        model.updateSizeLive(nodeID: node.id, width: Double(width), height: Double(height))
                    },
                    onResizeEnd: { original in
                        Task { await model.commitSize(nodeID: node.id, original: original) }
                    },
                    onOutputDrag: { port, location in
                        connectorDraft = ComfyConnectorDraft(nodeID: node.id, port: port, current: location)
                        updateConnectorHover(from: node, port: port, at: location)
                    },
                    onOutputEnd: { port, location in
                        connectNearest(from: node, port: port, at: location)
                        connectorDraft = nil
                        highlightedInputID = nil
                    },
                    onInputTap: { input in
                        ComfyHaptics.connectorTap()
                        if input.connectedFrom != nil {
                            Task { _ = await model.disconnect(target: node, input: input) }
                        }
                    }
                )
                .frame(width: CGFloat(node.nodeWidth), height: CGFloat(node.nodeHeight))
                .position(
                    x: CGFloat(node.positionX + node.nodeWidth / 2),
                    y: CGFloat(node.positionY + node.nodeHeight / 2)
                )
            }
        }
        .frame(width: canvasWidth, height: canvasHeight, alignment: .topLeading)
        .coordinateSpace(name: "FreeNodeCanvas")
        .background(
            Canvas { context, size in
                let minor: CGFloat = 28
                let major: CGFloat = minor * 4
                var minorPath = Path()
                var x: CGFloat = 0
                while x <= size.width { minorPath.move(to: CGPoint(x: x, y: 0)); minorPath.addLine(to: CGPoint(x: x, y: size.height)); x += minor }
                var y: CGFloat = 0
                while y <= size.height { minorPath.move(to: CGPoint(x: 0, y: y)); minorPath.addLine(to: CGPoint(x: size.width, y: y)); y += minor }
                context.stroke(minorPath, with: .color(.white.opacity(0.024)), lineWidth: 0.7)
                var majorPath = Path(); x = 0
                while x <= size.width { majorPath.move(to: CGPoint(x: x, y: 0)); majorPath.addLine(to: CGPoint(x: x, y: size.height)); x += major }
                y = 0
                while y <= size.height { majorPath.move(to: CGPoint(x: 0, y: y)); majorPath.addLine(to: CGPoint(x: size.width, y: y)); y += major }
                context.stroke(majorPath, with: .color(.white.opacity(0.05)), lineWidth: 1)
            }
            .allowsHitTesting(false)
        )
    }

    private func nearestCompatibleInput(from source: ComfyNodeInfo, port: ComfyNodePort, at location: CGPoint) -> (ComfyNodeInfo, ComfyNodeInput, CGFloat)? {
        var best: (ComfyNodeInfo, ComfyNodeInput, CGFloat)?
        for node in model.nodes where node.id != source.id {
            for (index, input) in node.inputs.enumerated() where ComfyNodeGeometry.isConnectorInput(input) {
                guard ComfyNodeGeometry.compatible(outputType: port.type, inputType: input.inputType) else { continue }
                let point = ComfyNodeGeometry.inputPoint(node: node, inputIndex: index)
                let distance = hypot(point.x - location.x, point.y - location.y)
                if distance < 78, best == nil || distance < best!.2 { best = (node, input, distance) }
            }
        }
        return best
    }

    private func updateConnectorHover(from source: ComfyNodeInfo, port: ComfyNodePort, at location: CGPoint) {
        let next = nearestCompatibleInput(from: source, port: port, at: location).map { ComfyNodeGeometry.inputID(nodeID: $0.0.id, input: $0.1) }
        if next != highlightedInputID {
            highlightedInputID = next
            if next != nil { ComfyHaptics.connectorApproach() }
        }
    }

    private func connectNearest(from source: ComfyNodeInfo, port: ComfyNodePort, at location: CGPoint) {
        guard let best = nearestCompatibleInput(from: source, port: port, at: location) else {
            ComfyHaptics.connectorMiss(); return
        }
        Task {
            if await model.connect(from: source, output: port, to: best.0, input: best.1) { ComfyHaptics.connected() }
            else { ComfyHaptics.connectorMiss() }
        }
    }

    private var nodeBounds: CGRect {
        guard let first = model.nodes.first else { return CGRect(x: 0, y: 0, width: 800, height: 600) }
        var minX = CGFloat(first.positionX), minY = CGFloat(first.positionY)
        var maxX = CGFloat(first.positionX + first.nodeWidth), maxY = CGFloat(first.positionY + first.nodeHeight)
        for node in model.nodes.dropFirst() {
            minX = min(minX, CGFloat(node.positionX)); minY = min(minY, CGFloat(node.positionY))
            maxX = max(maxX, CGFloat(node.positionX + node.nodeWidth)); maxY = max(maxY, CGFloat(node.positionY + node.nodeHeight))
        }
        return CGRect(x: minX, y: minY, width: max(1, maxX - minX), height: max(1, maxY - minY)).insetBy(dx: -90, dy: -90)
    }

    private func fitAllNodes(viewport: CGSize) {
        guard !model.nodes.isEmpty else { return }
        let bounds = nodeBounds
        let target = min(1.35, max(0.12, min(max(120, viewport.width - 30) / bounds.width, max(120, viewport.height - 30) / bounds.height)))
        let nextPan = CGSize(width: viewport.width / 2 - bounds.midX * target, height: viewport.height / 2 - bounds.midY * target)
        ComfyHaptics.connectorTap()
        withAnimation(.spring(response: 0.34, dampingFraction: 0.86)) {
            zoom = target
            panOffset = nextPan
            panStart = nextPan
        }
    }

    private func changeZoom(by factor: CGFloat, viewport: CGSize) {
        let old = zoom
        let next = min(2.8, max(0.12, old * factor))
        let center = CGPoint(x: viewport.width / 2, y: viewport.height / 2)
        let canvasCenter = CGPoint(x: (center.x - panOffset.width) / old, y: (center.y - panOffset.height) / old)
        let nextPan = CGSize(width: center.x - canvasCenter.x * next, height: center.y - canvasCenter.y * next)
        withAnimation(.spring(response: 0.24, dampingFraction: 0.88)) {
            zoom = next; panOffset = nextPan; panStart = nextPan
        }
    }

    private func performUndo() async { if await model.undo() { showToast("↶ Отменено") } }
    private func performRedo() async { if await model.redo() { showToast("↷ Возвращено") } }

    private func showToast(_ text: String) {
        withAnimation(.spring()) { gestureToast = text }
        Task {
            try? await Task.sleep(nanoseconds: 700_000_000)
            await MainActor.run { withAnimation(.easeOut(duration: 0.18)) { gestureToast = "" } }
        }
    }
}

@MainActor
private enum ComfyHaptics {
    static func connectorTap() {
        let generator = UISelectionFeedbackGenerator()
        generator.prepare()
        generator.selectionChanged()
    }

    static func nodePickedUp() {
        let generator = UIImpactFeedbackGenerator(style: .medium)
        generator.prepare()
        generator.impactOccurred(intensity: 0.78)
    }

    static func connectorApproach() {
        let generator = UIImpactFeedbackGenerator(style: .rigid)
        generator.prepare()
        generator.impactOccurred(intensity: 0.52)
    }

    static func connected() {
        let generator = UINotificationFeedbackGenerator()
        generator.prepare()
        generator.notificationOccurred(.success)
    }

    static func connectorMiss() {
        let generator = UIImpactFeedbackGenerator(style: .light)
        generator.prepare()
        generator.impactOccurred(intensity: 0.45)
    }
}

private enum ComfyNodeGeometry {
    static func isConnectorInput(_ input: ComfyNodeInput) -> Bool {
        let type = input.inputType.uppercased()
        return input.isConnection || !["INT", "FLOAT", "STRING", "BOOLEAN", "COMBO", "ENUM"].contains(type)
    }

    static func compatible(outputType: String, inputType: String) -> Bool {
        let out = outputType.uppercased()
        let input = inputType.uppercased()
        return out == input || out == "*" || input == "*" || input == "ANY" || out == "ANY"
    }

    static func inputID(nodeID: String, input: ComfyNodeInput) -> String { "\(nodeID)|\(input.name)" }

    static func inputPoint(node: ComfyNodeInfo, inputIndex: Int) -> CGPoint {
        CGPoint(x: CGFloat(node.positionX + 8), y: CGFloat(node.positionY + 72 + Double(inputIndex) * 28))
    }

    static func outputPoint(node: ComfyNodeInfo, outputIndex: Int) -> CGPoint {
        CGPoint(x: CGFloat(node.positionX + node.nodeWidth - 8), y: CGFloat(node.positionY + 72 + Double(outputIndex) * 28))
    }

    static func color(for type: String?) -> Color {
        let value = (type ?? "").uppercased()
        if value.contains("MODEL") { return .purple }
        if value.contains("CLIP") { return .yellow }
        if value.contains("CONDITION") { return .orange }
        if value.contains("LATENT") { return .pink }
        if value.contains("IMAGE") { return .green }
        if value.contains("VAE") { return .blue }
        if value.contains("MASK") { return .red }
        return .cyan
    }
}

private struct ComfyFreeConnectorLayer: View {
    let nodes: [ComfyNodeInfo]
    let connections: [ComfyNodeConnection]
    let draft: ComfyConnectorDraft?

    var body: some View {
        Canvas { context, _ in
            for link in connections {
                guard let source = nodes.first(where: { $0.id == link.from }),
                      let target = nodes.first(where: { $0.id == link.to }) else { continue }
                let start = ComfyNodeGeometry.outputPoint(node: source, outputIndex: link.fromSlot)
                let targetIndex = target.inputs.firstIndex(where: { $0.name == link.inputName }) ?? link.toSlot
                let end = ComfyNodeGeometry.inputPoint(node: target, inputIndex: targetIndex)
                drawConnection(context: context, start: start, end: end, color: ComfyNodeGeometry.color(for: link.type ?? link.label))
            }

            if let draft, let source = nodes.first(where: { $0.id == draft.nodeID }) {
                let start = ComfyNodeGeometry.outputPoint(node: source, outputIndex: draft.port.slot)
                drawConnection(context: context, start: start, end: draft.current, color: ComfyNodeGeometry.color(for: draft.port.type), dashed: true)
            }
        }
    }

    private func drawConnection(context: GraphicsContext, start: CGPoint, end: CGPoint, color: Color, dashed: Bool = false) {
        let dx = max(60, abs(end.x - start.x) * 0.45)
        var path = Path()
        path.move(to: start)
        path.addCurve(
            to: end,
            control1: CGPoint(x: start.x + dx, y: start.y),
            control2: CGPoint(x: end.x - dx, y: end.y)
        )
        context.stroke(path, with: .color(color.opacity(0.16)), style: StrokeStyle(lineWidth: 8, lineCap: .round, dash: dashed ? [9, 7] : []))
        context.stroke(path, with: .color(color.opacity(0.52)), style: StrokeStyle(lineWidth: 4, lineCap: .round, dash: dashed ? [9, 7] : []))
        context.stroke(path, with: .color(color.opacity(0.96)), style: StrokeStyle(lineWidth: 1.7, lineCap: .round, dash: dashed ? [9, 7] : []))
    }
}

private struct ComfyFreeNodeCard: View {
    let node: ComfyNodeInfo
    let canvasZoom: CGFloat
    let activeConnectorType: String?
    let highlightedInputID: String?
    let onExpand: () -> Void
    let onMove: (CGPoint) -> Void
    let onMoveEnd: (ComfyNodeInfo) -> Void
    let onResize: (CGFloat, CGFloat) -> Void
    let onResizeEnd: (ComfyNodeInfo) -> Void
    let onOutputDrag: (ComfyNodePort, CGPoint) -> Void
    let onOutputEnd: (ComfyNodePort, CGPoint) -> Void
    let onInputTap: (ComfyNodeInput) -> Void

    @State private var moveOrigin: CGPoint?
    @State private var moveOriginalNode: ComfyNodeInfo?
    @State private var resizeOrigin: CGSize?
    @State private var resizeOriginalNode: ComfyNodeInfo?
    @State private var activeOutputPortID: String?
    @State private var isMoving = false

    private var tint: Color { Color(comfyHex: node.color) ?? .blue }

    var body: some View {
        ZStack(alignment: .topLeading) {
            RoundedRectangle(cornerRadius: 11, style: .continuous)
                .fill(Color(red: 0.045, green: 0.055, blue: 0.095).opacity(0.96))
                .overlay(
                    RoundedRectangle(cornerRadius: 11, style: .continuous)
                        .fill(LinearGradient(colors: [tint.opacity(0.20), .clear], startPoint: .topLeading, endPoint: .bottomTrailing))
                )
                .overlay(RoundedRectangle(cornerRadius: 11, style: .continuous).stroke(tint.opacity(node.muted ? 0.22 : 0.58), lineWidth: 1.2))
                .shadow(color: tint.opacity(node.muted ? 0.03 : (isMoving ? 0.34 : 0.18)), radius: isMoving ? 28 : 18, y: isMoving ? 14 : 8)

            VStack(alignment: .leading, spacing: 8) {
                HStack(alignment: .top, spacing: 7) {
                    HStack(alignment: .top, spacing: 7) {
                        Circle()
                            .fill(tint)
                            .frame(width: 9, height: 9)
                            .shadow(color: tint.opacity(0.95), radius: 6)
                            .padding(.top, 5)
                        VStack(alignment: .leading, spacing: 2) {
                            Text(node.title)
                                .font(.system(size: 14, weight: .bold, design: .rounded))
                                .foregroundStyle(.white)
                                .lineLimit(2)
                            Text(node.classType)
                                .font(.system(size: 9, weight: .semibold))
                                .foregroundStyle(.white.opacity(0.40))
                                .lineLimit(1)
                        }
                        Spacer(minLength: 2)
                        Image(systemName: "line.3.horizontal")
                            .font(.system(size: 10, weight: .bold))
                            .foregroundStyle(.white.opacity(isMoving ? 0.80 : 0.30))
                            .padding(.top, 4)
                    }
                    .contentShape(Rectangle())
                    .gesture(
                        DragGesture(minimumDistance: 1, coordinateSpace: .named("FreeNodeCanvas"))
                            .onChanged { drag in
                                if moveOrigin == nil {
                                    moveOrigin = CGPoint(x: CGFloat(node.positionX), y: CGFloat(node.positionY))
                                    moveOriginalNode = node
                                    isMoving = true
                                    ComfyHaptics.nodePickedUp()
                                }
                                guard let origin = moveOrigin else { return }
                                // Both startLocation/location are expressed directly in the
                                // unscaled FreeNodeCanvas coordinate space. Do not divide by zoom.
                                let dx = drag.location.x - drag.startLocation.x
                                let dy = drag.location.y - drag.startLocation.y
                                onMove(CGPoint(
                                    x: max(12, origin.x + dx),
                                    y: max(12, origin.y + dy)
                                ))
                            }
                            .onEnded { _ in
                                if let original = moveOriginalNode { onMoveEnd(original) }
                                moveOrigin = nil
                                moveOriginalNode = nil
                                isMoving = false
                            }
                    )

                    Button(action: onExpand) {
                        Image(systemName: "arrow.up.left.and.arrow.down.right")
                            .font(.system(size: 10.5, weight: .bold))
                            .frame(width: 29, height: 29)
                            .background(Color.white.opacity(0.08), in: Circle())
                    }
                    .buttonStyle(.plain)
                }

                Divider().overlay(Color.white.opacity(0.07))

                ForEach(node.inputs.filter { !$0.isConnection }.prefix(3)) { input in
                    HStack(spacing: 6) {
                        Text(input.name)
                            .font(.system(size: 9, weight: .semibold))
                            .foregroundStyle(.white.opacity(0.43))
                            .lineLimit(1)
                        Spacer(minLength: 4)
                        Text(input.value.isEmpty ? "—" : input.value)
                            .font(.system(size: 9.5, weight: .bold))
                            .foregroundStyle(.white.opacity(0.78))
                            .lineLimit(1)
                            .truncationMode(.middle)
                    }
                }

                Spacer(minLength: 0)
                if node.muted {
                    Label("Muted", systemImage: "speaker.slash.fill")
                        .font(.system(size: 9, weight: .bold))
                        .foregroundStyle(.orange)
                }
            }
            .padding(13)

            ForEach(Array(node.inputs.enumerated()), id: \.element.id) { index, input in
                if ComfyNodeGeometry.isConnectorInput(input) {
                    Button { onInputTap(input) } label: {
                        ZStack {
                            Circle().fill(Color.clear).frame(width: 42, height: 42)
                            Circle()
                                .fill(isHighlighted(input) ? Color.red : ComfyNodeGeometry.color(for: input.inputType))
                                .frame(width: isHighlighted(input) ? 19 : 15, height: isHighlighted(input) ? 19 : 15)
                                .overlay(Circle().stroke(isHighlighted(input) ? Color.white : Color.white.opacity(0.82), lineWidth: isHighlighted(input) ? 2.4 : (input.connectedFrom == nil ? 1.0 : 2.0)))
                                .shadow(color: (isHighlighted(input) ? Color.red : ComfyNodeGeometry.color(for: input.inputType)).opacity(0.96), radius: isHighlighted(input) ? 16 : (compatibleGlow(for: input) ? 9 : 5))
                                .scaleEffect(isHighlighted(input) ? 1.22 : (compatibleGlow(for: input) ? 1.08 : 1.0))
                        }
                        .contentShape(Circle())
                    }
                    .buttonStyle(.plain)
                    .position(x: 8, y: CGFloat(72 + Double(index) * 28))

                    Text(input.name)
                        .font(.system(size: 8.5, weight: .semibold))
                        .foregroundStyle(isHighlighted(input) ? Color.red : Color.white.opacity(0.62))
                        .lineLimit(1)
                        .frame(width: max(40, CGFloat(node.nodeWidth) * 0.42), alignment: .leading)
                        .position(x: max(38, CGFloat(node.nodeWidth) * 0.24), y: CGFloat(72 + Double(index) * 28))
                        .allowsHitTesting(false)
                }
            }

            ForEach(node.outputs ?? []) { port in
                ZStack {
                    Circle().fill(Color.clear).frame(width: 42, height: 42)
                    Circle()
                        .fill(ComfyNodeGeometry.color(for: port.type))
                        .frame(width: 15, height: 15)
                        .overlay(Circle().stroke(Color.white.opacity(0.82), lineWidth: 1.1))
                        .shadow(color: ComfyNodeGeometry.color(for: port.type).opacity(0.95), radius: activeOutputPortID == port.id ? 11 : 6)
                        .scaleEffect(activeOutputPortID == port.id ? 1.18 : 1.0)
                }
                .contentShape(Circle())
                .position(x: CGFloat(node.nodeWidth) - 8, y: CGFloat(72 + Double(port.slot) * 28))
                .gesture(
                    DragGesture(minimumDistance: 0, coordinateSpace: .named("FreeNodeCanvas"))
                        .onChanged { value in
                            if activeOutputPortID != port.id {
                                activeOutputPortID = port.id
                                ComfyHaptics.connectorTap()
                            }
                            onOutputDrag(port, value.location)
                        }
                        .onEnded { value in
                            onOutputEnd(port, value.location)
                            activeOutputPortID = nil
                        }
                )

                Text(port.name)
                    .font(.system(size: 8.5, weight: .semibold))
                    .foregroundStyle(.white.opacity(0.62))
                    .lineLimit(1)
                    .frame(width: max(40, CGFloat(node.nodeWidth) * 0.38), alignment: .trailing)
                    .position(x: CGFloat(node.nodeWidth) - max(38, CGFloat(node.nodeWidth) * 0.22), y: CGFloat(72 + Double(port.slot) * 28))
                    .allowsHitTesting(false)
            }

            Image(systemName: "arrow.down.right.and.arrow.up.left")
                .font(.system(size: 9, weight: .bold))
                .foregroundStyle(.white.opacity(0.42))
                .frame(width: 28, height: 28)
                .background(Color.white.opacity(0.055), in: Circle())
                .position(x: CGFloat(node.nodeWidth) - 16, y: CGFloat(node.nodeHeight) - 16)
                .gesture(
                    DragGesture(minimumDistance: 0)
                        .onChanged { value in
                            if resizeOrigin == nil {
                                resizeOrigin = CGSize(width: CGFloat(node.nodeWidth), height: CGFloat(node.nodeHeight))
                                resizeOriginalNode = node
                            }
                            guard let origin = resizeOrigin else { return }
                            onResize(origin.width + value.translation.width, origin.height + value.translation.height)
                        }
                        .onEnded { _ in
                            if let original = resizeOriginalNode { onResizeEnd(original) }
                            resizeOrigin = nil
                            resizeOriginalNode = nil
                        }
                )
        }
        .opacity(node.muted ? 0.56 : 1)
        .scaleEffect(isMoving ? 1.035 : 1.0)
        .animation(.spring(response: 0.18, dampingFraction: 0.82), value: isMoving)
        .contentShape(RoundedRectangle(cornerRadius: 11, style: .continuous))
    }

    private func isHighlighted(_ input: ComfyNodeInput) -> Bool {
        highlightedInputID == ComfyNodeGeometry.inputID(nodeID: node.id, input: input)
    }

    private func compatibleGlow(for input: ComfyNodeInput) -> Bool {
        guard let activeConnectorType else { return false }
        return ComfyNodeGeometry.compatible(outputType: activeConnectorType, inputType: input.inputType)
    }
}

private struct ComfyNodeBrowser: View {
    @Environment(\.dismiss) private var dismiss
    @ObservedObject var model: ComfyNodeEditorModel
    let onPick: (ComfyNodeCatalogItem) -> Void
    @State private var search = ""
    @State private var refreshing = false

    private var nodes: [ComfyNodeCatalogItem] { model.catalog }

    private var loraNodes: [ComfyNodeCatalogItem] {
        nodes.filter {
            let low = "\($0.displayName) \($0.classType) \($0.category)".lowercased()
            return low.contains("lora")
        }
        .sorted { lhs, rhs in
            if lhs.classType == "LoraLoader" && rhs.classType != "LoraLoader" { return true }
            if rhs.classType == "LoraLoader" && lhs.classType != "LoraLoader" { return false }
            return lhs.displayName.localizedCaseInsensitiveCompare(rhs.displayName) == .orderedAscending
        }
    }

    private var filtered: [ComfyNodeCatalogItem] {
        let clean = search.trimmingCharacters(in: .whitespacesAndNewlines)
        if clean.isEmpty {
            return nodes.sorted { lhs, rhs in
                if lhs.recommended != rhs.recommended { return lhs.recommended && !rhs.recommended }
                return lhs.displayName.localizedCaseInsensitiveCompare(rhs.displayName) == .orderedAscending
            }
        }
        let q = clean.lowercased()
        return nodes.filter { item in
            let hay = "\(item.displayName) \(item.classType) \(item.category)".lowercased()
            return hay.contains(q) || hay.split(separator: " ").contains(where: { $0.hasPrefix(q) })
        }
    }

    var body: some View {
        NavigationStack {
            ZStack {
                ComfyBackground()
                ScrollView(showsIndicators: false) {
                    LazyVStack(spacing: 9) {
                        if search.isEmpty, !loraNodes.isEmpty {
                            HStack {
                                Label("LoRA", systemImage: "wand.and.stars")
                                    .font(.system(size: 13, weight: .bold))
                                Spacer()
                                Text("\(loraNodes.count)")
                                    .font(.system(size: 11, weight: .bold))
                                    .foregroundStyle(.white.opacity(0.42))
                            }
                            .foregroundStyle(.cyan.opacity(0.86))
                            .padding(.horizontal, 14)

                            ForEach(loraNodes.prefix(16)) { item in
                                nodeRow(item)
                            }

                            HStack {
                                Label("Все ноды", systemImage: "square.grid.2x2")
                                    .font(.system(size: 13, weight: .bold))
                                Spacer()
                            }
                            .foregroundStyle(.white.opacity(0.70))
                            .padding(.horizontal, 14)
                        }
                        ForEach(filtered.prefix(600)) { item in
                            if !search.isEmpty || !loraNodes.contains(item) {
                                nodeRow(item)
                            }
                        }
                    }
                    .padding(.horizontal, 14)
                    .padding(.bottom, 30)
                }
            }
            .searchable(text: $search, prompt: "Поиск ноды: lo, load, sampler…")
            .navigationTitle("Добавить ноду")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) { Button("Закрыть") { dismiss() } }
                ToolbarItem(placement: .primaryAction) {
                    Button {
                        guard !refreshing else { return }
                        refreshing = true
                        Task {
                            await model.refreshCatalog()
                            await MainActor.run { refreshing = false }
                        }
                    } label: {
                        if refreshing {
                            ProgressView().tint(.white)
                        } else {
                            Image(systemName: "arrow.clockwise")
                        }
                    }
                    .accessibilityLabel("Обновить список нод")
                }
            }
        }
    }

    @ViewBuilder
    private func nodeRow(_ item: ComfyNodeCatalogItem) -> some View {
        Button {
            onPick(item)
            dismiss()
        } label: {
            HStack(spacing: 12) {
                RoundedRectangle(cornerRadius: 15, style: .continuous)
                    .fill(LinearGradient(colors: [.blue.opacity(0.78), .purple.opacity(0.72)], startPoint: .topLeading, endPoint: .bottomTrailing))
                    .frame(width: 48, height: 48)
                    .overlay(Image(systemName: nodeSymbol(item)).foregroundStyle(.white).font(.system(size: 19, weight: .bold)))
                VStack(alignment: .leading, spacing: 4) {
                    Text(item.displayName)
                        .font(.system(size: 14, weight: .bold, design: .rounded))
                        .foregroundStyle(.white)
                    Text("\(item.category) • \(item.classType)")
                        .font(.system(size: 10, weight: .semibold))
                        .foregroundStyle(.white.opacity(0.44))
                        .lineLimit(1)
                }
                Spacer()
                if item.classType == "LoraLoader" {
                    Text("Load LoRA")
                        .font(.system(size: 10, weight: .bold))
                        .foregroundStyle(.cyan)
                } else if item.recommended {
                    Image(systemName: "star.fill")
                        .font(.system(size: 11))
                        .foregroundStyle(.yellow)
                }
                Image(systemName: "plus.circle.fill")
                    .foregroundStyle(.cyan)
            }
            .padding(11)
            .background(.ultraThinMaterial, in: RoundedRectangle(cornerRadius: 19, style: .continuous))
            .overlay(RoundedRectangle(cornerRadius: 19, style: .continuous).stroke(Color.white.opacity(0.08), lineWidth: 1))
        }
        .buttonStyle(.plain)
    }

    private func nodeSymbol(_ item: ComfyNodeCatalogItem) -> String {
        let low = item.classType.lowercased()
        if low.contains("loadimage") { return "photo" }
        if low.contains("checkpoint") { return "brain.head.profile" }
        if low.contains("lora") { return "wand.and.stars" }
        if low.contains("sampler") { return "waveform.path.ecg" }
        if low.contains("save") { return "square.and.arrow.down" }
        if low.contains("vae") { return "circle.hexagongrid" }
        if low.contains("clip") { return "text.quote" }
        return "square.stack.3d.up.fill"
    }
}

private struct ComfyUndoRedoGestureLayer: UIViewRepresentable {
    let onUndo: () -> Void
    let onRedo: () -> Void

    func makeCoordinator() -> Coordinator { Coordinator(onUndo: onUndo, onRedo: onRedo) }

    func makeUIView(context: Context) -> UIView {
        let view = UIView(frame: .zero)
        view.isUserInteractionEnabled = false
        DispatchQueue.main.async { context.coordinator.attach(from: view) }
        return view
    }

    func updateUIView(_ uiView: UIView, context: Context) {
        context.coordinator.onUndo = onUndo
        context.coordinator.onRedo = onRedo
        DispatchQueue.main.async { context.coordinator.attach(from: uiView) }
    }

    static func dismantleUIView(_ uiView: UIView, coordinator: Coordinator) { coordinator.detach() }

    final class Coordinator: NSObject {
        var onUndo: () -> Void
        var onRedo: () -> Void
        weak var window: UIWindow?
        var undoRecognizer: UITapGestureRecognizer?
        var redoRecognizer: UITapGestureRecognizer?

        init(onUndo: @escaping () -> Void, onRedo: @escaping () -> Void) {
            self.onUndo = onUndo
            self.onRedo = onRedo
        }

        func attach(from view: UIView) {
            guard let target = view.window, target !== window else { return }
            detach()
            window = target
            let undo = UITapGestureRecognizer(target: self, action: #selector(handleUndo))
            undo.numberOfTouchesRequired = 2
            undo.numberOfTapsRequired = 2
            undo.cancelsTouchesInView = false
            let redo = UITapGestureRecognizer(target: self, action: #selector(handleRedo))
            redo.numberOfTouchesRequired = 3
            redo.numberOfTapsRequired = 1
            redo.cancelsTouchesInView = false
            target.addGestureRecognizer(undo)
            target.addGestureRecognizer(redo)
            undoRecognizer = undo
            redoRecognizer = redo
        }

        func detach() {
            if let undoRecognizer { window?.removeGestureRecognizer(undoRecognizer) }
            if let redoRecognizer { window?.removeGestureRecognizer(redoRecognizer) }
            undoRecognizer = nil
            redoRecognizer = nil
            window = nil
        }

        @objc private func handleUndo() { onUndo() }
        @objc private func handleRedo() { onRedo() }
    }
}


private struct ComfyNodeInspector: View {
    @State private var draft: ComfyNodeInfo
    let onSave: (ComfyNodeInfo) -> Void
    let onCancel: () -> Void

    private let palette = ["#6D5DFB", "#2DA8FF", "#22C55E", "#F5A623", "#EF4444", "#EC4899", "#9B59B6", "#607D8B"]

    init(node: ComfyNodeInfo, onSave: @escaping (ComfyNodeInfo) -> Void, onCancel: @escaping () -> Void) {
        _draft = State(initialValue: node)
        self.onSave = onSave
        self.onCancel = onCancel
    }

    var body: some View {
        VStack(spacing: 0) {
            HStack(spacing: 10) {
                Circle()
                    .fill(Color(comfyHex: draft.color) ?? .blue)
                    .frame(width: 12, height: 12)
                VStack(alignment: .leading, spacing: 2) {
                    Text(draft.title)
                        .font(.system(size: 19, weight: .bold, design: .rounded))
                        .lineLimit(1)
                    Text(draft.classType)
                        .font(.system(size: 10.5, weight: .semibold))
                        .foregroundStyle(.white.opacity(0.48))
                }
                Spacer()
                Button(action: onCancel) {
                    Image(systemName: "xmark")
                        .font(.system(size: 13, weight: .bold))
                        .frame(width: 34, height: 34)
                        .background(Color.white.opacity(0.08), in: Circle())
                }
                .buttonStyle(.plain)
            }
            .padding(16)

            ScrollView(showsIndicators: false) {
                VStack(alignment: .leading, spacing: 16) {
                    inspectorSection("Название") {
                        TextField("Название ноды", text: $draft.title)
                            .textFieldStyle(.plain)
                            .padding(12)
                            .background(Color.white.opacity(0.06), in: RoundedRectangle(cornerRadius: 13, style: .continuous))
                    }

                    inspectorSection("Цвет") {
                        HStack(spacing: 9) {
                            ForEach(palette, id: \.self) { hex in
                                Button {
                                    draft.color = hex
                                } label: {
                                    Circle()
                                        .fill(Color(comfyHex: hex) ?? .blue)
                                        .frame(width: 28, height: 28)
                                        .overlay(
                                            Circle().stroke(Color.white, lineWidth: draft.color.lowercased() == hex.lowercased() ? 2.5 : 0)
                                        )
                                }
                                .buttonStyle(.plain)
                            }
                        }
                    }

                    inspectorSection("Размер на полотне") {
                        HStack {
                            Label("\(Int(draft.nodeWidth)) × \(Int(draft.nodeHeight))", systemImage: "aspectratio")
                                .font(.system(size: 12, weight: .semibold))
                            Spacer()
                            Text("Меняй маркером ↘ на ноде")
                                .font(.system(size: 10, weight: .medium))
                                .foregroundStyle(.white.opacity(0.42))
                        }
                        .padding(11)
                        .background(Color.white.opacity(0.05), in: RoundedRectangle(cornerRadius: 12, style: .continuous))
                    }

                    Toggle(isOn: $draft.muted) {
                        Label("Заглушить ноду", systemImage: "speaker.slash.fill")
                            .font(.system(size: 13, weight: .bold))
                    }
                    .tint(.orange)

                    if !draft.inputs.isEmpty {
                        inspectorSection("Настройки ноды") {
                            VStack(spacing: 11) {
                                ForEach($draft.inputs) { $input in
                                    ComfyNodeInputEditor(input: $input)
                                }
                            }
                        }
                    }
                }
                .padding(.horizontal, 16)
                .padding(.bottom, 18)
            }
            .frame(maxHeight: 520)

            Button {
                onSave(draft)
            } label: {
                Label("Сохранить изменения", systemImage: "checkmark.circle.fill")
                    .font(.system(size: 15, weight: .bold))
                    .frame(maxWidth: .infinity)
                    .padding(.vertical, 13)
                    .background(
                        LinearGradient(colors: [.blue, .cyan.opacity(0.88)], startPoint: .leading, endPoint: .trailing),
                        in: RoundedRectangle(cornerRadius: 15, style: .continuous)
                    )
            }
            .buttonStyle(.plain)
            .padding(14)
        }
        .foregroundStyle(.white)
        .background(.ultraThinMaterial, in: RoundedRectangle(cornerRadius: 30, style: .continuous))
        .overlay(RoundedRectangle(cornerRadius: 30, style: .continuous).stroke(Color.white.opacity(0.14), lineWidth: 1))
        .shadow(color: .black.opacity(0.45), radius: 30, y: 15)
    }

    private func inspectorSection<Content: View>(_ title: String, @ViewBuilder content: () -> Content) -> some View {
        VStack(alignment: .leading, spacing: 8) {
            Text(title.uppercased())
                .font(.system(size: 10, weight: .bold))
                .foregroundStyle(.white.opacity(0.42))
            content()
        }
    }
}

private struct ComfyNodeInputEditor: View {
    @Binding var input: ComfyNodeInput

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack {
                Text(input.name)
                    .font(.system(size: 11, weight: .bold))
                    .foregroundStyle(.white.opacity(0.62))
                Spacer()
                if input.isConnection {
                    Label("Connector", systemImage: "link")
                        .font(.system(size: 9, weight: .semibold))
                        .foregroundStyle(.cyan)
                }
            }

            if input.isConnection {
                Text(input.value)
                    .font(.system(size: 12, weight: .semibold))
                    .foregroundStyle(.white.opacity(0.45))
                    .padding(10)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .background(Color.white.opacity(0.04), in: RoundedRectangle(cornerRadius: 11, style: .continuous))
            } else if input.valueType == "bool" {
                Toggle("", isOn: Binding(
                    get: { ["true", "1", "yes", "on", "да"].contains(input.value.lowercased()) },
                    set: { input.value = $0 ? "true" : "false" }
                ))
                .labelsHidden()
                .tint(.blue)
            } else if let options = input.options, !options.isEmpty {
                Menu {
                    ForEach(options, id: \.self) { option in
                        Button(option) { input.value = option }
                    }
                } label: {
                    HStack {
                        Text(input.value.isEmpty ? "Выбрать" : input.value)
                            .lineLimit(1)
                        Spacer()
                        Image(systemName: "chevron.up.chevron.down")
                    }
                    .font(.system(size: 12, weight: .semibold))
                    .padding(10)
                    .background(Color.white.opacity(0.06), in: RoundedRectangle(cornerRadius: 11, style: .continuous))
                }
                .buttonStyle(.plain)
            } else {
                TextField("Значение", text: $input.value, axis: input.valueType == "string" ? .vertical : .horizontal)
                    .keyboardType((input.valueType == "int" || input.valueType == "float") ? .numbersAndPunctuation : .default)
                    .font(.system(size: 12, weight: .semibold))
                    .padding(10)
                    .background(Color.white.opacity(0.06), in: RoundedRectangle(cornerRadius: 11, style: .continuous))
            }
        }
    }
}

private extension Color {
    init?(comfyHex: String) {
        var value = comfyHex.trimmingCharacters(in: .whitespacesAndNewlines)
        if value.hasPrefix("#") { value.removeFirst() }
        guard value.count == 6, let rgb = Int(value, radix: 16) else { return nil }
        self.init(
            red: Double((rgb >> 16) & 0xFF) / 255.0,
            green: Double((rgb >> 8) & 0xFF) / 255.0,
            blue: Double(rgb & 0xFF) / 255.0
        )
    }
}


private final class ComfyImageMemoryCache {
    static let shared = ComfyImageMemoryCache()
    let images = NSCache<NSString, UIImage>()
}

private struct ComfyRemoteImage: View {
    let device: SavedDevice
    let item: ComfyImageItem
    @State private var image: UIImage?
    @State private var failed = false

    var body: some View {
        ZStack {
            Color.white.opacity(0.045)
            if item.isAudio {
                LinearGradient(colors: [Color.purple.opacity(0.34), Color.black.opacity(0.76)], startPoint: .topLeading, endPoint: .bottomTrailing)
                VStack(spacing: 9) {
                    Image(systemName: "waveform.circle.fill")
                        .font(.system(size: 38, weight: .semibold))
                        .foregroundStyle(.cyan.opacity(0.88))
                    Text(item.filename)
                        .font(.system(size: 10, weight: .semibold))
                        .foregroundStyle(.white.opacity(0.62))
                        .lineLimit(1)
                        .truncationMode(.middle)
                        .padding(.horizontal, 8)
                }
            } else if item.isVideo {
                LinearGradient(colors: [Color.indigo.opacity(0.38), Color.black.opacity(0.72)], startPoint: .topLeading, endPoint: .bottomTrailing)
                Image(systemName: "film.fill")
                    .font(.system(size: 32, weight: .semibold))
                    .foregroundStyle(.white.opacity(0.72))
            } else if let image {
                Image(uiImage: image)
                    .resizable()
                    .scaledToFill()
            } else if failed {
                Image(systemName: "exclamationmark.triangle")
                    .font(.system(size: 28))
                    .foregroundStyle(.white.opacity(0.35))
            } else {
                ProgressView().tint(.white)
            }
        }
        .task(id: cacheKey as String) {
            if !item.isVideo && !item.isAudio { await load() }
        }
    }

    private var cacheKey: NSString { "\(device.storageKey)|\(item.id)" as NSString }

    @MainActor
    private func load() async {
        if let cached = ComfyImageMemoryCache.shared.images.object(forKey: cacheKey) {
            image = cached
            return
        }
        do {
            let data = try await APIClient(device: device).comfyImageData(item)
            guard let loaded = UIImage(data: data) else { throw APIError.badResponse }
            ComfyImageMemoryCache.shared.images.setObject(loaded, forKey: cacheKey)
            image = loaded
        } catch {
            failed = true
        }
    }
}

private struct ComfyResultViewer: View {
    @Environment(\.dismiss) private var dismiss
    let device: SavedDevice
    let items: [ComfyImageItem]
    let initialItem: ComfyImageItem
    let onEdit: (ComfyImageItem) -> Void
    @State private var index: Int

    init(device: SavedDevice, items: [ComfyImageItem], initialItem: ComfyImageItem, onEdit: @escaping (ComfyImageItem) -> Void) {
        self.device = device
        self.items = items
        self.initialItem = initialItem
        self.onEdit = onEdit
        _index = State(initialValue: items.firstIndex(of: initialItem) ?? 0)
    }

    var body: some View {
        ZStack {
            Color.black.ignoresSafeArea()
            if items.isEmpty {
                Text("Результат недоступен").foregroundStyle(.white.opacity(0.7))
            } else {
                TabView(selection: $index) {
                    ForEach(Array(items.enumerated()), id: \.element.id) { idx, item in
                        ComfyResultPage(
                            device: device,
                            item: item,
                            position: "\(idx + 1) / \(items.count)",
                            onClose: { dismiss() },
                            onEdit: { onEdit(item) }
                        )
                        .tag(idx)
                    }
                }
                .tabViewStyle(.page(indexDisplayMode: .never))
            }
        }
    }
}

private struct ComfyResultPage: View {
    let device: SavedDevice
    let item: ComfyImageItem
    let position: String
    let onClose: () -> Void
    let onEdit: () -> Void

    @State private var image: UIImage?
    @State private var videoURL: URL?
    @State private var audioURL: URL?
    @State private var player: AVPlayer?
    @State private var isPlaying = false
    @State private var errorMessage = ""
    @State private var showShare = false

    var body: some View {
        ZStack {
            Color.black.ignoresSafeArea()

            if item.isAudio, let player {
                VStack(spacing: 22) {
                    Spacer()
                    ZStack {
                        Circle()
                            .fill(LinearGradient(colors: [Color.purple.opacity(0.72), Color.cyan.opacity(0.42)], startPoint: .topLeading, endPoint: .bottomTrailing))
                            .frame(width: 150, height: 150)
                        Image(systemName: "waveform")
                            .font(.system(size: 62, weight: .medium))
                            .foregroundStyle(.white)
                    }
                    Text(item.filename)
                        .font(.system(size: 16, weight: .bold, design: .rounded))
                        .foregroundStyle(.white)
                        .lineLimit(2)
                        .multilineTextAlignment(.center)
                        .padding(.horizontal, 28)
                    Button {
                        if isPlaying {
                            player.pause()
                        } else {
                            player.play()
                        }
                        isPlaying.toggle()
                    } label: {
                        Image(systemName: isPlaying ? "pause.fill" : "play.fill")
                            .font(.system(size: 28, weight: .bold))
                            .foregroundStyle(.black)
                            .frame(width: 68, height: 68)
                            .background(Color.white, in: Circle())
                    }
                    .buttonStyle(.plain)
                    Text("Audio • \(item.fileExtension.uppercased())")
                        .font(.system(size: 12, weight: .semibold))
                        .foregroundStyle(.white.opacity(0.55))
                    Spacer()
                }
                .frame(maxWidth: .infinity, maxHeight: .infinity)
                .background(LinearGradient(colors: [Color.purple.opacity(0.18), Color.black], startPoint: .top, endPoint: .bottom))
                .onDisappear { player.pause(); isPlaying = false }
            } else if item.isVideo, let player {
                VideoPlayer(player: player)
                    .ignoresSafeArea(edges: .horizontal)
                    .onAppear { player.play(); isPlaying = true }
                    .onDisappear { player.pause(); isPlaying = false }
            } else if let image {
                ZoomableImage(image: image)
                    .ignoresSafeArea(edges: .horizontal)
            } else {
                ProgressView("Загружаем результат…")
                    .tint(.white)
                    .foregroundStyle(.white)
            }

            VStack {
                HStack(spacing: 10) {
                    Button { player?.pause(); onClose() } label: {
                        Image(systemName: "xmark")
                            .font(.system(size: 16, weight: .bold))
                            .frame(width: 42, height: 42)
                            .background(.ultraThinMaterial, in: Circle())
                    }
                    Spacer()
                    Text(position)
                        .font(.system(size: 12, weight: .bold, design: .rounded))
                        .padding(.horizontal, 11)
                        .padding(.vertical, 7)
                        .background(.ultraThinMaterial, in: Capsule())
                    Spacer()
                    if image != nil || videoURL != nil || audioURL != nil {
                        if audioURL == nil {
                            Button { save() } label: {
                                Image(systemName: "square.and.arrow.down")
                                    .frame(width: 42, height: 42)
                                    .background(.ultraThinMaterial, in: Circle())
                            }
                        }
                        Button { showShare = true } label: {
                            Image(systemName: "square.and.arrow.up")
                                .frame(width: 42, height: 42)
                                .background(.ultraThinMaterial, in: Circle())
                        }
                    }
                }
                .foregroundStyle(.white)
                .padding(.horizontal, 14)
                .padding(.top, 8)

                Spacer()

                VStack(spacing: 9) {
                    Button {
                        player?.pause()
                        onEdit()
                    } label: {
                        Label("Изменить", systemImage: "slider.horizontal.3")
                            .font(.system(size: 14, weight: .bold))
                            .padding(.horizontal, 18)
                            .padding(.vertical, 11)
                            .background(.ultraThinMaterial, in: Capsule())
                    }
                    .buttonStyle(.plain)

                    if !errorMessage.isEmpty {
                        Text(errorMessage)
                            .font(.system(size: 12, weight: .semibold))
                            .foregroundStyle(.orange)
                            .padding(10)
                            .background(.ultraThinMaterial, in: Capsule())
                    }
                }
                .foregroundStyle(.white)
                .padding(.bottom, 16)
            }
        }
        .task(id: item.id) { await load() }
        .sheet(isPresented: $showShare) {
            if let audioURL { ActivityView(items: [audioURL]) }
            else if let videoURL { ActivityView(items: [videoURL]) }
            else if let image { ActivityView(items: [image]) }
        }
    }

    @MainActor
    private func load() async {
        image = nil
        player?.pause(); player = nil; videoURL = nil; audioURL = nil; isPlaying = false; errorMessage = ""
        do {
            let data = try await APIClient(device: device).comfyImageData(item)
            if item.isAudio {
                let ext = item.fileExtension.isEmpty ? "wav" : item.fileExtension
                let url = FileManager.default.temporaryDirectory.appendingPathComponent("ComfyRemote-audio-\(UUID().uuidString).\(ext)")
                try data.write(to: url, options: .atomic)
                audioURL = url
                player = AVPlayer(url: url)
            } else if item.isVideo {
                let ext = item.fileExtension.isEmpty ? "mp4" : item.fileExtension
                let url = FileManager.default.temporaryDirectory.appendingPathComponent("ComfyRemote-\(UUID().uuidString).\(ext)")
                try data.write(to: url, options: .atomic)
                videoURL = url
                player = AVPlayer(url: url)
            } else {
                guard let value = UIImage(data: data) else { throw APIError.badResponse }
                image = value
            }
        } catch { errorMessage = error.localizedDescription }
    }

    private func save() {
        if audioURL != nil { showShare = true }
        else if let videoURL { UISaveVideoAtPathToSavedPhotosAlbum(videoURL.path, nil, nil, nil) }
        else if let image { UIImageWriteToSavedPhotosAlbum(image, nil, nil, nil) }
    }
}

private struct ZoomableImage: View {
    let image: UIImage
    @State private var scale: CGFloat = 1
    @State private var lastScale: CGFloat = 1
    @State private var offset: CGSize = .zero
    @State private var lastOffset: CGSize = .zero

    var body: some View {
        Image(uiImage: image)
            .resizable()
            .scaledToFit()
            .scaleEffect(scale)
            .offset(offset)
            .gesture(
                MagnificationGesture()
                    .onChanged { value in
                        scale = max(1, min(5, lastScale * value))
                    }
                    .onEnded { _ in
                        lastScale = scale
                        if scale <= 1.01 {
                            withAnimation(.spring(response: 0.3, dampingFraction: 0.85)) {
                                scale = 1
                                lastScale = 1
                                offset = .zero
                                lastOffset = .zero
                            }
                        }
                    }
            )
            .simultaneousGesture(
                DragGesture()
                    .onChanged { value in
                        guard scale > 1 else { return }
                        offset = CGSize(width: lastOffset.width + value.translation.width, height: lastOffset.height + value.translation.height)
                    }
                    .onEnded { _ in lastOffset = offset }
            )
    }
}

private struct ActivityView: UIViewControllerRepresentable {
    let items: [Any]

    func makeUIViewController(context: Context) -> UIActivityViewController {
        UIActivityViewController(activityItems: items, applicationActivities: nil)
    }

    func updateUIViewController(_ uiViewController: UIActivityViewController, context: Context) { }
}
