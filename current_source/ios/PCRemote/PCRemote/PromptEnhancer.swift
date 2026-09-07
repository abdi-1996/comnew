import Foundation
import SwiftUI
import llama

// MARK: - Local prompt enhancer (iPhone only)

private enum PromptEnhancerError: LocalizedError {
    case modelMissing
    case downloadFailed(String)
    case modelLoadFailed
    case contextLoadFailed
    case promptTooLarge
    case decodeFailed
    case emptyResult

    var errorDescription: String? {
        switch self {
        case .modelMissing: return "Сначала скачайте лёгкую модель Prompt Enhancer."
        case .downloadFailed(let message): return "Не удалось скачать модель: \(message)"
        case .modelLoadFailed: return "Не удалось загрузить Qwen на iPhone."
        case .contextLoadFailed: return "Не удалось создать локальный LLM-контекст."
        case .promptTooLarge: return "Промт слишком длинный для лёгкого enhancer."
        case .decodeFailed: return "Ошибка локального inference llama.cpp."
        case .emptyResult: return "Enhancer не вернул текст. Попробуйте ещё раз."
        }
    }
}

enum PromptEnhancerMode: String, CaseIterable, Identifiable {
    case light
    case detailed
    case creative

    var id: String { rawValue }
    var title: String {
        switch self {
        case .light: return "Light"
        case .detailed: return "Detailed"
        case .creative: return "Creative"
        }
    }

    var instruction: String {
        switch self {
        case .light:
            return "Make a restrained improvement. Preserve the user's wording and intent; add only the most useful missing visual details."
        case .detailed:
            return "Expand the idea into a detailed production-ready prompt with coherent composition, lighting, environment and visual details."
        case .creative:
            return "Develop the idea more creatively while preserving the core subject and all explicit user constraints. Add tasteful cinematic or photographic details."
        }
    }
}

struct PromptEnhancerRequest {
    let prompt: String
    let profile: String
    let mediaType: String
    let checkpoint: String
    let lora: String
    let mode: PromptEnhancerMode
    let preserveSubject: Bool
    let preserveClothing: Bool
    let addCamera: Bool
    let addLighting: Bool
    let addEnvironment: Bool
}

@MainActor
final class PromptEnhancerModelStore: ObservableObject {
    static let shared = PromptEnhancerModelStore()

    @Published private(set) var isDownloading = false
    @Published private(set) var isInstalled = false
    @Published var errorMessage = ""

    let displayName = "Qwen3 0.6B · Local"
    let approximateSize = "≈ 639 MB"

    private let modelFilename = "Qwen3-0.6B-Q8_0.gguf"
    private let downloadURL = URL(string: "https://huggingface.co/Qwen/Qwen3-0.6B-GGUF/resolve/main/Qwen3-0.6B-Q8_0.gguf?download=true")!

    private init() {
        refresh()
    }

    var modelURL: URL {
        let fm = FileManager.default
        let root = (try? fm.url(for: .applicationSupportDirectory, in: .userDomainMask, appropriateFor: nil, create: true))
            ?? fm.urls(for: .documentDirectory, in: .userDomainMask)[0]
        return root
            .appendingPathComponent("ComfyRemote", isDirectory: true)
            .appendingPathComponent("PromptEnhancer", isDirectory: true)
            .appendingPathComponent(modelFilename, isDirectory: false)
    }

    func refresh() {
        isInstalled = isValidModelFile(at: modelURL)
        if FileManager.default.fileExists(atPath: modelURL.path) && !isInstalled {
            try? FileManager.default.removeItem(at: modelURL)
        }
    }

    private func isValidModelFile(at url: URL) -> Bool {
        guard let attributes = try? FileManager.default.attributesOfItem(atPath: url.path),
              let size = attributes[.size] as? NSNumber,
              size.int64Value > 500_000_000,
              let handle = try? FileHandle(forReadingFrom: url) else { return false }
        defer { try? handle.close() }
        guard let magic = try? handle.read(upToCount: 4), magic.count == 4 else { return false }
        return Array(magic) == [0x47, 0x47, 0x55, 0x46] // GGUF
    }

    func download() async {
        guard !isDownloading else { return }
        isDownloading = true
        errorMessage = ""
        defer { isDownloading = false }

        do {
            let (temporaryURL, response) = try await URLSession.shared.download(from: downloadURL)
            guard let http = response as? HTTPURLResponse, (200...299).contains(http.statusCode) else {
                throw PromptEnhancerError.downloadFailed("HTTP \((response as? HTTPURLResponse)?.statusCode ?? 0)")
            }

            let fm = FileManager.default
            let directory = modelURL.deletingLastPathComponent()
            try fm.createDirectory(at: directory, withIntermediateDirectories: true)
            if fm.fileExists(atPath: modelURL.path) { try fm.removeItem(at: modelURL) }
            try fm.moveItem(at: temporaryURL, to: modelURL)
            guard isValidModelFile(at: modelURL) else {
                try? fm.removeItem(at: modelURL)
                throw PromptEnhancerError.downloadFailed("получен повреждённый или неполный GGUF-файл")
            }

            var values = URLResourceValues()
            values.isExcludedFromBackup = true
            var file = modelURL
            try? file.setResourceValues(values)
            isInstalled = true
        } catch {
            errorMessage = error.localizedDescription
            refresh()
        }
    }

    func remove() {
        try? FileManager.default.removeItem(at: modelURL)
        refresh()
    }
}

private enum PromptKnowledgeBase {
    static func normalizedProfile(_ profile: String, checkpoint: String, mediaType: String) -> String {
        let blob = "\(profile) \(checkpoint)".lowercased()
        if blob.contains("wan2.2") || blob.contains("wan 2.2") || profile == "wan22" { return "wan22" }
        if (blob.contains("z-image") || blob.contains("z_image") || blob.contains("zimage")) && blob.contains("turbo") { return "zimage_turbo" }
        if blob.contains("z-image") || blob.contains("z_image") || blob.contains("zimage") { return "zimage" }
        if blob.contains("sdxl") || blob.contains("stable diffusion xl") || profile == "sdxl" { return "sdxl" }
        if profile == "wan" || mediaType == "video" { return "wan22" }
        if profile == "generic_audio" || mediaType == "audio" { return "generic_audio" }
        return "generic_image"
    }

    static func title(for profile: String) -> String {
        switch profile {
        case "wan22": return "WAN 2.2"
        case "zimage_turbo": return "Z-Image Turbo"
        case "zimage": return "Z-Image"
        case "sdxl": return "SDXL"
        case "generic_audio": return "Audio"
        default: return "Image"
        }
    }

    static func rules(for profile: String) -> String {
        switch profile {
        case "wan22":
            return """
            This is a WAN 2.2 video prompt. Write one coherent shot, not a pile of tags.
            Preferred structure: subject and appearance -> primary action -> environment/time -> shot size -> camera angle -> ONE main camera movement -> subject/secondary motion -> lighting -> mood/color -> cinematic finish.
            Keep motion physically coherent through time. Avoid contradictory camera movements in the same shot. Describe what should happen positively and concretely.
            """
        case "zimage_turbo":
            return """
            This is a Z-Image Turbo image prompt. Use concise natural-language visual direction with strong subject clarity and photorealistic details when requested.
            Start from the user's subject, then establish composition/angle, lighting, environment, camera/lens cues and fine material/skin details. Do not turn it into SD tag soup.
            Turbo prompts should be efficient: remove redundant quality synonyms and conflicting instructions. Do not invent a negative prompt.
            """
        case "zimage":
            return """
            This is a Z-Image image prompt. Use coherent natural language and preserve explicit attributes exactly.
            Build from subject and action/pose into composition, lighting, environment, camera/lens language, style and material details. Prefer concrete visual descriptions over repeated quality buzzwords.
            """
        case "sdxl":
            return """
            This is an SDXL image prompt. Keep the important subject concepts early. Use concise comma-separated or short natural-language clauses when useful.
            Useful order: subject -> pose/action -> composition -> environment -> lighting -> camera/lens -> style/medium -> high-value detail. Avoid excessive duplicated quality tags and contradictory styles.
            """
        case "generic_audio":
            return """
            This is an audio-generation prompt. Describe genre, mood, tempo/energy, instrumentation, vocal character if requested, arrangement, production and sonic texture.
            Keep musical directions coherent. Do not add camera, lens, lighting or visual composition language. Preserve explicit lyrics, language, instruments and duration cues exactly.
            """
        default:
            return """
            Improve this image-generation prompt while preserving the user's explicit intent. Use clear subject, composition, lighting, environment, style and detail descriptions without redundant buzzwords.
            """
        }
    }

    static let photographicVocabulary = """
    Photography knowledge when relevant: eye-level, low-angle, high-angle, close-up, medium shot, full-body, over-the-shoulder, POV; 24mm environmental wide, 35mm documentary/street, 50mm natural perspective, 85mm portrait compression, 105mm close portrait/detail; soft window light, diffused softbox, golden hour, blue hour, overcast soft light, hard directional sunlight, neon practical lighting, rim light. Only add camera/lens details when they improve the requested image.
    """

    static let videoVocabulary = """
    Video camera vocabulary when relevant: static locked shot, slow push-in, pull-back, pan, tilt, tracking/dolly follow, controlled orbit, handheld documentary drift. Choose one primary movement unless the user explicitly asks for a compound move. Describe natural acceleration/deceleration and secondary hair/cloth/environment motion only when useful.
    """

    static let audioVocabulary = """
    Audio vocabulary when relevant: tempo and groove, acoustic/electronic instrumentation, lead/supporting vocals, verse/chorus or evolving instrumental structure, stereo width, dynamic range, transient detail, ambience/reverb, clean low end and balanced mastering. Use only musical or sonic terms that help the requested result.
    """
}

private final class LocalLlamaRuntime {
    private var model: OpaquePointer?
    private var context: OpaquePointer?
    private var vocab: OpaquePointer?
    private var sampler: UnsafeMutablePointer<llama_sampler>?
    private var batch: llama_batch
    private var backendInitialized = false

    init(modelPath: String) throws {
        llama_backend_init()
        backendInitialized = true

        var modelParams = llama_model_default_params()
        // Mirror llama.cpp's official Swift example: disable GPU only in Simulator.
        // On a real iPhone, keep llama.cpp's native Apple/Metal defaults.
        #if targetEnvironment(simulator)
        modelParams.n_gpu_layers = 0
        #endif

        let loadedModel = modelPath.withCString { path in
            llama_model_load_from_file(path, modelParams)
        }
        guard let loadedModel else {
            throw PromptEnhancerError.modelLoadFailed
        }
        model = loadedModel
        vocab = llama_model_get_vocab(loadedModel)

        var contextParams = llama_context_default_params()
        contextParams.n_ctx = 3072
        let threads = max(2, min(8, ProcessInfo.processInfo.processorCount - 2))
        contextParams.n_threads = Int32(threads)
        contextParams.n_threads_batch = Int32(threads)

        guard let loadedContext = llama_init_from_model(loadedModel, contextParams) else {
            throw PromptEnhancerError.contextLoadFailed
        }
        context = loadedContext
        batch = llama_batch_init(3072, 0, 1)

        let chainParams = llama_sampler_chain_default_params()
        let chain = llama_sampler_chain_init(chainParams)
        // Qwen3 recommends TopK=20, TopP=0.8 and temperature=0.7 in non-thinking mode.
        llama_sampler_chain_add(chain, llama_sampler_init_top_k(20))
        llama_sampler_chain_add(chain, llama_sampler_init_top_p(0.8, 1))
        llama_sampler_chain_add(chain, llama_sampler_init_temp(0.7))
        llama_sampler_chain_add(chain, llama_sampler_init_dist(UInt32.random(in: 1...UInt32.max)))
        sampler = chain
    }

    deinit {
        if let sampler { llama_sampler_free(sampler) }
        llama_batch_free(batch)
        if let context { llama_free(context) }
        if let model { llama_model_free(model) }
        if backendInitialized { llama_backend_free() }
    }

    func generate(_ prompt: String, maxNewTokens: Int = 320) throws -> String {
        guard let context, let vocab, let sampler else { throw PromptEnhancerError.contextLoadFailed }
        let tokens = try tokenize(prompt, vocab: vocab)
        guard tokens.count < 2550 else { throw PromptEnhancerError.promptTooLarge }

        clearBatch()
        for (index, token) in tokens.enumerated() {
            add(token: token, position: Int32(index), logits: index == tokens.count - 1)
        }
        guard llama_decode(context, batch) == 0 else { throw PromptEnhancerError.decodeFailed }

        var position = Int32(tokens.count)
        var output = ""
        var pendingBytes: [CChar] = []

        for _ in 0..<maxNewTokens {
            let token = llama_sampler_sample(sampler, context, batch.n_tokens - 1)
            if llama_vocab_is_eog(vocab, token) { break }

            pendingBytes.append(contentsOf: tokenPiece(token, vocab: vocab))
            let decoded: String? = (pendingBytes + [0]).withUnsafeBufferPointer { ptr in
                guard let base = ptr.baseAddress else { return nil }
                return String(validatingUTF8: base)
            }
            if let decoded {
                output += decoded
                pendingBytes.removeAll(keepingCapacity: true)
            }

            clearBatch()
            add(token: token, position: position, logits: true)
            position += 1
            guard llama_decode(context, batch) == 0 else { throw PromptEnhancerError.decodeFailed }
        }

        if !pendingBytes.isEmpty {
            let tail = (pendingBytes + [0]).withUnsafeBufferPointer { ptr -> String in
                guard let base = ptr.baseAddress else { return "" }
                return String(cString: base)
            }
            output += tail
        }
        let cleaned = PromptEnhancerService.cleanModelOutput(output)
        guard !cleaned.isEmpty else { throw PromptEnhancerError.emptyResult }
        return cleaned
    }

    private func clearBatch() {
        batch.n_tokens = 0
    }

    private func add(token: llama_token, position: llama_pos, logits: Bool) {
        let index = Int(batch.n_tokens)
        batch.token[index] = token
        batch.pos[index] = position
        batch.n_seq_id[index] = 1
        batch.seq_id[index]![0] = 0
        batch.logits[index] = logits ? 1 : 0
        batch.n_tokens += 1
    }

    private func tokenize(_ text: String, vocab: OpaquePointer) throws -> [llama_token] {
        let length = text.utf8.count
        let capacity = max(256, length + 32)
        var buffer = [llama_token](repeating: 0, count: capacity)
        var count = text.withCString { cString in
            buffer.withUnsafeMutableBufferPointer { ptr in
                llama_tokenize(vocab, cString, Int32(length), ptr.baseAddress, Int32(ptr.count), true, true)
            }
        }
        if count < 0 {
            buffer = [llama_token](repeating: 0, count: Int(-count))
            count = text.withCString { cString in
                buffer.withUnsafeMutableBufferPointer { ptr in
                    llama_tokenize(vocab, cString, Int32(length), ptr.baseAddress, Int32(ptr.count), true, true)
                }
            }
        }
        guard count >= 0 else { throw PromptEnhancerError.decodeFailed }
        return Array(buffer.prefix(Int(count)))
    }

    private func tokenPiece(_ token: llama_token, vocab: OpaquePointer) -> [CChar] {
        var small = [CChar](repeating: 0, count: 16)
        let count = small.withUnsafeMutableBufferPointer { ptr in
            llama_token_to_piece(vocab, token, ptr.baseAddress, Int32(ptr.count), 0, false)
        }
        if count >= 0 { return Array(small.prefix(Int(count))) }
        var large = [CChar](repeating: 0, count: Int(-count))
        let second = large.withUnsafeMutableBufferPointer { ptr in
            llama_token_to_piece(vocab, token, ptr.baseAddress, Int32(ptr.count), 0, false)
        }
        guard second > 0 else { return [] }
        return Array(large.prefix(Int(second)))
    }
}

enum PromptEnhancerService {
    static func enhance(_ request: PromptEnhancerRequest, modelURL: URL) async throws -> String {
        guard FileManager.default.fileExists(atPath: modelURL.path) else { throw PromptEnhancerError.modelMissing }
        let fullPrompt = buildPrompt(request)
        let modelPath = modelURL.path
        return try await Task.detached(priority: .userInitiated) { () throws -> String in
            try autoreleasepool {
                let runtime = try LocalLlamaRuntime(modelPath: modelPath)
                return try runtime.generate(fullPrompt)
            }
        }.value
    }

    static func buildPrompt(_ request: PromptEnhancerRequest) -> String {
        let profile = PromptKnowledgeBase.normalizedProfile(request.profile, checkpoint: request.checkpoint, mediaType: request.mediaType)
        var constraints: [String] = []
        if request.preserveSubject { constraints.append("Never replace or materially alter the explicit subject/person/identity/concept.") }
        if request.preserveClothing { constraints.append("Preserve any explicitly stated clothing and colors exactly.") }
        if !request.addCamera { constraints.append("Do not add camera brand, lens, focal length or aperture unless already present.") }
        if !request.addLighting { constraints.append("Do not invent new lighting; preserve lighting if specified.") }
        if !request.addEnvironment { constraints.append("Do not invent a new location/background; preserve the existing environment.") }
        if !request.lora.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
            constraints.append("Active LoRA: \(request.lora). Do not contradict its apparent concept; do not invent unknown trigger words.")
        }

        let optionalKnowledge: String
        if profile == "wan22" { optionalKnowledge = PromptKnowledgeBase.videoVocabulary }
        else if profile == "generic_audio" { optionalKnowledge = PromptKnowledgeBase.audioVocabulary }
        else { optionalKnowledge = PromptKnowledgeBase.photographicVocabulary }
        let system = """
        You are a compact local prompt enhancer inside Comfy Remote. Your only job is to rewrite ONE prompt for the active generative model.
        Return ONLY the final enhanced prompt. No title, no bullets, no explanation, no quotes, no markdown.
        Write the final generation prompt in clear English even if the user writes in another language. Preserve proper names and literal text that must appear in an image.
        Do not add sexual content, violence, logos, text, people, objects, or story elements that the user did not request unless they are a small non-conflicting environmental detail in Creative mode.

        Active model profile: \(PromptKnowledgeBase.title(for: profile))
        \(PromptKnowledgeBase.rules(for: profile))
        \(optionalKnowledge)
        Enhancement level: \(request.mode.instruction)
        Constraints:
        \(constraints.isEmpty ? "- Preserve every explicit user constraint." : constraints.map { "- \($0)" }.joined(separator: "\n"))
        """

        // Qwen3-2504 models understand /no_think; the ChatML tokens are parsed as special tokens by llama.cpp.
        return """
        <|im_start|>system
        \(system)
        <|im_end|>
        <|im_start|>user
        Rewrite this prompt for \(PromptKnowledgeBase.title(for: profile)):
        \(request.prompt.trimmingCharacters(in: .whitespacesAndNewlines))
        /no_think
        <|im_end|>
        <|im_start|>assistant
        """
    }

    static func cleanModelOutput(_ text: String) -> String {
        var value = text.trimmingCharacters(in: .whitespacesAndNewlines)
        if let close = value.range(of: "</think>") { value = String(value[close.upperBound...]).trimmingCharacters(in: .whitespacesAndNewlines) }
        if let start = value.range(of: "<think>"), let end = value.range(of: "</think>", range: start.upperBound..<value.endIndex) {
            value.removeSubrange(start.lowerBound..<end.upperBound)
        }
        value = value.replacingOccurrences(of: "<|im_end|>", with: "")
        value = value.replacingOccurrences(of: "<|endoftext|>", with: "")
        let prefixes = ["Enhanced prompt:", "Prompt:", "Final prompt:"]
        for prefix in prefixes where value.lowercased().hasPrefix(prefix.lowercased()) {
            value = String(value.dropFirst(prefix.count)).trimmingCharacters(in: .whitespacesAndNewlines)
        }
        if value.hasPrefix("\"") && value.hasSuffix("\"") && value.count > 2 {
            value.removeFirst(); value.removeLast()
        }
        return value.trimmingCharacters(in: .whitespacesAndNewlines)
    }
}

struct PromptEnhancerSheet: View {
    @Environment(\.dismiss) private var dismiss
    @ObservedObject private var store = PromptEnhancerModelStore.shared

    let profile: String
    let mediaType: String
    let checkpoint: String
    let lora: String
    @Binding var prompt: String

    @State private var mode: PromptEnhancerMode = .detailed
    @State private var preserveSubject = true
    @State private var preserveClothing = true
    @State private var addCamera = true
    @State private var addLighting = true
    @State private var addEnvironment = true
    @State private var result = ""
    @State private var error = ""
    @State private var isEnhancing = false

    private var normalizedProfile: String {
        PromptKnowledgeBase.normalizedProfile(profile, checkpoint: checkpoint, mediaType: mediaType)
    }

    var body: some View {
        NavigationStack {
            ZStack {
                ComfyBackground()
                ScrollView(showsIndicators: false) {
                    VStack(spacing: 14) {
                        modelCard
                        if store.isInstalled { enhancerControls } else { installCard }
                        if !error.isEmpty { errorCard }
                    }
                    .padding(16)
                    .padding(.bottom, 24)
                }
            }
            .navigationTitle("✨ Prompt Enhancer")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .navigationBarTrailing) { Button("Готово") { dismiss() } }
            }
        }
    }

    private var modelCard: some View {
        ComfyGlassCard {
            HStack(spacing: 12) {
                Image(systemName: "iphone.gen3.radiowaves.left.and.right")
                    .font(.system(size: 25, weight: .semibold))
                    .foregroundStyle(.cyan)
                    .frame(width: 44, height: 44)
                    .background(Color.cyan.opacity(0.10), in: RoundedRectangle(cornerRadius: 13, style: .continuous))
                VStack(alignment: .leading, spacing: 3) {
                    Text("Локально на iPhone")
                        .font(.system(size: 15, weight: .bold))
                    Text("\(PromptKnowledgeBase.title(for: normalizedProfile)) · \(store.displayName)")
                        .font(.system(size: 11, weight: .semibold))
                        .foregroundStyle(.white.opacity(0.55))
                }
                Spacer()
                Circle().fill(store.isInstalled ? Color.green : Color.orange).frame(width: 9, height: 9)
            }
        }
    }

    private var installCard: some View {
        ComfyGlassCard {
            VStack(alignment: .leading, spacing: 12) {
                Text("Лёгкая локальная модель")
                    .font(.system(size: 16, weight: .bold))
                Text("Qwen3 0.6B запускается только на iPhone. ПК и видеопамять ComfyUI не используются. Модель скачивается один раз и хранится локально.")
                    .font(.system(size: 12, weight: .medium))
                    .foregroundStyle(.white.opacity(0.60))
                HStack {
                    Label(store.approximateSize, systemImage: "internaldrive")
                    Spacer()
                    Text("Wi‑Fi рекомендуется")
                }
                .font(.system(size: 10.5, weight: .semibold))
                .foregroundStyle(.white.opacity(0.46))

                Button {
                    Task { await store.download() }
                } label: {
                    HStack {
                        if store.isDownloading { ProgressView().tint(.white) }
                        Image(systemName: "arrow.down.circle.fill")
                        Text(store.isDownloading ? "Скачиваем…" : "Скачать Prompt Enhancer")
                    }
                    .font(.system(size: 13, weight: .bold))
                    .frame(maxWidth: .infinity)
                    .padding(.vertical, 12)
                    .background(Color.blue.opacity(0.75), in: RoundedRectangle(cornerRadius: 14, style: .continuous))
                }
                .buttonStyle(.plain)
                .disabled(store.isDownloading)
            }
        }
    }

    private var enhancerControls: some View {
        VStack(spacing: 14) {
            ComfyGlassCard {
                VStack(alignment: .leading, spacing: 11) {
                    Text("Режим")
                        .font(.system(size: 13, weight: .bold))
                    Picker("Режим", selection: $mode) {
                        ForEach(PromptEnhancerMode.allCases) { item in Text(item.title).tag(item) }
                    }
                    .pickerStyle(.segmented)

                    if mediaType == "audio" {
                        Toggle("Не менять основную идею / жанр", isOn: $preserveSubject)
                        Text("Для Audio workflow enhancer использует только музыкальные и звуковые параметры — камера, объектив и визуальное освещение не добавляются.")
                            .font(.system(size: 10.5, weight: .medium))
                            .foregroundStyle(.white.opacity(0.52))
                    } else {
                        Toggle("Не менять персонажа / предмет", isOn: $preserveSubject)
                        Toggle("Не менять указанную одежду", isOn: $preserveClothing)
                        Divider().overlay(Color.white.opacity(0.08))
                        Toggle("Добавлять камеру / объектив", isOn: $addCamera)
                        Toggle("Добавлять освещение", isOn: $addLighting)
                        Toggle("Добавлять окружение", isOn: $addEnvironment)
                    }
                }
                .font(.system(size: 12, weight: .semibold))
            }

            ComfyGlassCard {
                VStack(alignment: .leading, spacing: 9) {
                    Text("Исходный prompt")
                        .font(.system(size: 12, weight: .bold))
                        .foregroundStyle(.white.opacity(0.55))
                    Text(prompt.isEmpty ? "Введите Positive Prompt перед Enhance." : prompt)
                        .font(.system(size: 12.5))
                        .foregroundStyle(.white.opacity(prompt.isEmpty ? 0.35 : 0.82))
                        .frame(maxWidth: .infinity, alignment: .leading)
                        .textSelection(.enabled)
                }
            }

            Button { runEnhance() } label: {
                HStack(spacing: 8) {
                    if isEnhancing { ProgressView().tint(.white) }
                    Image(systemName: "wand.and.stars")
                    Text(isEnhancing ? "Enhancing on iPhone…" : "✨ Enhance")
                }
                .font(.system(size: 14, weight: .bold))
                .frame(maxWidth: .infinity)
                .padding(.vertical, 14)
                .background(LinearGradient(colors: [.purple.opacity(0.9), .blue.opacity(0.9)], startPoint: .leading, endPoint: .trailing), in: RoundedRectangle(cornerRadius: 16, style: .continuous))
            }
            .buttonStyle(.plain)
            .disabled(prompt.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty || isEnhancing)

            if !result.isEmpty {
                ComfyGlassCard {
                    VStack(alignment: .leading, spacing: 10) {
                        HStack {
                            Label("Enhanced", systemImage: "sparkles")
                                .font(.system(size: 13, weight: .bold))
                                .foregroundStyle(.cyan)
                            Spacer()
                            Button { result = "" } label: { Image(systemName: "xmark.circle.fill") }
                                .buttonStyle(.plain)
                                .foregroundStyle(.white.opacity(0.45))
                        }
                        Text(result)
                            .font(.system(size: 13))
                            .textSelection(.enabled)
                            .frame(maxWidth: .infinity, alignment: .leading)
                        HStack(spacing: 9) {
                            Button { runEnhance() } label: {
                                Label("Повторить", systemImage: "arrow.clockwise")
                                    .frame(maxWidth: .infinity)
                            }
                            .buttonStyle(.bordered)
                            Button {
                                prompt = result
                                dismiss()
                            } label: {
                                Label("Применить", systemImage: "checkmark")
                                    .frame(maxWidth: .infinity)
                            }
                            .buttonStyle(.borderedProminent)
                        }
                    }
                }
            }

            Button(role: .destructive) { store.remove() } label: {
                Label("Удалить локальную модель", systemImage: "trash")
                    .font(.system(size: 11.5, weight: .semibold))
            }
            .buttonStyle(.plain)
            .padding(.top, 2)
        }
    }

    private var errorCard: some View {
        Text(error.isEmpty ? store.errorMessage : error)
            .font(.system(size: 11.5, weight: .semibold))
            .foregroundStyle(.orange)
            .frame(maxWidth: .infinity, alignment: .leading)
            .padding(12)
            .background(Color.orange.opacity(0.10), in: RoundedRectangle(cornerRadius: 14, style: .continuous))
    }

    private func runEnhance() {
        guard !isEnhancing else { return }
        isEnhancing = true
        error = ""
        result = ""
        let request = PromptEnhancerRequest(
            prompt: prompt,
            profile: profile,
            mediaType: mediaType,
            checkpoint: checkpoint,
            lora: lora,
            mode: mode,
            preserveSubject: preserveSubject,
            preserveClothing: preserveClothing,
            addCamera: addCamera,
            addLighting: addLighting,
            addEnvironment: addEnvironment
        )
        Task {
            do {
                result = try await PromptEnhancerService.enhance(request, modelURL: store.modelURL)
            } catch {
                self.error = error.localizedDescription
            }
            isEnhancing = false
        }
    }
}
