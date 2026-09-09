# CHANGELOG

## ComfyRemote Web 1.0.0 / PCRemoteServer 6.4.0

### Добавлено
- PWA web-клиент по адресу `/web/`.
- Вход тем же паролем PC Remote Server или через Connection ID.
- Workflow picker, импорт JSON, image/video/audio inputs, output target.
- Positive/Negative Prompt с live-синхронизацией в реальные workflow-ноды.
- Advanced параметры, Generate, Stop, Random Seed, live progress/queue.
- Галерея image/video/audio через защищённый streaming proxy.
- Адаптивный Node Editor для scalar inputs.
- Адаптация iPhone/iPad/desktop и установка на домашний экран как PWA.

## 2.2.2 build 19

### Исправлено
- Positive/Negative Prompt теперь читаются из UI-format и API-format ComfyUI workflow.
- Добавлен fallback через нормализованные Node Editor inputs для custom prompt nodes.
- Изменение Prompt записывается в реальную prompt-ноду и не остаётся только в UI приложения.
- Generate принудительно сохраняет Prompt перед постановкой workflow в очередь.

