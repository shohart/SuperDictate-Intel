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

    // (value, [(wordform, digitSuffix)]) — units 1-3 are irregular
    // stems; 4-10 follow the regular "cardinal-derived stem + ending"
    // pattern. Endings covered: -ый/-ой (masc nom), -ое (neut nom),
    // -ая (fem nom), -ого (masc/neut gen), -ому (dat), -ым (instr),
    // -ом (prep).
    static let ordinalWordSuffixes: [String: (value: Int, digitSuffix: String)] = {
        var table: [String: (value: Int, digitSuffix: String)] = [:]

        let entries: [(value: Int, forms: [(word: String, suffix: String)])] = [
            (1, [("первый", "-й"), ("первое", "-е"), ("первая", "-я"), ("первого", "-го"), ("первому", "-му"), ("первым", "-м"), ("первом", "-м")]),
            (2, [("второй", "-й"), ("второе", "-е"), ("вторая", "-я"), ("второго", "-го"), ("второму", "-му"), ("вторым", "-м"), ("втором", "-м")]),
            (3, [("третий", "-й"), ("третье", "-е"), ("третья", "-я"), ("третьего", "-го"), ("третьему", "-му"), ("третьим", "-м"), ("третьем", "-м")]),
            (4, [("четвёртый", "-й"), ("четвертый", "-й"), ("четвёртое", "-е"), ("четвертое", "-е"), ("четвёртая", "-я"), ("четвертая", "-я"), ("четвёртого", "-го"), ("четвертого", "-го"), ("четвёртому", "-му"), ("четвертому", "-му"), ("четвёртым", "-м"), ("четвертым", "-м"), ("четвёртом", "-м"), ("четвертом", "-м")]),
            (5, [("пятый", "-й"), ("пятое", "-е"), ("пятая", "-я"), ("пятого", "-го"), ("пятому", "-му"), ("пятым", "-м"), ("пятом", "-м")]),
            (6, [("шестой", "-й"), ("шестое", "-е"), ("шестая", "-я"), ("шестого", "-го"), ("шестому", "-му"), ("шестым", "-м"), ("шестом", "-м")]),
            (7, [("седьмой", "-й"), ("седьмое", "-е"), ("седьмая", "-я"), ("седьмого", "-го"), ("седьмому", "-му"), ("седьмым", "-м"), ("седьмом", "-м")]),
            (8, [("восьмой", "-й"), ("восьмое", "-е"), ("восьмая", "-я"), ("восьмого", "-го"), ("восьмому", "-му"), ("восьмым", "-м"), ("восьмом", "-м")]),
            (9, [("девятый", "-й"), ("девятое", "-е"), ("девятая", "-я"), ("девятого", "-го"), ("девятому", "-му"), ("девятым", "-м"), ("девятом", "-м")]),
            (10, [("десятый", "-й"), ("десятое", "-е"), ("десятая", "-я"), ("десятого", "-го"), ("десятому", "-му"), ("десятым", "-м"), ("десятом", "-м")]),
            (11, [("одиннадцатый", "-й"), ("одиннадцатое", "-е"), ("одиннадцатая", "-я"), ("одиннадцатого", "-го"), ("одиннадцатому", "-му"), ("одиннадцатым", "-м"), ("одиннадцатом", "-м")]),
            (12, [("двенадцатый", "-й"), ("двенадцатое", "-е"), ("двенадцатая", "-я"), ("двенадцатого", "-го"), ("двенадцатому", "-му"), ("двенадцатым", "-м"), ("двенадцатом", "-м")]),
            (13, [("тринадцатый", "-й"), ("тринадцатое", "-е"), ("тринадцатая", "-я"), ("тринадцатого", "-го"), ("тринадцатому", "-му"), ("тринадцатым", "-м"), ("тринадцатом", "-м")]),
            (14, [("четырнадцатый", "-й"), ("четырнадцатое", "-е"), ("четырнадцатая", "-я"), ("четырнадцатого", "-го"), ("четырнадцатому", "-му"), ("четырнадцатым", "-м"), ("четырнадцатом", "-м")]),
            (15, [("пятнадцатый", "-й"), ("пятнадцатое", "-е"), ("пятнадцатая", "-я"), ("пятнадцатого", "-го"), ("пятнадцатому", "-му"), ("пятнадцатым", "-м"), ("пятнадцатом", "-м")]),
            (16, [("шестнадцатый", "-й"), ("шестнадцатое", "-е"), ("шестнадцатая", "-я"), ("шестнадцатого", "-го"), ("шестнадцатому", "-му"), ("шестнадцатым", "-м"), ("шестнадцатом", "-м")]),
            (17, [("семнадцатый", "-й"), ("семнадцатое", "-е"), ("семнадцатая", "-я"), ("семнадцатого", "-го"), ("семнадцатому", "-му"), ("семнадцатым", "-м"), ("семнадцатом", "-м")]),
            (18, [("восемнадцатый", "-й"), ("восемнадцатое", "-е"), ("восемнадцатая", "-я"), ("восемнадцатого", "-го"), ("восемнадцатому", "-му"), ("восемнадцатым", "-м"), ("восемнадцатом", "-м")]),
            (19, [("девятнадцатый", "-й"), ("девятнадцатое", "-е"), ("девятнадцатая", "-я"), ("девятнадцатого", "-го"), ("девятнадцатому", "-му"), ("девятнадцатым", "-м"), ("девятнадцатом", "-м")]),
            (20, [("двадцатый", "-й"), ("двадцатое", "-е"), ("двадцатая", "-я"), ("двадцатого", "-го"), ("двадцатому", "-му"), ("двадцатым", "-м"), ("двадцатом", "-м")]),
            (30, [("тридцатый", "-й"), ("тридцатое", "-е"), ("тридцатая", "-я"), ("тридцатого", "-го"), ("тридцатому", "-му"), ("тридцатым", "-м"), ("тридцатом", "-м")]),
            // 40 is the one irregular stem in this run: "сороковой", not
            // "сорок(ов)ый" — nominative masc ends -ой like второй/шестой,
            // not -ый.
            (40, [("сороковой", "-й"), ("сороковое", "-е"), ("сороковая", "-я"), ("сорокового", "-го"), ("сороковому", "-му"), ("сороковым", "-м"), ("сороковом", "-м")]),
            (50, [("пятидесятый", "-й"), ("пятидесятое", "-е"), ("пятидесятая", "-я"), ("пятидесятого", "-го"), ("пятидесятому", "-му"), ("пятидесятым", "-м"), ("пятидесятом", "-м")]),
            (60, [("шестидесятый", "-й"), ("шестидесятое", "-е"), ("шестидесятая", "-я"), ("шестидесятого", "-го"), ("шестидесятому", "-му"), ("шестидесятым", "-м"), ("шестидесятом", "-м")]),
            (70, [("семидесятый", "-й"), ("семидесятое", "-е"), ("семидесятая", "-я"), ("семидесятого", "-го"), ("семидесятому", "-му"), ("семидесятым", "-м"), ("семидесятом", "-м")]),
            (80, [("восьмидесятый", "-й"), ("восьмидесятое", "-е"), ("восьмидесятая", "-я"), ("восьмидесятого", "-го"), ("восьмидесятому", "-му"), ("восьмидесятым", "-м"), ("восьмидесятом", "-м")]),
            (90, [("девяностый", "-й"), ("девяностое", "-е"), ("девяностая", "-я"), ("девяностого", "-го"), ("девяностому", "-му"), ("девяностым", "-м"), ("девяностом", "-м")]),
            (100, [("сотый", "-й"), ("сотое", "-е"), ("сотая", "-я"), ("сотого", "-го"), ("сотому", "-му"), ("сотым", "-м"), ("сотом", "-м")]),
        ]
        for entry in entries {
            for form in entry.forms {
                table[form.word] = (entry.value, form.suffix)
            }
        }
        return table
    }()

    /// Reuses `parseCardinalRun` for every word except the last (compound
    /// Russian ordinals only inflect their final word — "двадцать пятый",
    /// not "двадцатый пятый") and matches the last word against
    /// `ordinalWordSuffixes`.
    static func parseOrdinalRun(_ words: [String]) -> (value: Int, digitSuffix: String, consumedWordCount: Int)? {
        guard !words.isEmpty else { return nil }

        // Find the longest prefix (all but a trailing ordinal word) that
        // parses as a cardinal run, then require the very next word to be
        // a recognized ordinal wordform. Try shrinking the prefix from the
        // full remaining span down to zero so "двадцать пятый" (prefix
        // "двадцать" + ordinal "пятый") and "пятый" alone (empty prefix)
        // both work.
        var prefixLength = words.count - 1
        while prefixLength >= 0 {
            let prefixWords = Array(words[0..<prefixLength])
            let prefixValue: Int
            if prefixWords.isEmpty {
                prefixValue = 0
            } else if let parsed = parseCardinalRun(prefixWords), parsed.consumedWordCount == prefixWords.count {
                prefixValue = parsed.value
            } else {
                prefixLength -= 1
                continue
            }

            guard prefixLength < words.count, let ordinalEntry = ordinalWordSuffixes[words[prefixLength]] else {
                prefixLength -= 1
                continue
            }
            return (prefixValue + ordinalEntry.value, ordinalEntry.digitSuffix, prefixLength + 1)
        }
        return nil
    }

    static func normalize(_ text: String) -> String {
        let tokens = tokenize(text)
        var result = ""
        var index = 0

        while index < tokens.count {
            let token = tokens[index]
            if case .word(let word) = token,
               (numberWordValues[word.lowercased()] != nil || ordinalWordSuffixes[word.lowercased()] != nil) {
                let remainingWords: [String] = tokens[index...].compactMap {
                    if case .word(let w) = $0 { return w.lowercased() }
                    return nil
                }
                if let ordinal = parseOrdinalRun(remainingWords) {
                    result += "\(ordinal.value)\(ordinal.digitSuffix)"
                    index = advance(tokens, from: index, byWordTokenCount: ordinal.consumedWordCount)
                    continue
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
