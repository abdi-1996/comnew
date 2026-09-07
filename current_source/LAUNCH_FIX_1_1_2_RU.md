# Comfy Remote 1.1.2 build 4 — исправление вылета при запуске

По записи экрана приложение завершалось ещё до появления SwiftUI-интерфейса.

Причина в проекте 1.1.x: официальный `llama.xcframework` является динамическим framework. Он был добавлен только в фазу **Link Binary With Libraries**, но не копировался в `PCRemote.app/Frameworks`. На устройстве загрузчик iOS поэтому мог завершить процесс до показа интерфейса.

Исправления:

- добавлена фаза **Embed Frameworks**;
- `llama.xcframework` копируется внутрь приложения;
- включены `CodeSignOnCopy` и `RemoveHeadersOnCopy`;
- явно добавлен `@executable_path/Frameworks` в Runpath Search Paths;
- GitHub Actions теперь проверяет, что `Frameworks/llama.framework/llama` реально находится внутри собранного `.app` и IPA;
- сборка падает ещё на GitHub Actions, если framework снова не был встроен.

Prompt Enhancer по-прежнему не загружает GGUF и не запускает inference при старте приложения. Модель загружается только после нажатия Enhance.
