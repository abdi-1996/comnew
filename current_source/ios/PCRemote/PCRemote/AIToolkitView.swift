import SwiftUI
import UIKit
import Foundation

// MARK: - AI Toolkit data models

struct AIToolkitStatusResponse: Codable {
    let ok: Bool
    let available: Bool
    let url: String
    let path: String?
    let configured_path: String?
    let token_set: Bool
    let active_jobs: Int
    let error: String?

    var configuredPath: String { configured_path ?? "" }
    var tokenSet: Bool { token_set }
    var activeJobs: Int { active_jobs }
}

struct AIToolkitSettingsResponse: Codable {
    let ok: Bool
    let url: String
    let path: String
    let detected_path: String?
    let token_set: Bool

    var detectedPath: String? { detected_path }
    var tokenSet: Bool { token_set }
}

struct AIToolkitJobSummary: Codable, Hashable {
    let trigger_word: String?
    let steps: Int?
    let lr: Double?
    let batch_size: Int?
    let rank: Int?
    let alpha: Int?
    let model_path: String?
    let model_arch: String?
    let dataset_path: String?
    let resolution: [Int]?

    var triggerWord: String? { trigger_word }
    var batchSize: Int? { batch_size }
    var modelPath: String? { model_path }
    var modelArch: String? { model_arch }
    var datasetPath: String? { dataset_path }
}

struct AIToolkitJob: Codable, Identifiable, Hashable {
    let id: String
    let name: String
    let gpu_ids: String?
    let created_at: String?
    let updated_at: String?
    let status: String
    let stop: Bool?
    let step: Int
    let total_steps: Int?
    let info: String?
    let speed_string: String?
    let queue_position: Int?
    let pid: Int?
    let job_type: String?
    let job_ref: String?
    let summary: AIToolkitJobSummary?

    var gpuIDs: String { gpu_ids ?? "0" }
    var totalSteps: Int { max(total_steps ?? summary?.steps ?? 0, 0) }
    var progress: Double {
        guard totalSteps > 0 else { return 0 }
        return min(max(Double(step) / Double(totalSteps), 0), 1)
    }
    var isRunning: Bool { ["running", "queued", "stopping"].contains(status.lowercased()) }
    var speedString: String { speed_string ?? "" }
}

struct AIToolkitJobsResponse: Codable {
    let ok: Bool
    let jobs: [AIToolkitJob]
    let error: String?
}

struct AIToolkitJobResponse: Codable {
    let ok: Bool
    let job: AIToolkitJob?
    let error: String?
}

struct AIToolkitLogResponse: Codable {
    let ok: Bool
    let log: String
    let offset: Int
    let reset: Bool
}

struct AIToolkitLossPoint: Codable, Hashable {
    let step: Int
    let wall_time: Double?
    let value: Double?
}

struct AIToolkitLossResponse: Codable {
    let ok: Bool
    let key: String
    let keys: [String]
    let points: [AIToolkitLossPoint]
}

struct AIToolkitSamplesResponse: Codable {
    let ok: Bool
    let samples: [String]
}

struct AIToolkitOutputFile: Codable, Hashable, Identifiable {
    let path: String
    let size: Int

    var id: String { path }
    var name: String { URL(fileURLWithPath: path).lastPathComponent }
    var sizeText: String { ByteCountFormatter.string(fromByteCount: Int64(size), countStyle: .file) }
}

struct AIToolkitFilesResponse: Codable {
    let ok: Bool
    let files: [AIToolkitOutputFile]
}

struct AIToolkitDatasetsResponse: Codable {
    let ok: Bool
    let datasets: [String]
}

struct AIToolkitDatasetImagesResponse: Codable {
    let ok: Bool
    let root: String
    let images: [String]
}

struct AIToolkitCloneRequest {
    var name: String
    var triggerWord: String
    var datasetPath: String
    var modelPath: String
    var modelArch: String
    var steps: Int
    var learningRate: Double
    var rank: Int
    var alpha: Int
    var batchSize: Int
    var resolution: Int
    var gpuIDs: String
}

// MARK: - View model

@MainActor
final class AIToolkitModel: ObservableObject {
    let device: SavedDevice
    private let client: APIClient

    @Published var status: AIToolkitStatusResponse?
    @Published var jobs: [AIToolkitJob] = []
    @Published var datasets: [String] = []
    @Published var selectedJob: AIToolkitJob?
    @Published var logText = ""
    @Published var logOffset = 0
    @Published var lossPoints: [AIToolkitLossPoint] = []
    @Published var samples: [String] = []
    @Published var outputFiles: [AIToolkitOutputFile] = []
    @Published var busy = false
    @Published var errorMessage = ""
    @Published var lastUpdated: Date?

    init(device: SavedDevice) {
        self.device = device
        self.client = APIClient(device: device)
    }

    func refreshAll() async {
        busy = true
        defer { busy = false }
        do {
            async let s = client.aitoolkitStatus()
            async let j = client.aitoolkitJobs()
            async let d = client.aitoolkitDatasets()
            let (statusValue, jobsValue, datasetsValue) = try await (s, j, d)
            status = statusValue
            jobs = jobsValue.jobs
            datasets = datasetsValue.datasets
            lastUpdated = Date()
            errorMessage = ""
            if let selected = selectedJob,
               let fresh = jobs.first(where: { $0.id == selected.id }) {
                selectedJob = fresh
            }
        } catch {
            errorMessage = error.localizedDescription
        }
    }

    func refreshJobs() async {
        do {
            let response = try await client.aitoolkitJobs()
            jobs = response.jobs
            lastUpdated = Date()
            if let selected = selectedJob,
               let fresh = jobs.first(where: { $0.id == selected.id }) {
                selectedJob = fresh
            }
            errorMessage = ""
        } catch {
            errorMessage = error.localizedDescription
        }
    }

    func select(_ job: AIToolkitJob) async {
        selectedJob = job
        logText = ""
        logOffset = 0
        lossPoints = []
        samples = []
        outputFiles = []
        await refreshSelected(includeLogTail: true)
    }

    func refreshSelected(includeLogTail: Bool = false) async {
        guard let id = selectedJob?.id else { return }
        do {
            async let detail = client.aitoolkitJob(id: id)
            async let loss = client.aitoolkitLoss(id: id)
            async let sampleResponse = client.aitoolkitSamples(id: id)
            async let filesResponse = client.aitoolkitFiles(id: id)
            let (detailValue, lossValue, samplesValue, filesValue) = try await (detail, loss, sampleResponse, filesResponse)
            if let job = detailValue.job { selectedJob = job }
            lossPoints = lossValue.points
            samples = samplesValue.samples
            outputFiles = filesValue.files
            if includeLogTail || selectedJob?.isRunning == true {
                let log = try await client.aitoolkitLog(id: id, offset: includeLogTail ? nil : logOffset)
                if log.reset { logText = log.log } else { logText += log.log }
                logOffset = log.offset
                if logText.count > 120_000 { logText = String(logText.suffix(120_000)) }
            }
            errorMessage = ""
        } catch {
            errorMessage = error.localizedDescription
        }
    }

    func start(_ job: AIToolkitJob) async { await action(job, kind: .start) }
    func stop(_ job: AIToolkitJob) async { await action(job, kind: .stop) }
    func saveNow(_ job: AIToolkitJob) async { await action(job, kind: .saveNow) }
    func sampleNow(_ job: AIToolkitJob) async { await action(job, kind: .sampleNow) }

    enum JobAction { case start, stop, saveNow, sampleNow }

    private func action(_ job: AIToolkitJob, kind: JobAction) async {
        do {
            switch kind {
            case .start: try await client.aitoolkitStart(id: job.id)
            case .stop: try await client.aitoolkitStop(id: job.id)
            case .saveNow: try await client.aitoolkitSaveNow(id: job.id)
            case .sampleNow: try await client.aitoolkitSampleNow(id: job.id)
            }
            try? await Task.sleep(nanoseconds: 450_000_000)
            await refreshJobs()
            if selectedJob?.id == job.id { await refreshSelected(includeLogTail: true) }
        } catch {
            errorMessage = error.localizedDescription
        }
    }

    func clone(job: AIToolkitJob, request: AIToolkitCloneRequest) async -> Bool {
        busy = true
        defer { busy = false }
        do {
            _ = try await client.aitoolkitClone(id: job.id, request: request)
            await refreshJobs()
            return true
        } catch {
            errorMessage = error.localizedDescription
            return false
        }
    }

    func startUI(rebuild: Bool = false) async {
        do {
            try await client.aitoolkitStartUI(rebuild: rebuild)
            for _ in 0..<12 {
                try? await Task.sleep(nanoseconds: 800_000_000)
                if let current = try? await client.aitoolkitStatus(), current.available {
                    status = current
                    await refreshAll()
                    return
                }
            }
            status = try? await client.aitoolkitStatus()
        } catch {
            errorMessage = error.localizedDescription
        }
    }

    func openUIOnPC() async {
        do { try await client.aitoolkitOpenUI() }
        catch { errorMessage = error.localizedDescription }
    }

    func loadSettings() async throws -> AIToolkitSettingsResponse {
        try await client.aitoolkitSettings()
    }

    func saveSettings(url: String, path: String, token: String?) async throws {
        try await client.aitoolkitSaveSettings(url: url, path: path, token: token)
        status = try? await client.aitoolkitStatus()
    }

    func datasetImages(_ name: String) async throws -> AIToolkitDatasetImagesResponse {
        try await client.aitoolkitDatasetImages(name: name)
    }

    func mediaData(path: String) async throws -> Data {
        try await client.aitoolkitMedia(path: path)
    }

    func openOutputOnPC(_ job: AIToolkitJob) async {
        do { try await client.aitoolkitOpenOutput(id: job.id) }
        catch { errorMessage = error.localizedDescription }
    }
}

// MARK: - Main AI Toolkit module

private struct AIToolkitDatasetSelection: Identifiable {
    let id: String
}

struct AIToolkitView: View {
    @Environment(\.dismiss) private var dismiss
    @ObservedObject var model: AIToolkitModel
    @State private var segment = 0
    @State private var showSettings = false
    @State private var selectedDataset: AIToolkitDatasetSelection?
    @State private var cloneSource: AIToolkitJob?

    var body: some View {
        NavigationStack {
            ZStack {
                AITKBackground().ignoresSafeArea()
                ScrollView(showsIndicators: false) {
                    VStack(spacing: 16) {
                        header
                        statusCard
                        Picker("Раздел", selection: $segment) {
                            Text("Jobs").tag(0)
                            Text("Datasets").tag(1)
                        }
                        .pickerStyle(.segmented)

                        if !model.errorMessage.isEmpty {
                            AITKMessage(text: model.errorMessage, icon: "exclamationmark.triangle.fill")
                        }

                        if segment == 0 { jobsSection } else { datasetsSection }
                    }
                    .padding(.horizontal, 16)
                    .padding(.top, 8)
                    .padding(.bottom, 34)
                }
                .refreshable { await model.refreshAll() }
            }
            .toolbar(.hidden, for: .navigationBar)
        }
        .task {
            await model.refreshAll()
            while !Task.isCancelled {
                try? await Task.sleep(nanoseconds: 2_000_000_000)
                if model.jobs.contains(where: { $0.isRunning }) {
                    await model.refreshJobs()
                    if model.selectedJob != nil { await model.refreshSelected() }
                } else {
                    model.status = try? await APIClient(device: model.device).aitoolkitStatus()
                }
            }
        }
        .sheet(isPresented: $showSettings) {
            AIToolkitSettingsSheet(model: model)
        }
        .sheet(item: $cloneSource) { job in
            AIToolkitCloneSheet(model: model, job: job)
        }
        .sheet(item: $selectedDataset) { selection in
            AIToolkitDatasetSheet(model: model, dataset: selection.id)
        }
        .fullScreenCover(item: $model.selectedJob) { job in
            AIToolkitJobDetailView(model: model, initialJob: job)
        }
    }

    private var header: some View {
        HStack(spacing: 12) {
            Button { dismiss() } label: {
                Image(systemName: "chevron.down")
                    .font(.system(size: 17, weight: .bold))
                    .foregroundStyle(.white)
                    .frame(width: 42, height: 42)
                    .background(.ultraThinMaterial, in: RoundedRectangle(cornerRadius: 14))
            }
            .buttonStyle(.plain)

            VStack(alignment: .leading, spacing: 2) {
                Text("AI Toolkit")
                    .font(.system(size: 28, weight: .bold, design: .rounded))
                    .foregroundStyle(.white)
                Text("LoRA Training · Stage 2")
                    .font(.system(size: 12, weight: .semibold))
                    .foregroundStyle(.white.opacity(0.52))
            }
            Spacer()
            Button { showSettings = true } label: {
                Image(systemName: "gearshape.fill")
                    .foregroundStyle(.white)
                    .frame(width: 42, height: 42)
                    .background(.ultraThinMaterial, in: RoundedRectangle(cornerRadius: 14))
            }
            .buttonStyle(.plain)
        }
    }

    private var statusCard: some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack(spacing: 11) {
                ZStack {
                    RoundedRectangle(cornerRadius: 15).fill((model.status?.available == true ? Color.green : Color.orange).opacity(0.14))
                    Image(systemName: model.status?.available == true ? "bolt.horizontal.circle.fill" : "bolt.slash.circle.fill")
                        .font(.system(size: 23, weight: .semibold))
                        .foregroundStyle(model.status?.available == true ? .green : .orange)
                }
                .frame(width: 52, height: 52)
                VStack(alignment: .leading, spacing: 3) {
                    Text(model.status?.available == true ? "AI Toolkit подключён" : "AI Toolkit не запущен")
                        .font(.system(size: 17, weight: .bold))
                        .foregroundStyle(.white)
                    Text(model.status?.url ?? "http://127.0.0.1:8675")
                        .font(.system(size: 11, weight: .medium, design: .monospaced))
                        .foregroundStyle(.white.opacity(0.48))
                        .lineLimit(1)
                }
                Spacer()
                if model.busy { ProgressView().tint(.white) }
            }

            HStack(spacing: 8) {
                Button {
                    Task { await model.startUI() }
                } label: {
                    Label(model.status?.available == true ? "Запущен" : "Запустить", systemImage: "play.fill")
                }
                .buttonStyle(AITKCompactButtonStyle(accent: .purple))
                .disabled(model.status?.available == true)

                Button { Task { await model.openUIOnPC() } } label: {
                    Label("Открыть на ПК", systemImage: "arrow.up.right.square")
                }
                .buttonStyle(AITKCompactButtonStyle(accent: .cyan))

                Spacer(minLength: 0)
                Text("Active: \(model.status?.activeJobs ?? model.jobs.filter { $0.isRunning }.count)")
                    .font(.system(size: 11, weight: .bold, design: .rounded))
                    .foregroundStyle(.white.opacity(0.56))
            }
        }
        .padding(15)
        .background(.ultraThinMaterial, in: RoundedRectangle(cornerRadius: 24, style: .continuous))
        .overlay(RoundedRectangle(cornerRadius: 24).stroke(Color.purple.opacity(0.2), lineWidth: 1))
    }

    private var jobsSection: some View {
        VStack(alignment: .leading, spacing: 11) {
            HStack {
                Text("Training Jobs")
                    .font(.system(size: 19, weight: .bold))
                    .foregroundStyle(.white)
                Spacer()
                Button { Task { await model.refreshJobs() } } label: {
                    Image(systemName: "arrow.clockwise")
                        .foregroundStyle(.white.opacity(0.74))
                }
            }

            if model.jobs.isEmpty {
                AITKMessage(
                    text: model.status?.available == true
                        ? "Jobs пока нет. Создай первый job в AI Toolkit UI, после этого его можно полностью запускать, контролировать и клонировать с iPhone."
                        : "Запусти AI Toolkit UI или укажи путь/токен в настройках.",
                    icon: "tray"
                )
            }

            ForEach(model.jobs) { job in
                Button {
                    Task { await model.select(job) }
                } label: {
                    AIToolkitJobCard(job: job)
                }
                .buttonStyle(.plain)
                .contextMenu {
                    Button { cloneSource = job } label: { Label("Дублировать job", systemImage: "plus.square.on.square") }
                    if job.isRunning {
                        Button(role: .destructive) { Task { await model.stop(job) } } label: { Label("Остановить", systemImage: "stop.fill") }
                    } else {
                        Button { Task { await model.start(job) } } label: { Label("Запустить", systemImage: "play.fill") }
                    }
                }
            }
        }
    }

    private var datasetsSection: some View {
        VStack(alignment: .leading, spacing: 11) {
            HStack {
                Text("Datasets")
                    .font(.system(size: 19, weight: .bold))
                    .foregroundStyle(.white)
                Spacer()
                Text("\(model.datasets.count)")
                    .font(.system(size: 12, weight: .bold))
                    .foregroundStyle(.white.opacity(0.45))
            }
            if model.datasets.isEmpty {
                AITKMessage(text: "Datasets не найдены или AI Toolkit UI не отвечает.", icon: "photo.stack")
            }
            ForEach(model.datasets, id: \.self) { dataset in
                Button { selectedDataset = AIToolkitDatasetSelection(id: dataset) } label: {
                    HStack(spacing: 12) {
                        Image(systemName: "photo.stack.fill")
                            .font(.system(size: 20, weight: .semibold))
                            .foregroundStyle(.purple)
                            .frame(width: 42, height: 42)
                            .background(Color.purple.opacity(0.12), in: RoundedRectangle(cornerRadius: 13))
                        VStack(alignment: .leading, spacing: 3) {
                            Text(dataset).font(.system(size: 16, weight: .bold)).foregroundStyle(.white)
                            Text("Открыть dataset").font(.system(size: 12)).foregroundStyle(.white.opacity(0.48))
                        }
                        Spacer()
                        Image(systemName: "chevron.right").foregroundStyle(.white.opacity(0.35))
                    }
                    .padding(13)
                    .background(Color.white.opacity(0.055), in: RoundedRectangle(cornerRadius: 19))
                }
                .buttonStyle(.plain)
            }
        }
    }
}

// MARK: - Job card + detail

private struct AIToolkitJobCard: View {
    let job: AIToolkitJob

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack {
                VStack(alignment: .leading, spacing: 4) {
                    Text(job.name)
                        .font(.system(size: 17, weight: .bold))
                        .foregroundStyle(.white)
                        .lineLimit(1)
                    Text([job.summary?.modelArch, job.summary?.triggerWord].compactMap { $0 }.joined(separator: " · "))
                        .font(.system(size: 11, weight: .medium))
                        .foregroundStyle(.white.opacity(0.46))
                        .lineLimit(1)
                }
                Spacer()
                AITKStatusPill(status: job.status)
            }
            if job.totalSteps > 0 {
                ProgressView(value: job.progress)
                    .tint(job.isRunning ? .purple : .gray)
                HStack {
                    Text("\(job.step) / \(job.totalSteps)")
                    Spacer()
                    if !job.speedString.isEmpty { Text(job.speedString) }
                }
                .font(.system(size: 10, weight: .semibold, design: .monospaced))
                .foregroundStyle(.white.opacity(0.45))
            }
            if let info = job.info, !info.isEmpty {
                Text(info)
                    .font(.system(size: 11))
                    .foregroundStyle(.white.opacity(0.53))
                    .lineLimit(2)
            }
        }
        .padding(14)
        .background(.ultraThinMaterial, in: RoundedRectangle(cornerRadius: 21))
        .overlay(RoundedRectangle(cornerRadius: 21).stroke(Color.white.opacity(0.08), lineWidth: 1))
    }
}

private struct AIToolkitJobDetailView: View {
    @Environment(\.dismiss) private var dismiss
    @ObservedObject var model: AIToolkitModel
    let initialJob: AIToolkitJob
    @State private var showClone = false

    private var job: AIToolkitJob { model.selectedJob ?? initialJob }

    var body: some View {
        ZStack {
            AITKBackground().ignoresSafeArea()
            ScrollView(showsIndicators: false) {
                VStack(spacing: 15) {
                    detailHeader
                    progressCard
                    controls
                    parametersCard
                    lossCard
                    samplesCard
                    outputFilesCard
                    logCard
                }
                .padding(.horizontal, 16)
                .padding(.top, 8)
                .padding(.bottom, 32)
            }
        }
        .task {
            await model.refreshSelected(includeLogTail: true)
            while !Task.isCancelled && job.isRunning {
                try? await Task.sleep(nanoseconds: 1_300_000_000)
                await model.refreshSelected()
            }
        }
        .sheet(isPresented: $showClone) {
            AIToolkitCloneSheet(model: model, job: job)
        }
    }

    private var detailHeader: some View {
        HStack(spacing: 12) {
            Button {
                model.selectedJob = nil
                dismiss()
            } label: {
                Image(systemName: "chevron.down")
                    .foregroundStyle(.white)
                    .frame(width: 42, height: 42)
                    .background(.ultraThinMaterial, in: RoundedRectangle(cornerRadius: 14))
            }
            .buttonStyle(.plain)
            VStack(alignment: .leading, spacing: 2) {
                Text(job.name).font(.system(size: 23, weight: .bold)).foregroundStyle(.white).lineLimit(1)
                Text(job.summary?.modelArch ?? "AI Toolkit job")
                    .font(.system(size: 12, weight: .semibold)).foregroundStyle(.white.opacity(0.48))
            }
            Spacer()
            AITKStatusPill(status: job.status)
        }
    }

    private var progressCard: some View {
        VStack(alignment: .leading, spacing: 9) {
            HStack {
                Text("Progress").font(.system(size: 15, weight: .bold)).foregroundStyle(.white)
                Spacer()
                Text("\(Int(job.progress * 100))%")
                    .font(.system(size: 18, weight: .bold, design: .rounded)).foregroundStyle(.purple)
            }
            ProgressView(value: job.progress).tint(.purple).scaleEffect(y: 1.4)
            HStack {
                Text("Step \(job.step) / \(job.totalSteps)")
                Spacer()
                Text(job.speedString)
            }
            .font(.system(size: 11, weight: .semibold, design: .monospaced))
            .foregroundStyle(.white.opacity(0.5))
            if let info = job.info, !info.isEmpty {
                Text(info).font(.system(size: 12)).foregroundStyle(.white.opacity(0.62))
            }
        }
        .padding(15)
        .background(.ultraThinMaterial, in: RoundedRectangle(cornerRadius: 22))
    }

    private var controls: some View {
        VStack(spacing: 9) {
            HStack(spacing: 9) {
                if job.isRunning {
                    Button { Task { await model.stop(job) } } label: { Label("Stop", systemImage: "stop.fill") }
                        .buttonStyle(AITKWideButtonStyle(accent: .red))
                } else {
                    Button { Task { await model.start(job) } } label: { Label("Start", systemImage: "play.fill") }
                        .buttonStyle(AITKWideButtonStyle(accent: .green))
                }
                Button { showClone = true } label: { Label("Clone", systemImage: "plus.square.on.square") }
                    .buttonStyle(AITKWideButtonStyle(accent: .purple))
            }
            HStack(spacing: 9) {
                Button { Task { await model.saveNow(job) } } label: { Label("Save now", systemImage: "square.and.arrow.down") }
                    .buttonStyle(AITKWideButtonStyle(accent: .cyan))
                Button { Task { await model.sampleNow(job) } } label: { Label("Sample", systemImage: "photo.badge.plus") }
                    .buttonStyle(AITKWideButtonStyle(accent: .orange))
            }
        }
    }

    private var parametersCard: some View {
        let s = job.summary
        return VStack(alignment: .leading, spacing: 10) {
            Text("Training Settings").font(.system(size: 15, weight: .bold)).foregroundStyle(.white)
            AITKKeyValue(key: "Trigger", value: s?.triggerWord ?? "—")
            AITKKeyValue(key: "Model", value: s?.modelPath ?? "—")
            AITKKeyValue(key: "Dataset", value: s?.datasetPath ?? "—")
            AITKKeyValue(key: "Steps", value: s?.steps.map { String($0) } ?? "—")
            AITKKeyValue(key: "LR", value: s?.lr.map { String(format: "%.2e", $0) } ?? "—")
            AITKKeyValue(key: "Rank / Alpha", value: "\(s?.rank ?? 0) / \(s?.alpha ?? 0)")
            AITKKeyValue(key: "Batch", value: s?.batchSize.map { String($0) } ?? "—")
            AITKKeyValue(key: "GPU", value: job.gpuIDs)
        }
        .padding(15)
        .background(Color.white.opacity(0.055), in: RoundedRectangle(cornerRadius: 22))
    }

    private var lossCard: some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack {
                Text("Loss").font(.system(size: 15, weight: .bold)).foregroundStyle(.white)
                Spacer()
                if let last = model.lossPoints.last?.value {
                    Text(String(format: "%.5f", last)).font(.system(size: 12, weight: .bold, design: .monospaced)).foregroundStyle(.cyan)
                }
            }
            AITKLossGraph(points: model.lossPoints)
                .frame(height: 105)
        }
        .padding(15)
        .background(Color.white.opacity(0.055), in: RoundedRectangle(cornerRadius: 22))
    }

    private var samplesCard: some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack {
                Text("Samples").font(.system(size: 15, weight: .bold)).foregroundStyle(.white)
                Spacer()
                Text("\(model.samples.count)").font(.system(size: 11, weight: .bold)).foregroundStyle(.white.opacity(0.45))
            }
            if model.samples.isEmpty {
                Text("Sample-файлов пока нет.").font(.system(size: 12)).foregroundStyle(.white.opacity(0.45))
            } else {
                ScrollView(.horizontal, showsIndicators: false) {
                    HStack(spacing: 10) {
                        ForEach(Array(model.samples.suffix(12)), id: \.self) { path in
                            AITKRemoteMediaTile(model: model, path: path)
                        }
                    }
                }
            }
        }
        .padding(15)
        .background(Color.white.opacity(0.055), in: RoundedRectangle(cornerRadius: 22))
    }

    private var outputFilesCard: some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack {
                Text("Checkpoints / LoRA")
                    .font(.system(size: 15, weight: .bold))
                    .foregroundStyle(.white)
                Spacer()
                if !model.outputFiles.isEmpty {
                    Button { Task { await model.openOutputOnPC(job) } } label: {
                        Label("ПК", systemImage: "folder")
                            .font(.system(size: 10, weight: .bold))
                    }
                    .buttonStyle(.plain)
                    .foregroundStyle(.cyan)
                }
                Text("\(model.outputFiles.count)")
                    .font(.system(size: 11, weight: .bold))
                    .foregroundStyle(.white.opacity(0.45))
            }
            if model.outputFiles.isEmpty {
                Text("Сохранённых .safetensors/checkpoint-файлов пока нет.")
                    .font(.system(size: 12))
                    .foregroundStyle(.white.opacity(0.45))
            } else {
                ForEach(model.outputFiles.suffix(8)) { file in
                    HStack(spacing: 10) {
                        Image(systemName: file.name.lowercased().hasSuffix(".safetensors") ? "shippingbox.fill" : "doc.fill")
                            .foregroundStyle(.cyan)
                            .frame(width: 28)
                        VStack(alignment: .leading, spacing: 2) {
                            Text(file.name)
                                .font(.system(size: 12, weight: .semibold, design: .monospaced))
                                .foregroundStyle(.white)
                                .lineLimit(1)
                            Text(file.path)
                                .font(.system(size: 9.5, design: .monospaced))
                                .foregroundStyle(.white.opacity(0.35))
                                .lineLimit(1)
                        }
                        Spacer()
                        Text(file.sizeText)
                            .font(.system(size: 10, weight: .semibold))
                            .foregroundStyle(.white.opacity(0.5))
                    }
                    .padding(.vertical, 4)
                }
            }
        }
        .padding(15)
        .background(Color.white.opacity(0.055), in: RoundedRectangle(cornerRadius: 22))
    }

    private var logCard: some View {
        VStack(alignment: .leading, spacing: 9) {
            HStack {
                Text("Live Log").font(.system(size: 15, weight: .bold)).foregroundStyle(.white)
                Spacer()
                Button { Task { await model.refreshSelected(includeLogTail: true) } } label: {
                    Image(systemName: "arrow.clockwise").foregroundStyle(.white.opacity(0.7))
                }
            }
            ScrollView([.vertical, .horizontal]) {
                Text(model.logText.isEmpty ? "Log пока пуст." : model.logText)
                    .font(.system(size: 10.5, weight: .regular, design: .monospaced))
                    .foregroundStyle(.green.opacity(0.9))
                    .textSelection(.enabled)
                    .frame(maxWidth: .infinity, alignment: .leading)
            }
            .frame(minHeight: 190, maxHeight: 310)
        }
        .padding(15)
        .background(Color.black.opacity(0.5), in: RoundedRectangle(cornerRadius: 22))
        .overlay(RoundedRectangle(cornerRadius: 22).stroke(Color.green.opacity(0.12), lineWidth: 1))
    }
}

// MARK: - Settings / clone / datasets

private struct AIToolkitSettingsSheet: View {
    @Environment(\.dismiss) private var dismiss
    @ObservedObject var model: AIToolkitModel
    @State private var url = "http://127.0.0.1:8675"
    @State private var path = ""
    @State private var token = ""
    @State private var tokenAlreadySet = false
    @State private var loaded = false
    @State private var saving = false
    @State private var message = ""

    var body: some View {
        NavigationStack {
            Form {
                Section("AI Toolkit UI") {
                    TextField("URL", text: $url).textInputAutocapitalization(.never).autocorrectionDisabled()
                    TextField("Путь на ПК", text: $path).textInputAutocapitalization(.never).autocorrectionDisabled()
                    SecureField(tokenAlreadySet ? "Токен уже сохранён — оставь пустым" : "AI_TOOLKIT_AUTH token (если используется)", text: $token)
                }
                Section {
                    Button("Сохранить") {
                        Task {
                            saving = true
                            defer { saving = false }
                            do {
                                try await model.saveSettings(url: url, path: path, token: token.isEmpty && tokenAlreadySet ? nil : token)
                                message = "Сохранено"
                            } catch { message = error.localizedDescription }
                        }
                    }
                    .disabled(saving)
                    Button("Запустить UI") { Task { await model.startUI() } }
                    Button("Пересобрать и запустить UI") { Task { await model.startUI(rebuild: true) } }
                } footer: {
                    Text("Обычно URL оставляй 127.0.0.1:8675. Путь нужен только если сервер не может автоматически найти папку ai-toolkit.")
                }
                if !message.isEmpty { Section { Text(message) } }
            }
            .navigationTitle("AI Toolkit Settings")
            .toolbar { ToolbarItem(placement: .topBarTrailing) { Button("Готово") { dismiss() } } }
        }
        .task {
            guard !loaded else { return }
            loaded = true
            do {
                let settings = try await model.loadSettings()
                url = settings.url
                path = settings.path.isEmpty ? (settings.detectedPath ?? "") : settings.path
                tokenAlreadySet = settings.tokenSet
            } catch { message = error.localizedDescription }
        }
    }
}

private struct AIToolkitCloneSheet: View {
    @Environment(\.dismiss) private var dismiss
    @ObservedObject var model: AIToolkitModel
    let job: AIToolkitJob

    @State private var name = ""
    @State private var trigger = ""
    @State private var dataset = ""
    @State private var modelPath = ""
    @State private var modelArch = ""
    @State private var steps = 2000
    @State private var lr = 0.0001
    @State private var rank = 32
    @State private var alpha = 32
    @State private var batch = 1
    @State private var resolution = 1024
    @State private var gpu = "0"

    var body: some View {
        NavigationStack {
            Form {
                Section("Новый job из \(job.name)") {
                    TextField("Имя", text: $name).textInputAutocapitalization(.never).autocorrectionDisabled()
                    TextField("Trigger word", text: $trigger).textInputAutocapitalization(.never).autocorrectionDisabled()
                    TextField("Dataset path", text: $dataset).textInputAutocapitalization(.never).autocorrectionDisabled()
                    if !model.datasets.isEmpty {
                        Menu {
                            ForEach(model.datasets, id: \.self) { datasetName in
                                Button(datasetName) {
                                    Task {
                                        if let response = try? await model.datasetImages(datasetName) {
                                            dataset = response.root.trimmingCharacters(in: CharacterSet(charactersIn: "\\/"))
                                        }
                                    }
                                }
                            }
                        } label: {
                            Label("Выбрать dataset с ПК", systemImage: "photo.stack")
                        }
                    }
                }
                Section("Model") {
                    TextField("Model path", text: $modelPath).textInputAutocapitalization(.never).autocorrectionDisabled()
                    TextField("Architecture", text: $modelArch).textInputAutocapitalization(.never).autocorrectionDisabled()
                    TextField("GPU", text: $gpu).keyboardType(.numbersAndPunctuation)
                }
                Section("Training") {
                    Stepper("Steps: \(steps)", value: $steps, in: 50...100_000, step: 50)
                    HStack { Text("Learning rate"); Spacer(); TextField("LR", value: $lr, format: .number).multilineTextAlignment(.trailing).keyboardType(.decimalPad) }
                    Stepper("Rank: \(rank)", value: $rank, in: 1...512)
                    Stepper("Alpha: \(alpha)", value: $alpha, in: 1...512)
                    Stepper("Batch: \(batch)", value: $batch, in: 1...32)
                    Stepper("Resolution: \(resolution)", value: $resolution, in: 256...2048, step: 64)
                }
                Section {
                    Button("Создать копию job") {
                        let req = AIToolkitCloneRequest(
                            name: name, triggerWord: trigger, datasetPath: dataset,
                            modelPath: modelPath, modelArch: modelArch,
                            steps: steps, learningRate: lr, rank: rank, alpha: alpha,
                            batchSize: batch, resolution: resolution, gpuIDs: gpu
                        )
                        Task { if await model.clone(job: job, request: req) { dismiss() } }
                    }
                    .disabled(name.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty || model.busy)
                }
            }
            .navigationTitle("Duplicate Job")
            .toolbar { ToolbarItem(placement: .topBarTrailing) { Button("Отмена") { dismiss() } } }
        }
        .onAppear {
            let s = job.summary
            name = job.name + "_copy"
            trigger = s?.triggerWord ?? ""
            dataset = s?.datasetPath ?? ""
            modelPath = s?.modelPath ?? ""
            modelArch = s?.modelArch ?? ""
            steps = s?.steps ?? max(job.totalSteps, 2000)
            lr = s?.lr ?? 0.0001
            rank = s?.rank ?? 32
            alpha = s?.alpha ?? rank
            batch = s?.batchSize ?? 1
            resolution = s?.resolution?.first ?? 1024
            gpu = job.gpuIDs
        }
    }
}

private struct AIToolkitDatasetSheet: View {
    @Environment(\.dismiss) private var dismiss
    @ObservedObject var model: AIToolkitModel
    let dataset: String
    @State private var root = ""
    @State private var images: [String] = []
    @State private var error = ""

    private var fullPaths: [String] { images.map { root + $0 } }

    var body: some View {
        NavigationStack {
            ZStack {
                Color.black.ignoresSafeArea()
                ScrollView {
                    if !error.isEmpty { Text(error).foregroundStyle(.red).padding() }
                    LazyVGrid(columns: [GridItem(.flexible()), GridItem(.flexible()), GridItem(.flexible())], spacing: 4) {
                        ForEach(fullPaths, id: \.self) { path in
                            AITKRemoteMediaTile(model: model, path: path, compact: true)
                        }
                    }
                    .padding(4)
                }
            }
            .navigationTitle(dataset)
            .navigationBarTitleDisplayMode(.inline)
            .toolbar { ToolbarItem(placement: .topBarTrailing) { Button("Готово") { dismiss() } } }
        }
        .task {
            do {
                let response = try await model.datasetImages(dataset)
                root = response.root
                images = Array(response.images.prefix(400))
            } catch let caught { error = caught.localizedDescription }
        }
    }
}

// MARK: - Small reusable AI Toolkit components

private struct AITKRemoteMediaTile: View {
    @ObservedObject var model: AIToolkitModel
    let path: String
    var compact = false
    @State private var image: UIImage?
    @State private var loading = true

    private var isVideo: Bool {
        let low = path.lowercased()
        return [".mp4", ".mov", ".m4v", ".avi", ".mkv", ".webm"].contains { low.hasSuffix($0) }
    }

    var body: some View {
        ZStack {
            RoundedRectangle(cornerRadius: compact ? 5 : 14).fill(Color.white.opacity(0.06))
            if let image {
                Image(uiImage: image).resizable().scaledToFill()
            } else if isVideo {
                VStack(spacing: 5) {
                    Image(systemName: "video.fill").font(.system(size: compact ? 20 : 28)).foregroundStyle(.purple)
                    if !compact { Text(URL(fileURLWithPath: path).lastPathComponent).font(.system(size: 9)).foregroundStyle(.white.opacity(0.55)).lineLimit(2) }
                }
            } else if loading {
                ProgressView().tint(.white)
            } else {
                Image(systemName: "photo").foregroundStyle(.white.opacity(0.35))
            }
        }
        .frame(width: compact ? nil : 128, height: compact ? 112 : 128)
        .aspectRatio(compact ? 1 : nil, contentMode: .fit)
        .clipShape(RoundedRectangle(cornerRadius: compact ? 5 : 14))
        .task(id: path) {
            loading = true
            defer { loading = false }
            if !isVideo, let data = try? await model.mediaData(path: path), let ui = UIImage(data: data) { image = ui }
        }
    }
}

private struct AITKLossGraph: View {
    let points: [AIToolkitLossPoint]

    var body: some View {
        GeometryReader { geo in
            let values = points.compactMap { $0.value }
            if values.count < 2 {
                ZStack {
                    RoundedRectangle(cornerRadius: 12).fill(Color.black.opacity(0.24))
                    Text("Loss data появится после начала обучения")
                        .font(.system(size: 11)).foregroundStyle(.white.opacity(0.36))
                }
            } else {
                let minV = values.min() ?? 0
                let maxV = values.max() ?? 1
                let span = max(maxV - minV, 0.0000001)
                ZStack {
                    RoundedRectangle(cornerRadius: 12).fill(Color.black.opacity(0.24))
                    Path { path in
                        for (index, value) in values.enumerated() {
                            let x = geo.size.width * CGFloat(index) / CGFloat(max(values.count - 1, 1))
                            let normalized = (value - minV) / span
                            let y = geo.size.height - geo.size.height * CGFloat(normalized)
                            if index == 0 { path.move(to: CGPoint(x: x, y: y)) }
                            else { path.addLine(to: CGPoint(x: x, y: y)) }
                        }
                    }
                    .stroke(Color.cyan, style: StrokeStyle(lineWidth: 1.6, lineJoin: .round))
                    .padding(7)
                }
            }
        }
    }
}

private struct AITKKeyValue: View {
    let key: String
    let value: String
    var body: some View {
        HStack(alignment: .top, spacing: 12) {
            Text(key).font(.system(size: 11, weight: .semibold)).foregroundStyle(.white.opacity(0.42)).frame(width: 82, alignment: .leading)
            Text(value).font(.system(size: 11, weight: .medium, design: .monospaced)).foregroundStyle(.white.opacity(0.75)).frame(maxWidth: .infinity, alignment: .leading).textSelection(.enabled)
        }
    }
}

private struct AITKStatusPill: View {
    let status: String
    private var accent: Color {
        switch status.lowercased() {
        case "running": return .green
        case "queued": return .orange
        case "stopping": return .yellow
        case "failed", "error": return .red
        default: return .gray
        }
    }
    var body: some View {
        Text(status.uppercased())
            .font(.system(size: 9, weight: .heavy, design: .rounded))
            .foregroundStyle(accent)
            .padding(.horizontal, 8).padding(.vertical, 5)
            .background(accent.opacity(0.13), in: Capsule())
    }
}

private struct AITKMessage: View {
    let text: String
    let icon: String
    var body: some View {
        HStack(alignment: .top, spacing: 10) {
            Image(systemName: icon).foregroundStyle(.orange)
            Text(text).font(.system(size: 12)).foregroundStyle(.white.opacity(0.62)).frame(maxWidth: .infinity, alignment: .leading)
        }
        .padding(13)
        .background(Color.white.opacity(0.055), in: RoundedRectangle(cornerRadius: 17))
    }
}

private struct AITKBackground: View {
    var body: some View {
        ZStack {
            LinearGradient(colors: [Color.black, Color(red: 0.06, green: 0.025, blue: 0.11), Color.black], startPoint: .topLeading, endPoint: .bottomTrailing)
            Circle().fill(Color.purple.opacity(0.16)).frame(width: 300, height: 300).blur(radius: 70).offset(x: 140, y: -280)
            Circle().fill(Color.cyan.opacity(0.08)).frame(width: 260, height: 260).blur(radius: 70).offset(x: -150, y: 320)
        }
    }
}

private struct AITKCompactButtonStyle: ButtonStyle {
    let accent: Color
    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .font(.system(size: 11, weight: .bold))
            .foregroundStyle(.white)
            .padding(.horizontal, 11).padding(.vertical, 9)
            .background(accent.opacity(configuration.isPressed ? 0.22 : 0.14), in: RoundedRectangle(cornerRadius: 11))
    }
}

private struct AITKWideButtonStyle: ButtonStyle {
    let accent: Color
    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .font(.system(size: 12, weight: .bold))
            .foregroundStyle(.white)
            .frame(maxWidth: .infinity)
            .padding(.vertical, 12)
            .background(accent.opacity(configuration.isPressed ? 0.28 : 0.17), in: RoundedRectangle(cornerRadius: 14))
            .overlay(RoundedRectangle(cornerRadius: 14).stroke(accent.opacity(0.24), lineWidth: 1))
    }
}
