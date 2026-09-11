//
//  CopilotEngine.swift
//  mv1E Copilot — context-aware dylib author.
//
//  Feeds the model a STRUCTURED summary of the mv1E-inspected target (class name,
//  superclass, selectors + type encodings, ivars, protocols) — never the raw binary —
//  and asks it to write a raw Objective-C swizzle dylib targeting the real selectors. The user's
//  own API key (OpenAI or Anthropic) is used; nothing is proxied through our servers.
//
//  This is a developer tool for apps the user owns or is authorized to modify.
//

import Foundation

nonisolated enum Copilot {

    // MARK: Provider + key (user-supplied, Keychain-stored)

    enum Provider: String, CaseIterable { case openai, anthropic
        var label: String { self == .openai ? "OpenAI" : "Anthropic" }
        var defaultModel: String { self == .openai ? "gpt-4o" : "claude-sonnet-4-6" }
    }
    static var provider: Provider {
        get { Provider(rawValue: UserDefaults.standard.string(forKey: "copilot_provider") ?? "") ?? .openai }
        set { UserDefaults.standard.set(newValue.rawValue, forKey: "copilot_provider") }
    }
    static var model: String {
        get { let m = UserDefaults.standard.string(forKey: "copilot_model") ?? ""; return m.isEmpty ? provider.defaultModel : m }
        set { UserDefaults.standard.set(newValue, forKey: "copilot_model") }
    }
    static var apiKey: String {
        get { Keychain.get("copilot_api_key") ?? "" }
        set { _ = Keychain.set("copilot_api_key", newValue) }
    }
    static var hasKey: Bool { !apiKey.isEmpty }

    enum CopilotError: LocalizedError {
        case noKey, http(Int, String), empty, badResponse
        var errorDescription: String? {
            switch self {
            case .noKey: return "No API key — add one in Settings › Copilot."
            case .http(let c, let m): return "API error \(c): \(m)"
            case .empty: return "Model returned nothing."
            case .badResponse: return "Couldn't parse the model response."
            }
        }
    }

    // MARK: Structured target context (what the model sees)

    /// Compact JSON summary of a selected class — small, auditable, no binary bytes.
    static func contextJSON(app: String, bundleID: String, cls: MV1E.DumpedClass) -> String {
        var obj: [String: Any] = [
            "app": app, "bundleID": bundleID,
            "class": cls.name,
            "superclass": cls.superName ?? NSNull(),
            "protocols": cls.protocols,
            "kind": cls.kind,
        ]
        obj["methods"] = cls.methods.prefix(120).map { ["sel": $0.name, "types": $0.types, "class": $0.isClassMethod] }
        obj["ivars"] = cls.ivars.prefix(80).map { ["name": $0.name, "type": $0.type] }
        obj["properties"] = cls.properties.prefix(80).map { ["name": $0.name, "attrs": $0.attributes] }
        let data = (try? JSONSerialization.data(withJSONObject: obj, options: [.prettyPrinted, .sortedKeys])) ?? Data()
        return String(decoding: data, as: UTF8.self)
    }

    private static let systemPrompt = """
    You are an Objective-C runtime engineer. You write a self-contained dylib in PLAIN
    Objective-C (.m) that hooks the given class by METHOD SWIZZLING with the Objective-C
    runtime — no Theos, no Logos, no %hook, no MobileSubstrate/MSHookFunction. Compiles
    with clang directly. Rules:
    - Output ONE ```objc code block with the complete .m source, then a short note.
    - #import <objc/runtime.h> and <Foundation/Foundation.h> (UIKit if needed).
    - Swizzle with class_getInstanceMethod / class_getClassMethod + method_exchangeImplementations,
      inside a category +load OR a __attribute__((constructor)) function. Save the original IMP
      (or call the swizzled-back selector) so you can invoke the original implementation.
    - Match the original method signature exactly (return + argument types from the ObjC type
      encoding in the context). Use the real selectors/ivars/properties from the context JSON
      ONLY — never fabricate.
    - Resolve the target class with objc_getClass("Name") / NSClassFromString since it lives in
      another binary; guard for nil. For Swift classes use the module-qualified name.
    - Dependency-free: must build with `clang -dynamiclib -framework Foundation`.
    - If the request needs a selector not in context, say so in the note instead of inventing one.
    This is for an app the user owns or is authorized to modify.
    """

    // MARK: Generate

    struct Result { let source: String; let note: String; let raw: String }

    static func generate(context: String, request: String) async throws -> Result {
        guard hasKey else { throw CopilotError.noKey }
        let user = "Class context:\n\(context)\n\nUser request:\n\(request)"
        let raw = try await (provider == .openai ? callOpenAI(user) : callAnthropic(user))
        let (src, note) = splitCodeBlock(raw)
        return Result(source: src, note: note, raw: raw)
    }

    // MARK: Providers

    private static func callOpenAI(_ user: String) async throws -> String {
        var req = URLRequest(url: URL(string: "https://api.openai.com/v1/chat/completions")!)
        req.httpMethod = "POST"; req.timeoutInterval = 120
        req.setValue("Bearer \(apiKey)", forHTTPHeaderField: "Authorization")
        req.setValue("application/json", forHTTPHeaderField: "Content-Type")
        let body: [String: Any] = ["model": model, "temperature": 0.2, "messages": [
            ["role": "system", "content": systemPrompt],
            ["role": "user", "content": user]]]
        req.httpBody = try JSONSerialization.data(withJSONObject: body)
        let (data, resp) = try await URLSession.shared.data(for: req)
        let code = (resp as? HTTPURLResponse)?.statusCode ?? 0
        guard code < 400 else { throw CopilotError.http(code, snippet(data)) }
        guard let o = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let choices = o["choices"] as? [[String: Any]],
              let msg = choices.first?["message"] as? [String: Any],
              let content = msg["content"] as? String else { throw CopilotError.badResponse }
        return content
    }

    private static func callAnthropic(_ user: String) async throws -> String {
        var req = URLRequest(url: URL(string: "https://api.anthropic.com/v1/messages")!)
        req.httpMethod = "POST"; req.timeoutInterval = 120
        req.setValue(apiKey, forHTTPHeaderField: "x-api-key")
        req.setValue("2023-06-01", forHTTPHeaderField: "anthropic-version")
        req.setValue("application/json", forHTTPHeaderField: "Content-Type")
        let body: [String: Any] = ["model": model, "max_tokens": 4096, "temperature": 0.2,
            "system": systemPrompt,
            "messages": [["role": "user", "content": user]]]
        req.httpBody = try JSONSerialization.data(withJSONObject: body)
        let (data, resp) = try await URLSession.shared.data(for: req)
        let code = (resp as? HTTPURLResponse)?.statusCode ?? 0
        guard code < 400 else { throw CopilotError.http(code, snippet(data)) }
        guard let o = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let content = o["content"] as? [[String: Any]],
              let text = content.first?["text"] as? String else { throw CopilotError.badResponse }
        return text
    }

    // MARK: helpers

    private static func splitCodeBlock(_ s: String) -> (String, String) {
        // pull the first ```…``` block as source, the rest as note.
        guard let open = s.range(of: "```") else { return (s, "") }
        let afterOpen = s[open.upperBound...]
        // skip a language tag line
        let bodyStart = afterOpen.firstIndex(of: "\n").map { afterOpen.index(after: $0) } ?? afterOpen.startIndex
        guard let close = afterOpen.range(of: "```", range: bodyStart..<afterOpen.endIndex) else { return (s, "") }
        let code = String(afterOpen[bodyStart..<close.lowerBound]).trimmingCharacters(in: .whitespacesAndNewlines)
        let note = (String(s[..<open.lowerBound]) + String(afterOpen[close.upperBound...]))
            .trimmingCharacters(in: .whitespacesAndNewlines)
        return (code, note)
    }
    private static func snippet(_ d: Data) -> String { String(decoding: d.prefix(300), as: UTF8.self) }
}
