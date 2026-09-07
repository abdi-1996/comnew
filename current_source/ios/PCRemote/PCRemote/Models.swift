import Foundation

struct StatusResponse: Codable {
    let ok: Bool
    let computer: String
    let ip: String
    let port: Int
    let locked: Bool?
    let mac: String?
    let broadcast: String?
    let tailscale_ip: String?
    let tailscale_dns: String?
    let tailscale_online: Bool?
    let zerotier_ip: String?
    let zerotier_online: Bool?
    let transport: String?
    let server_version: String?
    let api_version: Int?
    let features: [String: Bool]?

    var tailscaleIP: String? { tailscale_ip }
    var tailscaleDNS: String? { tailscale_dns }
    var zerotierIP: String? { zerotier_ip }
}

struct ServerModuleCapability: Codable, Hashable {
    let supported: Bool
    let enabled: Bool
    let status: String?
    let detail: String?
}

struct ServerCapabilitiesResponse: Codable {
    let ok: Bool
    let server_version: String
    let api_version: Int
    let stable_api: Bool?
    let modules: [String: ServerModuleCapability]
    let features: [String: Bool]

    var serverVersion: String { server_version }
    var apiVersion: Int { api_version }

    func module(_ key: String) -> ServerModuleCapability? {
        modules[key]
    }
}

struct RemoteApp: Codable, Identifiable, Hashable {
    let id: String
    let name: String
    let icon: String
    let integration: String?
    let aliases: [String]?

    /// Fail-safe recognition on the phone as well as on the Windows server.
    /// This lets portable ComfyUI launchers such as run_nvidia_gpu*.bat render
    /// as ComfyUI even if the server was upgraded a moment later than the IPA.
    var isComfyUI: Bool {
        let lowName = name.lowercased()
        let lowID = id.lowercased()
        if integration?.lowercased() == "comfyui" { return true }
        if lowName.contains("comfyui") || lowName.contains("comfy ui") { return true }
        if lowID.contains("comfyui") || lowID.contains("comfy ui") { return true }
        if lowName.contains("run_nvidia_gpu") || lowID.contains("run_nvidia_gpu") { return true }
        if lowName.contains("fast_fp16_accumulation") || lowID.contains("fast_fp16_accumulation") { return true }
        return false
    }

    var isCorelDRAW: Bool {
        let lowName = name.lowercased()
        let lowID = id.lowercased()
        if integration?.lowercased() == "coreldraw" { return true }
        if lowName.contains("coreldraw") || lowName.contains("corel draw") { return true }
        if lowID.contains("coreldraw") || lowID.contains("corel draw") { return true }
        return false
    }

    var displayName: String {
        if isComfyUI { return "ComfyUI" }
        if isCorelDRAW { return "CorelDRAW" }
        return name
    }

    var searchableText: String {
        ([displayName, name, id, integration ?? ""] + (aliases ?? []))
            .joined(separator: " ")
            .lowercased()
    }
}

struct FileItem: Codable, Identifiable, Hashable {
    var id: String { path }
    let name: String
    let path: String
    let kind: String
    let icon: String?
    let size: Int64?
    let mtime: Double?
    var isFolder: Bool { kind == "folder" }
}

struct ActionResponse: Codable {
    let ok: Bool
    let error: String?
}

struct TailscaleStatusResponse: Codable {
    let ok: Bool
    let installed: Bool
    let enabled: Bool
    let online: Bool
    let ip: String?
    let dns: String?
    let backend_state: String?
    let disconnecting: Bool?
    let error: String?

    var backendState: String { backend_state ?? "Unknown" }
}

struct AuthLoginResponse: Codable {
    let ok: Bool
    let token: String?
    let status: StatusResponse?
    let error: String?
}

struct FileUploadResponse: Codable {
    let ok: Bool
    let error: String?
    let item: FileItem?
}

struct SavedDevice: Codable, Identifiable, Hashable {
    var id: UUID
    var name: String
    var host: String
    var port: Int
    var password: String
    var connectionID: String?
    var macAddress: String?
    var broadcastAddress: String?
    var tailscaleHost: String?
    var tailscaleDNS: String?
    var zerotierHost: String?

    init(
        id: UUID = UUID(),
        name: String,
        host: String,
        port: Int,
        password: String,
        connectionID: String? = nil,
        macAddress: String? = nil,
        broadcastAddress: String? = nil,
        tailscaleHost: String? = nil,
        tailscaleDNS: String? = nil,
        zerotierHost: String? = nil
    ) {
        self.id = id
        self.name = name
        self.host = host
        self.port = port
        self.password = password
        self.connectionID = connectionID
        self.macAddress = macAddress
        self.broadcastAddress = broadcastAddress
        self.tailscaleHost = tailscaleHost
        self.tailscaleDNS = tailscaleDNS
        self.zerotierHost = zerotierHost
    }

    var storageKey: String {
        if let connectionID, !connectionID.isEmpty { return connectionID }
        return "\(host):\(port)"
    }
}

enum ConnectionRouteMode: String, CaseIterable, Identifiable {
    case automatic
    case tailscale
    case zerotier
    case lan

    var id: String { rawValue }

    var title: String {
        switch self {
        case .automatic: return "Авто"
        case .tailscale: return "Tailscale"
        case .zerotier: return "ZeroTier"
        case .lan: return "LAN"
        }
    }

    var detail: String {
        switch self {
        case .automatic: return "LAN → ZeroTier → Tailscale"
        case .tailscale: return "Подключаться только через Tailscale"
        case .zerotier: return "Подключаться только через ZeroTier"
        case .lan: return "Подключаться только по локальному IP"
        }
    }
}

enum AppearanceMode: String, CaseIterable, Identifiable {
    case automatic
    case light
    case dark

    var id: String { rawValue }

    var title: String {
        switch self {
        case .automatic: return "Авто"
        case .light: return "Светлая"
        case .dark: return "Тёмная"
        }
    }
}

enum ThemeStyle: String, CaseIterable, Identifiable {
    case windowsBlue
    case glass
    case graphite
    case aurora

    var id: String { rawValue }

    var title: String {
        switch self {
        case .windowsBlue: return "Windows 11"
        case .glass: return "Стекло"
        case .graphite: return "Графит"
        case .aurora: return "Аврора"
        }
    }
}

enum RemoteQualityMode: String, CaseIterable, Identifiable {
    case quality
    case balanced
    case latency

    var id: String { rawValue }

    var title: String {
        switch self {
        case .quality: return "Качество"
        case .balanced: return "Баланс"
        case .latency: return "Мин. задержка"
        }
    }

    var shortTitle: String {
        switch self {
        case .quality: return "Качество"
        case .balanced: return "Баланс"
        case .latency: return "Задержка"
        }
    }

    var intervalNanoseconds: UInt64 {
        switch self {
        case .quality: return 125_000_000
        case .balanced: return 83_000_000
        case .latency: return 50_000_000
        }
    }
}

struct RemoteModeDetails: Codable {
    let fps: Int
    let jpeg: Int
    let max_width: Int
}

struct RemoteScreenInfo: Codable {
    let ok: Bool
    let width: Int
    let height: Int
    let modes: [String: RemoteModeDetails]?
}

struct RemoteFocusInfo: Codable {
    let ok: Bool
    let text_input: Bool
}


// MARK: - ComfyUI

struct ComfyWorkflow: Codable, Identifiable, Hashable {
    let id: String
    let name: String
    let source: String
    let node_count: Int
    let category: String?
    let editable: Bool?
    let executable: Bool?
    let format: String?

    var nodeCount: Int { node_count }
    var isRecent: Bool { category == "recent" || source.localizedCaseInsensitiveContains("История") }
    var canEdit: Bool { editable ?? true }
    var canExecute: Bool { executable ?? true }
}

struct ComfyNodeInput: Codable, Identifiable, Hashable {
    var id: String { name }
    let name: String
    var value: String
    let value_type: String
    let options: [String]?
    let connected_from: String?
    let input_type: String?
    let slot: Int?

    var valueType: String { value_type }
    var connectedFrom: String? { connected_from }
    var inputType: String { input_type ?? "*" }
    var isConnection: Bool { value_type == "connection" }
}

struct ComfyNodePort: Codable, Identifiable, Hashable {
    var id: String { "\(slot):\(name)" }
    let name: String
    let type: String
    let slot: Int
}

struct ComfyNodeInfo: Codable, Identifiable, Hashable {
    let id: String
    var title: String
    let class_type: String
    var color: String
    var placement: String
    var width_mode: String
    var muted: Bool
    var inputs: [ComfyNodeInput]
    var outputs: [ComfyNodePort]?
    var position_x: Double?
    var position_y: Double?
    var node_width: Double?
    var node_height: Double?

    var classType: String { class_type }
    var widthMode: String {
        get { width_mode }
        set { width_mode = newValue }
    }
    var positionX: Double { position_x ?? 180 }
    var positionY: Double { position_y ?? 160 }
    var nodeWidth: Double { max(150, node_width ?? (width_mode == "wide" ? 330 : 220)) }
    var nodeHeight: Double { max(120, node_height ?? 170) }
}

struct ComfyNodeConnection: Codable, Hashable, Identifiable {
    var id: String { "\(from):\(from_slot ?? 0)->\(to):\(to_slot ?? 0):\(input_name ?? "")" }
    let from: String
    let to: String
    let label: String?
    let from_slot: Int?
    let to_slot: Int?
    let input_name: String?
    let type: String?

    var fromSlot: Int { from_slot ?? 0 }
    var toSlot: Int { to_slot ?? 0 }
    var inputName: String? { input_name }
}

struct ComfyNodeCatalogItem: Codable, Identifiable, Hashable {
    let id: String
    let class_type: String
    let display_name: String
    let category: String
    let recommended: Bool
    let inputs: [ComfyNodeInput]
    let outputs: [ComfyNodePort]

    var classType: String { class_type }
    var displayName: String { display_name }
}

struct ComfyNodeCatalogResponse: Codable {
    let ok: Bool
    let nodes: [ComfyNodeCatalogItem]
    let error: String?
}

struct ComfyWorkflowDetailsResponse: Codable {
    let ok: Bool
    let workflow_id: String
    let name: String
    let format: String
    let executable: Bool
    let nodes: [ComfyNodeInfo]
    let connections: [ComfyNodeConnection]
    let error: String?

    var workflowID: String { workflow_id }
}

struct ComfyImportResponse: Codable {
    let ok: Bool
    let error: String?
    let workflow: ComfyWorkflow?
}

struct ComfyParameters: Codable, Hashable {
    var positive: String
    var negative: String
    var steps: Int
    var cfg: Double
    var seed: Int64
    var sampler: String
    var scheduler: String
    var width: Int
    var height: Int
    var checkpoint: String
    var lora: String
    var vae: String
}

struct ComfyImageItem: Codable, Identifiable, Hashable {
    let id: String
    let filename: String
    let subfolder: String
    let type: String
    let prompt_id: String
    var workflow_id: String? = nil
    var positive: String? = nil
    var negative: String? = nil
    var steps: Int? = nil
    var cfg: Double? = nil
    var seed: Int64? = nil
    var sampler: String? = nil
    var scheduler: String? = nil
    var width: Int? = nil
    var height: Int? = nil
    var checkpoint: String? = nil
    var lora: String? = nil
    var vae: String? = nil

    var promptID: String { prompt_id }
    var workflowID: String { workflow_id ?? "" }
    var fileExtension: String { URL(fileURLWithPath: filename).pathExtension.lowercased() }
    var isVideo: Bool { ["mp4", "mov", "m4v", "webm", "avi", "mkv"].contains(fileExtension) }
    var isAudio: Bool { ["mp3", "wav", "m4a", "aac", "flac", "ogg", "opus", "aiff", "aif", "wma"].contains(fileExtension) }
    var isAnimatedImage: Bool { ["gif", "webp"].contains(fileExtension) }
    var mediaKind: String { isAudio ? "audio" : (isVideo ? "video" : "image") }
}

struct ComfySystemStats: Codable, Hashable {
    let cpu_percent: Double
    let ram_used_gb: Double
    let ram_total_gb: Double
    let gpu_percent: Double?
    let gpu_temperature: Double?
    let gpu_name: String?
    let vram_used_gb: Double?
    let vram_total_gb: Double?

    var cpuPercent: Double { cpu_percent }
    var ramUsedGB: Double { ram_used_gb }
    var ramTotalGB: Double { ram_total_gb }
    var gpuPercent: Double? { gpu_percent }
    var gpuTemperature: Double? { gpu_temperature }
    var gpuName: String? { gpu_name }
    var vramUsedGB: Double? { vram_used_gb }
    var vramTotalGB: Double? { vram_total_gb }
}

struct ComfyDashboardResponse: Codable {
    let ok: Bool
    let available: Bool
    let message: String?
    let running: Bool
    let progress: Double
    let queue_remaining: Int
    let current_node: String?
    let prompt_id: String?
    let error: String?
    let workflows: [ComfyWorkflow]
    let selected_workflow: String?
    let parameters: ComfyParameters
    let checkpoints: [String]
    let loras: [String]
    let vaes: [String]
    let samplers: [String]
    let schedulers: [String]
    let images: [ComfyImageItem]
    let gpu: String?
    let vram: String?
    let system: ComfySystemStats?
    let model_profile: String?
    let media_type: String?
    let stage: String?
    let started_at: Double?
    let finished_at: Double?

    var queueRemaining: Int { queue_remaining }
    var currentNode: String? { current_node }
    var promptID: String? { prompt_id }
    var selectedWorkflow: String? { selected_workflow }
    var modelProfile: String { model_profile ?? "generic" }
    var mediaType: String { media_type ?? "image" }
    var generationStage: String { stage ?? (running ? "executing" : (queue_remaining > 0 ? "queued" : "idle")) }
    var startedAt: Double? { started_at }
    var finishedAt: Double? { finished_at }
}

struct ComfyGenerateResponse: Codable {
    let ok: Bool
    let prompt_id: String?
    let error: String?
    var workflow_id: String? = nil
}

struct ComfyGenerateRequest: Codable {
    let workflow_id: String
    let parameters: ComfyParameters
    let output_node_id: String?
}


// MARK: - CorelDRAW

struct CorelShapeInfo: Codable, Identifiable, Hashable {
    let id: String
    let index: Int
    let name: String
    let type: Int
    let x: Double
    let y: Double
    let width: Double
    let height: Double
    let rotation: Double
    let text: String?
    let selected: Bool?

    var isSelected: Bool { selected ?? false }
}

struct CorelWorkspace: Codable, Identifiable, Hashable {
    let id: String
    let kind: String
    let title: String
    let created_at: Double
    let import_count: Int
    let page_index: Int
    let page_count: Int
    let selection_count: Int
    let document_name: String

    var isTrace: Bool { kind == "trace" }
    var isConverter: Bool { kind == "converter" }
    var importCount: Int { import_count }
    var pageIndex: Int { page_index }
    var pageCount: Int { page_count }
    var selectionCount: Int { selection_count }
}

struct CorelWorkspaceListResponse: Codable {
    let ok: Bool
    let running: Bool
    let version: String?
    let workspaces: [CorelWorkspace]
    let error: String?
}

struct CorelWorkspaceResponse: Codable {
    let ok: Bool
    let workspace: CorelWorkspace?
    let error: String?
}

struct CorelWorkspaceMutationResponse: Codable {
    let ok: Bool
    let workspace: CorelWorkspace?
    let objects: [CorelShapeInfo]?
    let error: String?
}

struct CorelExportResponse: Codable {
    let ok: Bool
    let path: String?
    let filename: String?
    let size: Int64?
    let format: String?
    let destination: String?
    let export_id: String?
    let error: String?
}

struct CorelStatusResponse: Codable {
    let ok: Bool
    let running: Bool
    let document_open: Bool
    let document_name: String
    let document_path: String
    let dirty: Bool
    let page_index: Int
    let page_count: Int
    let selection_count: Int
    let selection: CorelShapeInfo?
    let version: String?
    let error: String?

    var documentOpen: Bool { document_open }
    var documentName: String { document_name }
    var documentPath: String { document_path }
    var pageIndex: Int { page_index }
    var pageCount: Int { page_count }
    var selectionCount: Int { selection_count }
}

// MARK: - Task Manager

struct TaskProcess: Codable, Identifiable, Hashable {
    let pid: Int
    let name: String
    let cpu: Double
    let memory_mb: Double

    var id: Int { pid }
}

struct TaskWindow: Codable, Identifiable, Hashable {
    let hwnd: Int64
    let pid: Int
    let title: String
    let process_name: String
    let minimized: Bool
    let maximized: Bool
    let responding: Bool

    var id: Int64 { hwnd }
    var processName: String { process_name }
}

struct TaskManagerSnapshot: Codable {
    let cpu_percent: Double
    let memory_percent: Double
    let memory_used_gb: Double
    let memory_total_gb: Double
    let processes: [TaskProcess]
    let windows: [TaskWindow]?

    var openWindows: [TaskWindow] { windows ?? [] }
}
