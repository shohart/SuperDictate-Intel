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

/// Decoded result of a token-timestamp transcription call.
struct TokenTranscription: Sendable, Decodable, Equatable {
    let text: String
    let frameSec: Double
    let tokens: [Token]

    enum CodingKeys: String, CodingKey {
        case text
        case frameSec = "frame_sec"
        case tokens
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
