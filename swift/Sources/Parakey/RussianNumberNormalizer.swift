import Foundation

// Ports the token-classification approach used by established Russian ITN
// tools (NVIDIA NeMo text-processing's Russian grammar, natasha/yargy number
// extractors) as native Swift pattern matching — no external runtime, see
// docs/superpowers/specs/2026-07-29-clipboard-race-and-number-itn-design.md
// for the full rationale. Deliberately conservative: a numeral word sequence
// is only converted when it's unambiguous; anything else is left as the
// original dictated words.
enum RussianNumberNormalizer {
    enum NumberWordCategory {
        case unit, teen, ten, hundred, thousandMultiplier, millionMultiplier
    }

    // Every literal inflected wordform we recognize, lowercased, mapped to
    // its numeric value and structural role. Deliberately covers nominative/
    // accusative forms (by far the most common in dictated cardinal counts)
    // plus the oblique forms needed for money/date phrasing added in later
    // tasks. Case forms beyond this table are a known, documented gap — an
    // unrecognized inflection simply falls through to the "leave as-is"
    // fallback rather than being guessed at.
    static let numberWordValues: [String: (value: Int, category: NumberWordCategory)] = {
        var table: [String: (value: Int, category: NumberWordCategory)] = [:]

        let units: [(words: [String], value: Int)] = [
            (["ноль", "нуля", "нулю", "нулём", "нуле"], 0),
            (["один", "одного", "одному", "одним", "одном", "одна", "одной", "одну", "одно"], 1),
            (["два", "двух", "двум", "двумя", "две"], 2),
            (["три", "трёх", "трех", "трём", "трем", "тремя"], 3),
            (["четыре", "четырёх", "четырех", "четырём", "четырем", "четырьмя"], 4),
            (["пять", "пяти", "пятью"], 5),
            (["шесть", "шести", "шестью"], 6),
            (["семь", "семи", "семью"], 7),
            (["восемь", "восьми", "восемью"], 8),
            (["девять", "девяти", "девятью"], 9),
        ]
        for group in units {
            for word in group.words { table[word] = (group.value, .unit) }
        }

        let teens: [(words: [String], value: Int)] = [
            (["десять", "десяти", "десятью"], 10),
            (["одиннадцать", "одиннадцати", "одиннадцатью"], 11),
            (["двенадцать", "двенадцати", "двенадцатью"], 12),
            (["тринадцать", "тринадцати", "тринадцатью"], 13),
            (["четырнадцать", "четырнадцати", "четырнадцатью"], 14),
            (["пятнадцать", "пятнадцати", "пятнадцатью"], 15),
            (["шестнадцать", "шестнадцати", "шестнадцатью"], 16),
            (["семнадцать", "семнадцати", "семнадцатью"], 17),
            (["восемнадцать", "восемнадцати", "восемнадцатью"], 18),
            (["девятнадцать", "девятнадцати", "девятнадцатью"], 19),
        ]
        for group in teens {
            for word in group.words { table[word] = (group.value, .teen) }
        }

        let tens: [(words: [String], value: Int)] = [
            (["двадцать", "двадцати", "двадцатью"], 20),
            (["тридцать", "тридцати", "тридцатью"], 30),
            (["сорок", "сорока"], 40),
            (["пятьдесят", "пятидесяти", "пятьюдесятью"], 50),
            (["шестьдесят", "шестидесяти", "шестьюдесятью"], 60),
            (["семьдесят", "семидесяти", "семьюдесятью"], 70),
            (["восемьдесят", "восьмидесяти", "восемьюдесятью"], 80),
            (["девяносто", "девяноста"], 90),
        ]
        for group in tens {
            for word in group.words { table[word] = (group.value, .ten) }
        }

        let hundreds: [(words: [String], value: Int)] = [
            (["сто", "ста"], 100),
            (["двести", "двухсот", "двумстам", "двумястами", "двухстах"], 200),
            (["триста", "трёхсот", "трехсот", "трёмстам", "тремстам", "тремястами", "трёхстах", "трехстах"], 300),
            (["четыреста", "четырёхсот", "четырехсот", "четырёмстам", "четыремстам", "четырьмястами", "четырёхстах", "четырехстах"], 400),
            (["пятьсот", "пятисот", "пятистам", "пятьюстами", "пятистах"], 500),
            (["шестьсот", "шестисот", "шестистам", "шестьюстами", "шестистах"], 600),
            (["семьсот", "семисот", "семистам", "семьюстами", "семистах"], 700),
            (["восемьсот", "восьмисот", "восьмистам", "восемьюстами", "восьмистах"], 800),
            (["девятьсот", "девятисот", "девятистам", "девятьюстами", "девятистах"], 900),
        ]
        for group in hundreds {
            for word in group.words { table[word] = (group.value, .hundred) }
        }

        for word in ["тысяча", "тысячи", "тысяч", "тысячу", "тысяче", "тысячей", "тысячам", "тысячами", "тысячах"] {
            table[word] = (1_000, .thousandMultiplier)
        }
        for word in ["миллион", "миллиона", "миллионов", "миллиону", "миллионом", "миллионе", "миллионам", "миллионами", "миллионах"] {
            table[word] = (1_000_000, .millionMultiplier)
        }

        return table
    }()

    /// Greedily parses as many leading words as form one valid cardinal
    /// number (e.g. ["две", "тысячи", "двадцать", "шесть"] -> 2026, consuming
    /// all 4). Returns nil if `words.first` isn't a recognized number word.
    /// Malformed continuations (e.g. a second hundred-word after one was
    /// already consumed) stop the run rather than erroring — the caller
    /// treats a shorter `consumedWordCount` as "that's as far as the number
    /// goes" and leaves the rest of the sentence untouched.
    static func parseCardinalRun(_ words: [String]) -> (value: Int, consumedWordCount: Int)? {
        guard let first = words.first, let firstEntry = numberWordValues[first] else { return nil }
        _ = firstEntry

        var total = 0
        var currentGroup = 0
        var consumed = 0
        var lastCategory: NumberWordCategory?

        wordLoop: for word in words {
            guard let entry = numberWordValues[word] else { break wordLoop }

            switch entry.category {
            case .unit, .teen:
                if lastCategory == .unit || lastCategory == .teen { break wordLoop }
                currentGroup += entry.value
            case .ten:
                if lastCategory == .ten || lastCategory == .unit || lastCategory == .teen { break wordLoop }
                currentGroup += entry.value
            case .hundred:
                if lastCategory == .hundred || lastCategory == .ten || lastCategory == .unit || lastCategory == .teen { break wordLoop }
                currentGroup += entry.value
            case .thousandMultiplier, .millionMultiplier:
                if lastCategory == .thousandMultiplier || lastCategory == .millionMultiplier { break wordLoop }
                let multiplier = entry.category == .thousandMultiplier ? 1_000 : 1_000_000
                let groupValue = currentGroup == 0 ? 1 : currentGroup
                total += groupValue * multiplier
                currentGroup = 0
                lastCategory = entry.category
                consumed += 1
                continue wordLoop
            }
            lastCategory = entry.category
            consumed += 1
        }

        let finalValue = total + currentGroup
        guard consumed > 0 else { return nil }
        return (finalValue, consumed)
    }

    static func normalize(_ text: String) -> String {
        let tokens = tokenize(text)
        var result = ""
        var index = 0

        while index < tokens.count {
            let token = tokens[index]
            if case .word(let word) = token, numberWordValues[word.lowercased()] != nil {
                let remainingWords: [String] = tokens[index...].compactMap {
                    if case .word(let w) = $0 { return w.lowercased() }
                    return nil
                }
                if let parsed = parseCardinalRun(remainingWords), isConfidentStandaloneNumber(tokens, at: index, consumedWordTokens: parsed.consumedWordCount) {
                    result += String(parsed.value)
                    index = advance(tokens, from: index, byWordTokenCount: parsed.consumedWordCount)
                    continue
                }
            }
            result += token.rawText
            index += 1
        }
        return result
    }

    /// Guards against converting a bare "one"/"два" that's actually being
    /// used as a pronoun/quantifier ("один из способов" = "one of the
    /// ways") rather than a dictated count. Conservative rule: a
    /// single-word match on `.unit` category is only converted if it's not
    /// immediately followed by "из"/"из-за" (the common "one of ..."
    /// construction); everything else (teens, tens, hundreds, multi-word
    /// runs) is always converted since those are unambiguous.
    private static func isConfidentStandaloneNumber(_ tokens: [Token], at index: Int, consumedWordTokens: Int) -> Bool {
        guard consumedWordTokens == 1,
              case .word(let word) = tokens[index],
              let entry = numberWordValues[word.lowercased()],
              entry.category == .unit else {
            return true
        }
        var lookahead = index + 1
        while lookahead < tokens.count, case .whitespace = tokens[lookahead] {
            lookahead += 1
        }
        guard lookahead < tokens.count, case .word(let next) = tokens[lookahead] else { return true }
        return !["из", "из-за"].contains(next.lowercased())
    }

    private static func advance(_ tokens: [Token], from index: Int, byWordTokenCount count: Int) -> Int {
        var remaining = count
        var cursor = index
        while cursor < tokens.count, remaining > 0 {
            if case .word = tokens[cursor] { remaining -= 1 }
            cursor += 1
        }
        return cursor
    }

    enum Token {
        case word(String)
        case whitespace(String)
        case punctuation(String)

        var rawText: String {
            switch self {
            case .word(let s), .whitespace(let s), .punctuation(let s): return s
            }
        }
    }

    static func tokenize(_ text: String) -> [Token] {
        var tokens: [Token] = []
        var current = ""
        var currentIsWord = false

        func flush() {
            guard !current.isEmpty else { return }
            tokens.append(currentIsWord ? .word(current) : .punctuation(current))
            current = ""
        }

        for character in text {
            if character.isWhitespace {
                flush()
                tokens.append(.whitespace(String(character)))
                continue
            }
            let isWordCharacter = character.isLetter || character == "-"
            if current.isEmpty {
                currentIsWord = isWordCharacter
            } else if isWordCharacter != currentIsWord {
                flush()
                currentIsWord = isWordCharacter
            }
            current.append(character)
        }
        flush()
        return tokens
    }
}
