from pathlib import Path
import plistlib

ROOT = Path(__file__).resolve().parents[1] / "current_source"
MAIN = ROOT / "ios/PCRemote/PCRemote/MainView.swift"
MODELS = ROOT / "ios/PCRemote/PCRemote/Models.swift"
PLIST = ROOT / "ios/PCRemote/PCRemote/Info.plist"
SERVER = ROOT / "windows/server.py"
VERSION = ROOT / "VERSION.txt"
CHANGELOG = ROOT / "CHANGELOG_RU.md"


def replace_once(text: str, old: str, new: str, label: str) -> str:
    count = text.count(old)
    if count != 1:
        raise RuntimeError(f"{label}: expected exactly one anchor, found {count}")
    return text.replace(old, new, 1)


# ---------- Models.swift ----------
text = MODELS.read_text(encoding="utf-8")
text = replace_once(
    text,
    "    let model_profile: String?\n    let media_type: String?\n\n    var queueRemaining: Int { queue_remaining }",
    "    let model_profile: String?\n    let media_type: String?\n    let stage: String?\n    let started_at: Double?\n    let finished_at: Double?\n\n    var queueRemaining: Int { queue_remaining }",
    "dashboard live-state fields",
)
text = replace_once(
    text,
    "    var modelProfile: String { model_profile ?? \"generic\" }\n    var mediaType: String { media_type ?? \"image\" }\n}",
    "    var modelProfile: String { model_profile ?? \"generic\" }\n    var mediaType: String { media_type ?? \"image\" }\n    var generationStage: String { stage ?? (running ? \"executing\" : (queue_remaining > 0 ? \"queued\" : \"idle\")) }\n    var startedAt: Double? { started_at }\n    var finishedAt: Double? { finished_at }\n}",
    "dashboard computed live-state fields",
)
MODELS.write_text(text, encoding="utf-8")


# ---------- MainView.swift ----------
text = MAIN.read_text(encoding="utf-8")
text = replace_once(
    text,
    "struct ComfyUIView: View {\n    @Environment(\\.dismiss) private var dismiss",
    "struct ComfyUIView: View {\n    @Environment(\\.dismiss) private var dismiss\n    @Environment(\\.scenePhase) private var scenePhase",
    "scene phase environment",
)

text = replace_once(
    text,
    "        let known = Set([\"text\", \"prompt\", \"positive\", \"negative\", \"caption\", \"text_g\", \"text_l\", \"positive_prompt\", \"negative_prompt\"])\n        return known.contains(name) && (input.valueType == \"string\" || input.valueType == \"json\")",
    "        let known = Set([\n            \"text\", \"prompt\", \"positive\", \"negative\", \"caption\", \"description\", \"instruction\",\n            \"text_g\", \"text_l\", \"prompt_text\", \"text_prompt\", \"positive_prompt\", \"negative_prompt\",\n            \"positive_text\", \"negative_text\", \"text_positive\", \"text_negative\"\n        ])\n        let looksTextual = input.valueType == \"string\" || input.valueType == \"json\" || input.inputType.uppercased() == \"STRING\"\n        return known.contains(name) && looksTextual",
    "prompt input aliases",
)

old_output_name = '''    func outputNodeDisplayName(_ node: ComfyNodeInfo) -> String {
        let title = node.title.trimmingCharacters(in: .whitespacesAndNewlines)
        let base = title.isEmpty ? node.classType : title
        return "\\(base) (#\\(node.id))"
    }
'''
new_output_name = old_output_name + '''
    private func outputSelectionKey(for workflowID: String) -> String {
        "comfy.output.selection.\\(device.storageKey).\\(workflowID)"
    }

    private func outputOnlyKey(for workflowID: String) -> String {
        "comfy.output.only.\\(device.storageKey).\\(workflowID)"
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

    var currentNodeDisplayName: String {
        guard let nodeID = dashboard?.currentNode, !nodeID.isEmpty else { return "" }
        if let node = workflowDetails?.nodes.first(where: { $0.id == nodeID }) {
            let title = node.title.trimmingCharacters(in: .whitespacesAndNewlines)
            return title.isEmpty ? "\\(node.classType) #\\(nodeID)" : "\\(title) #\\(nodeID)"
        }
        return "Node #\\(nodeID)"
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
'''
text = replace_once(text, old_output_name, new_output_name, "output persistence/status helpers")

old_output_restore = '''            if !outputNodes.isEmpty {
                if selectedOutputNodeID.isEmpty || !outputNodes.contains(where: { $0.id == selectedOutputNodeID }) {
                    selectedOutputNodeID = outputNodes.first?.id ?? ""
                }
            } else {
                selectedOutputNodeID = ""
                generateOnlySelectedOutput = false
            }
'''
new_output_restore = '''            if !outputNodes.isEmpty {
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
'''
text = replace_once(text, old_output_restore, new_output_restore, "restore output selection")

text = replace_once(
    text,
    '''                Toggle(isOn: Binding(
                    get: { model.generateOnlySelectedOutput },
                    set: { model.generateOnlySelectedOutput = $0 }
                )) {''',
    '''                Toggle(isOn: Binding(
                    get: { model.generateOnlySelectedOutput },
                    set: { model.setGenerateOnlySelectedOutput($0) }
                )) {''',
    "persist output-only toggle",
)
text = replace_once(
    text,
    "                            Button { model.selectedOutputNodeID = node.id } label: {",
    "                            Button { model.selectOutputNode(node.id) } label: {",
    "persist selected output",
)

old_toolbar = '''        .toolbar {
            ToolbarItemGroup(placement: .keyboard) {
                Spacer()
                Button("🎲 Generate") {
                    promptEditorFocused = false
                    hideKeyboard()
                    Task { await model.generateWithNewSeed() }
                }
                .font(.system(size: 13, weight: .bold))
            }
        }
'''
new_toolbar = '''        .toolbar {
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
'''
text = replace_once(text, old_toolbar, new_toolbar, "keyboard Done button")

old_lifecycle = '''        .onAppear { model.start() }
        .onDisappear { model.stop() }
'''
new_lifecycle = '''        .onAppear { model.start() }
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
'''
text = replace_once(text, old_lifecycle, new_lifecycle, "foreground/background recovery")

old_queue_head = '''                    HStack {
                        VStack(alignment: .leading, spacing: 4) {
                            if model.running {
                                Text("Generating…")
                                    .font(.system(size: 16, weight: .bold))
                            } else {
                                Button { model.randomizeSeed() } label: {
                                    HStack(spacing: 6) {
                                        Image(systemName: "dice.fill")
                                        Text("Random Seed Generated")
                                    }
                                    .font(.system(size: 16, weight: .bold))
                                }
                                .buttonStyle(.plain)
                            }
                            Text(queueSubtitle)
                                .font(.system(size: 11, weight: .medium))
                                .foregroundStyle(.white.opacity(0.54))
                        }
                        Spacer()
                        Text(model.running ? "\\(Int((model.dashboard?.progress ?? 0) * 100))%" : "Idle")
                            .font(.system(size: 14, weight: .bold, design: .rounded))
                            .foregroundStyle(model.running ? Color.cyan : Color.green)
                    }
'''
new_queue_head = '''                    HStack {
                        VStack(alignment: .leading, spacing: 4) {
                            Text(model.generationStageTitle)
                                .font(.system(size: 16, weight: .bold))
                            Text(queueSubtitle)
                                .font(.system(size: 11, weight: .medium))
                                .foregroundStyle(.white.opacity(0.54))
                        }
                        Spacer()
                        VStack(alignment: .trailing, spacing: 3) {
                            Text(model.running ? "\\(Int((model.dashboard?.progress ?? 0) * 100))%" : (model.dashboard?.generationStage == "complete" ? "100%" : "Idle"))
                                .font(.system(size: 14, weight: .bold, design: .rounded))
                                .foregroundStyle(model.running ? Color.cyan : Color.green)
                            if !model.generationElapsedText.isEmpty {
                                Label(model.generationElapsedText, systemImage: "timer")
                                    .font(.system(size: 10.5, weight: .semibold, design: .monospaced))
                                    .foregroundStyle(.white.opacity(0.48))
                            }
                        }
                    }
'''
text = replace_once(text, old_queue_head, new_queue_head, "live generation header")

old_subtitle = '''    private var queueSubtitle: String {
        let remaining = model.dashboard?.queueRemaining ?? 0
        if let node = model.dashboard?.currentNode, model.running {
            return "Node \\(node) • Queue: \\(remaining)"
        }
        return remaining > 0 ? "В очереди: \\(remaining)" : "Очередь пуста"
    }
'''
new_subtitle = '''    private var queueSubtitle: String {
        let remaining = model.dashboard?.queueRemaining ?? 0
        if model.running, !model.currentNodeDisplayName.isEmpty {
            return "\\(model.currentNodeDisplayName) • Queue: \\(remaining)"
        }
        if model.dashboard?.generationStage == "complete" { return "Результат сохранён • Queue: \\(remaining)" }
        if model.dashboard?.generationStage == "stopped" { return "Генерация остановлена • Queue: \\(remaining)" }
        if model.dashboard?.generationStage == "error", let message = model.dashboard?.error, !message.isEmpty { return message }
        return remaining > 0 ? "В очереди: \\(remaining)" : "Очередь пуста"
    }
'''
text = replace_once(text, old_subtitle, new_subtitle, "live generation subtitle")

MAIN.write_text(text, encoding="utf-8")


# ---------- server.py ----------
text = SERVER.read_text(encoding="utf-8")
text = replace_once(text, 'PCREMOTE_VERSION = "6.2.2"', 'PCREMOTE_VERSION = "6.3.0"', "server version")
text = text.replace('PCRemoteServer/6.2"', 'PCRemoteServer/6.3"')

text = replace_once(
    text,
    '''    "prompt_id": None,
    "error": None,
    "updated": 0.0,
}''',
    '''    "prompt_id": None,
    "error": None,
    "stage": "idle",
    "started_at": None,
    "finished_at": None,
    "updated": 0.0,
}''',
    "server comfy state fields",
)

text = replace_once(
    text,
    '''                    _set_comfy_state(connected=True, queue_remaining=remaining, error=None)''',
    '''                    snapshot = _comfy_state_copy()
                    updates = {"connected": True, "queue_remaining": remaining, "error": None}
                    if remaining > 0 and not snapshot.get("running"):
                        updates["stage"] = "queued"
                    elif remaining == 0 and not snapshot.get("running") and snapshot.get("stage") == "queued":
                        updates["stage"] = "idle"
                    _set_comfy_state(**updates)''',
    "server queue stage",
)

text = replace_once(
    text,
    '''                        current_node=None,
                        error=None,
                    )''',
    '''                        current_node=None,
                        error=None,
                        stage="starting",
                        started_at=time.time(),
                        finished_at=None,
                    )''',
    "execution start stage",
)

text = replace_once(
    text,
    '''                        current_node=str(data.get("node")) if data.get("node") is not None else None,
                        error=None,
                    )''',
    '''                        current_node=str(data.get("node")) if data.get("node") is not None else None,
                        error=None,
                        stage="sampling",
                    )''',
    "progress stage",
)

text = replace_once(
    text,
    '''                            current_node=None,
                            error=None,
                        )''',
    '''                            current_node=None,
                            error=None,
                            stage="complete",
                            finished_at=time.time(),
                        )''',
    "execution complete stage",
)

text = replace_once(
    text,
    '''                            current_node=str(node),
                            error=None,
                        )''',
    '''                            current_node=str(node),
                            error=None,
                            stage="executing",
                        )''',
    "executing stage",
)

text = replace_once(
    text,
    '''                        prompt_id=data.get("prompt_id"),
                        error=str(data.get("exception_message") or data.get("exception_type") or "Ошибка ComfyUI"),
                    )''',
    '''                        prompt_id=data.get("prompt_id"),
                        error=str(data.get("exception_message") or data.get("exception_type") or "Ошибка ComfyUI"),
                        stage="error",
                        finished_at=time.time(),
                    )''',
    "execution error stage",
)

text = replace_once(
    text,
    '''                        prompt_id=data.get("prompt_id"),
                        error="Генерация остановлена",
                    )''',
    '''                        prompt_id=data.get("prompt_id"),
                        error="Генерация остановлена",
                        stage="stopped",
                        finished_at=time.time(),
                    )''',
    "execution stopped stage",
)

text = replace_once(
    text,
    '''            "current_node": None, "prompt_id": None, "error": None,
            "workflows": [], "selected_workflow": None,''',
    '''            "current_node": None, "prompt_id": None, "error": None,
            "stage": "offline", "started_at": None, "finished_at": None,
            "workflows": [], "selected_workflow": None,''',
    "offline dashboard stage",
)

text = replace_once(
    text,
    '''        "prompt_id": state.get("prompt_id"),
        "error": state.get("error"),
        "workflows": catalog,''',
    '''        "prompt_id": state.get("prompt_id"),
        "error": state.get("error"),
        "stage": state.get("stage") or ("executing" if state.get("running") else ("queued" if state.get("queue_remaining") else "idle")),
        "started_at": state.get("started_at"),
        "finished_at": state.get("finished_at"),
        "workflows": catalog,''',
    "online dashboard stage",
)

text = replace_once(
    text,
    '''        _set_comfy_state(connected=True, running=True, progress=0.0, prompt_id=prompt_id, current_node=None, error=None)''',
    '''        _set_comfy_state(connected=True, running=True, progress=0.0, prompt_id=prompt_id, current_node=None, error=None, stage="queued", started_at=time.time(), finished_at=None)''',
    "generate queued stage",
)

text = replace_once(
    text,
    '''        _set_comfy_state(running=False, error="Генерация остановлена")''',
    '''        _set_comfy_state(running=False, error="Генерация остановлена", stage="stopped", finished_at=time.time())''',
    "interrupt stage",
)
SERVER.write_text(text, encoding="utf-8")


# ---------- version metadata ----------
with PLIST.open("rb") as fh:
    info = plistlib.load(fh)
info["CFBundleShortVersionString"] = "2.2.0"
info["CFBundleVersion"] = "17"
with PLIST.open("wb") as fh:
    plistlib.dump(info, fh, sort_keys=False)

VERSION.write_text("2.2.0 build 17\nPCRemoteServer 6.3.0\n", encoding="utf-8")

entry = '''# Version 2.2.0 — build 17\n\nДобавлено:\n- расширенный live-статус ComfyUI: Queued / Starting / Executing / Sampling / Complete / Stopped / Error;\n- отображение имени текущей ноды, процента и времени генерации;\n- восстановление статуса сразу после возврата приложения из фона;\n- сохранение выбранной output-ноды и режима Generate only selected output отдельно для каждого workflow.\n\nУлучшено:\n- распознавание дополнительных prompt-полей custom nodes;\n- клавиатура получила отдельную кнопку «Готово»;\n- сервер ComfyUI bridge обновлён до 6.3.0 и хранит стадии/время текущей генерации.\n\nИсправлено:\n- потеря актуального статуса после сворачивания приложения;\n- сброс выбранной output-ноды после повторного открытия workflow.\n\n'''
existing = CHANGELOG.read_text(encoding="utf-8") if CHANGELOG.exists() else ""
if not existing.startswith("# Version 2.2.0"):
    CHANGELOG.write_text(entry + existing, encoding="utf-8")

print("Comfy Remote 2.2.0 / PCRemoteServer 6.3.0 source upgrade applied")
