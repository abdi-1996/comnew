from pathlib import Path

ROOT = Path('current_source')
server_path = ROOT / 'windows' / 'server.py'
main_path = ROOT / 'ios' / 'PCRemote' / 'PCRemote' / 'MainView.swift'
pbx_path = ROOT / 'ios' / 'PCRemote' / 'PCRemote.xcodeproj' / 'project.pbxproj'
version_path = ROOT / 'VERSION.txt'

server = server_path.read_text(encoding='utf-8')
main = main_path.read_text(encoding='utf-8')
pbx = pbx_path.read_text(encoding='utf-8')

helper_marker = '''def _extract_workflow_parameters(prompt):\n'''
if helper_marker not in server:
    raise SystemExit('extract marker not found')

helpers = r'''def _details_prompt_targets(details, kind):
    """Find prompt-bearing scalar inputs in normalized workflow details.

    This works for both API-format and ComfyUI UI-format workflows because
    _workflow_details() exposes both as the same node/input structure.
    """
    kind = "negative" if str(kind).lower().startswith("neg") else "positive"
    nodes = details.get("nodes") if isinstance(details, dict) else None
    if not isinstance(nodes, list):
        return []

    ranked = []
    blocked_names = {
        "filename", "file", "path", "url", "image", "video", "audio", "sound",
        "ckpt_name", "checkpoint", "model", "model_name", "unet_name", "vae_name",
        "lora_name", "sampler_name", "scheduler", "device", "dtype", "format",
        "prefix", "output", "output_path", "save_path", "directory", "folder",
    }

    for node in nodes:
        if not isinstance(node, dict):
            continue
        node_id = str(node.get("id") or "")
        identity = (str(node.get("class_type") or "") + " " + str(node.get("title") or "")).lower()
        identity_norm = identity.replace("-", "_")
        node_negative = any(token in identity_norm for token in ("negative", "neg_prompt", "neg prompt"))
        node_positive = "positive" in identity_norm or "pos_prompt" in identity_norm or "pos prompt" in identity_norm

        for input_item in node.get("inputs") or []:
            if not isinstance(input_item, dict):
                continue
            if str(input_item.get("value_type") or "").lower() == "connection":
                continue
            value_type = str(input_item.get("value_type") or "").lower()
            input_type = str(input_item.get("input_type") or "").upper()
            if value_type not in {"string", "json", ""} and input_type != "STRING":
                continue
            value = input_item.get("value")
            if not isinstance(value, str):
                continue
            name = str(input_item.get("name") or "")
            low = name.lower().replace("-", "_").strip()
            if not low:
                continue

            negative_signal = node_negative or "negative" in low or low.startswith("neg_") or low in {"neg", "negative_text"}
            positive_signal = node_positive or "positive" in low or low.startswith("pos_")
            prompt_signal = "prompt" in low
            caption_signal = "caption" in low
            text_signal = low in {"text", "text_g", "text_l", "text_1", "text_2", "description", "instruction"} or low.startswith("text_") or low.endswith("_text")
            identity_signal = any(token in identity_norm for token in ("prompt", "text", "clip", "encode", "caption", "conditioning"))

            if low in blocked_names and not (prompt_signal or caption_signal or text_signal or positive_signal or negative_signal):
                continue
            if any(token in low for token in ("filename", "filepath", "file_path", "model_name", "ckpt", "checkpoint", "lora_name", "vae_name", "sampler", "scheduler")) and not prompt_signal:
                continue

            if kind == "negative":
                if not negative_signal:
                    continue
            else:
                if negative_signal:
                    continue
                if not (positive_signal or prompt_signal or caption_signal or text_signal or identity_signal):
                    continue

            score = 0
            if kind == "negative" and negative_signal:
                score += 180
            if kind == "positive" and positive_signal:
                score += 170
            if prompt_signal:
                score += 145
            if caption_signal:
                score += 125
            if low in {"text", "text_g", "text_l", "text_1", "text_2"} or low.startswith("text_"):
                score += 110
            if low in {"description", "instruction"}:
                score += 95
            if (kind == "negative" and node_negative) or (kind == "positive" and node_positive):
                score += 115
            if "prompt" in identity_norm:
                score += 90
            if any(token in identity_norm for token in ("text", "clip", "encode", "caption")):
                score += 55
            if len(value.strip()) >= 12:
                score += 12
            if any(ch.isspace() for ch in value.strip()):
                score += 8

            ranked.append({
                "score": score,
                "node_id": node_id,
                "input_name": name,
                "value": value,
            })

    if not ranked:
        return []
    ranked.sort(key=lambda item: (-int(item["score"]), item["node_id"], item["input_name"]))
    best = ranked[0]
    best_node = best["node_id"]
    best_score = int(best["score"])
    selected = [
        item for item in ranked
        if item["node_id"] == best_node and int(item["score"]) >= best_score - 35
    ]
    return selected or [best]


def _fill_prompt_parameters_from_details(params, details):
    if not isinstance(params, dict):
        return params
    positive = _details_prompt_targets(details, "positive")
    negative = _details_prompt_targets(details, "negative")
    if not str(params.get("positive") or "").strip() and positive:
        value = str(positive[0].get("value") or "")
        if value.strip():
            params["positive"] = value
    if not str(params.get("negative") or "").strip() and negative:
        value = str(negative[0].get("value") or "")
        if value.strip():
            params["negative"] = value
    return params


'''
server = server.replace(helper_marker, helpers + helper_marker, 1)

old_dashboard = '''    effective_prompt = _apply_editor_overrides(selected_id, prompt) if selected_id and _is_api_workflow(prompt) else (prompt or {})\n    parameters = _extract_workflow_parameters(effective_prompt)\n\n    checkpoints = _comfy_models("checkpoints")\n'''
new_dashboard = '''    effective_prompt = _apply_editor_overrides(selected_id, prompt) if selected_id and _is_api_workflow(prompt) else (prompt or {})\n    parameters = _extract_workflow_parameters(effective_prompt if _is_api_workflow(effective_prompt) else {})\n    if selected_id:\n        try:\n            parameters = _fill_prompt_parameters_from_details(parameters, _workflow_details(selected_id))\n        except Exception:\n            pass\n\n    checkpoints = _comfy_models("checkpoints")\n'''
if old_dashboard not in server:
    raise SystemExit('dashboard marker not found')
server = server.replace(old_dashboard, new_dashboard, 1)

start = server.find('@app.post("/api/comfy/prompt/set")')
end = server.find('@app.post("/api/comfy/workflow/order")', start)
if start < 0 or end < 0:
    raise SystemExit('prompt endpoint block not found')
new_endpoint = r'''@app.post("/api/comfy/prompt/set")
def comfy_prompt_set():
    """Persist the main Prompt tab into real workflow text inputs.

    Supports API-format and ComfyUI UI-format workflows. Normalized workflow
    details are used as a fallback for custom nodes that do not expose the
    classic KSampler -> CLIPTextEncode graph shape.
    """
    body = request.get_json(silent=True) or {}
    workflow_id = str(body.get("workflow_id") or "")
    if not workflow_id:
        return jsonify({"ok": False, "error": "Не указан workflow."}), 400

    selected_id, prompt = _load_workflow(workflow_id)
    if prompt is None:
        return jsonify({"ok": False, "error": "Workflow не найден."}), 404

    positive = body.get("positive")
    negative = body.get("negative")

    def flatten_api_targets(targets):
        out = []
        for node_id, node, keys in targets:
            inputs = node.get("inputs", {}) if isinstance(node, dict) else {}
            for key in keys:
                out.append({
                    "node_id": str(node_id),
                    "input_name": str(key),
                    "value": inputs.get(key) if isinstance(inputs.get(key), str) else "",
                })
        return out

    positive_targets = []
    negative_targets = []
    if _is_api_workflow(prompt):
        effective = _apply_editor_overrides(selected_id, prompt)
        _, sampler = _find_node(effective, ("ksampler", "samplercustom", "sampler"))
        sampler_inputs = sampler.get("inputs", {}) if isinstance(sampler, dict) else {}
        positive_targets = flatten_api_targets(_prompt_text_targets(effective, sampler_inputs, "positive"))
        negative_targets = flatten_api_targets(_prompt_text_targets(effective, sampler_inputs, "negative"))

    details = _workflow_details(selected_id)
    if not positive_targets:
        positive_targets = _details_prompt_targets(details, "positive")
    if not negative_targets:
        negative_targets = _details_prompt_targets(details, "negative")

    changed = 0

    def persist_targets(targets, value):
        nonlocal changed
        if not isinstance(value, str):
            return
        seen = set()
        for target in targets:
            node_id = str(target.get("node_id") or "")
            input_name = str(target.get("input_name") or "")
            key = (node_id, input_name)
            if not node_id or not input_name or key in seen:
                continue
            seen.add(key)
            _set_workflow_scalar_input(selected_id, node_id, input_name, value)
            changed += 1

    persist_targets(positive_targets, positive)
    persist_targets(negative_targets, negative)

    if isinstance(positive, str) and not positive_targets:
        return jsonify({
            "ok": False,
            "error": "Не удалось определить Positive Prompt ноду. Откройте Node Editor и проверьте текстовую ноду workflow."
        }), 422

    refreshed_id, refreshed_prompt = _load_workflow(selected_id)
    if refreshed_prompt is not None and _is_api_workflow(refreshed_prompt):
        refreshed_effective = _apply_editor_overrides(refreshed_id, refreshed_prompt)
        params = _extract_workflow_parameters(refreshed_effective)
    else:
        params = _extract_workflow_parameters({})
    try:
        params = _fill_prompt_parameters_from_details(params, _workflow_details(selected_id))
    except Exception:
        pass

    return jsonify({
        "ok": True,
        "error": None,
        "changed": changed,
        "positive": params.get("positive", ""),
        "negative": params.get("negative", ""),
        "positive_nodes": sorted({str(item.get("node_id") or "") for item in positive_targets if item.get("node_id")}),
        "negative_nodes": sorted({str(item.get("node_id") or "") for item in negative_targets if item.get("node_id")}),
    })


'''
server = server[:start] + new_endpoint + server[end:]

if 'PCREMOTE_VERSION = "6.3.1"' not in server:
    raise SystemExit('server version marker missing')
server = server.replace('PCREMOTE_VERSION = "6.3.1"', 'PCREMOTE_VERSION = "6.3.2"', 1)

old_generate_sync = '''            // Main-screen prompt fields are authoritative. Write them through\n            // the same real node-update API used by Node Editor immediately\n            // before queueing the workflow. This fixes workflows where the\n            // server cannot infer the prompt node from a custom guider chain.\n            try await synchronizeMainScreenIntoWorkflow()\n'''
new_generate_sync = '''            // Flush Prompt immediately through the server-side normalized node\n            // resolver. This covers API and UI-format/custom prompt nodes and\n            // avoids racing the 450 ms live-sync debounce when Generate is tapped.\n            promptSyncTask?.cancel()\n            try await client.comfySetMainPrompts(\n                workflowID: selectedWorkflowID,\n                positive: parameters.positive,\n                negative: parameters.negative\n            )\n'''
if old_generate_sync not in main:
    raise SystemExit('MainView generate prompt sync marker not found')
main = main.replace(old_generate_sync, new_generate_sync, 1)

if 'MARKETING_VERSION = 2.2.1;' not in pbx:
    raise SystemExit('marketing version marker missing')
if 'CURRENT_PROJECT_VERSION = 18;' not in pbx:
    raise SystemExit('build version marker missing')
pbx = pbx.replace('MARKETING_VERSION = 2.2.1;', 'MARKETING_VERSION = 2.2.2;')
pbx = pbx.replace('CURRENT_PROJECT_VERSION = 18;', 'CURRENT_PROJECT_VERSION = 19;')

server_path.write_text(server, encoding='utf-8')
main_path.write_text(main, encoding='utf-8')
pbx_path.write_text(pbx, encoding='utf-8')
version_path.write_text('2.2.2 build 19\nPCRemoteServer 6.3.2\n', encoding='utf-8')

changelog = ROOT / 'CHANGELOG.md'
old = changelog.read_text(encoding='utf-8') if changelog.exists() else '# CHANGELOG\n\n'
entry = '''## 2.2.2 build 19\n\n### Исправлено\n- Positive/Negative Prompt теперь читаются из UI-format и API-format ComfyUI workflow.\n- Добавлен fallback через нормализованные Node Editor inputs для custom prompt nodes.\n- Изменение Prompt записывается в реальную prompt-ноду и не остаётся только в UI приложения.\n- Generate принудительно сохраняет Prompt перед постановкой workflow в очередь.\n\n'''
if '## 2.2.2 build 19' not in old:
    old = old.replace('# CHANGELOG\n\n', '# CHANGELOG\n\n' + entry, 1)
changelog.write_text(old, encoding='utf-8')

print('Upgraded to Comfy Remote 2.2.2 build 19 / PCRemoteServer 6.3.2')
