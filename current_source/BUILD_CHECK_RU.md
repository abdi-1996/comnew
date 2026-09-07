# Проверка Comfy Remote 1.1.0

Перед упаковкой исходников выполнены статические проверки:

- все Swift-файлы проходят `swiftc -frontend -parse`;
- `server.py`, `gui.py`, `corel_bridge.py` и WOL relay проходят `py_compile`;
- `Info.plist` и `project.pbxproj` проходят `plutil -lint`;
- GitHub Actions YAML разбирается без ошибок;
- `PromptEnhancer.swift` подключён к Xcode target;
- `llama.xcframework` подключён к проекту и скачивается в GitHub Actions из закреплённого релиза `b10453`;
- GGUF не находится в исходниках и workflow дополнительно запрещает упаковку `.gguf` в IPA;
- после загрузки на iPhone приложение проверяет минимальный размер модели и сигнатуру `GGUF`;
- временные `__pycache__` / `.pyc` удалены.

## Что нельзя проверить в этой среде

Здесь нет Xcode/iOS SDK и физического iPhone, поэтому финальная компиляция XCFramework + Metal и реальная скорость/память Qwen проверяются первым запуском GitHub Actions и затем на iPhone. Это интеграционный тест, а не скрытая гарантия до сборки.
