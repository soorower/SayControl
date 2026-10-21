import Foundation

// The keys behind Settings › Models: who polishes on your own key, whether a
// key works, and which models it can reach. One key per provider, kept in
// .env under the provider's own name, so a key saved for transcription is
// already there for polish (OpenAI, OpenRouter, Google) and the other way.

/// Who polishes on this Mac's own key. All but Claude speak OpenAI's chat
/// API; Cerebras and OpenRouter keep the routing Refine.swift always gave
/// them (direct with a fallback, fast hosts only).
enum PolishProvider: String, CaseIterable {
    case anthropic, openai, openrouter, cerebras, groq, google

    var title: String {
        switch self {
        case .anthropic:  return "Claude"
        case .openai:     return "OpenAI"
        case .openrouter: return "OpenRouter"
        case .cerebras:   return "Cerebras"
        case .groq:       return "Groq"
        case .google:     return "Google"
        }
    }

    /// Who the text goes to, by the company's name — what the privacy line
    /// says.
    var company: String { self == .anthropic ? "Anthropic" : title }

    /// The same names Provider uses where the two overlap, so one key
    /// serves both.
    var keyVar: String {
        switch self {
        case .anthropic:  return "ANTHROPIC_API_KEY"
        case .openai:     return Provider.openai.keyVar
        case .openrouter: return Provider.openrouter.keyVar
        case .cerebras:   return "CEREBRAS_API_KEY"
        case .groq:       return "GROQ_API_KEY"
        case .google:     return Provider.gemini.keyVar
        }
    }

    var modelVar: String { "POLISH_MODEL_\(rawValue.uppercased())" }

    var keyPlaceholder: String {
        switch self {
        case .anthropic:  return "sk-ant-…"
        case .openai:     return "sk-…"
        case .openrouter: return "sk-or-v1-…"
        case .cerebras:   return "csk-…"
        case .groq:       return "gsk_…"
        case .google:     return "AIza…"
        }
    }

    var keyHelpURL: String {
        switch self {
        case .anthropic:  return "https://console.anthropic.com/settings/keys"
        case .openai:     return "https://platform.openai.com/api-keys"
        case .openrouter: return "https://openrouter.ai/settings/keys"
        case .cerebras:   return "https://cloud.cerebras.ai/"
        case .groq:       return "https://console.groq.com/keys"
        case .google:     return "https://aistudio.google.com/apikey"
        }
    }

    /// Fast enough for the paste path, where nothing has been picked yet.
    var defaultModel: String {
        switch self {
        case .anthropic:  return "claude-haiku-5-5"
        case .openai:     return "gpt-4.1-mini"
        case .openrouter: return REFINE_DEFAULT_MODEL
        case .cerebras:   return "gpt-oss-120b"
        case .groq:       return "openai/gpt-oss-120b"
        case .google:     return "gemini-2.5-flash"
        }
    }

    var chatURL: String {
        switch self {
        case .anthropic:  return "https://api.anthropic.com/v1/messages"
        case .openai:     return "https://api.openai.com/v1/chat/completions"
        case .openrouter: return OPENROUTER_CHAT_URL
        case .cerebras:   return CEREBRAS_CHAT_URL
        case .groq:       return "https://api.groq.com/openai/v1/chat/completions"
        case .google:     return "https://generativelanguage.googleapis.com/v1beta/openai/chat/completions"
        }
    }

    var modelsURL: String {
        switch self {
        case .anthropic:  return "https://api.anthropic.com/v1/models?limit=100"
        case .openai:     return "https://api.openai.com/v1/models"
        case .openrouter: return "https://openrouter.ai/api/v1/models"
        case .cerebras:   return CEREBRAS_MODELS_URL
        case .groq:       return "https://api.groq.com/openai/v1/models"
        case .google:     return "https://generativelanguage.googleapis.com/v1beta/models?pageSize=1000"
        }
    }

    func authorize(_ req: inout URLRequest, key: String) {
        switch self {
        case .anthropic:
            req.setValue(key, forHTTPHeaderField: "x-api-key")
            req.setValue("2023-06-01", forHTTPHeaderField: "anthropic-version")
        case .google where req.url?.path.contains("/openai/") == false:
            req.setValue(key, forHTTPHeaderField: "x-goog-api-key")
        default:
            req.setValue("Bearer \(key)", forHTTPHeaderField: "Authorization")
        }
    }
}

/// What a polish key can reach, fetched from the provider: its chat models,
/// the fast ones first. Fetching is also the check that the key works.
enum PolishModels {
    /// Answer quickly enough to sit in the paste path (well under a second
    /// for a sentence), by name: the small tiers and the fast hosts. The
    /// o-series reason before they answer, whatever their size.
    static func isFast(_ id: String) -> Bool {
        let m = id.lowercased()
        if m.hasPrefix("o1") || m.hasPrefix("o3") || m.hasPrefix("o4") || m.contains("/o3") || m.contains("/o4") { return false }
        // "-mini", not "mini": every "gemini" has those letters.
        return ["haiku", "-nano", "-mini", "flash", "gpt-oss", "llama-3.3-70b", "qwen3-32b", "qwen-3-32b", "llama-3.1-8b"]
            .contains { m.contains($0) }
    }

    /// What each provider is best picked from, best first: the models the
    /// paste path was measured on, or the provider's fast tier.
    private static func recommended(_ provider: PolishProvider) -> [String] {
        switch provider {
        case .anthropic:  return ["claude-haiku-5-5", "claude-haiku-4-5", "claude-sonnet-5-5"]
        case .openai:     return ["gpt-4.1-mini", "gpt-4.1-nano", "gpt-5-mini", "gpt-5-nano"]
        case .openrouter: return ["openai/gpt-oss-120b", "meta-llama/llama-3.3-70b-instruct", "qwen/qwen3-32b"]
        case .cerebras:   return ["gpt-oss-120b", "llama-3.3-70b", "qwen-3-32b"]
        case .groq:       return ["openai/gpt-oss-120b", "llama-3.3-70b-versatile", "qwen/qwen3-32b"]
        case .google:     return ["gemini-2.5-flash", "gemini-2.5-flash-lite"]
        }
    }

    /// Recognisably not a chat model: speech, images, embeddings, guards.
    private static func isChat(_ id: String, _ provider: PolishProvider) -> Bool {
        let m = id.lowercased()
        let skip = ["whisper", "transcribe", "tts", "audio", "realtime", "image", "dall-e", "embedding", "embed",
                    "moderation", "search", "guard", "vision", "sora", "computer-use", "codex", "-instruct-",
                    "babbage", "davinci", "aqa", "imagen", "veo", "learnlm", "deep-research", "playai", "compound",
                    "robotics", "banana", "-live", "omni", ":batch"]
        if skip.contains(where: { m.contains($0) }) { return false }
        switch provider {
        case .openai: return m.hasPrefix("gpt-") || m.hasPrefix("o1") || m.hasPrefix("o3") || m.hasPrefix("o4")
        case .google: return m.hasPrefix("gemini") || m.hasPrefix("gemma")
        case .anthropic: return m.hasPrefix("claude")
        default: return true
        }
    }

    /// A dated snapshot ("…-2025-04-16", "…-20251001") whose undated name
    /// is listed too: the same model twice.
    private static func isDatedTwin(_ id: String, in all: Set<String>) -> Bool {
        guard let r = id.range(of: #"-(\d{4}-\d{2}-\d{2}|\d{8})$"#, options: .regularExpression) else { return false }
        return all.contains(String(id[..<r.lowerBound]))
    }

    static func fetch(_ provider: PolishProvider, key: String,
                      completion: @escaping (Result<[String], Error>) -> Void) {
        var req = URLRequest(url: URL(string: provider.modelsURL)!)
        provider.authorize(&req, key: key)
        req.timeoutInterval = 20
        URLSession.shared.dataTask(with: req) { data, resp, error in
            let code = (resp as? HTTPURLResponse)?.statusCode ?? 0
            let json = data.flatMap { try? JSONSerialization.jsonObject(with: $0) }
            let result: Result<[String], Error>
            if let error = error {
                result = .failure(error)
            } else if let ids = Self.ids(in: json, provider), code < 400 {
                let all = Set(ids)
                let chat = ids.filter { isChat($0, provider) && !isDatedTwin($0, in: all) }
                // The recommended ones first, then the fast, then the rest;
                // newest names sort high within each, the order people look
                // for them in.
                let best = recommended(provider).filter(all.contains)
                let rest = chat.filter { !best.contains($0) }.sorted { a, b in
                    let fa = isFast(a), fb = isFast(b)
                    return fa != fb ? fa : a.localizedStandardCompare(b) == .orderedDescending
                }
                result = .success(best + rest)
            } else {
                result = .failure(KeyCheck.problem(json, code: code))
            }
            DispatchQueue.main.async { completion(result) }
        }.resume()
    }

    private static func ids(in json: Any?, _ provider: PolishProvider) -> [String]? {
        guard let dict = json as? [String: Any] else { return nil }
        if provider == .google, let models = dict["models"] as? [[String: Any]] {
            return models.compactMap { m in
                guard (m["supportedGenerationMethods"] as? [String])?.contains("generateContent") ?? true,
                      let name = m["name"] as? String else { return nil }
                return name.hasPrefix("models/") ? String(name.dropFirst(7)) : name
            }
        }
        guard let data = dict["data"] as? [[String: Any]] else { return nil }
        return data.compactMap { m in
            // OpenRouter lists what each model reads and writes; polish needs
            // text out.
            if let arch = m["architecture"] as? [String: Any],
               let out = arch["output_modalities"] as? [String], !out.contains("text") { return nil }
            return m["id"] as? String
        }
    }
}

/// Whether a transcription key works, in one line — the old Verify
/// button's checks, provider by provider, kept whole: an ElevenLabs key
/// scoped to speech alone still works, an xAI key can be blocked while it
/// still authenticates, Soniox and OpenAI say whether the model is there.
enum KeyCheck {
    struct Outcome {
        let ok: Bool
        let line: String
    }

    static func verify(_ provider: Provider, key: String, model: String,
                       completion: @escaping (Outcome) -> Void) {
        let checkURL: String
        switch provider {
        case .openai:     checkURL = OPENAI_KEY_URL
        case .elevenlabs: checkURL = ELEVEN_KEY_URL
        case .assemblyai: checkURL = ASSEMBLY_KEY_URL
        case .gemini:     checkURL = GEMINI_KEY_URL
        case .smallest:   checkURL = SMALLEST_KEY_URL
        case .meta:       checkURL = META_KEY_URL
        case .xai:        checkURL = XAI_KEY_URL
        case .soniox:     checkURL = SONIOX_KEY_URL
        default:          checkURL = OPENROUTER_KEY_URL
        }
        var req = URLRequest(url: URL(string: checkURL)!)
        req.setValue(provider.authHeaderValue(key), forHTTPHeaderField: provider.authHeaderName)
        req.timeoutInterval = 20
        // smallest.ai refuses GET outright, so the check POSTs an empty body
        // at the STT endpoint: auth is judged before the body is looked at.
        if provider == .smallest {
            req.httpMethod = "POST"
            req.setValue("application/octet-stream", forHTTPHeaderField: "Content-Type")
            req.httpBody = Data()
        }
        URLSession.shared.dataTask(with: req) { data, resp, err in
            let code = (resp as? HTTPURLResponse)?.statusCode ?? 0
            let json = data.flatMap { try? JSONSerialization.jsonObject(with: $0) as? [String: Any] }
            let outcome: Outcome
            if let err = err {
                outcome = Outcome(ok: false, line: "Couldn't reach \(provider.title) — \(err.localizedDescription)")
            } else if let json = json {
                outcome = judge(provider, json: json, code: code, model: model)
            } else {
                outcome = Outcome(ok: false, line: "Unexpected reply (HTTP \(code)).")
            }
            DispatchQueue.main.async { completion(outcome) }
        }.resume()
    }

    private static func judge(_ provider: Provider, json: [String: Any], code: Int, model: String) -> Outcome {
        func refused(_ msg: String?) -> Outcome { Outcome(ok: false, line: msg ?? "Refused (HTTP \(code))") }
        switch provider {
        case .smallest:
            // A bad key is a 401 before the empty body is looked at; a good
            // one gets past auth and is told there is no audio.
            if code == 401 || code == 403 {
                return refused((json["message"] as? String) ?? (json["error"] as? String))
            }
            return Outcome(ok: true, line: "Usage is shown on app.smallest.ai.")
        case .assemblyai:
            // No account endpoint answers for this key, so listing
            // transcripts is the check: it needs a valid key and nothing else.
            return json["page_details"] != nil ? Outcome(ok: true, line: "Credits are on AssemblyAI's dashboard.")
                                               : refused(json["error"] as? String)
        case .gemini:
            // A list at all is a working key: brand-new names lag the catalogue.
            return json["models"] is [[String: Any]] ? Outcome(ok: true, line: "Usage is in Google AI Studio.")
                : refused((json["error"] as? [String: Any])?["message"] as? String)
        case .xai:
            // This answers for the KEY: a blocked key or team still returns
            // 200, and would read as healthy until a dictation failed.
            guard let name = json["name"] as? String else { return refused(json["error"] as? String) }
            let stopped = [json["api_key_blocked"], json["api_key_disabled"], json["team_blocked"]]
                .contains { ($0 as? Bool) == true }
            return stopped ? refused("This key is blocked or disabled — check console.x.ai.")
                           : Outcome(ok: true, line: name.isEmpty ? "Usage is on console.x.ai." : "“\(name)”")
        case .soniox:
            guard let models = json["models"] as? [[String: Any]] else { return refused(json["message"] as? String) }
            let listed = models.contains { $0["id"] as? String == model }
            return Outcome(ok: true, line: listed ? "\(model) is available." : "Works, though “\(model)” isn't listed.")
        case .elevenlabs:
            // Scribe bills the account's credit pool, so this is the number
            // that runs out.
            if let limit = json["character_limit"] as? Double {
                let used = json["character_count"] as? Double ?? 0
                return Outcome(ok: true, line: "\(Int(used).formatted()) of \(Int(limit).formatted()) credits used.")
            }
            let detail = json["detail"] as? [String: Any]
            // A key scoped to speech-to-text alone can't read the account:
            // authentication SUCCEEDED, and dictation works.
            if detail?["status"] as? String == "missing_permissions" {
                return Outcome(ok: true, line: "Speech-to-text only, so credits can't be shown here.")
            }
            return refused(detail?["message"] as? String ?? json["detail"] as? String)
        case .openai, .meta:
            // Meta's /v1/models answers in OpenAI's shape.
            guard let models = json["data"] as? [[String: Any]] else {
                return refused((json["error"] as? [String: Any])?["message"] as? String)
            }
            let ids = Set(models.compactMap { $0["id"] as? String })
            return Outcome(ok: true, line: ids.contains(model) ? "\(ids.count) models, including \(model)."
                                                               : "\(ids.count) models on this key.")
        default:
            // OpenRouter's /key: its label and what it has spent.
            guard let d = json["data"] as? [String: Any] else {
                return refused((json["error"] as? [String: Any])?["message"] as? String)
            }
            let usage = d["usage"] as? Double ?? 0
            let limit = (d["limit"] as? Double).map { String(format: " of $%.2f", $0) } ?? ""
            return Outcome(ok: true, line: String(format: "$%.2f used%@.", usage, limit))
        }
    }

    /// A provider's refusal, in its own words where it gave any.
    static func problem(_ json: Any?, code: Int) -> Error {
        var message: String?
        if let dict = json as? [String: Any] {
            message = (dict["error"] as? [String: Any])?["message"] as? String
                ?? dict["error"] as? String ?? dict["message"] as? String
        } else if let list = json as? [[String: Any]] {
            message = (list.first?["error"] as? [String: Any])?["message"] as? String
        }
        if message == nil {
            message = code == 401 || code == 403 ? "This key was refused." : "Unexpected reply (HTTP \(code))."
        }
        return NSError(domain: "SayCtrl", code: code, userInfo: [NSLocalizedDescriptionKey: message!])
    }
}
