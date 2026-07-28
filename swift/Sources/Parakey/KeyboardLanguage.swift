import Carbon
import Foundation

/// Reads the language of the user's *currently active keyboard input source*
/// (e.g. "Russian", "U.S.") via Carbon's Text Input Sources API — the same
/// signal macOS itself uses to label the input menu. Used to resolve
/// `.auto` into a concrete `DictationLanguage` for deterministic
/// post-processing (`ParakeetTranscriptRepair`'s Russian/`ё` handling) —
/// parakeet.cpp's plain PCM transcription entry point does not take a
/// forced-language parameter (see `DictationLanguage`'s doc comment in
/// main.swift), so this signal no longer biases native decoding the way it
/// once biased whisper.cpp's `audio_ctx`/language hint; it now only feeds
/// the effective-language resolution used after transcription completes.
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
    // BCP-47 tags like "en-US" or "ru" — DictationLanguage only cares about
    // the primary subtag.
    let primary = first.split(separator: "-").first.map(String.init) ?? first
    return primary.lowercased()
}

/// Pure mapping from a keyboard input source's BCP-47 language tag (e.g.
/// "en-US", "RU", "zh-Hans") to a `DictationLanguage` ISO code, or nil if
/// the tag is empty, malformed, or doesn't correspond to a known
/// `DictationLanguage`. Factored out of `currentKeyboardLanguageCode()` /
/// `resolveEffectiveDictationLanguage(setting:)` so the mapping itself is
/// testable without a live Carbon input source (e.g. over SSH with no
/// active GUI session, where `currentKeyboardLanguageCode()` always
/// returns nil).
func dictationLanguageCode(forKeyboardLanguageTag tag: String) -> String? {
    let primary = tag.split(separator: "-").first.map(String.init) ?? tag
    let lowered = primary.lowercased()
    guard lowered != DictationLanguage.auto.rawValue,
          DictationLanguage(rawValue: lowered) != nil else {
        return nil
    }
    return lowered
}

/// See KeyboardLanguage.swift's file doc comment for why this exists. Falls
/// back to nil (Parakeet's own auto-detect / "no forced language" state)
/// whenever the keyboard signal is unavailable or maps to a language this
/// app doesn't know about — never regresses on today's behavior in that
/// case.
func resolveEffectiveDictationLanguage(setting: DictationLanguage) -> String? {
    guard setting == .auto else {
        return setting.isoLanguageCode
    }
    guard let keyboardTag = currentKeyboardLanguageCode() else {
        return nil
    }
    return dictationLanguageCode(forKeyboardLanguageTag: keyboardTag)
}
