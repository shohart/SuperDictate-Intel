import Carbon
import Foundation

/// Reads the language of the user's *currently active keyboard input source*
/// (e.g. "Russian", "U.S.") via Carbon's Text Input Sources API — the same
/// signal macOS itself uses to label the input menu. This is a much cheaper
/// and more reliable signal for "what language is the user typing/speaking"
/// than asking whisper.cpp to auto-detect it from audio, especially once
/// `audio_ctx` is trimmed for speed (see WhisperEngine.swift): whisper's own
/// auto-detect was found to become unreliable under a trimmed encoder
/// context, silently mistranslating non-English speech into English.
func currentKeyboardLanguageCode() -> String? {
    guard let source = TISCopyCurrentKeyboardInputSource()?.takeRetainedValue() else {
        return nil
    }
    guard let languagesPtr = TISGetInputSourceProperty(source, kTISPropertyInputSourceLanguages) else {
        return nil
    }
    let languages = Unmanaged<CFArray>.fromOpaque(languagesPtr).takeUnretainedValue() as NSArray
    guard let first = languages.firstObject as? String else {
        return nil
    }
    // BCP-47 tags like "en-US" or "ru" — whisper.cpp/DictationLanguage only
    // care about the primary subtag.
    let primary = first.split(separator: "-").first.map(String.init) ?? first
    return primary.lowercased()
}

/// Pure mapping from a keyboard input source's BCP-47 language tag (e.g.
/// "en-US", "RU", "zh-Hans") to a whisper.cpp language code, or nil if the
/// tag is empty, malformed, or doesn't correspond to a known
/// `DictationLanguage`. Factored out of `currentKeyboardLanguageCode()` /
/// `resolveEffectiveWhisperLanguage(setting:)` so the mapping itself is
/// testable without a live Carbon input source (e.g. over SSH with no
/// active GUI session, where `currentKeyboardLanguageCode()` always
/// returns nil).
func whisperLanguageCode(forKeyboardLanguageTag tag: String) -> String? {
    let primary = tag.split(separator: "-").first.map(String.init) ?? tag
    let lowered = primary.lowercased()
    guard lowered != DictationLanguage.auto.rawValue,
          DictationLanguage(rawValue: lowered) != nil else {
        return nil
    }
    return lowered
}

/// See KeyboardLanguage.swift's file doc comment for why this exists.
/// Falls back to whisper.cpp's own auto-detect (returns nil) whenever the
/// keyboard signal is unavailable or maps to a language this app doesn't
/// know how to force — never regresses on today's behavior in that case.
func resolveEffectiveWhisperLanguage(setting: DictationLanguage) -> String? {
    guard setting == .auto else {
        return setting.whisperLanguageCode
    }
    guard let keyboardTag = currentKeyboardLanguageCode() else {
        return nil
    }
    return whisperLanguageCode(forKeyboardLanguageTag: keyboardTag)
}
