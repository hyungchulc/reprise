import Foundation
import RepriseCore

/// What turns a meeting recording into text.
enum TranscriptionEngine: String, Codable, CaseIterable, Identifiable {
    /// Apple's speech models on this Mac, in each chosen language.
    case apple
    /// OpenAI's Whisper models through WhisperKit, downloaded once and run on this Mac.
    case whisperKit
    /// OpenAI's transcription models through the person's ChatGPT plan, signed in with Codex, or an API key.
    case openAI
    /// Google's Gemini models through the person's Google AI plan, signed in with Antigravity, or an API key.
    case gemini
    var id: String { rawValue }

    var title: String {
        switch self {
        case .apple: "Apple, on this Mac"
        case .whisperKit: "Whisper, on this Mac"
        case .openAI: "OpenAI, online"
        case .gemini: "Gemini, online"
        }
    }

    var shortTitle: String {
        switch self {
        case .apple: "Apple"
        case .whisperKit: "Whisper"
        case .openAI: "OpenAI"
        case .gemini: "Gemini"
        }
    }

    var about: String {
        switch self {
        case .apple:
            "Apple's speech models transcribe on this Mac in each chosen language. Nothing leaves this Mac."
        case .whisperKit:
            "OpenAI's open Whisper model runs on this Mac through WhisperKit and recognizes about 100 languages on its own. The model downloads once from Hugging Face; recordings never leave this Mac."
        case .openAI:
            "OpenAI's newest transcription models, through your ChatGPT plan or an OpenAI API key. Recordings are sent to OpenAI to be transcribed. When neither works, Reprise transcribes with Apple on this Mac instead."
        case .gemini:
            "Google's Gemini listens to the recording and tells the voices apart, through your Google AI plan or a Gemini API key. Recordings are sent to Google to be transcribed. When neither works, Reprise transcribes with Apple on this Mac instead."
        }
    }

    /// Whether the chosen languages decide what is heard, or only hint at it.
    var languagesAreHints: Bool { self != .apple }
}

/// Who finds the voices when speakers are labeled. Gemini names voices itself in recordings of one piece.
enum SpeakerFinder: String, Codable, CaseIterable, Identifiable {
    /// SpeakerKit's speaker model on this Mac.
    case mac
    /// OpenAI's diarization model, through the OpenAI account chosen for transcription.
    case openAI
    var id: String { rawValue }
    var title: String { self == .mac ? "On this Mac" : "OpenAI, online" }
}

/// OpenAI's transcription models that work with a ChatGPT sign-in.
struct OpenAITranscriptionModel: Identifiable, Equatable {
    let id: String
    let name: String
    let note: String

    static let standard = "gpt-transcribe"
    /// Live transcription during a meeting starts from this model.
    static let live = "gpt-live-transcribe"
    static let all = [
        OpenAITranscriptionModel(id: "gpt-transcribe", name: "GPT Transcribe", note: "Most accurate"),
        OpenAITranscriptionModel(id: "gpt-live-transcribe", name: "GPT Live Transcribe", note: "Fastest text while speech is still going"),
        OpenAITranscriptionModel(id: "gpt-4o-transcribe", name: "GPT-4o Transcribe", note: "The earlier model"),
        OpenAITranscriptionModel(id: "gpt-4o-mini-transcribe", name: "GPT-4o mini Transcribe", note: "Earlier and lighter"),
        OpenAITranscriptionModel(id: "gpt-realtime-whisper", name: "GPT Realtime Whisper", note: "Whisper, served by OpenAI")
    ]
    static func named(_ id: String) -> String { all.first { $0.id == id }?.name ?? id }
}

/// Whisper models WhisperKit can download, smallest last.
struct WhisperModel: Identifiable, Equatable {
    let id: String
    let name: String
    let megabytes: Int
    let note: String

    static let recommended = "large-v3-v20240930_626MB"
    static let all = [
        WhisperModel(id: "large-v3-v20240930_626MB", name: "Large v3 Turbo", megabytes: 627, note: "Recommended: accurate, compressed"),
        WhisperModel(id: "large-v3-v20240930_turbo", name: "Large v3 Turbo, full size", megabytes: 1_638, note: "A little more accurate, larger"),
        WhisperModel(id: "small", name: "Small", megabytes: 486, note: "Faster, less accurate"),
        WhisperModel(id: "base", name: "Base", megabytes: 147, note: "Fastest, for short clear speech")
    ]
    static func named(_ id: String) -> String { all.first { $0.id == id }?.name ?? id }
}

/// Everything one transcription needs from the settings, taken when it starts.
struct TranscriptionRequest: Sendable {
    var engine = TranscriptionEngine.apple
    var locales: [String] = []
    var openAIModel = OpenAITranscriptionModel.standard
    var openAIAccess = OpenAIAccess.chatGPT
    var whisperModel = WhisperModel.recommended
    var geminiAccess = GeminiAccess.subscription
    var geminiModel = ""
    var speakerLabels = false
    var speakerFinder = SpeakerFinder.mac
    /// The Codex set in AI & Models; its ChatGPT sign-in reaches OpenAI.
    var codexPath: String?
    /// The Antigravity set in AI & Models; its Google sign-in reaches Gemini.
    var geminiPath: String?

    /// One chosen language goes along as a hint; with several, the model recognizes each part.
    var languageHint: String? {
        guard locales.count == 1 else { return nil }
        return Locale(identifier: locales[0]).language.languageCode?.identifier
    }
}
