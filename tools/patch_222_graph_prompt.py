from pathlib import Path

path = Path('current_source/windows/server.py')
s = path.read_text(encoding='utf-8')
start = s.find('def _details_prompt_targets(details, kind):')
end = s.find('def _fill_prompt_parameters_from_details(params, details):', start)
if start < 0 or end < 0:
    raise SystemExit('prompt details helper block not found')

replacement = r'''def _details_prompt_targets(details, kind):
    """Find prompt-bearing scalar inputs in normalized workflow details.

    Works with API-format and ComfyUI UI-format workflows. In addition to
    literal prompt/text fields it understands String/Multiline primitive nodes
    by looking at where their output is connected in the graph.
    """
    kind = "negative" if str(kind).lower().startswith("neg") else "positive"
    nodes = details.get("nodes") if isinstance(details, dict) else None
    if not isinstance(nodes, list):
        return []

    node_identity = {}
    for node in nodes:
        if isinstance(node, dict):
            node_identity[str(node.get("id") or "")] = (
                str(node.get("class_type") or "") + " " + str(node.get("title") or "")
            ).lower().replace("-", "_")

    downstream = {}
    for connection in details.get("connections") or []:
        if not isinstance(connection, dict):
            continue
        source = str(connection.get("from") or "")
        target = str(connection.get("to") or "")
        label = str(connection.get("input_name") or connection.get("label") or "").lower().replace("-", "_")
        downstream.setdefault(source, []).append((label, node_identity.get(target, "")))

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
        identity_norm = node_identity.get(node_id, "")
        node_negative = any(token in identity_norm for token in ("negative", "neg_prompt", "neg prompt"))
        node_positive = "positive" in identity_norm or "pos_prompt" in identity_norm or "pos prompt" in identity_norm

        outgoing = downstream.get(node_id, [])
        downstream_prompt = any(
            any(token in label for token in ("prompt", "text", "positive", "caption", "description", "instruction", "lyrics", "tags"))
            or any(token in target_identity for token in ("prompt", "text", "clip", "encode", "caption", "conditioning"))
            for label, target_identity in outgoing
        )
        downstream_negative = any(
            "negative" in label or "negative" in target_identity or "neg_prompt" in target_identity
            for label, target_identity in outgoing
        )

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

            negative_signal = node_negative or downstream_negative or "negative" in low or low.startswith("neg_") or low in {"neg", "negative_text"}
            positive_signal = node_positive or "positive" in low or low.startswith("pos_")
            prompt_signal = "prompt" in low
            caption_signal = "caption" in low
            text_signal = (
                low in {"text", "text_g", "text_l", "text_1", "text_2", "description", "instruction", "lyrics", "tags", "style"}
                or low.startswith("text_") or low.endswith("_text")
            )
            identity_signal = any(token in identity_norm for token in ("prompt", "text", "clip", "encode", "caption", "conditioning"))
            primitive_signal = (
                any(token in identity_norm for token in ("string", "multiline", "primitive", "textbox", "text box"))
                and low in {"value", "string", "content", "text", "text_value"}
            )

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
                if not (positive_signal or prompt_signal or caption_signal or text_signal or identity_signal or primitive_signal or downstream_prompt):
                    continue

            score = 0
            if kind == "negative" and negative_signal:
                score += 190
            if kind == "positive" and positive_signal:
                score += 180
            if prompt_signal:
                score += 150
            if downstream_prompt:
                score += 130
            if caption_signal:
                score += 125
            if low in {"text", "text_g", "text_l", "text_1", "text_2"} or low.startswith("text_"):
                score += 115
            if low in {"description", "instruction", "lyrics", "tags", "style"}:
                score += 95
            if primitive_signal:
                score += 85
            if (kind == "negative" and node_negative) or (kind == "positive" and node_positive):
                score += 120
            if "prompt" in identity_norm:
                score += 95
            if any(token in identity_norm for token in ("text", "clip", "encode", "caption")):
                score += 60
            if len(value.strip()) >= 12:
                score += 14
            if any(ch.isspace() for ch in value.strip()):
                score += 10

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


'''
s = s[:start] + replacement + s[end:]
path.write_text(s, encoding='utf-8')
print('Graph-aware prompt detection patched')
