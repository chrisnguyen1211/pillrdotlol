import SwiftUI

/// Which mark a provider cell draws.
enum ProviderGlyph: String, Codable, Equatable {
    case claude
    case devin
    case openai
    case third
    case cursor
    /// The raw value stays `gemini`: it is the key archived readings were
    /// written under, and renaming it would make every stored reading for this
    /// provider undecodable.
    case antigravity = "gemini"
    /// Gemini's own sparkle, for the provider that meters a raw API key.
    ///
    /// It cannot be called `gemini`: that raw value already names Antigravity's
    /// arch inside every archived snapshot, and swapping its meaning would
    /// redraw old readings as a mark they were never written for. So the
    /// sparkle gets a key of its own instead.
    case geminiSpark = "gemini-spark"
    case glm
    case qwen
    case gemma
    case meta
    case deepseek
    case mistral
    case grok
    case opencode
    case commandcode
    case copilot
    case kimi
    case ollama
    case ollamaLocal = "ollama-local"
    case lmstudio
    // Added later, with the providers that wear them.
    case kilo
    case kiro
    case amp
    case apify
    case minimax
    case qianwenAI = "qianwenai"
    /// A plain key, for an API in the catalog with no mark of its own here.
    /// Drawn from SF Symbols rather than an outline — see `ProviderGlyphView`.
    case apiKey = "api-key"
    // The API tab's providers, each in its own mark: Lobe Icons (MIT) and
    // Simple Icons (CC0) where they have one, the provider's own site icon
    // where neither does. Drawn from the asset catalogue only.
    case openrouter
    case vercel
    case poe
    case venice
    case chutes
    case cloudflare
    case anthropic
    case xai
    case groq
    case together
    case fireworks
    case deepinfra
    case novita
    case hyperbolic
    case featherless
    case cerebras
    case sambanova
    case nebius
    case cohere
    case perplexity
    case ai21
    case huggingface
    case siliconflow
    case stepfun
    case zai
    case baichuan
    case elevenlabs
    case assemblyai
    case pruna
    case bria
    case stability
    case runway
    case ideogram
    case fal
    case replicate
    case tavily
    case exa
    case firecrawl
    case jina
    case deepgram
    case neon
    case supabase
    case upstash
    case resend
    case aimlapi
    case brightdata
    case cartesia
    case composio
    case e2b
    case nanogpt
    case pinecone
    case requesty
    case runware
    case scraperapi
    case scrapingbee
    case serpapi
    case serper
    case browserbase

    /// If an asset with this name is in the bundle it wins over the traced
    /// outline — drop a PDF/SVG export from Figma in and it is picked up.
    var assetName: String { self == .ollamaLocal ? "glyph-ollama" : "glyph-\(rawValue)" }

    /// How much to scale this mark so it reads the same size as the others.
    ///
    /// Every outline is normalised into the same unit box, which makes their
    /// *boxes* identical and their marks anything but: measured on screen at
    /// 16pt, the OpenAI knot covered 32px while the Gemini spark covered 25 —
    /// a fifth smaller — because a spark's points are thin and its corners are
    /// mostly empty. Boxes of equal size are not marks of equal size, and the
    /// eye reads the mark.
    ///
    /// Measured from a render rather than guessed: each value brings that
    /// glyph's ink to the same extent as Claude's.
    var opticalScale: CGFloat {
        switch self {
        case .claude: return 0.97
        case .cursor: return 0.97
        case .openai: return 0.94
        case .antigravity: return 1.0
        case .geminiSpark: return 1.0
        case .glm:    return 0.95
        case .grok:   return 1.0
        case .opencode: return 0.95
        case .commandcode: return 0.96
        case .copilot: return 0.96
        case .kimi:   return 0.95
        case .ollama: return 0.95
        case .third:  return 1.0
        case .ollamaLocal: return 0.98
        case .lmstudio: return 0.96
        case .devin, .qwen, .gemma, .meta, .deepseek, .mistral: return 1.0
        case .kilo:   return 0.97
        case .kiro:   return 0.95
        case .amp:    return 1.0
        case .apify:  return 0.97
        case .minimax: return 0.95
        case .qianwenAI: return 0.97
        case .apiKey: return 1.0
        default: return isFullColour ? 1.0 : 0.95
        }
    }

    /// A site icon, which has its own colours and background: drawn as it
    /// is, not as a template the cell tints.
    var isFullColour: Bool {
        switch self {
        case .aimlapi, .brightdata, .cartesia, .composio, .e2b, .nanogpt, .pinecone, .requesty, .runware, .scraperapi, .scrapingbee, .serpapi, .serper, .browserbase:
            return true
        default:
            return false
        }
    }

    var outline: [[CGPoint]] {
        switch self {
        case .claude: return GlyphOutline.claude
        case .openai: return GlyphOutline.openai
        case .third:  return GlyphOutline.third
        case .cursor: return GlyphOutline.cursor
        case .antigravity: return GlyphOutline.antigravity
        case .geminiSpark: return GlyphOutline.gemini
        case .glm:    return GlyphOutline.glm
        case .devin, .qwen, .gemma, .meta, .deepseek, .mistral, .lmstudio: return []
        case .grok:   return GlyphOutline.grok
        case .opencode: return GlyphOutline.opencode
        case .commandcode: return GlyphOutline.commandcode
        case .copilot: return GlyphOutline.copilot
        case .kimi:   return GlyphOutline.kimi
        case .ollama, .ollamaLocal: return GlyphOutline.ollama
        case .kilo:   return GlyphOutline.kilo
        case .kiro:   return GlyphOutline.kiro
        // A fallback only: the asset catalogue's glyph is drawn instead.
        case .minimax: return GlyphOutline.minimax
        case .amp, .apify, .qianwenAI, .apiKey: return []
        default: return []
        }
    }
}

/// A traced outline scaled into the view's bounds, filled even-odd so the
/// counters inside a knot stay open.
struct GlyphShape: Shape {
    let outline: [[CGPoint]]

    func path(in rect: CGRect) -> Path {
        var path = Path()
        for loop in outline {
            guard let first = loop.first else { continue }
            path.move(to: point(first, in: rect))
            for p in loop.dropFirst() { path.addLine(to: point(p, in: rect)) }
            path.closeSubpath()
        }
        return path
    }

    private func point(_ p: CGPoint, in rect: CGRect) -> CGPoint {
        CGPoint(x: rect.minX + p.x * rect.width, y: rect.minY + p.y * rect.height)
    }
}

extension ProviderGlyph {
    /// The mark for a provider or monitor id — "claude", "claude-work",
    /// "codex", "grok", "gemini-api" — so a card about a session shows
    /// whose it is even when that agent has no ring connected.
    static func forProvider(_ id: String) -> ProviderGlyph? {
        // A catalog key's id splits into nothing the switch below knows.
        if id.hasPrefix(ExtraKey.catalogPrefix) { return APICatalog.entry(forProviderID: id)?.glyph }
        if id.hasPrefix("gemini-api") || id.hasPrefix("gemini-cli") { return .geminiSpark }
        let base = EffortState.targetID(forProviderID: id)
        switch base {
        case "codex": return .openai
        case "gemini", "antigravity": return .antigravity
        default: return ProviderGlyph(rawValue: base)
        }
    }

    /// The mark for a session, from its id ("grok.…", "claude.…").
    static func forSession(_ session: AgentSession) -> ProviderGlyph? {
        forProvider(String(session.id.split(separator: ".").first ?? ""))
    }

    /// What to call that agent, for "Reply to Grok · …".
    var agentName: String {
        switch self {
        case .claude: return "Claude"
        case .openai: return "Codex"
        case .grok: return "Grok"
        case .cursor: return "Cursor"
        case .antigravity: return "Antigravity"
        case .geminiSpark: return "Gemini"
        case .kimi: return "Kimi"
        case .copilot: return "Copilot"
        case .opencode: return "OpenCode"
        case .devin: return "Devin"
        case .kilo: return "Kilo"
        case .kiro: return "Kiro"
        case .amp: return "Amp"
        case .apify: return "Apify"
        case .minimax: return "MiniMax"
        case .qianwenAI: return "QianwenAI"
        default: return ""
        }
    }
}

struct ProviderGlyphView: View {
    let glyph: ProviderGlyph
    /// A custom endpoint's own image, which wins over the glyph — in colour,
    /// not as a template, because it is a picture somebody chose.
    var customIconFilename: String? = nil
    var size: CGFloat = Design.px(46)

    var body: some View {
        Group {
            if let customIconFilename,
               let image = CustomIconStore.loadIcon(filename: customIconFilename) {
                Image(nsImage: image)
                    .resizable()
                    .scaledToFit()
            } else if glyph == .apiKey {
                Image(systemName: "key.horizontal.fill")
                    .resizable()
                    .scaledToFit()
            } else if glyph.isFullColour, let image = Assets.image(named: glyph.assetName) {
                Image(nsImage: image)
                    .resizable()
                    .scaledToFit()
                    .clipShape(RoundedRectangle(cornerRadius: size * 0.22, style: .continuous))
            } else if let image = Assets.image(named: glyph.assetName) {
                Image(nsImage: image)
                    .renderingMode(.template)
                    .resizable()
                    .scaledToFit()
            } else {
                GlyphShape(outline: glyph.outline)
                    .fill(style: FillStyle(eoFill: true))
            }
        }
        // Scaled inside a frame of the fixed size, so the *layout* stays on a
        // single grid — every row still reserves the same width — while the ink
        // is evened out within it.
        .scaleEffect(glyph.opticalScale)
        .frame(width: size, height: size)
    }
}
