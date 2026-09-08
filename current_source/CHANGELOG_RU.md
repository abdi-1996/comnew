# Version 2.2.1

Исправлено:
- Prompt теперь загружается из реальных prompt/text нод выбранного ComfyUI workflow.
- Учитываются editor overrides, поэтому вкладка Prompt больше не показывает устаревший исходный JSON.
- Добавлена поддержка custom guider / conditioning цепочек WAN, LTX, Qwen, Flux и сторонних нод.
- Изменение Positive/Negative Prompt записывается обратно в workflow автоматически с debounce 450 мс.
- Prompt больше не ждёт нажатия Generate для синхронизации с workflow.

# Version 2.2.0 — build 17

Добавлено:
- расширенный live-статус ComfyUI: Queued / Starting / Executing / Sampling / Complete / Stopped / Error;
- отображение имени текущей ноды, процента и времени генерации;
- восстановление статуса сразу после возврата приложения из фона;
- сохранение выбранной output-ноды и режима Generate only selected output отдельно для каждого workflow.

Улучшено:
- распознавание дополнительных prompt-полей custom nodes;
- клавиатура получила отдельную кнопку «Готово»;
- сервер ComfyUI bridge обновлён до 6.3.0 и хранит стадии/время текущей генерации.

Исправлено:
- потеря актуального статуса после сворачивания приложения;
- сброс выбранной output-ноды после повторного открытия workflow.

## 1.1.4 build 6

- Кнопка **Tailscale на ПК** перенесена на экран входа, поэтому её видно до подключения к ComfyUI.
- Переключение Tailscale до входа защищено паролем PC Remote Server.
- Windows Server 5.2.4 добавляет безопасные pre-login endpoints для статуса и переключения Tailscale.
- Ошибка таймаута входа теперь показывает адрес/порт и подсказывает проверить `PCRemoteServer.exe`.

# Changelog

## 1.1.2 (build 4)

- Исправлен вылет iOS сразу после запуска: динамический `llama.xcframework` теперь встроен в `PCRemote.app/Frameworks`.
- Добавлены CodeSignOnCopy/RemoveHeadersOnCopy и явный runpath `@executable_path/Frameworks`.
- GitHub Actions проверяет наличие llama.framework внутри `.app` и IPA.

## 1.1.0 (build 2)

- Локальный iPhone-only Prompt Enhancer на Qwen3 0.6B + llama.cpp.
- Download/remove GGUF внутри приложения; модель не упаковывается в IPA, после загрузки проверяется целостность файла.
- Light / Detailed / Creative и ограничения «не менять персонажа/одежду».
- Локальные knowledge rules для WAN 2.2, Z-Image, Z-Image Turbo, SDXL.
- Новый последовательный Prompt Builder по профилю модели с сохранением выбранных слотов и заменой старого значения без дублирования.
- Расширенная библиотека ракурсов, света, камер, объективов, эмоций, взгляда, поз, Instagram-сцен и WAN camera motion.
- `− / +` для числовых Advanced inputs.
- Return/Go в Positive Prompt и кнопка `🎲 Generate` запускают новый seed + Generate.
- Улучшено определение model profile на Windows-сервере.

## 1.0.0

- Первый отдельный Comfy Remote только для ComfyUI.

## 1.1.3 build 5

- На главном экране Comfy Remote добавлена кнопка Tailscale ON/OFF для Windows-ПК.
- При выключении Tailscale через активное Tailscale-соединение приложение предупреждает, что связь с ПК будет потеряна.
- Windows Server 5.2.3 получил `/api/tailscale/status` и `/api/tailscale/set`.
- Отключение Tailscale запускается с небольшой задержкой после HTTP-ответа, чтобы телефон успел получить подтверждение.
- Каталог нод теперь принудительно обновляется из ComfyUI `/object_info` по кнопке обновления.
- Убран старый лимит 160 нод: сервер может отдавать до 1200 установленных нод.
- LoRA loader-ноды выводятся в отдельный верхний раздел; стандартный `LoraLoader` помечается как `Load LoRA`.
- Если `LoraLoader` не найден при первом открытии редактора, приложение автоматически делает принудительный refresh каталога.
