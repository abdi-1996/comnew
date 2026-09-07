# Comfy Remote 1.1.0

Отдельное iPhone-приложение только для ComfyUI с локальным Prompt Enhancer.

## Основное

- После подключения к ПК приложение сразу открывает ComfyUI.
- Workflow, node editor, Advanced, очередь и галерея остаются.
- Prompt Enhancer выполняется только на iPhone; ПК не запускает LLM.
- Лёгкая Qwen3 0.6B скачивается отдельно по кнопке Enhance и не увеличивает размер IPA на размер GGUF.
- Локальные knowledge-профили: WAN 2.2, Z-Image, Z-Image Turbo и SDXL.
- Templates переделаны в последовательный model-aware Prompt Builder.
- Advanced: `− / +` возле числовых параметров.
- Return/Go и `🎲 Generate` запускают генерацию с новым seed.
- Bundle id `com.example.ComfyRemote`, поэтому приложение можно держать рядом с основным PC Remote.

Подробности: `PROMPT_ENHANCER_RU.md`.

## Сборка IPA

1. Загрузите содержимое проекта в GitHub repository.
2. Actions → **Build Comfy Remote** → Run workflow.
3. Workflow скачает закреплённый официальный iOS XCFramework llama.cpp и соберёт приложение.
4. Скачайте artifact **ComfyRemote-IPA**.
5. Установите IPA вашим обычным способом.
6. В приложении откройте Enhance и один раз скачайте локальную Qwen-модель.

## Windows

Используется тот же `PCRemoteServer.exe`. Windows-часть в 1.1.0 дополнительно точнее распознаёт WAN 2.2, Z-Image Turbo и SDXL для выбора правильного Prompt Builder/knowledge profile. Prompt Enhancer на Windows не запускается.


## 1.1.4

Добавлены Tailscale ON/OFF на главном экране и полный refresh каталога нод ComfyUI с отдельным разделом LoRA / Load LoRA.


### 1.1.4
На экране входа появилась отдельная карточка **Tailscale на ПК**. Она работает через доступный LAN/ZeroTier/Tailscale маршрут и требует пароль сервера для изменения состояния.
