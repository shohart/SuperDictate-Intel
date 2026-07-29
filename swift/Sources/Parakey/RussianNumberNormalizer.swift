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
        let state = cardinalRunState(words)
        guard state.consumedWordCount > 0 else { return nil }
        return (state.value, state.consumedWordCount)
    }

    /// True when a word of `category`, appearing right after a run that
    /// last consumed a word of `lastCategory`, would be an illegal/
    /// malformed continuation of the SAME number (e.g. two unit-level
    /// words in a row: "пять шесть" is two separate numbers, not one).
    /// Shared between `cardinalRunState` (deciding when to stop a cardinal
    /// run) and `parseOrdinalRun` (deciding whether a trailing ordinal word
    /// genuinely completes the preceding cardinal run, or is an unrelated,
    /// independent number that happens to follow it — see that function's
    /// doc comment for why this check exists).
    private static func blocksContinuation(category: NumberWordCategory, after lastCategory: NumberWordCategory?) -> Bool {
        switch category {
        case .unit, .teen:
            return lastCategory == .unit || lastCategory == .teen
        case .ten:
            return lastCategory == .ten || lastCategory == .unit || lastCategory == .teen
        case .hundred:
            return lastCategory == .hundred || lastCategory == .ten || lastCategory == .unit || lastCategory == .teen
        case .thousandMultiplier, .millionMultiplier:
            return lastCategory == .thousandMultiplier || lastCategory == .millionMultiplier
        }
    }

    /// The full state behind `parseCardinalRun`'s greedy scan, additionally
    /// exposing the category of the last word consumed. `parseOrdinalRun`
    /// needs that category to check whether a trailing ordinal word is a
    /// legal continuation of this exact run, not just "any recognized
    /// ordinal wordform" — see its doc comment.
    private static func cardinalRunState(_ words: [String]) -> (value: Int, consumedWordCount: Int, lastCategory: NumberWordCategory?) {
        var total = 0
        var currentGroup = 0
        var consumed = 0
        var lastCategory: NumberWordCategory?

        wordLoop: for word in words {
            guard let entry = numberWordValues[word] else { break wordLoop }
            if blocksContinuation(category: entry.category, after: lastCategory) { break wordLoop }

            switch entry.category {
            case .unit, .teen, .ten, .hundred:
                currentGroup += entry.value
            case .thousandMultiplier, .millionMultiplier:
                let multiplier = entry.category == .thousandMultiplier ? 1_000 : 1_000_000
                let groupValue = currentGroup == 0 ? 1 : currentGroup
                total += groupValue * multiplier
                currentGroup = 0
            }
            lastCategory = entry.category
            consumed += 1
        }

        return (total + currentGroup, consumed, lastCategory)
    }

    // (value, [(wordform, digitSuffix)]) — units 1-3 are irregular
    // stems; 4-10 follow the regular "cardinal-derived stem + ending"
    // pattern. Endings covered: -ый/-ой (masc nom), -ое (neut nom),
    // -ая (fem nom), -ого (masc/neut gen), -ому (dat), -ым (instr),
    // -ом (prep).
    //
    // Known gap: stops at 100 ("сотый"). Ordinal hundreds beyond that
    // (двухсотый/трёхсотый/... for 200/300/.../900, тысячный for 1000)
    // aren't in this table, so e.g. "двухтысячного года" (year 2000)
    // falls through normalize(_:) unconverted — safe (never produces a
    // wrong digit), just an incomplete date-year range for now.
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

    /// Maps an ordinal's numeric value to the `NumberWordCategory` its
    /// cardinal counterpart would have (1-9 -> unit, 10-19 -> teen, the
    /// tens 20/30/.../90 -> ten, 100 -> hundred). Used only to decide
    /// whether a trailing ordinal word legally continues a preceding
    /// cardinal run — see `parseOrdinalRun`.
    private static func category(forOrdinalValue value: Int) -> NumberWordCategory {
        switch value {
        case 100: return .hundred
        case 10...19: return .teen
        case 20, 30, 40, 50, 60, 70, 80, 90: return .ten
        default: return .unit
        }
    }

    /// Reuses `parseCardinalRun`'s scan for every word except the last
    /// (compound Russian ordinals only inflect their final word —
    /// "двадцать пятый", not "двадцатый пятый") and matches the word right
    /// after that run against `ordinalWordSuffixes`.
    ///
    /// Critically, the cardinal run is taken as its OWN maximal greedy
    /// parse (not tried at every shrinking prefix length), and the
    /// trailing ordinal word is only merged into it when the ordinal's
    /// category would have been a legal continuation of that same run
    /// (via `blocksContinuation`) — the identical rule `cardinalRunState`
    /// already uses to stop a cardinal run at a duplicate/conflicting
    /// category. Without that check, "сто двадцать пять первого" ("one
    /// hundred twenty-five" — a complete number whose units slot is
    /// already filled by "пять" — followed by the unrelated "первого",
    /// e.g. "the first [item]") would wrongly fuse into "126-го": the
    /// maximal cardinal prefix "сто двадцать пять" (125) is immediately
    /// followed by a recognized ordinal wordform, but "первого" is a
    /// unit-level ordinal and the run's last word ("пять") was ALSO
    /// unit-level — the same conflict that already stops two adjacent
    /// cardinal unit words ("пять шесть") from merging. Legitimate compound
    /// ordinals never hit this: "двадцать пятый" ends its cardinal run at
    /// ten-level ("двадцать"), and the trailing unit-level ordinal
    /// ("пятый") fills the still-open units slot, exactly like "двадцать
    /// пять" would as a plain cardinal.
    static func parseOrdinalRun(_ words: [String]) -> (value: Int, digitSuffix: String, consumedWordCount: Int)? {
        guard !words.isEmpty else { return nil }

        let prefix = cardinalRunState(words)
        let boundary = prefix.consumedWordCount

        guard boundary < words.count, let ordinalEntry = ordinalWordSuffixes[words[boundary]] else {
            return nil
        }

        let ordinalCategory = category(forOrdinalValue: ordinalEntry.value)
        guard !blocksContinuation(category: ordinalCategory, after: prefix.lastCategory) else {
            return nil
        }

        return (prefix.value + ordinalEntry.value, ordinalEntry.digitSuffix, boundary + 1)
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
