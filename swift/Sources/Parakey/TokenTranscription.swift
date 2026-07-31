import Foundation

/// One decoded token from `parakeet_capi_transcribe_pcm_batch_json`'s JSON
/// document. `t` is the token's timestamp in seconds, relative to the
/// START of whatever audio buffer was passed to that specific transcribe
/// call (i.e. NOT yet an absolute dictation-relative timestamp — callers
/// convert to absolute time by adding the window's own absolute start
/// offset; see OverlapWindow.swift).
struct Token: Sendable, Decodable, Equatable {
    let id: Int
    let t: Double
    let conf: Double
}

/// One ALREADY-DECODED word from the same JSON document's `"words"` array
/// (`{"w":"...","start":0.480,"end":0.640,"conf":0.9100}`, per
/// `parakeet_capi_transcribe_path_json`'s doc comment, which
/// `parakeet_capi_transcribe_pcm_batch_json` reproduces per clip). Unlike
/// `Token`, this carries its own human-readable text, so overlap assembly
/// (see OverlapAssembly.swift) can dedup and re-join words without ever
/// needing SentencePiece detokenization. `start`/`end` are seconds relative
/// to the START of the buffer passed to that transcribe call, exactly like
/// `Token.t`.
struct TranscribedWord: Sendable, Decodable, Equatable {
    let w: String
    let start: Double
    let end: Double
    let conf: Double
}

/// Decoded result of a token-timestamp transcription call.
///
/// `tokens` and `words` are both decoded leniently (missing key -> empty
/// array) rather than as required keys: the two arrays are independently
/// useful, the real bridge always emits both, and a hypothetical future
/// bridge/model that emitted only one must not turn into a hard decode
/// failure for callers that only wanted the other.
struct TokenTranscription: Sendable, Decodable, Equatable {
    let text: String
    let frameSec: Double
    let tokens: [Token]
    let words: [TranscribedWord]

    enum CodingKeys: String, CodingKey {
        case text
        case frameSec = "frame_sec"
        case tokens
        case words
    }

    init(text: String, frameSec: Double, tokens: [Token], words: [TranscribedWord] = []) {
        self.text = text
        self.frameSec = frameSec
        self.tokens = tokens
        self.words = words
    }

    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        text = try container.decode(String.self, forKey: .text)
        frameSec = try container.decode(Double.self, forKey: .frameSec)
        tokens = try container.decodeIfPresent([Token].self, forKey: .tokens) ?? []
        words = try container.decodeIfPresent([TranscribedWord].self, forKey: .words) ?? []
    }
}

enum TokenTranscriptionDecodeError: Error {
    case emptyArray
    case malformedJSON(Error)
}

/// Decodes `parakeet_capi_transcribe_pcm_batch_json`'s JSON document for a
/// single-clip (`n_clips=1`) call. The upstream API returns a JSON ARRAY
/// even for one clip (per its own doc comment) -- decode the array and take
/// its one element.
func decodeTokenTranscription(json: String) throws -> TokenTranscription {
    guard let data = json.data(using: .utf8) else {
        throw TokenTranscriptionDecodeError.malformedJSON(
            NSError(domain: "TokenTranscription", code: -1,
                    userInfo: [NSLocalizedDescriptionKey: "JSON string was not valid UTF-8"]))
    }
    do {
        let clips = try JSONDecoder().decode([TokenTranscription].self, from: data)
        guard let first = clips.first else {
            throw TokenTranscriptionDecodeError.emptyArray
        }
        return first
    } catch let error as TokenTranscriptionDecodeError {
        throw error
    } catch {
        throw TokenTranscriptionDecodeError.malformedJSON(error)
    }
}
