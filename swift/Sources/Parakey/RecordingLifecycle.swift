// SuperDictate — extracted from the monolithic main.swift
// during the refactor/split-main refactor.
//

import AppKit
import AVFoundation
import AudioToolbox
import Foundation
import CoreGraphics
import parakeet_cpp
import CryptoKit
import Darwin
import ApplicationServices
import IOKit
import QuartzCore
import ServiceManagement
import UniformTypeIdentifiers

// MARK: - Recording lifecycle decisions

enum RecordingReleaseAction: Equatable {
    case discardTooShort(duration: Double)
    case transcribe(duration: Double)
}

func recordingReleaseAction(capturedSampleCount: Int,
                                    sampleRate: Double = SAMPLE_RATE,
                                    minimumClipSeconds: Double = MIN_CLIP_SECONDS) -> RecordingReleaseAction {
    let duration = sampleRate > 0 ? Double(max(0, capturedSampleCount)) / sampleRate : 0
    return duration < minimumClipSeconds
        ? .discardTooShort(duration: duration)
        : .transcribe(duration: duration)
}

struct DictationTextProcessingResult: Equatable {
    let text: String
    let appliedCorrectionCount: Int
    let removedFillerWordCount: Int
}

func processedDictationText(rawTranscript: String,
                                    corrections: [TranscriptCorrection],
                                    removeFillerWords: Bool,
                                    normalizeNumbersToDigits: Bool = false,
                                    language: DictationLanguage = .auto,
                                    enabledFillerPresetKeys: Set<String> = FillerWordRemover.defaultEnabledPresetKeys,
                                    customFillerWords: [String] = []) -> DictationTextProcessingResult {
    let trimmed = rawTranscript.trimmingCharacters(in: .whitespacesAndNewlines)
    let repaired = ParakeetTranscriptRepair.apply(to: trimmed, language: language)

    let numberNormalized: String
    switch language {
    case .auto, .russian:
        numberNormalized = normalizeNumbersToDigits ? RussianNumberNormalizer.normalize(repaired) : repaired
    default:
        numberNormalized = repaired
    }

    let corrected = TranscriptCorrector.apply(to: numberNormalized, corrections: corrections)

    guard removeFillerWords else {
        return DictationTextProcessingResult(text: corrected.text,
                                             appliedCorrectionCount: corrected.appliedCount,
                                             removedFillerWordCount: 0)
    }

    let stripped = FillerWordRemover.apply(to: corrected.text,
                                           enabledPresetKeys: enabledFillerPresetKeys,
                                           customWords: customFillerWords)
    return DictationTextProcessingResult(text: stripped.text,
                                         appliedCorrectionCount: corrected.appliedCount,
                                         removedFillerWordCount: stripped.removedCount)
}

