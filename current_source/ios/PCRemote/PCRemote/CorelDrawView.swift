import SwiftUI
import UIKit
import UniformTypeIdentifiers

@MainActor
final class CorelDrawModel: ObservableObject {
    let device: SavedDevice
    let app: RemoteApp
    let client: APIClient

    @Published var workspaces: [CorelWorkspace] = []
    @Published var selectedWorkspaceID: String?
    @Published var objects: [CorelShapeInfo] = []
    @Published var selectedIDs: Set<String> = []
    @Published var preview: UIImage?
    @Published var busy = false
    @Published var errorMessage = ""
    @Published var statusMessage = "Подключение к CorelDRAW…"

    init(device: SavedDevice, app: RemoteApp) {
        self.device = device
        self.app = app
        self.client = APIClient(device: device)
    }

    var currentWorkspace: CorelWorkspace? {
        workspaces.first { $0.id == selectedWorkspaceID }
    }

    var traceWorkspace: CorelWorkspace? {
        workspaces.first { $0.isTrace }
    }

    var converterWorkspaces: [CorelWorkspace] {
        workspaces.filter { $0.isConverter }
    }

    func bootstrap() async {
        guard !busy else { return }
        busy = true
        errorMessage = ""
        do {
            // Attach to an already running CorelDRAW. The Windows bridge launches
            // Corel only when GetActiveObject cannot find an existing instance.
            try await client.corelLaunch()
            let response = try await client.corelWorkspaceBootstrap()
            workspaces = response.workspaces
            if let existing = selectedWorkspaceID, workspaces.contains(where: { $0.id == existing }) {
                selectedWorkspaceID = existing
            } else {
                selectedWorkspaceID = response.workspaces.first(where: { $0.isTrace })?.id ?? response.workspaces.first?.id
            }
            statusMessage = "CorelDRAW подключён"
            try await refreshCurrent(includePreview: true)
        } catch {
            errorMessage = error.localizedDescription
            statusMessage = "CorelDRAW не отвечает"
        }
        busy = false
    }

    func refreshWorkspaces() async throws {
        let response = try await client.corelWorkspaces()
        workspaces = response.workspaces
        if let current = selectedWorkspaceID, !workspaces.contains(where: { $0.id == current }) {
            selectedWorkspaceID = workspaces.first?.id
        }
    }

    func choose(_ workspace: CorelWorkspace) async {
        selectedWorkspaceID = workspace.id
        errorMessage = ""
        busy = true
        do {
            try await refreshCurrent(includePreview: true)
        } catch {
            errorMessage = error.localizedDescription
        }
        busy = false
    }

    func chooseFunction(_ kind: String) async {
        if kind == "trace" {
            if let trace = traceWorkspace { await choose(trace) }
            return
        }
        if let converter = converterWorkspaces.first {
            await choose(converter)
        } else {
            await createWorkspace(kind: "converter")
        }
    }

    func createWorkspace(kind: String) async {
        guard !busy else { return }
        busy = true
        errorMessage = ""
        do {
            let workspace = try await client.corelCreateWorkspace(kind: kind)
            try await refreshWorkspaces()
            selectedWorkspaceID = workspace.id
            objects = []
            selectedIDs = []
            preview = nil
            try await refreshCurrent(includePreview: true)
            UINotificationFeedbackGenerator().notificationOccurred(.success)
        } catch {
            errorMessage = error.localizedDescription
            UINotificationFeedbackGenerator().notificationOccurred(.error)
        }
        busy = false
    }

    func refreshCurrent(includePreview: Bool) async throws {
        guard let id = selectedWorkspaceID else { return }
        let values = try await client.corelWorkspaceObjects(id: id)
        objects = values
        selectedIDs = Set(values.filter(\.isSelected).map(\.id))
        if includePreview {
            do {
                let data = try await client.corelWorkspacePreviewData(id: id)
                preview = UIImage(data: data)
            } catch {
                // Empty fresh Corel documents can fail to render on some versions.
                if !values.isEmpty { throw error }
                preview = nil
            }
        }
        try await refreshWorkspaces()
    }

    func importFiles(_ urls: [URL]) async {
        guard let id = selectedWorkspaceID, !urls.isEmpty else { return }
        busy = true
        errorMessage = ""
        do {
            for url in urls {
                let scoped = url.startAccessingSecurityScopedResource()
                let data: Data
                do {
                    data = try Data(contentsOf: url, options: .mappedIfSafe)
                } catch {
                    if scoped { url.stopAccessingSecurityScopedResource() }
                    throw error
                }
                if scoped { url.stopAccessingSecurityScopedResource() }
                let response = try await client.corelWorkspaceImport(id: id, filename: url.lastPathComponent, data: data)
                apply(response)
            }
            try await refreshCurrent(includePreview: true)
            UINotificationFeedbackGenerator().notificationOccurred(.success)
        } catch {
            errorMessage = error.localizedDescription
            UINotificationFeedbackGenerator().notificationOccurred(.error)
        }
        busy = false
    }

    func setSelection(_ ids: Set<String>) async {
        guard let workspaceID = selectedWorkspaceID else { return }
        selectedIDs = ids
        do {
            let response = try await client.corelWorkspaceSelect(id: workspaceID, ids: Array(ids))
            apply(response)
            try await refreshPreviewOnly()
        } catch {
            errorMessage = error.localizedDescription
        }
    }

    func toggleSelection(_ object: CorelShapeInfo) async {
        var next = selectedIDs
        if next.contains(object.id) { next.remove(object.id) }
        else { next.insert(object.id) }
        UISelectionFeedbackGenerator().selectionChanged()
        await setSelection(next)
    }

    func selectOnly(_ object: CorelShapeInfo) async {
        UISelectionFeedbackGenerator().selectionChanged()
        await setSelection([object.id])
    }

    func action(_ action: String) async {
        await mutate { id in
            try await self.client.corelWorkspaceAction(id: id, action: action)
        }
    }

    func transform(width: Double?, height: Double?, rotation: Double?, keepRatio: Bool) async {
        await mutate { id in
            try await self.client.corelWorkspaceTransform(
                id: id, width: width, height: height, rotation: rotation, keepRatio: keepRatio
            )
        }
    }

    func trace(mode: String, influence: Int, strength: Int) async {
        await mutate { id in
            try await self.client.corelWorkspaceTrace(
                id: id, mode: mode, influence: influence, strength: strength
            )
        }
    }

    func export(
        format: String,
        selectionOnly: Bool,
        destination: String,
        filename: String,
        folder: String? = nil
    ) async throws -> CorelExportResponse {
        guard let id = selectedWorkspaceID else { throw APIError.server("Рабочая область не выбрана.") }
        return try await client.corelWorkspaceExport(
            id: id,
            format: format,
            selectionOnly: selectionOnly,
            destination: destination,
            filename: filename,
            folder: folder
        )
    }

    func downloadExport(_ response: CorelExportResponse) async throws -> URL {
        guard let exportID = response.export_id else { throw APIError.server("Сервер не вернул файл экспорта.") }
        return try await client.corelDownloadExport(
            exportID: exportID,
            preferredName: response.filename ?? "CorelExport"
        )
    }

    private func refreshPreviewOnly() async throws {
        guard let id = selectedWorkspaceID else { return }
        if objects.isEmpty {
            preview = nil
            return
        }
        let data = try await client.corelWorkspacePreviewData(id: id)
        preview = UIImage(data: data)
    }

    private func mutate(_ operation: @escaping (String) async throws -> CorelWorkspaceMutationResponse) async {
        guard let id = selectedWorkspaceID, !busy else { return }
        busy = true
        errorMessage = ""
        do {
            let response = try await operation(id)
            apply(response)
            try await refreshCurrent(includePreview: true)
            UINotificationFeedbackGenerator().notificationOccurred(.success)
        } catch {
            errorMessage = error.localizedDescription
            UINotificationFeedbackGenerator().notificationOccurred(.error)
        }
        busy = false
    }

    private func apply(_ response: CorelWorkspaceMutationResponse) {
        if let workspace = response.workspace,
           let index = workspaces.firstIndex(where: { $0.id == workspace.id }) {
            workspaces[index] = workspace
        }
        if let values = response.objects {
            objects = values
            selectedIDs = Set(values.filter(\.isSelected).map(\.id))
        }
    }
}

struct CorelDrawView: View {
    @ObservedObject var model: CorelDrawModel
    @Environment(\.dismiss) private var dismiss

    @State private var showMenu = false
    @State private var showImporter = false
    @State private var showExport = false
    @State private var localSave: CorelLocalFile?
    @State private var localShare: CorelLocalFile?

    private var workspace: CorelWorkspace? { model.currentWorkspace }

    var body: some View {
        ZStack(alignment: .leading) {
            NavigationStack {
                Group {
                    if workspace?.isTrace == true {
                        CorelTraceWorkspaceView(model: model, showImporter: $showImporter, showExport: $showExport)
                    } else if workspace?.isConverter == true {
                        CorelConverterWorkspaceView(model: model, showImporter: $showImporter, showExport: $showExport)
                    } else {
                        CorelEmptyWorkspaceView(model: model)
                    }
                }
                .navigationTitle(workspace?.title ?? "CorelDRAW")
                .navigationBarTitleDisplayMode(.inline)
                .toolbar {
                    ToolbarItem(placement: .topBarLeading) {
                        Button { withAnimation(.easeOut(duration: 0.18)) { showMenu.toggle() } } label: {
                            Image(systemName: "line.3.horizontal")
                        }
                    }
                    ToolbarItem(placement: .topBarTrailing) {
                        HStack(spacing: 14) {
                            Button {
                                Task {
                                    do { try await model.refreshCurrent(includePreview: true) }
                                    catch { model.errorMessage = error.localizedDescription }
                                }
                            } label: { Image(systemName: "arrow.clockwise") }
                            Button { dismiss() } label: { Image(systemName: "xmark") }
                        }
                    }
                }
                .safeAreaInset(edge: .top, spacing: 0) {
                    CorelConnectionBanner(model: model)
                }
            }
            .disabled(showMenu)

            if showMenu {
                Color.black.opacity(0.28)
                    .ignoresSafeArea()
                    .onTapGesture { withAnimation(.easeIn(duration: 0.15)) { showMenu = false } }

                CorelSideMenu(model: model, isPresented: $showMenu)
                    .transition(.move(edge: .leading))
                    .zIndex(2)
            }

            if model.busy {
                ProgressView()
                    .controlSize(.large)
                    .padding(22)
                    .background(.regularMaterial, in: RoundedRectangle(cornerRadius: 20))
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
            }
        }
        .task { await model.bootstrap() }
        .fileImporter(
            isPresented: $showImporter,
            allowedContentTypes: workspace?.isTrace == true ? [.image] : [.item],
            allowsMultipleSelection: true
        ) { result in
            switch result {
            case .success(let urls): Task { await model.importFiles(urls) }
            case .failure(let error): model.errorMessage = error.localizedDescription
            }
        }
        .sheet(isPresented: $showExport) {
            CorelExportSheet(model: model) { result, action in
                Task {
                    do {
                        if action == .pc {
                            model.statusMessage = "Сохранено на ПК: \(result.path ?? result.filename ?? "готово")"
                        } else {
                            let url = try await model.downloadExport(result)
                            let item = CorelLocalFile(url: url)
                            if action == .iphone { localSave = item }
                            else { localShare = item }
                        }
                    } catch {
                        model.errorMessage = error.localizedDescription
                    }
                }
            }
            .presentationDetents([.medium, .large])
        }
        .sheet(item: $localSave) { item in
            CorelDocumentExportPicker(url: item.url)
        }
        .sheet(item: $localShare) { item in
            CorelShareSheet(url: item.url)
        }
    }
}

private struct CorelConnectionBanner: View {
    @ObservedObject var model: CorelDrawModel

    var body: some View {
        VStack(spacing: 0) {
            HStack(spacing: 8) {
                Circle()
                    .fill(model.errorMessage.isEmpty ? Color.green : Color.orange)
                    .frame(width: 8, height: 8)
                Text(model.errorMessage.isEmpty ? model.statusMessage : model.errorMessage)
                    .font(.caption)
                    .foregroundColor(model.errorMessage.isEmpty ? .primary : .orange)
                    .lineLimit(model.errorMessage.isEmpty ? 1 : 4)
                    .textSelection(.enabled)
                    .contextMenu {
                        if !model.errorMessage.isEmpty {
                            Button {
                                UIPasteboard.general.string = model.errorMessage
                            } label: {
                                Label("Копировать ошибку", systemImage: "doc.on.doc")
                            }
                        }
                    }
                Spacer()
                if let workspace = model.currentWorkspace {
                    Text("\(workspace.selectionCount) выбрано")
                        .font(.caption2)
                        .foregroundStyle(.secondary)
                }
            }
            .padding(.horizontal, 16)
            .padding(.vertical, 7)
            Divider()
        }
        .background(.bar)
    }
}

private struct CorelSideMenu: View {
    @ObservedObject var model: CorelDrawModel
    @Binding var isPresented: Bool

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            HStack {
                VStack(alignment: .leading, spacing: 3) {
                    Text("CorelDRAW").font(.title2.bold())
                    Text("PC Remote модуль").font(.caption).foregroundStyle(.secondary)
                }
                Spacer()
                Button { withAnimation { isPresented = false } } label: {
                    Image(systemName: "xmark.circle.fill").font(.title2).foregroundStyle(.secondary)
                }
            }
            .padding(.horizontal, 18)
            .padding(.top, 20)
            .padding(.bottom, 18)

            Text("ФУНКЦИИ")
                .font(.caption2.weight(.semibold))
                .foregroundStyle(.secondary)
                .padding(.horizontal, 18)
                .padding(.bottom, 6)

            CorelMenuButton(title: "Трассировка", systemImage: "scribble.variable", active: model.currentWorkspace?.isTrace == true) {
                Task { await model.chooseFunction("trace"); withAnimation { isPresented = false } }
            }
            CorelMenuButton(title: "Конвертер", systemImage: "arrow.triangle.2.circlepath.doc.on.clipboard", active: model.currentWorkspace?.isConverter == true) {
                Task { await model.chooseFunction("converter"); withAnimation { isPresented = false } }
            }

            Divider().padding(.vertical, 14)

            HStack {
                Text("РАБОЧИЕ ОБЛАСТИ")
                    .font(.caption2.weight(.semibold))
                    .foregroundStyle(.secondary)
                Spacer()
                Button {
                    Task { await model.createWorkspace(kind: "converter"); withAnimation { isPresented = false } }
                } label: { Image(systemName: "plus.circle.fill") }
            }
            .padding(.horizontal, 18)
            .padding(.bottom, 6)

            ScrollView {
                LazyVStack(spacing: 4) {
                    ForEach(model.workspaces) { workspace in
                        Button {
                            Task { await model.choose(workspace); withAnimation { isPresented = false } }
                        } label: {
                            HStack(spacing: 11) {
                                Image(systemName: workspace.isTrace ? "scribble.variable" : "doc.on.doc")
                                    .frame(width: 24)
                                VStack(alignment: .leading, spacing: 2) {
                                    Text(workspace.title).font(.subheadline.weight(.medium))
                                    Text("Стр. \(workspace.pageIndex)/\(workspace.pageCount) · \(workspace.importCount) импорт.")
                                        .font(.caption2).foregroundStyle(.secondary)
                                }
                                Spacer()
                                if model.selectedWorkspaceID == workspace.id {
                                    Image(systemName: "checkmark.circle.fill").foregroundStyle(.green)
                                }
                            }
                            .contentShape(Rectangle())
                            .padding(.horizontal, 18)
                            .padding(.vertical, 10)
                        }
                        .buttonStyle(.plain)
                    }
                }
            }

            Spacer()
            Text("Выход из этого экрана не закрывает CorelDRAW на ПК.")
                .font(.caption2)
                .foregroundStyle(.secondary)
                .padding(18)
        }
        .frame(width: min(UIScreen.main.bounds.width * 0.82, 330))
        .frame(maxHeight: .infinity)
        .background(.regularMaterial)
        .ignoresSafeArea(edges: .vertical)
    }
}

private struct CorelMenuButton: View {
    let title: String
    let systemImage: String
    let active: Bool
    let action: () -> Void

    var body: some View {
        Button(action: action) {
            HStack(spacing: 12) {
                Image(systemName: systemImage).frame(width: 25)
                Text(title).font(.headline)
                Spacer()
                if active { Image(systemName: "checkmark").font(.caption.bold()) }
            }
            .padding(.horizontal, 18)
            .padding(.vertical, 13)
            .background(active ? Color.accentColor.opacity(0.13) : Color.clear, in: RoundedRectangle(cornerRadius: 14))
            .padding(.horizontal, 8)
        }
        .buttonStyle(.plain)
    }
}

private struct CorelTraceWorkspaceView: View {
    @ObservedObject var model: CorelDrawModel
    @Binding var showImporter: Bool
    @Binding var showExport: Bool
    @State private var mode = "logo"
    @State private var influence = 45.0
    @State private var strength = 70.0

    private let modes: [(String, String)] = [
        ("logo", "Логотип"), ("photo", "Фото"), ("lineart", "Линии"), ("technical", "Тех.")
    ]

    var body: some View {
        ScrollView {
            VStack(spacing: 16) {
                CorelPreviewCard(model: model)

                Button { showImporter = true } label: {
                    Label("Загрузить фото", systemImage: "photo.badge.plus")
                        .frame(maxWidth: .infinity)
                }
                .buttonStyle(.borderedProminent)
                .controlSize(.large)

                VStack(alignment: .leading, spacing: 10) {
                    Text("Режим трассировки").font(.headline)
                    Picker("Режим", selection: $mode) {
                        ForEach(modes, id: \.0) { item in Text(item.1).tag(item.0) }
                    }
                    .pickerStyle(.segmented)

                    CorelSliderRow(title: "Влияние", value: $influence)
                    CorelSliderRow(title: "Сила", value: $strength)

                    Button {
                        Task { await model.trace(mode: mode, influence: Int(influence), strength: Int(strength)) }
                    } label: {
                        Label("Трассировать", systemImage: "wand.and.stars")
                            .frame(maxWidth: .infinity)
                    }
                    .buttonStyle(.borderedProminent)
                    .controlSize(.large)
                    .disabled(model.selectedIDs.count != 1)

                    if model.selectedIDs.count != 1 {
                        Text("Выбери одно растровое изображение в списке объектов ниже.")
                            .font(.caption).foregroundStyle(.secondary)
                    }
                }
                .corelPanel()

                CorelObjectStrip(model: model)

                Button { showExport = true } label: {
                    Label("Сохранить / Экспорт", systemImage: "square.and.arrow.up")
                        .frame(maxWidth: .infinity)
                }
                .buttonStyle(.bordered)
                .controlSize(.large)
                .disabled(model.objects.isEmpty)
            }
            .padding(16)
        }
    }
}

private struct CorelConverterWorkspaceView: View {
    @ObservedObject var model: CorelDrawModel
    @Binding var showImporter: Bool
    @Binding var showExport: Bool
    @State private var widthText = ""
    @State private var heightText = ""
    @State private var rotationText = ""
    @State private var keepRatio = true

    var body: some View {
        ScrollView {
            VStack(spacing: 16) {
                CorelPreviewCard(model: model)

                HStack(spacing: 10) {
                    Button { showImporter = true } label: {
                        Label("Импорт файла", systemImage: "plus.doc")
                            .frame(maxWidth: .infinity)
                    }
                    .buttonStyle(.borderedProminent)

                    Button { showExport = true } label: {
                        Label("Экспорт", systemImage: "square.and.arrow.up")
                            .frame(maxWidth: .infinity)
                    }
                    .buttonStyle(.bordered)
                    .disabled(model.objects.isEmpty)
                }
                .controlSize(.large)

                CorelObjectStrip(model: model)

                VStack(alignment: .leading, spacing: 12) {
                    HStack {
                        Text("Размер и поворот").font(.headline)
                        Spacer()
                        Text("\(model.selectedIDs.count) выбрано").font(.caption).foregroundStyle(.secondary)
                    }
                    HStack(spacing: 10) {
                        CorelNumberField(title: "W", text: $widthText, suffix: "mm")
                        CorelNumberField(title: "H", text: $heightText, suffix: "mm")
                        CorelNumberField(title: "°", text: $rotationText, suffix: "")
                    }
                    Toggle("Сохранять пропорции", isOn: $keepRatio)
                    Button("Применить размер") {
                        Task {
                            await model.transform(
                                width: Double(widthText.replacingOccurrences(of: ",", with: ".")),
                                height: Double(heightText.replacingOccurrences(of: ",", with: ".")),
                                rotation: Double(rotationText.replacingOccurrences(of: ",", with: ".")),
                                keepRatio: keepRatio
                            )
                        }
                    }
                    .buttonStyle(.borderedProminent)
                    .disabled(model.selectedIDs.isEmpty)
                }
                .corelPanel()

                LazyVGrid(columns: [GridItem(.flexible()), GridItem(.flexible())], spacing: 10) {
                    CorelActionButton(title: "Группировать", icon: "square.3.layers.3d") { Task { await model.action("group") } }
                    CorelActionButton(title: "Разгруппировать", icon: "square.3.layers.3d.down.right") { Task { await model.action("ungroup") } }
                    CorelActionButton(title: "Дублировать", icon: "plus.square.on.square") { Task { await model.action("duplicate") } }
                    CorelActionButton(title: "Удалить", icon: "trash", destructive: true) { Task { await model.action("delete") } }
                }
                .disabled(model.selectedIDs.isEmpty)
            }
            .padding(16)
        }
        .onChange(of: model.selectedIDs) { _ in
            guard model.selectedIDs.count == 1,
                  let id = model.selectedIDs.first,
                  let object = model.objects.first(where: { $0.id == id }) else { return }
            widthText = String(format: "%.2f", object.width)
            heightText = String(format: "%.2f", object.height)
            rotationText = String(format: "%.1f", object.rotation)
        }
    }
}

private struct CorelEmptyWorkspaceView: View {
    @ObservedObject var model: CorelDrawModel
    var body: some View {
        VStack(spacing: 14) {
            Image(systemName: "scribble.variable")
                .font(.system(size: 42))
                .foregroundStyle(.secondary)
            Text("CorelDRAW").font(.title2.bold())
            Text(model.errorMessage.isEmpty ? "Подготавливаем рабочую область." : model.errorMessage)
                .font(.subheadline)
                .foregroundStyle(.secondary)
                .multilineTextAlignment(.center)
            Button("Повторить") { Task { await model.bootstrap() } }
                .buttonStyle(.borderedProminent)
        }
        .padding(24)
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }
}

private struct CorelPreviewCard: View {
    @ObservedObject var model: CorelDrawModel

    var body: some View {
        ZStack {
            RoundedRectangle(cornerRadius: 18)
                .fill(Color.secondary.opacity(0.08))
            if let image = model.preview {
                Image(uiImage: image)
                    .resizable()
                    .scaledToFit()
                    .padding(8)
            } else {
                VStack(spacing: 10) {
                    Image(systemName: "doc.richtext").font(.system(size: 34)).foregroundStyle(.secondary)
                    Text("Импортируй файл — здесь появится превью")
                        .font(.subheadline).foregroundStyle(.secondary)
                }
                .multilineTextAlignment(.center)
                .padding()
            }
        }
        .frame(minHeight: 250, idealHeight: 330, maxHeight: 430)
        .overlay(alignment: .topTrailing) {
            if let workspace = model.currentWorkspace {
                HStack(spacing: 6) {
                    if workspace.pageCount > 1 {
                        Button { Task { await model.action("previous_page") } } label: {
                            Image(systemName: "chevron.left")
                        }
                        .disabled(workspace.pageIndex <= 1)
                    }
                    Text("стр. \(workspace.pageIndex)/\(workspace.pageCount)")
                        .font(.caption2.weight(.medium))
                    if workspace.pageCount > 1 {
                        Button { Task { await model.action("next_page") } } label: {
                            Image(systemName: "chevron.right")
                        }
                        .disabled(workspace.pageIndex >= workspace.pageCount)
                    }
                }
                .padding(.horizontal, 9).padding(.vertical, 6)
                .background(.thinMaterial, in: Capsule())
                .padding(10)
            }
        }
    }
}

private struct CorelObjectStrip: View {
    @ObservedObject var model: CorelDrawModel

    var body: some View {
        VStack(alignment: .leading, spacing: 9) {
            HStack {
                Text("Объекты").font(.headline)
                Spacer()
                if !model.objects.isEmpty {
                    Button(model.selectedIDs.count == model.objects.count ? "Снять" : "Все") {
                        Task {
                            if model.selectedIDs.count == model.objects.count { await model.setSelection([]) }
                            else { await model.setSelection(Set(model.objects.map(\.id))) }
                        }
                    }
                    .font(.caption)
                }
            }
            if model.objects.isEmpty {
                Text("Пока нет импортированных объектов.").font(.caption).foregroundStyle(.secondary)
            } else {
                ScrollView(.horizontal, showsIndicators: false) {
                    HStack(spacing: 8) {
                        ForEach(model.objects) { object in
                            Button {
                                Task { await model.toggleSelection(object) }
                            } label: {
                                HStack(spacing: 6) {
                                    Image(systemName: model.selectedIDs.contains(object.id) ? "checkmark.circle.fill" : "circle")
                                    Text(object.name.isEmpty ? "Объект \(object.index)" : object.name)
                                        .lineLimit(1)
                                }
                                .font(.caption.weight(.medium))
                                .padding(.horizontal, 10).padding(.vertical, 8)
                                .background(model.selectedIDs.contains(object.id) ? Color.accentColor.opacity(0.14) : Color.secondary.opacity(0.09), in: Capsule())
                            }
                            .buttonStyle(.plain)
                        }
                    }
                }
            }
        }
        .corelPanel()
    }
}

private struct CorelSliderRow: View {
    let title: String
    @Binding var value: Double
    var body: some View {
        VStack(spacing: 4) {
            HStack { Text(title); Spacer(); Text("\(Int(value))%").foregroundStyle(.secondary) }
                .font(.subheadline)
            Slider(value: $value, in: 0...100, step: 1)
        }
    }
}

private struct CorelNumberField: View {
    let title: String
    @Binding var text: String
    let suffix: String
    var body: some View {
        HStack(spacing: 5) {
            Text(title).font(.caption).foregroundStyle(.secondary)
            TextField("—", text: $text)
                .keyboardType(.decimalPad)
                .multilineTextAlignment(.trailing)
            if !suffix.isEmpty { Text(suffix).font(.caption2).foregroundStyle(.secondary) }
        }
        .padding(.horizontal, 10).padding(.vertical, 9)
        .background(Color.secondary.opacity(0.08), in: RoundedRectangle(cornerRadius: 10))
    }
}

private struct CorelActionButton: View {
    let title: String
    let icon: String
    var destructive = false
    let action: () -> Void

    var body: some View {
        Button(action: action) {
            Label(title, systemImage: icon)
                .font(.subheadline.weight(.medium))
                .frame(maxWidth: .infinity)
                .padding(.vertical, 11)
        }
        .buttonStyle(.bordered)
        .tint(destructive ? .red : .accentColor)
    }
}

private enum CorelExportAction { case pc, iphone, share }

private struct CorelExportSheet: View {
    @ObservedObject var model: CorelDrawModel
    let completion: (CorelExportResponse, CorelExportAction) -> Void
    @Environment(\.dismiss) private var dismiss

    @State private var format = "pdf"
    @State private var selectionOnly = false
    @State private var filename = "CorelExport"
    @State private var pcFolder = ""
    @State private var working = false
    @State private var message = ""

    private let formats = ["pdf", "svg", "eps", "ai", "png", "jpg", "tiff", "dxf", "emf", "cdr"]

    var body: some View {
        NavigationStack {
            Form {
                Section("Что экспортировать") {
                    Picker("Область", selection: $selectionOnly) {
                        Text("Текущая страница").tag(false)
                        Text("Только выбранные").tag(true)
                    }
                    .pickerStyle(.segmented)
                    if selectionOnly && model.selectedIDs.isEmpty {
                        Text("Для этого режима сначала выбери объекты.").font(.caption).foregroundStyle(.orange)
                    }
                }
                Section("Формат") {
                    Picker("Формат", selection: $format) {
                        ForEach(formats, id: \.self) { Text($0.uppercased()).tag($0) }
                    }
                    TextField("Имя файла", text: $filename)
                }
                Section("Сохранение на ПК") {
                    TextField("Папка (необязательно)", text: $pcFolder)
                        .textInputAutocapitalization(.never)
                    Text("Если папка не указана: Загрузки\\PC Remote Corel")
                        .font(.caption).foregroundStyle(.secondary)
                    Button { run(.pc) } label: { Label("Сохранить на ПК", systemImage: "desktopcomputer") }
                }
                Section("iPhone") {
                    Button { run(.iphone) } label: { Label("Сохранить в Файлы", systemImage: "folder") }
                    Button { run(.share) } label: { Label("Поделиться", systemImage: "square.and.arrow.up") }
                }
                if !message.isEmpty { Section { Text(message).font(.caption).foregroundStyle(.red) } }
            }
            .navigationTitle("Экспорт")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar { ToolbarItem(placement: .topBarTrailing) { Button("Готово") { dismiss() } } }
            .overlay { if working { ProgressView().controlSize(.large) } }
        }
    }

    private func run(_ action: CorelExportAction) {
        guard !working else { return }
        if selectionOnly && model.selectedIDs.isEmpty {
            message = "Сначала выбери хотя бы один объект."
            return
        }
        if format == "cdr" && selectionOnly {
            message = "Выбранные объекты экспортируй в SVG/PDF; CDR сохраняет всю рабочую область."
            return
        }
        working = true
        message = ""
        Task {
            do {
                let response = try await model.export(
                    format: format,
                    selectionOnly: selectionOnly,
                    destination: action == .pc ? "pc" : "iphone",
                    filename: filename.isEmpty ? "CorelExport" : filename,
                    folder: action == .pc && !pcFolder.isEmpty ? pcFolder : nil
                )
                working = false
                completion(response, action)
                dismiss()
            } catch {
                working = false
                message = error.localizedDescription
            }
        }
    }
}

private struct CorelLocalFile: Identifiable {
    let id = UUID()
    let url: URL
}

private struct CorelShareSheet: UIViewControllerRepresentable {
    let url: URL
    func makeUIViewController(context: Context) -> UIActivityViewController {
        UIActivityViewController(activityItems: [url], applicationActivities: nil)
    }
    func updateUIViewController(_ uiViewController: UIActivityViewController, context: Context) {}
}

private struct CorelDocumentExportPicker: UIViewControllerRepresentable {
    let url: URL
    func makeUIViewController(context: Context) -> UIDocumentPickerViewController {
        UIDocumentPickerViewController(forExporting: [url], asCopy: true)
    }
    func updateUIViewController(_ uiViewController: UIDocumentPickerViewController, context: Context) {}
}

private extension View {
    func corelPanel() -> some View {
        self
            .padding(14)
            .background(Color.secondary.opacity(0.07), in: RoundedRectangle(cornerRadius: 16))
    }
}
