"""CorelDRAW automation bridge for PC Remote.

The bridge keeps every COM call on one dedicated STA thread.  CorelDRAW's
object model is an out-of-process COM server; using a single worker avoids
cross-thread COM proxy problems when Flask/Waitress handles concurrent calls.
"""
from __future__ import annotations

import os
import queue
import tempfile
import threading
import time
import traceback
import uuid
from datetime import datetime
from pathlib import Path


class CorelBridgeError(RuntimeError):
    pass


def _corel_log_path() -> Path:
    base = Path(os.environ.get("LOCALAPPDATA") or tempfile.gettempdir()) / "PCRemote"
    base.mkdir(parents=True, exist_ok=True)
    return base / "corel.log"


def _write_corel_log(message: str):
    try:
        path = _corel_log_path()
        stamp = datetime.now().strftime("%Y-%m-%d %H:%M:%S")
        with path.open("a", encoding="utf-8") as stream:
            stream.write(f"[{stamp}] {message.rstrip()}\n")
        # Avoid an ever-growing log. Keep roughly the last 512 KiB.
        if path.stat().st_size > 1024 * 1024:
            data = path.read_bytes()[-512 * 1024:]
            path.write_bytes(data)
    except Exception:
        pass


def _safe(obj, name, default=None):
    try:
        value = getattr(obj, name)
        return value
    except Exception:
        return default


def _float(value, default=0.0):
    try:
        return float(value)
    except Exception:
        return default


def _int(value, default=0):
    try:
        return int(value)
    except Exception:
        return default


def _hex_to_rgb(value: str):
    value = str(value or "").strip().lstrip("#")
    if len(value) == 3:
        value = "".join(ch * 2 for ch in value)
    if len(value) != 6:
        raise ValueError("Цвет должен быть в формате #RRGGBB")
    try:
        return tuple(int(value[i : i + 2], 16) for i in (0, 2, 4))
    except ValueError as exc:
        raise ValueError("Некорректный цвет") from exc


class CorelAutomation:
    def __init__(self):
        self._queue: queue.Queue = queue.Queue()
        self._workspaces = {}
        self._thread = threading.Thread(target=self._run, name="PCRemote-CorelDRAW", daemon=True)
        self._started = threading.Event()
        self._thread.start()
        self._started.wait(timeout=3)

    def call(self, operation: str, **kwargs):
        result_queue: queue.Queue = queue.Queue(maxsize=1)
        self._queue.put((operation, kwargs, result_queue))
        # PowerTRACE, PDF import and high-resolution export can legitimately
        # take longer than a normal UI command. Keep short commands responsive
        # while allowing heavy Corel operations to finish on the STA worker.
        heavy = {"workspace_import", "workspace_trace", "workspace_export", "workspace_preview", "preview"}
        timeout = 180 if operation in heavy else 30
        try:
            ok, payload = result_queue.get(timeout=timeout)
        except queue.Empty as exc:
            raise CorelBridgeError("CorelDRAW не ответил вовремя.") from exc
        if ok:
            return payload
        raise CorelBridgeError(str(payload))

    def _run(self):
        try:
            import comtypes
            from comtypes.client import CreateObject, GetActiveObject

            comtypes.CoInitialize()
            self._CreateObject = CreateObject
            self._GetActiveObject = GetActiveObject
            self._com_available = True
        except Exception as exc:
            self._com_available = False
            self._com_error = exc
        self._app = None
        self._started.set()

        while True:
            operation, kwargs, result_queue = self._queue.get()
            try:
                handler = getattr(self, f"_op_{operation}")
                result_queue.put((True, handler(**kwargs)))
            except Exception as exc:
                friendly = self._friendly_error(exc)
                _write_corel_log(
                    f"operation={operation} kwargs={kwargs!r} error={friendly}\n"
                    + traceback.format_exc()
                )
                result_queue.put((False, friendly))

    def _friendly_error(self, exc: Exception) -> str:
        text = str(exc).strip()
        if not text:
            text = exc.__class__.__name__
        if "class not registered" in text.lower():
            return "CorelDRAW не найден или его COM-интерфейс не зарегистрирован."
        return text

    def _connect(self, create=True):
        if not self._com_available:
            raise CorelBridgeError(f"COM недоступен: {self._com_error}")

        # Re-use the same proxy while it remains alive.
        if self._app is not None:
            try:
                _ = self._app.Documents.Count
                return self._app
            except Exception:
                self._app = None
                self._workspaces.clear()

        try:
            self._app = self._GetActiveObject("CorelDRAW.Application")
            _write_corel_log("Connected to already running CorelDRAW.Application")
        except Exception as active_exc:
            if not create:
                raise CorelBridgeError("CorelDRAW не запущен.")
            # dynamic=True avoids depending on a generated Python wrapper for a
            # particular CorelDRAW version.
            try:
                self._app = self._CreateObject("CorelDRAW.Application", dynamic=True)
                _write_corel_log("Started CorelDRAW.Application through COM")
            except Exception as create_exc:
                raise CorelBridgeError(
                    f"Не удалось подключиться к CorelDRAW COM. "
                    f"ActiveObject: {self._friendly_error(active_exc)}; "
                    f"CreateObject: {self._friendly_error(create_exc)}"
                ) from create_exc
        try:
            self._app.Visible = True
        except Exception:
            pass
        return self._app

    def _document(self, create=False):
        app = self._connect(create=True)
        try:
            count = _int(app.Documents.Count)
        except Exception:
            count = 0
        if count <= 0:
            if not create:
                return app, None
            doc = app.CreateDocument()
            return app, doc
        try:
            return app, app.ActiveDocument
        except Exception:
            return app, app.Documents.Item(count)

    @staticmethod
    def _selection(doc):
        try:
            return doc.ActiveSelectionRange
        except Exception:
            return None

    @staticmethod
    def _selection_count(doc):
        selection = CorelAutomation._selection(doc)
        if selection is None:
            return 0
        return _int(_safe(selection, "Count", 0))

    @staticmethod
    def _active_shape(doc):
        try:
            selection = doc.ActiveSelectionRange
            if _int(selection.Count) > 0:
                return selection.Shapes.Item(1)
        except Exception:
            pass
        try:
            return doc.ActiveShape
        except Exception:
            return None

    def _shape_payload(self, shape, index: int):
        name = str(_safe(shape, "Name", "") or "").strip()
        shape_type = _int(_safe(shape, "Type", 0))
        label = name or f"Объект {index}"
        text_value = ""
        try:
            text_obj = shape.Text
            text_value = str(text_obj.Story.Text or "")
            if text_value.strip():
                label = text_value.strip().replace("\r", " ").replace("\n", " ")[:48]
        except Exception:
            pass
        return {
            "id": str(index),
            "index": index,
            "name": label,
            "type": shape_type,
            "x": _float(_safe(shape, "PositionX", 0)),
            "y": _float(_safe(shape, "PositionY", 0)),
            "width": _float(_safe(shape, "SizeWidth", 0)),
            "height": _float(_safe(shape, "SizeHeight", 0)),
            "rotation": _float(_safe(shape, "RotationAngle", 0)),
            "text": text_value[:300],
        }

    def _status_payload(self, app, doc):
        if doc is None:
            return {
                "ok": True,
                "running": True,
                "document_open": False,
                "document_name": "Без документа",
                "document_path": "",
                "dirty": False,
                "page_index": 0,
                "page_count": 0,
                "selection_count": 0,
                "selection": None,
                "version": str(_safe(app, "Version", _safe(app, "VersionMajor", "")) or ""),
            }

        page_count = _int(_safe(_safe(doc, "Pages", None), "Count", 0))
        page_index = _int(_safe(_safe(doc, "ActivePage", None), "Index", 1), 1)
        selected = self._active_shape(doc)
        selected_payload = self._shape_payload(selected, 0) if selected is not None else None
        return {
            "ok": True,
            "running": True,
            "document_open": True,
            "document_name": str(_safe(doc, "Name", "Документ") or "Документ"),
            "document_path": str(_safe(doc, "FilePath", "") or ""),
            "dirty": bool(_safe(doc, "Dirty", False)),
            "page_index": page_index,
            "page_count": page_count,
            "selection_count": self._selection_count(doc),
            "selection": selected_payload,
            "version": str(_safe(app, "Version", _safe(app, "VersionMajor", "")) or ""),
        }

    # ---- operations -----------------------------------------------------

    def _op_diagnostics(self):
        log_path = _corel_log_path()
        tail = ""
        try:
            if log_path.exists():
                text = log_path.read_text(encoding="utf-8", errors="replace")
                tail = text[-12000:]
        except Exception:
            pass
        return {
            "ok": True,
            "com_available": bool(getattr(self, "_com_available", False)),
            "com_error": str(getattr(self, "_com_error", "") or ""),
            "connected": self._app is not None,
            "workspace_count": len(self._workspaces),
            "log_path": str(log_path),
            "log_tail": tail,
        }

    def _op_launch(self):
        app = self._connect(create=True)
        try:
            app.Visible = True
        except Exception:
            pass
        return {"ok": True}

    def _op_status(self):
        app, doc = self._document(create=False)
        return self._status_payload(app, doc)

    def _op_new(self):
        app = self._connect(create=True)
        app.Visible = True
        app.CreateDocument()
        return self._status_payload(app, app.ActiveDocument)

    def _op_open(self, path: str):
        path = str(Path(path).resolve())
        if not Path(path).is_file():
            raise CorelBridgeError("Файл не найден.")
        app = self._connect(create=True)
        app.Visible = True
        app.OpenDocument(path)
        return self._status_payload(app, app.ActiveDocument)

    def _op_preview(self):
        app, doc = self._document(create=False)
        if doc is None:
            raise CorelBridgeError("В CorelDRAW нет открытого документа.")
        root = Path(tempfile.gettempdir()) / "PCRemoteCorelPreview"
        root.mkdir(parents=True, exist_ok=True)
        path = root / f"preview-{int(time.time() * 1000)}.png"
        export_filter = doc.ExportBitmap(str(path), 802, 1, 4, 1200, 0, 96, 96)  # PNG, current page, RGB
        try:
            export_filter.Finish()
        except Exception:
            pass
        if not path.exists() or path.stat().st_size == 0:
            raise CorelBridgeError("CorelDRAW не смог создать предпросмотр.")
        # Keep the directory bounded.
        for old in sorted(root.glob("preview-*.png"), key=lambda p: p.stat().st_mtime)[:-4]:
            try:
                old.unlink()
            except Exception:
                pass
        return str(path)

    def _op_objects(self):
        _app, doc = self._document(create=False)
        if doc is None:
            return []
        try:
            shapes = doc.ActivePage.Shapes
            count = _int(shapes.Count)
        except Exception:
            return []
        items = []
        # Corel collections are 1-based. Limit the mobile object list to keep
        # extremely complex artwork responsive; the full editor stays on PC.
        for index in range(1, min(count, 300) + 1):
            try:
                items.append(self._shape_payload(shapes.Item(index), index))
            except Exception:
                continue
        return items

    def _op_select(self, index: int):
        _app, doc = self._document(create=False)
        if doc is None:
            raise CorelBridgeError("Нет открытого документа.")
        index = int(index)
        shape = doc.ActivePage.Shapes.Item(index)
        try:
            doc.ClearSelection()
        except Exception:
            pass
        shape.CreateSelection()
        return self._status_payload(_app, doc)

    def _op_transform(self, x=None, y=None, width=None, height=None, rotation=None, keep_ratio=True):
        app, doc = self._document(create=False)
        if doc is None:
            raise CorelBridgeError("Нет открытого документа.")
        selection = self._selection(doc)
        if selection is None or _int(_safe(selection, "Count", 0)) <= 0:
            raise CorelBridgeError("Сначала выберите объект.")

        # SetSize is preferable because it keeps the selection centered and
        # handles multi-object selections. PositionX/Y and RotationAngle are
        # available on both Shape and ShapeRange in modern CorelDRAW versions.
        if width is not None or height is not None:
            current_w = max(_float(_safe(selection, "SizeWidth", 1), 1), 0.0001)
            current_h = max(_float(_safe(selection, "SizeHeight", 1), 1), 0.0001)
            new_w = _float(width, current_w) if width is not None else current_w
            new_h = _float(height, current_h) if height is not None else current_h
            if keep_ratio:
                if width is not None and height is None:
                    new_h = current_h * new_w / current_w
                elif height is not None and width is None:
                    new_w = current_w * new_h / current_h
            try:
                selection.SetSize(new_w, new_h)
            except Exception:
                # Single-shape fallback.
                shape = self._active_shape(doc)
                if shape is not None:
                    shape.SetSize(new_w, new_h)
        if x is not None:
            try:
                selection.PositionX = _float(x)
            except Exception:
                shape = self._active_shape(doc)
                if shape is not None:
                    shape.PositionX = _float(x)
        if y is not None:
            try:
                selection.PositionY = _float(y)
            except Exception:
                shape = self._active_shape(doc)
                if shape is not None:
                    shape.PositionY = _float(y)
        if rotation is not None:
            value = _float(rotation)
            try:
                selection.RotationAngle = value
            except Exception:
                shape = self._active_shape(doc)
                if shape is not None:
                    shape.RotationAngle = value
        try:
            app.Refresh()
        except Exception:
            pass
        return self._status_payload(app, doc)

    def _op_style(self, fill=None, outline=None, outline_width=None):
        app, doc = self._document(create=False)
        if doc is None:
            raise CorelBridgeError("Нет открытого документа.")
        selection = self._selection(doc)
        if selection is None or _int(_safe(selection, "Count", 0)) <= 0:
            raise CorelBridgeError("Сначала выберите объект.")

        count = _int(selection.Count)
        for i in range(1, count + 1):
            try:
                shape = selection.Shapes.Item(i)
            except Exception:
                continue
            if fill:
                r, g, b = _hex_to_rgb(fill)
                try:
                    shape.Fill.UniformColor.RGBAssign(r, g, b)
                except Exception:
                    pass
            if outline:
                r, g, b = _hex_to_rgb(outline)
                try:
                    shape.Outline.Color.RGBAssign(r, g, b)
                except Exception:
                    pass
            if outline_width is not None:
                try:
                    shape.Outline.Width = max(0.0, _float(outline_width))
                except Exception:
                    pass
        try:
            app.Refresh()
        except Exception:
            pass
        return self._status_payload(app, doc)

    def _op_create(self, kind: str, text: str = "Текст"):
        app, doc = self._document(create=True)
        page = doc.ActivePage
        layer = doc.ActiveLayer
        page_w = max(_float(_safe(page, "SizeWidth", 8.0), 8.0), 1.0)
        page_h = max(_float(_safe(page, "SizeHeight", 8.0), 8.0), 1.0)
        cx = page_w / 2.0
        cy = page_h / 2.0
        width = max(page_w * 0.28, 1.0)
        height = max(page_h * 0.18, 0.7)
        kind = str(kind or "").lower()

        if kind == "rectangle":
            shape = layer.CreateRectangle2(cx - width / 2, cy + height / 2, width, height)
        elif kind == "ellipse":
            shape = layer.CreateEllipse2(cx, cy, width / 2, height / 2)
        elif kind == "text":
            shape = layer.CreateArtisticText(cx - width / 2, cy, str(text or "Текст"))
        elif kind == "line":
            shape = layer.CreateLineSegment(cx - width / 2, cy, cx + width / 2, cy)
        else:
            raise CorelBridgeError("Неизвестный инструмент.")
        try:
            doc.ClearSelection()
        except Exception:
            pass
        try:
            shape.CreateSelection()
        except Exception:
            pass
        try:
            app.Refresh()
        except Exception:
            pass
        return self._status_payload(app, doc)

    def _op_page(self, action: str, index=None):
        app, doc = self._document(create=False)
        if doc is None:
            raise CorelBridgeError("Нет открытого документа.")
        pages = doc.Pages
        count = _int(pages.Count)
        current = _int(doc.ActivePage.Index, 1)
        action = str(action or "").lower()
        if action == "add":
            doc.AddPages(1)
            try:
                doc.Pages.Item(_int(doc.Pages.Count)).Activate()
            except Exception:
                pass
        elif action == "next":
            pages.Item(min(count, current + 1)).Activate()
        elif action == "previous":
            pages.Item(max(1, current - 1)).Activate()
        elif action == "set":
            target = max(1, min(_int(index, current), count))
            pages.Item(target).Activate()
        else:
            raise CorelBridgeError("Неизвестная команда страницы.")
        return self._status_payload(app, doc)

    def _op_action(self, action: str):
        app, doc = self._document(create=False)
        action = str(action or "").lower()
        if action == "show":
            app.Visible = True
            try:
                app.Refresh()
            except Exception:
                pass
            return {"ok": True}
        if doc is None:
            raise CorelBridgeError("Нет открытого документа.")

        selection = self._selection(doc)
        selection_count = self._selection_count(doc)

        if action == "save":
            doc.Save()
        elif action == "undo":
            doc.Undo()
        elif action == "redo":
            doc.Redo()
        elif action == "delete":
            if selection_count <= 0:
                raise CorelBridgeError("Сначала выберите объект.")
            selection.Delete()
        elif action == "duplicate":
            if selection_count <= 0:
                raise CorelBridgeError("Сначала выберите объект.")
            selection.Duplicate()
        elif action == "group":
            if selection_count < 2:
                raise CorelBridgeError("Для группировки выберите минимум два объекта.")
            selection.Group()
        elif action == "ungroup":
            if selection_count <= 0:
                raise CorelBridgeError("Сначала выберите группу.")
            selection.Ungroup()
        elif action == "select_all":
            doc.ActivePage.Shapes.All.CreateSelection()
        elif action == "deselect":
            doc.ClearSelection()
        elif action == "front":
            if selection_count <= 0:
                raise CorelBridgeError("Сначала выберите объект.")
            for i in range(1, selection_count + 1):
                try:
                    selection.Shapes.Item(i).OrderToFront()
                except Exception:
                    pass
        elif action == "back":
            if selection_count <= 0:
                raise CorelBridgeError("Сначала выберите объект.")
            for i in range(1, selection_count + 1):
                try:
                    selection.Shapes.Item(i).OrderToBack()
                except Exception:
                    pass
        else:
            raise CorelBridgeError("Неизвестная команда CorelDRAW.")

        try:
            app.Refresh()
        except Exception:
            pass
        return self._status_payload(app, doc)


    # ---- PC Remote workspaces ------------------------------------------

    @staticmethod
    def _workspace_title(kind: str, ordinal: int) -> str:
        if kind == "trace":
            return "Трассировка" if ordinal == 1 else f"Трассировка {ordinal}"
        return "Конвертер" if ordinal == 1 else f"Конвертер {ordinal}"

    def _workspace_alive(self, workspace) -> bool:
        try:
            return _int(workspace["doc"].Pages.Count) > 0
        except Exception:
            return False

    def _prune_workspaces(self):
        dead = [key for key, value in self._workspaces.items() if not self._workspace_alive(value)]
        for key in dead:
            self._workspaces.pop(key, None)

    def _workspace_payload(self, workspace):
        doc = workspace["doc"]
        try:
            page_index = _int(doc.ActivePage.Index, 1)
            page_count = _int(doc.Pages.Count, 1)
        except Exception:
            page_index, page_count = 0, 0
        return {
            "id": workspace["id"],
            "kind": workspace["kind"],
            "title": workspace["title"],
            "created_at": workspace["created_at"],
            "import_count": workspace.get("import_count", 0),
            "page_index": page_index,
            "page_count": page_count,
            "selection_count": self._selection_count(doc),
            "document_name": str(_safe(doc, "Name", workspace["title"]) or workspace["title"]),
        }

    def _workspace(self, workspace_id: str):
        self._connect(create=True)
        self._prune_workspaces()
        workspace = self._workspaces.get(str(workspace_id or ""))
        if not workspace:
            raise CorelBridgeError("Рабочая область CorelDRAW больше не существует.")
        if not self._workspace_alive(workspace):
            self._workspaces.pop(workspace["id"], None)
            raise CorelBridgeError("Рабочая область была закрыта в CorelDRAW.")
        return workspace

    def _activate_workspace(self, workspace):
        doc = workspace["doc"]
        try:
            doc.Activate()
        except Exception:
            pass
        return doc

    def _create_workspace(self, kind: str):
        kind = str(kind or "trace").lower().strip()
        if kind not in {"trace", "converter"}:
            raise CorelBridgeError("Неизвестный тип рабочей области.")
        app = self._connect(create=True)
        self._prune_workspaces()
        ordinal = 1 + sum(1 for value in self._workspaces.values() if value["kind"] == kind)
        doc = app.CreateDocument()
        workspace_id = uuid.uuid4().hex
        workspace = {
            "id": workspace_id,
            "kind": kind,
            "title": self._workspace_title(kind, ordinal),
            "doc": doc,
            "created_at": time.time(),
            "import_count": 0,
        }
        self._workspaces[workspace_id] = workspace
        try:
            doc.ReferencePoint = 9  # cdrCenter
        except Exception:
            pass
        return workspace

    def _op_workspace_bootstrap(self):
        app = self._connect(create=True)
        try:
            app.Visible = True
        except Exception:
            pass
        self._prune_workspaces()
        if not any(item["kind"] == "trace" for item in self._workspaces.values()):
            self._create_workspace("trace")
        workspaces = [self._workspace_payload(item) for item in self._workspaces.values()]
        workspaces.sort(key=lambda item: (0 if item["kind"] == "trace" else 1, item["created_at"]))
        return {
            "ok": True,
            "running": True,
            "version": str(_safe(app, "Version", _safe(app, "VersionMajor", "")) or ""),
            "workspaces": workspaces,
        }

    def _op_workspaces(self):
        app = self._connect(create=True)
        self._prune_workspaces()
        items = [self._workspace_payload(item) for item in self._workspaces.values()]
        items.sort(key=lambda item: (0 if item["kind"] == "trace" else 1, item["created_at"]))
        return {
            "ok": True,
            "running": True,
            "version": str(_safe(app, "Version", _safe(app, "VersionMajor", "")) or ""),
            "workspaces": items,
        }

    def _op_workspace_create(self, kind: str):
        workspace = self._create_workspace(kind)
        self._activate_workspace(workspace)
        return {"ok": True, "workspace": self._workspace_payload(workspace)}

    def _op_workspace_status(self, workspace_id: str):
        workspace = self._workspace(workspace_id)
        return {"ok": True, "workspace": self._workspace_payload(workspace)}

    def _workspace_shapes(self, workspace):
        doc = workspace["doc"]
        try:
            shapes = doc.ActivePage.Shapes
            count = _int(shapes.Count)
        except Exception:
            return []

        selected_ids = set()
        selection = self._selection(doc)
        try:
            selected_shapes = selection.Shapes if selection is not None else None
            selected_count = _int(_safe(selected_shapes, "Count", 0))
            for selected_index in range(1, selected_count + 1):
                selected_shape = selected_shapes.Item(selected_index)
                selected_ids.add(str(_int(_safe(selected_shape, "StaticID", 0), 0)))
        except Exception:
            selected_ids = set()

        items = []
        for index in range(1, min(count, 600) + 1):
            try:
                shape = shapes.Item(index)
                payload = self._shape_payload(shape, index)
                payload["id"] = str(_int(_safe(shape, "StaticID", index), index))
                payload["selected"] = payload["id"] in selected_ids
                items.append(payload)
            except Exception:
                continue
        return items

    def _op_workspace_objects(self, workspace_id: str):
        workspace = self._workspace(workspace_id)
        return self._workspace_shapes(workspace)

    def _op_workspace_preview(self, workspace_id: str):
        workspace = self._workspace(workspace_id)
        doc = self._activate_workspace(workspace)
        root = Path(tempfile.gettempdir()) / "PCRemoteCorelPreview" / workspace["id"]
        root.mkdir(parents=True, exist_ok=True)
        path = root / f"preview-{int(time.time() * 1000)}.png"
        export_filter = doc.ExportBitmap(str(path), 802, 1, 4, 1400, 0, 96, 96)
        try:
            export_filter.Finish()
        except Exception:
            pass
        if not path.exists() or path.stat().st_size == 0:
            raise CorelBridgeError("CorelDRAW не смог создать предпросмотр рабочей области.")
        old_items = sorted(root.glob("preview-*.png"), key=lambda item: item.stat().st_mtime)
        for old in old_items[:-3]:
            try:
                old.unlink()
            except Exception:
                pass
        return str(path)

    def _grid_place_selection(self, workspace, selection):
        doc = workspace["doc"]
        page = doc.ActivePage
        try:
            doc.ReferencePoint = 9  # cdrCenter
        except Exception:
            pass

        page_w = max(_float(_safe(page, "SizeWidth", 8.27), 8.27), 1.0)
        page_h = max(_float(_safe(page, "SizeHeight", 11.69), 11.69), 1.0)
        cols, rows = 2, 3
        margin_x = page_w * 0.06
        margin_y = page_h * 0.05
        cell_w = max((page_w - margin_x * (cols + 1)) / cols, page_w * 0.20)
        cell_h = max((page_h - margin_y * (rows + 1)) / rows, page_h * 0.18)

        current_w = max(_float(_safe(selection, "SizeWidth", 0.01), 0.01), 0.0001)
        current_h = max(_float(_safe(selection, "SizeHeight", 0.01), 0.01), 0.0001)
        max_w = cell_w * 0.86
        max_h = cell_h * 0.82
        scale = min(1.0, max_w / current_w, max_h / current_h)
        if scale < 0.999:
            try:
                selection.SetSize(current_w * scale, current_h * scale)
            except Exception:
                pass

        slot = workspace.get("import_count", 0) % (cols * rows)
        col = slot % cols
        row = slot // cols
        target_x = margin_x + cell_w * (col + 0.5) + margin_x * col
        target_y = page_h - (margin_y + cell_h * (row + 0.5) + margin_y * row)
        try:
            selection.PositionX = target_x
            selection.PositionY = target_y
        except Exception:
            pass

    def _op_workspace_import(self, workspace_id: str, path: str):
        workspace = self._workspace(workspace_id)
        source = Path(path).resolve()
        if not source.is_file():
            raise CorelBridgeError("Файл для импорта не найден.")
        doc = self._activate_workspace(workspace)

        # Six imports per page keeps the Corel canvas and iPhone preview readable.
        per_page = 6
        page_number = workspace.get("import_count", 0) // per_page + 1
        while _int(doc.Pages.Count, 1) < page_number:
            doc.AddPages(1)
        try:
            doc.Pages.Item(page_number).Activate()
        except Exception:
            pass

        importer = doc.ActiveLayer.ImportEx(str(source), 0)
        try:
            importer.Finish()
        except Exception:
            pass
        selection = self._selection(doc)
        if selection is None or _int(_safe(selection, "Count", 0)) <= 0:
            raise CorelBridgeError("CorelDRAW импортировал файл, но не вернул объекты.")
        self._grid_place_selection(workspace, selection)
        workspace["import_count"] = workspace.get("import_count", 0) + 1
        try:
            self._app.Refresh()
        except Exception:
            pass
        return {
            "ok": True,
            "workspace": self._workspace_payload(workspace),
            "objects": self._workspace_shapes(workspace),
        }

    def _find_workspace_shape(self, workspace, static_id):
        doc = workspace["doc"]
        static_id = _int(static_id, 0)
        if static_id <= 0:
            return None
        try:
            return doc.ActivePage.FindShape("", 0, static_id, True)
        except Exception:
            try:
                return doc.ActiveLayer.FindShape("", 0, static_id, True)
            except Exception:
                return None

    def _op_workspace_select(self, workspace_id: str, ids=None):
        workspace = self._workspace(workspace_id)
        doc = self._activate_workspace(workspace)
        ids = ids if isinstance(ids, (list, tuple)) else []
        try:
            doc.ClearSelection()
        except Exception:
            pass
        selected = 0
        for raw_id in ids[:300]:
            shape = self._find_workspace_shape(workspace, raw_id)
            if shape is None:
                continue
            try:
                if selected == 0:
                    shape.CreateSelection()
                else:
                    shape.AddToSelection()
                selected += 1
            except Exception:
                continue
        return {
            "ok": True,
            "workspace": self._workspace_payload(workspace),
            "objects": self._workspace_shapes(workspace),
        }

    def _op_workspace_transform(self, workspace_id: str, width=None, height=None, keep_ratio=True, rotation=None):
        workspace = self._workspace(workspace_id)
        doc = self._activate_workspace(workspace)
        selection = self._selection(doc)
        if selection is None or _int(_safe(selection, "Count", 0)) <= 0:
            raise CorelBridgeError("Сначала выберите объект.")
        if width is not None or height is not None:
            current_w = max(_float(_safe(selection, "SizeWidth", 1), 1), 0.0001)
            current_h = max(_float(_safe(selection, "SizeHeight", 1), 1), 0.0001)
            new_w = _float(width, current_w) if width is not None else current_w
            new_h = _float(height, current_h) if height is not None else current_h
            if keep_ratio:
                if width is not None and height is None:
                    new_h = current_h * new_w / current_w
                elif height is not None and width is None:
                    new_w = current_w * new_h / current_h
            selection.SetSize(max(new_w, 0.001), max(new_h, 0.001))
        if rotation is not None:
            try:
                selection.RotationAngle = _float(rotation)
            except Exception:
                pass
        try:
            self._app.Refresh()
        except Exception:
            pass
        return {
            "ok": True,
            "workspace": self._workspace_payload(workspace),
            "objects": self._workspace_shapes(workspace),
        }

    def _op_workspace_action(self, workspace_id: str, action: str):
        workspace = self._workspace(workspace_id)
        doc = self._activate_workspace(workspace)
        action = str(action or "").lower()
        selection = self._selection(doc)
        count = self._selection_count(doc)
        if action == "group":
            if count < 2:
                raise CorelBridgeError("Для группировки выберите минимум два объекта.")
            selection.Group()
        elif action == "ungroup":
            if count <= 0:
                raise CorelBridgeError("Сначала выберите группу.")
            selection.Ungroup()
        elif action == "delete":
            if count <= 0:
                raise CorelBridgeError("Сначала выберите объект.")
            selection.Delete()
        elif action == "duplicate":
            if count <= 0:
                raise CorelBridgeError("Сначала выберите объект.")
            selection.Duplicate()
        elif action == "select_all":
            doc.ActivePage.Shapes.All.CreateSelection()
        elif action == "deselect":
            doc.ClearSelection()
        elif action in {"previous_page", "next_page"}:
            try:
                current = _int(doc.ActivePage.Index, 1)
                total = max(_int(doc.Pages.Count, 1), 1)
                target = current - 1 if action == "previous_page" else current + 1
                target = max(1, min(total, target))
                doc.ClearSelection()
                doc.Pages.Item(target).Activate()
            except Exception as exc:
                raise CorelBridgeError(f"Не удалось переключить страницу: {exc}") from exc
        elif action == "save":
            # Untitled module workspaces are intentionally not auto-saved here.
            # Explicit export/save endpoints decide the destination.
            pass
        else:
            raise CorelBridgeError("Неизвестная команда рабочей области.")
        try:
            self._app.Refresh()
        except Exception:
            pass
        return {
            "ok": True,
            "workspace": self._workspace_payload(workspace),
            "objects": self._workspace_shapes(workspace),
        }

    def _op_workspace_trace(self, workspace_id: str, mode: str = "logo", influence: int = 45, strength: int = 70):
        workspace = self._workspace(workspace_id)
        if workspace["kind"] != "trace":
            raise CorelBridgeError("Трассировка доступна только в рабочей области трассировки.")
        doc = self._activate_workspace(workspace)
        selection = self._selection(doc)
        if selection is None or _int(_safe(selection, "Count", 0)) != 1:
            raise CorelBridgeError("Для трассировки выберите одно растровое изображение.")
        shape = selection.Shapes.Item(1)
        try:
            bitmap = shape.Bitmap
        except Exception as exc:
            raise CorelBridgeError("Выбранный объект не является растровым изображением.") from exc

        trace_types = {
            "lineart": 1,
            "logo": 3,
            "clipart": 4,
            "photo": 6,
            "technical": 7,
            "drawing": 8,
        }
        trace_type = trace_types.get(str(mode or "logo").lower(), 3)
        smoothing = max(0, min(100, _int(influence, 45)))
        detail = max(1, min(100, _int(strength, 70)))
        settings = bitmap.Trace(trace_type, smoothing, detail)
        try:
            settings.DeleteOriginalObject = False
            settings.Smoothing = smoothing
            settings.DetailLevelPercent = detail
            settings.ApplyChanges()
        except Exception:
            pass
        try:
            settings.Finish()
        except Exception as exc:
            raise CorelBridgeError(f"PowerTRACE не смог завершить трассировку: {exc}") from exc
        try:
            self._app.Refresh()
        except Exception:
            pass
        return {
            "ok": True,
            "workspace": self._workspace_payload(workspace),
            "objects": self._workspace_shapes(workspace),
        }

    def _op_workspace_export(self, workspace_id: str, path: str, format: str, selection_only: bool = False):
        workspace = self._workspace(workspace_id)
        doc = self._activate_workspace(workspace)
        target = Path(path).resolve()
        target.parent.mkdir(parents=True, exist_ok=True)
        fmt = str(format or "png").lower().lstrip(".")
        range_value = 2 if bool(selection_only) else 1  # cdrSelection / cdrCurrentPage
        if selection_only and self._selection_count(doc) <= 0:
            raise CorelBridgeError("Для экспорта выбранных объектов сначала выберите объекты.")

        filter_map = {
            "bmp": 769,
            "tif": 772,
            "tiff": 772,
            "jpg": 774,
            "jpeg": 774,
            "png": 802,
            "eps": 1289,
            "wmf": 1294,
            "dxf": 1296,
            "emf": 1300,
            "ai": 1305,
            "svg": 1345,
            "svgz": 1347,
        }
        if fmt == "pdf":
            previous_range = None
            try:
                previous_range = doc.PDFSettings.PublishRange
            except Exception:
                pass
            try:
                doc.PDFSettings.PublishRange = 2 if selection_only else 1  # pdfSelection / pdfCurrentPage
                doc.PublishToPDF(str(target))
            finally:
                if previous_range is not None:
                    try:
                        doc.PDFSettings.PublishRange = previous_range
                    except Exception:
                        pass
        elif fmt == "cdr":
            if selection_only:
                raise CorelBridgeError("CDR выбранных объектов пока экспортируйте как SVG/PDF; весь документ можно сохранить в CDR.")
            try:
                options = self._app.CreateStructSaveAsOptions()
                options.Overwrite = True
                doc.SaveAsCopy(str(target), options)
            except Exception:
                try:
                    doc.SaveAsCopy(str(target))
                except Exception as exc:
                    raise CorelBridgeError(f"CorelDRAW не смог сохранить копию CDR: {exc}") from exc
        else:
            filter_id = filter_map.get(fmt)
            if filter_id is None:
                raise CorelBridgeError("Этот формат пока не добавлен в мобильный конвертер.")
            export_filter = doc.ExportEx(str(target), filter_id, range_value)
            try:
                export_filter.Finish()
            except Exception:
                pass

        if not target.exists() or target.stat().st_size <= 0:
            raise CorelBridgeError("CorelDRAW не создал экспортируемый файл.")
        return {
            "ok": True,
            "path": str(target),
            "filename": target.name,
            "size": target.stat().st_size,
            "format": fmt,
        }


COREL = CorelAutomation()
