# Comfy Remote 1.1.1 build 3

Исправлена ошибка компиляции `PromptEnhancer.swift` в GitHub Actions/Xcode 16.4:

`call can throw, but it is not marked with 'try' and the error is not handled`

Причина была в throwing-вызовах внутри `autoreleasepool`. Теперь detached task имеет явный throwing-return type, а `autoreleasepool` вызывается через `try`.

Исправленный фрагмент:

```swift
return try await Task.detached(priority: .userInitiated) { () throws -> String in
    try autoreleasepool {
        let runtime = try LocalLlamaRuntime(modelPath: modelPath)
        return try runtime.generate(fullPrompt)
    }
}.value
```

Другие функции Comfy Remote 1.1.0 не изменялись.
