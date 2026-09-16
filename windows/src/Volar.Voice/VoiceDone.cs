// src/Volar.Voice/VoiceDone.cs — voice-done matcher (Phase 5, feature 002:
// specs/002-workflow-command-center/contracts/phase5-contract.md §A). Port of macOS
// `Volar/Sources/Speech/VoiceDone.swift` (post-review, merge commit `4fa783d` on `window`).
//
// OWNERSHIP: this file owns `VoiceDoneIntent` (+ its three cases) / `VoiceMatch` / `VoiceDoneTask`
// / `VoiceDone` — the frozen seam Wave 3-C's App-wiring codes against (mirrors the Swift header's
// note that AppState.swift/PopoverView.swift code against these exact types). Do not redefine
// these types elsewhere.
//
// Classifies a spoken utterance as a COMPLETION ("xong", "done", "làm xong", "hoàn thành" — the
// SPEAKER's own task is done), a CLEAR-EXTERNAL ("client đã ký", "anh Nam gửi rồi" — an external
// party finished their part of a task's `.external` wait-condition), or neither (falls through to
// normal new-task capture, Phase 3).
//
// Assistive, never authoritative (constitution II — "Never Silently Guess"): this type NEVER
// completes or clears anything itself; it only proposes scored candidates. The caller always
// confirms with the user before mutating a task. A single weak match is never collapsed into an
// auto-completion here (see `SelectCandidates` below) — only an unambiguous, high-confidence,
// UNIQUE match ever shrinks to a one-item list; every other outcome returns either every
// above-floor candidate (so the caller disambiguates) or an explicit empty list (so the caller
// states "no matching task" instead of guessing).
//
// Vietnamese + English, on-device, pure (constitution I/III): no network, no disk, no clock reads
// — output depends solely on `transcript` and `openTasks`, and is deterministic (stable ordering:
// score descending, then phrase-match, then match-ratio, then `taskId` ascending). Reuses the
// diacritic+case-fold / "đ/Đ" special-case tokenization convention established by
// `Volar.Core.ConflictCheck` (`NormalizedTitleTokens`, itself a port of `Model/NLParser.swift` and
// `VolarCore/ConflictCheck.swift`) rather than inventing a new scheme. Tokenization is
// re-implemented here (not called into `Volar.Core`) because the Swift original does the same —
// `VoiceDone.swift`'s `normalizedTokens` is its own private copy, not a call into
// `ConflictCheck.normalizedTitleTokens` — and because this project must stay free of any
// dependency the App-wiring layer doesn't already need for this seam.
//
// SCORING (containment, weighted by IDF over the current open-task corpus — replaces an earlier
// Jaccard/token-set formula): a short, vắn tắt utterance ("xong vụ hợp đồng rồi") should still find
// a task whose title says a lot more ("gọi cho anh Hùng về hợp đồng thuê văn phòng") — Jaccard
// penalizes the title's extra words, containment does not. See `ScoreCandidate` / `QueryContext`
// below for the coverage formula and its one-tap safety gate (`DistinctiveIdf`), and
// `ScoreAgainstText` for the exact-phrase-containment shortcut that runs before it.
//
// Deliberately wide at the candidate tier, narrow only at one-tap: the candidate list exists so
// the USER picks, not so the machine decides — recall matters more than precision below
// `HighConfidenceThreshold`, and precision matters a lot right at/above it (see `DistinctiveIdf`'s
// one-tap guard, the only score-suppressing gate left after an earlier absolute-evidence-floor gate
// was found to be deleting legitimate candidates and was removed).
//
// TWO CORPORA, not one: `ScoredTitleCandidates` scores against a corpus built from every open
// task's TITLE tokens; `ScoredExternalCandidates` scores against a separate corpus built from every
// open task's EXTERNAL-DESCRIPTION tokens (see `BuildDocumentFrequency` /
// `BuildExternalDocumentFrequency`). An earlier single-corpus design (title-only, reused for both
// branches) silently zeroed out almost every clear-external query, because
// external-description-only vocabulary by definition never appears in any title.
//
// TWO POLICIES for a `df == 0` token (present in NO open task), one per use, DELIBERATELY
// different — see `BuildQueryContext`:
//   - SCORING: kept. `df == 0` is itself the strongest possible evidence that the utterance is
//     about something else ("viết BÁO CÁO xong rồi" against the only open task "Viết email" — "báo"
//     and "cáo" appear nowhere in the corpus at all), so throwing it away throws away exactly the
//     signal needed to correctly NOT match. It gets the max possible idf (`ln(1 + N)`, same formula
//     as any other token, `df` just happens to be 0) and sits in the coverage denominator only — it
//     can never appear in a numerator because, by construction, nothing in the corpus contains it.
//     An earlier design dropped these tokens from scoring entirely, which is what let "viết báo cáo
//     xong rồi" wrongly one-tap-match "Viết email" on the shared generic verb alone.
//   - PHRASE-MATCH NEEDLE: still filtered out. This shortcut is a precision-favoring heuristic (see
//     `ScoreAgainstText`), and a filler word like "cái"/"vụ" breaking an otherwise-verbatim phrase
//     hit is a false negative worth avoiding — do NOT "clean up" the two policies to match each
//     other; they are intentionally asymmetric for opposite reasons (recall for scoring, precision
//     for the phrase needle).
//
// // UNVERIFIED (carried over from the Swift): the Swift original notes it was authored without a
// macOS toolchain and needed a real `swift test` pass before merge; the .NET port carries an
// analogous risk in the opposite direction — .NET's NFD-decomposition diacritic fold (see
// `NormalizedTokens` below) has not been exercised against real Vietnamese ASR output from
// WhisperKit/Groq/whisper.net on Windows. Both platforms fold diacritics for matching purposes,
// but via different mechanisms (ICU `folding(options:locale:)` on Swift vs
// `NormalizationForm.FormD` + stripping `NonSpacingMark` codepoints here), so edge-case Unicode
// input (rare combining sequences, precomposed vs decomposed forms in Whisper's own output) could
// in principle fold differently on the two platforms. Verify with real captured transcripts once
// Wave 3-C wires a live ASR engine in front of this classifier.
//
// CONCURRENCY: there is no C# equivalent of Swift's actor-isolation concern (the Swift header's
// long comment about why the type is deliberately NOT `@MainActor`), but the underlying property
// still holds and is worth stating: `VoiceDone` has no instance state — it is a static class over
// pure functions and `static readonly` data — so it is safe to call from any thread, including a
// UI thread, without synchronization.

using System.Globalization;
using System.Text;

namespace Volar.Voice;

/// <summary>
/// Result of classifying a transcript against the user's current open tasks. Modeled as a closed
/// discriminated union (an <see langword="abstract record"/> with exactly three
/// <see langword="sealed"/> subtypes, mirroring Swift's <c>enum VoiceDoneIntent: Sendable,
/// Equatable</c> with associated values and <see cref="Volar.Core.Condition"/>'s own C# hierarchy
/// convention), matched exhaustively via a <see langword="switch"/> expression rather than a
/// Swift-style <see langword="switch"/> statement over an enum.
/// </summary>
public abstract record VoiceDoneIntent
{
    // `private protected` constructor: only the three sealed subtypes declared in this file may
    // derive from VoiceDoneIntent, keeping the union effectively closed, mirroring
    // Volar.Core.Condition.
    private protected VoiceDoneIntent() { }
}

/// <summary>
/// A "xong/done" phrase was detected. <see cref="Candidates"/> may be empty — that specifically
/// means the phrase was clearly present but nothing in <c>openTasks</c> matched, so the caller
/// states "no matching task" rather than guessing (constitution II), never falling silently back
/// to <see cref="NotACompletionIntent"/>.
/// </summary>
public sealed record CompleteIntent(IReadOnlyList<VoiceMatch> Candidates) : VoiceDoneIntent;

/// <summary>
/// A "client đã ký" / "anh Nam gửi rồi" style external-condition phrase was detected. Same
/// empty-candidates convention as <see cref="CompleteIntent"/>.
/// </summary>
public sealed record ClearExternalIntent(IReadOnlyList<VoiceMatch> Candidates) : VoiceDoneIntent;

/// <summary>
/// No completion/clear-external phrase detected at all — falls through to normal new-task capture
/// (Phase 3).
/// </summary>
public sealed record NotACompletionIntent : VoiceDoneIntent;

/// <summary>
/// One scored match against an open task. <see cref="Score"/> is in <c>[0, 1]</c>: an IDF-weighted
/// containment coverage of the utterance (cue words stripped) by either the task's title
/// (<see cref="CompleteIntent"/>) or one of its external descriptions
/// (<see cref="ClearExternalIntent"/>) — see <c>VoiceDone.ScoreCandidate</c> — floored up to at
/// least <c>HighConfidenceThreshold</c> when the utterance appears verbatim as a contiguous phrase
/// inside the title/description (see <c>VoiceDone.ScoreAgainstText</c>).
/// </summary>
public sealed record VoiceMatch(Guid TaskId, string Title, double Score);

/// <summary>
/// The minimal shape <see cref="VoiceDone"/> needs from an open/in-progress task: id + title for
/// <see cref="CompleteIntent"/> matching, plus each currently-unsatisfied <c>.external</c>
/// condition's description text for <see cref="ClearExternalIntent"/> matching.
/// </summary>
public sealed record VoiceDoneTask(Guid Id, string Title, IReadOnlyList<string> ExternalDescriptions);

/// <summary>
/// Vietnamese+English aware voice-done matcher. Pure, stateless, deterministic — see file header.
/// <see cref="Classify"/> is the whole public surface.
/// </summary>
public static class VoiceDone
{
    // MARK: - Tuning constants

    /// <summary>
    /// A single candidate at/above this score is confident enough to collapse the result to a
    /// one-item list (the caller offers a one-tap/one-word confirm). Matches the contract's "~0.8"
    /// high bar.
    /// </summary>
    private const double HighConfidenceThreshold = 0.8;

    /// <summary>
    /// Floor below which a candidate is noise and never surfaced at all. Matches the contract's
    /// "~0.5" disambiguation floor.
    /// </summary>
    private const double CandidateFloor = 0.5;

    /// <summary>
    /// Margin subtracted from <see cref="HighConfidenceThreshold"/> when a candidate's raw coverage
    /// clears the one-tap bar on the strength of a single non-distinctive token (see
    /// <see cref="ScoreCandidate"/>'s one-tap guard). The clamp intentionally keeps the candidate
    /// well above <see cref="CandidateFloor"/> — it was a real match, just not a safely-unique
    /// one — while unambiguously placing it below <see cref="HighConfidenceThreshold"/> so it never
    /// collapses to a false one-tap confirm.
    /// </summary>
    private const double HighConfidenceGuardMargin = 0.01;

    /// <summary>
    /// Defensive bound on how much of the transcript is tokenized/matched — protects against
    /// adversarial/pathological input (megabyte-scale paste from a runaway ASR feed) doing
    /// unbounded work. Mirrors <c>HeuristicNLParser.maxWorkingLength</c>'s role in
    /// <c>NLParser.swift</c>.
    /// </summary>
    private const int MaxWorkingLength = 4_000;

    /// <summary>
    /// Bounds tokenization cost per string (transcript or a title/external-description), mirroring
    /// <c>ConflictCheck.maxTokensForMatching</c>.
    /// </summary>
    private const int MaxTokens = 64;

    /// <summary>
    /// Bounds per-task <c>ExternalDescriptions</c> scanning so a pathologically long list on one
    /// task snapshot can't blow up matching cost.
    /// </summary>
    private const int MaxExternalDescriptionsPerTask = 20;

    /// <summary>
    /// Bounds an individual external-description string before tokenizing, mirroring
    /// <c>ConflictCheck.maxTitleCharsForMatching</c>'s role for titles.
    /// </summary>
    private const int MaxExternalDescriptionChars = 500;

    // MARK: - Cue phrases

    /// <summary>
    /// Phrases indicating the SPEAKER's own task is complete, expressed as their normalized
    /// (folded) token sequences so detection is token-exact rather than raw substring
    /// <c>Contains</c> (substring matching on short cues like "done"/"sent" false-positives inside
    /// unrelated English words — e.g. "abandoned" contains "done", "presentation" contains "sent"
    /// — so this keeps that class of false positive out). Data, not logic: ported verbatim,
    /// same order as the Swift table.
    /// </summary>
    private static readonly IReadOnlyList<IReadOnlyList<string>> CompletionCuePhrases =
        new string[]
        {
            "làm xong", "đã xong", "xong rồi", "hoàn thành", "hoàn tất",
            "xong", "finished", "done", "completed", "complete"
        }
        .Select(NormalizedTokens)
        .Cast<IReadOnlyList<string>>()
        .ToArray();

    /// <summary>
    /// Phrases indicating an EXTERNAL party finished their part (clears a <c>.external</c>
    /// condition) rather than the speaker's own task, same token-sequence convention as above.
    /// Ported verbatim, same order as the Swift table.
    /// </summary>
    private static readonly IReadOnlyList<IReadOnlyList<string>> ExternalCuePhrases =
        new string[]
        {
            "đã ký", "ký rồi", "đã gửi", "gửi rồi", "đã trả lời", "trả lời rồi",
            "signed", "sent", "replied", "responded", "answered"
        }
        .Select(NormalizedTokens)
        .Cast<IReadOnlyList<string>>()
        .ToArray();

    /// <summary>
    /// Flattened set of every token appearing in any cue phrase above. Stripped out of the
    /// transcript's token set before matching against titles/external-descriptions so cue
    /// words ("xong", "rồi", "đã"...) never dilute or pollute the coverage score.
    /// </summary>
    private static readonly IReadOnlySet<string> CueStripTokens = BuildCueStripTokens();

    private static HashSet<string> BuildCueStripTokens()
    {
        var tokens = new HashSet<string>(StringComparer.Ordinal);
        foreach (var phrase in CompletionCuePhrases)
        {
            tokens.UnionWith(phrase);
        }
        foreach (var phrase in ExternalCuePhrases)
        {
            tokens.UnionWith(phrase);
        }
        return tokens;
    }

    // MARK: - Classification

    /// <summary>
    /// Classifies <paramref name="transcript"/> against <paramref name="openTasks"/>. Pure and
    /// synchronous: no I/O, no logging, no clock reads. See the type's file header for the
    /// completion-vs-clear-external-vs-neither decision and the confirm-vs-disambiguate rule.
    /// </summary>
    public static VoiceDoneIntent Classify(string transcript, IReadOnlyList<VoiceDoneTask> openTasks)
    {
        var bounded = transcript.Length > MaxWorkingLength ? transcript[..MaxWorkingLength] : transcript;
        if (string.IsNullOrWhiteSpace(bounded))
        {
            return new NotACompletionIntent();
        }

        var transcriptTokens = NormalizedTokens(bounded);

        var hasExternalCue = ExternalCuePhrases.Any(phrase => ContainsCuePhrase(phrase, transcriptTokens));
        var hasCompletionCue = CompletionCuePhrases.Any(phrase => ContainsCuePhrase(phrase, transcriptTokens));

        // No recognizable done/clear-external phrase at all -> not our concern, let the normal
        // new-task capture flow handle it (Phase 3).
        if (!hasExternalCue && !hasCompletionCue)
        {
            return new NotACompletionIntent();
        }

        // A compound utterance naming both an external verb ("ký"/"gửi"/"trả lời") and a bare
        // completion word ("xong") is classified as clear-external — the external verb is the
        // more specific signal (a bare "xong" is ambiguous between "my task is done" and "the
        // external thing is done", per the contract's own "X đã xong/gửi/trả lời" example
        // grouping "xong" alongside "gửi"/"trả lời" under clear-external).
        //
        // Order-preserving (a List, not a HashSet): scoring needs both an unordered token view
        // (for containment/IDF membership tests) and an ordered, space-joined phrase (for the
        // exact-phrase-containment shortcut) — see BuildQueryContext.
        var referenceTokens = transcriptTokens.Where(token => !CueStripTokens.Contains(token)).ToList();

        // IDF corpus: title-matching and external-description-matching use SEPARATE corpora (built
        // only for the branch actually being scored) — see the file header's "TWO CORPORA" note for
        // why a single shared corpus silently broke clear-external matching.
        var corpusSize = openTasks.Count;

        if (hasExternalCue)
        {
            var documentFrequency = BuildExternalDocumentFrequency(openTasks);
            var query = BuildQueryContext(referenceTokens, documentFrequency, corpusSize);
            var candidates = ScoredExternalCandidates(query, openTasks, documentFrequency, corpusSize);
            return new ClearExternalIntent(SelectCandidates(candidates));
        }
        else
        {
            var documentFrequency = BuildDocumentFrequency(openTasks);
            var query = BuildQueryContext(referenceTokens, documentFrequency, corpusSize);
            var candidates = ScoredTitleCandidates(query, openTasks, documentFrequency, corpusSize);
            return new CompleteIntent(SelectCandidates(candidates));
        }
    }

    /// <summary>
    /// True when <paramref name="phraseTokens"/> appears as a contiguous run inside
    /// <paramref name="tokens"/> (subsequence-of-length-<c>phraseTokens.Count</c> equality check).
    /// Cue phrase lists are short (~10 entries) and <paramref name="tokens"/> is bounded by
    /// <see cref="MaxTokens"/>, so the worst case is a small, fixed amount of work — no
    /// catastrophic-regex-style blowup.
    /// </summary>
    private static bool ContainsCuePhrase(IReadOnlyList<string> phraseTokens, IReadOnlyList<string> tokens)
    {
        if (phraseTokens.Count == 0 || phraseTokens.Count > tokens.Count)
        {
            return false;
        }
        if (phraseTokens.Count == 1)
        {
            return tokens.Contains(phraseTokens[0]);
        }
        for (var start = 0; start <= tokens.Count - phraseTokens.Count; start++)
        {
            var matches = true;
            for (var offset = 0; offset < phraseTokens.Count; offset++)
            {
                if (tokens[start + offset] != phraseTokens[offset])
                {
                    matches = false;
                    break;
                }
            }
            if (matches)
            {
                return true;
            }
        }
        return false;
    }

    // MARK: - Candidate scoring

    /// <summary>
    /// Internal, richer sibling of the public <see cref="VoiceMatch"/>: carries the extra ranking
    /// signals (<see cref="IsPhraseMatch"/>, <see cref="MatchRatio"/>) <see cref="SelectCandidates"/>
    /// needs for its tie-break rule, which the frozen public seam does not expose. Projected down to
    /// <see cref="VoiceMatch"/> only at the very end of <see cref="SelectCandidates"/>.
    /// </summary>
    private readonly record struct ScoredCandidate(
        Guid TaskId, string Title, double Score, double MatchRatio, bool IsPhraseMatch);

    /// <summary>
    /// Scores every open task's title against <paramref name="query"/> (the utterance with cue
    /// words stripped), keeping only tasks at/above <see cref="CandidateFloor"/>. An empty
    /// <see cref="QueryContext.Tokens"/> — the whole utterance WAS the cue phrase, like a bare
    /// "xong" — always yields no candidates, the "done-phrase present but nothing matched" case the
    /// contract requires to surface as empty candidates rather than a guess. An utterance whose
    /// every word is unknown to the corpus (<c>df == 0</c>) reaches the same outcome one step
    /// later, at coverage 0, rather than short-circuiting here: since anh Khôi's 2026-08-11 call
    /// those tokens are kept for scoring, so they are no longer filtered out of
    /// <see cref="QueryContext.Tokens"/> (see <see cref="BuildQueryContext"/>).
    /// </summary>
    private static List<ScoredCandidate> ScoredTitleCandidates(
        QueryContext query,
        IReadOnlyList<VoiceDoneTask> openTasks,
        IReadOnlyDictionary<string, int> documentFrequency,
        int corpusSize)
    {
        var results = new List<ScoredCandidate>();
        if (query.Tokens.Count == 0)
        {
            return results;
        }
        foreach (var task in openTasks)
        {
            var (score, ratio, isPhraseMatch) =
                ScoreAgainstText(task.Title, query, documentFrequency, corpusSize);
            if (score < CandidateFloor)
            {
                continue;
            }
            results.Add(new ScoredCandidate(task.Id, task.Title, score, ratio, isPhraseMatch));
        }
        return results;
    }

    /// <summary>
    /// Scores every open task's <c>ExternalDescriptions</c> against <paramref name="query"/>,
    /// taking each task's BEST-matching description (by final, post-phrase-match-boost score) as
    /// that task's candidate (a task is a single candidate for disambiguation purposes even if it
    /// has several unsatisfied external conditions).
    /// </summary>
    private static List<ScoredCandidate> ScoredExternalCandidates(
        QueryContext query,
        IReadOnlyList<VoiceDoneTask> openTasks,
        IReadOnlyDictionary<string, int> documentFrequency,
        int corpusSize)
    {
        var results = new List<ScoredCandidate>();
        if (query.Tokens.Count == 0)
        {
            return results;
        }
        foreach (var task in openTasks)
        {
            var bestScore = 0.0;
            var bestRatio = 0.0;
            var bestIsPhraseMatch = false;
            foreach (var description in task.ExternalDescriptions.Take(MaxExternalDescriptionsPerTask))
            {
                var bounded = description.Length > MaxExternalDescriptionChars
                    ? description[..MaxExternalDescriptionChars]
                    : description;
                var (score, ratio, isPhraseMatch) =
                    ScoreAgainstText(bounded, query, documentFrequency, corpusSize);
                if (score > bestScore)
                {
                    bestScore = score;
                    bestRatio = ratio;
                    bestIsPhraseMatch = isPhraseMatch;
                }
            }
            if (bestScore < CandidateFloor)
            {
                continue;
            }
            results.Add(new ScoredCandidate(task.Id, task.Title, bestScore, bestRatio, bestIsPhraseMatch));
        }
        return results;
    }

    /// <summary>
    /// Applies the confirm-vs-disambiguate threshold rule (phase5-contract.md §A / constitution
    /// II): a SINGLE candidate at/above <see cref="HighConfidenceThreshold"/> is confident and
    /// unambiguous enough to collapse to a one-item list (the caller offers a one-tap/one-word
    /// confirm). Anything else — zero high-confidence candidates, OR two-or-more tied at high
    /// confidence — returns every candidate at/above the floor so the caller disambiguates instead
    /// of guessing. Stable ordering: score descending; then exact-phrase-match candidates before
    /// non-phrase-match candidates (a literal contiguous phrase hit is stronger evidence than a
    /// same-scoring fuzzy/token hit — added per the exact-phrase-containment shortcut); then by
    /// <see cref="ScoredCandidate.MatchRatio"/> descending (a title with less unmatched filler is a
    /// tighter match); then <c>taskId</c> string ascending (mirrors <c>ConflictChecker</c>'s
    /// id-ordinal tiebreak), so output is deterministic for identical input regardless of
    /// <c>openTasks</c>' original order.
    /// </summary>
    private static IReadOnlyList<VoiceMatch> SelectCandidates(List<ScoredCandidate> candidates)
    {
        if (candidates.Count == 0)
        {
            return [];
        }
        var sorted = candidates
            .OrderByDescending(match => match.Score)
            .ThenByDescending(match => match.IsPhraseMatch)
            .ThenByDescending(match => match.MatchRatio)
            .ThenBy(match => match.TaskId.ToString(), StringComparer.Ordinal)
            .ToList();
        var highConfidence = sorted.Where(match => match.Score >= HighConfidenceThreshold).ToList();
        var winners = highConfidence.Count == 1 ? highConfidence : sorted;
        return winners.Select(match => new VoiceMatch(match.TaskId, match.Title, match.Score)).ToList();
    }

    // MARK: - Normalization (same convention as ConflictCheck.NormalizedTitleTokens)

    /// <summary>
    /// Diacritic- and case-fold (so "Đã xong" and "da xong" tokenize identically), then split on
    /// any non-letter/non-digit boundary. Bounded on both input length and token count so
    /// adversarially huge input cannot make this (or any O(n) scan that calls it once per task)
    /// expensive.
    /// </summary>
    /// <remarks>
    /// The Swift original folds via <c>String.folding(options: [.diacriticInsensitive,
    /// .caseInsensitive], locale: Locale(identifier: "vi_VN"))</c> then replaces the atomic
    /// "đ"/"Đ" (a letter-with-stroke with no Unicode diacritic decomposition, unlike ô/ơ/ư/tone
    /// marks) — i.e. it DOES fold diacritics away, which is what makes "bao cao" match "báo cáo"
    /// when Whisper drops tone marks. This port reproduces that with .NET's own idiom instead of
    /// attempting to call into ICU: Unicode NFD decomposition splits base letters from their
    /// combining diacritical marks, then stripping Unicode category <c>NonSpacingMark</c> (Mn)
    /// codepoints folds them away without touching "đ" (which survives decomposition untouched,
    /// so it is mapped explicitly, post-lowercasing). Identical algorithm to
    /// <c>Volar.Core.ConflictCheck.NormalizedTitleTokens</c> — re-implemented here rather than
    /// referenced because the Swift original does the same (its own private copy, not a call into
    /// <c>ConflictCheck.normalizedTitleTokens</c>).
    /// </remarks>
    private static List<string> NormalizedTokens(string text)
    {
        var bounded = text.Length > MaxWorkingLength ? text[..MaxWorkingLength] : text;

        var decomposed = bounded.Normalize(NormalizationForm.FormD);
        var stripped = new StringBuilder(decomposed.Length);
        foreach (var ch in decomposed)
        {
            if (CharUnicodeInfo.GetUnicodeCategory(ch) == UnicodeCategory.NonSpacingMark)
            {
                continue;
            }
            stripped.Append(ch);
        }

        var folded = stripped.ToString().ToLowerInvariant().Replace('đ', 'd');

        var tokens = new List<string>();
        var current = new StringBuilder();
        foreach (var ch in folded)
        {
            if (char.IsLetterOrDigit(ch))
            {
                current.Append(ch);
            }
            else if (current.Length > 0)
            {
                tokens.Add(current.ToString());
                current.Clear();
            }
        }
        if (current.Length > 0)
        {
            tokens.Add(current.ToString());
        }

        return tokens.Count > MaxTokens ? tokens.Take(MaxTokens).ToList() : tokens;
    }

    private static HashSet<string> NormalizedTokenSet(string text) =>
        new(NormalizedTokens(text), StringComparer.Ordinal);

    // MARK: - IDF containment scoring
    //
    // Replaces the earlier Jaccard (|intersection| / |union|) formula. Jaccard penalizes a
    // candidate title for words the SPEAKER never said ("Viết báo cáo quý" scores worse than "Viết
    // báo cáo" against the same utterance, purely because of the extra "quý"). Containment doesn't:
    // it asks "how much of what the user SAID is explained by this task", which is the question
    // that actually matters for a vắn tắt ("gọi cho anh Hùng..." spoken back as "xong vụ hợp đồng
    // rồi") voice command. IDF-weighting on top means a coincidental match on one very common word
    // ("gọi", "làm") can't alone manufacture a high score the way an unweighted containment
    // fraction could.

    /// <summary>
    /// The query side of a single <see cref="Classify"/> call's scoring, computed once by
    /// <see cref="BuildQueryContext"/> and reused for every candidate (every open task's title, and
    /// every external description) so the (cheap but still O(query) per call) work isn't repeated.
    /// Deliberately carries TWO different views of the same underlying tokens — see
    /// <see cref="BuildQueryContext"/>'s remarks and the file header's "TWO POLICIES" note for why.
    /// </summary>
    /// <param name="Tokens">
    /// EVERY cue-stripped reference token, UNFILTERED — including tokens with
    /// <c>documentFrequency == 0</c>. The denominator (via <see cref="SumIdf"/>) of
    /// <see cref="ScoreCandidate"/>'s coverage fraction; a <c>df == 0</c> token can never contribute
    /// to the numerator (nothing in the corpus contains it) but still dilutes the denominator, which
    /// is the intended, evidence-preserving behavior.
    /// </param>
    /// <param name="SumIdf">Σ idf(t) over <see cref="Tokens"/> — the coverage denominator.</param>
    /// <param name="Phrase">
    /// The cue-stripped reference tokens, FILTERED to drop any token with
    /// <c>documentFrequency == 0</c>, rejoined with single spaces IN THE ORDER THE USER SPOKE THEM —
    /// the needle for the exact-phrase-containment shortcut in <see cref="ScoreAgainstText"/>. Built
    /// from a DIFFERENTLY-filtered token set than <see cref="Tokens"/> on purpose (see
    /// <see cref="BuildQueryContext"/>'s remarks).
    /// </param>
    /// <param name="PhraseMatchEligible">
    /// True only when the (filtered) token set backing <see cref="Phrase"/> has at least 2 distinct
    /// tokens — see <see cref="BuildQueryContext"/>'s remarks for why a single token is never
    /// allowed to trigger the phrase-match shortcut.
    /// </param>
    private readonly record struct QueryContext(
        IReadOnlySet<string> Tokens, double SumIdf, string Phrase, bool PhraseMatchEligible);

    /// <summary>
    /// Builds the TITLE-side corpus document-frequency table: for each token, how many open tasks'
    /// TITLES contain it. Used only by the completion (<see cref="CompleteIntent"/>) branch — see
    /// <see cref="BuildExternalDocumentFrequency"/> for the sibling used by the clear-external
    /// branch, and the file header's "TWO CORPORA" note for why they are kept separate rather than
    /// shared.
    /// </summary>
    private static Dictionary<string, int> BuildDocumentFrequency(IReadOnlyList<VoiceDoneTask> openTasks)
    {
        var documentFrequency = new Dictionary<string, int>(StringComparer.Ordinal);
        foreach (var task in openTasks)
        {
            foreach (var token in NormalizedTokenSet(task.Title))
            {
                documentFrequency[token] = documentFrequency.GetValueOrDefault(token) + 1;
            }
        }
        return documentFrequency;
    }

    /// <summary>
    /// Builds the EXTERNAL-DESCRIPTION-side corpus document-frequency table: for each token, how
    /// many open tasks have AT LEAST ONE <c>ExternalDescriptions</c> entry containing it (tokens are
    /// deduplicated within a task first — a word repeated across several of one task's descriptions
    /// still only counts once towards that token's <c>df</c> — mirroring how
    /// <see cref="BuildDocumentFrequency"/> counts a title token once per task). Used only by the
    /// clear-external (<see cref="ClearExternalIntent"/>) branch. Bounded the same way
    /// <see cref="ScoredExternalCandidates"/> bounds its own per-description scan
    /// (<see cref="MaxExternalDescriptionsPerTask"/>, <see cref="MaxExternalDescriptionChars"/>) so
    /// corpus-building cost can't exceed scoring cost.
    /// </summary>
    private static Dictionary<string, int> BuildExternalDocumentFrequency(IReadOnlyList<VoiceDoneTask> openTasks)
    {
        var documentFrequency = new Dictionary<string, int>(StringComparer.Ordinal);
        foreach (var task in openTasks)
        {
            var taskTokens = new HashSet<string>(StringComparer.Ordinal);
            foreach (var description in task.ExternalDescriptions.Take(MaxExternalDescriptionsPerTask))
            {
                var bounded = description.Length > MaxExternalDescriptionChars
                    ? description[..MaxExternalDescriptionChars]
                    : description;
                taskTokens.UnionWith(NormalizedTokens(bounded));
            }
            foreach (var token in taskTokens)
            {
                documentFrequency[token] = documentFrequency.GetValueOrDefault(token) + 1;
            }
        }
        return documentFrequency;
    }

    /// <summary>
    /// <c>idf(t) = ln(1 + N / (1 + df(t)))</c>. A token absent from every title (<c>df == 0</c>,
    /// e.g. a word that only ever appears in an external description) is not an error — it is
    /// scored as maximally rare, which is the correct treatment for
    /// <see cref="ScoreCandidate"/>'s <c>MatchRatio</c> denominator (an external-only word in a
    /// candidate is genuinely distinctive relative to the title corpus).
    /// </summary>
    private static double Idf(string token, IReadOnlyDictionary<string, int> documentFrequency, int corpusSize)
    {
        var df = documentFrequency.GetValueOrDefault(token);
        return Math.Log(1.0 + (double)corpusSize / (1 + df));
    }

    /// <summary>
    /// The idf a token with <c>df = 1</c> (present in exactly one open task — a near-unique token,
    /// e.g. a proper name) would have in THIS call's corpus. Feeds <see cref="ScoreCandidate"/>'s
    /// one-tap guard: a single matched token only counts as strong enough evidence on its own to
    /// reach <see cref="HighConfidenceThreshold"/> when its own idf clears this bar. Grows without
    /// bound as <c>corpusSize</c> grows, so it is computed per <see cref="Classify"/> call rather
    /// than hard-coded to a fixed constant.
    /// </summary>
    /// <remarks>
    /// This is the ONLY score-suppressing gate left in <see cref="ScoreCandidate"/> — an earlier
    /// absolute-evidence-floor gate (<c>MinMatchedWeight</c>, a floor on <c>Σ idf(matched)</c>) was
    /// deleted: it was meant to stop a single common token from manufacturing a full-coverage
    /// "match" collapsing straight to one-tap, but that risk is already fully covered by THIS
    /// gate — the floor's actual, unintended effect was deleting legitimate below-one-tap
    /// CANDIDATES outright (e.g. two open tasks sharing one common word, at floor coverage 1.0,
    /// both zeroed instead of shown for the user to pick from). Per the product's own confirm-first
    /// design (constitution II — the user always picks/confirms, the candidate list is not an
    /// auto-decision), that tradeoff was backwards: be wide at the candidate tier (recall), narrow
    /// only at the one-tap tier (precision) — which is exactly what this gate alone already does.
    /// </remarks>
    private static double DistinctiveIdf(int corpusSize) => Math.Log(1.0 + corpusSize / 2.0);

    /// <summary>
    /// Builds this <see cref="Classify"/> call's <see cref="QueryContext"/> from the utterance's
    /// ordered, cue-stripped tokens.
    /// </summary>
    /// <remarks>
    /// Applies the file header's TWO POLICIES for a <c>documentFrequency == 0</c> token — anh Khôi
    /// chốt 2026-08-11, closing the contradiction where this method's code dropped such tokens
    /// while the header and <see cref="QueryContext.Tokens"/> said scoring keeps them:
    ///
    /// SCORING (<see cref="Tokens"/>/<see cref="SumIdf"/>): KEPT. A word appearing in NO open task
    /// is not the absence of signal, it is the strongest available signal that the utterance is
    /// about something else — "viết BÁO CÁO xong rồi" against a lone open "Viết email" must NOT
    /// match, and "báo"/"cáo" being absent from the whole corpus is the only thing that says so.
    /// Such a token gets the maximum idf the formula can yield (<c>ln(1 + N)</c>, <c>df</c> simply
    /// being 0) and can only ever sit in <see cref="ScoreCandidate"/>'s coverage denominator: by
    /// construction no candidate contains it, so it cannot reach a numerator.
    ///
    /// PHRASE-MATCH NEEDLE (<see cref="Phrase"/>): still DROPPED. That shortcut favors precision,
    /// and one filler word ("vụ", "cái", "chuyện") breaking an otherwise verbatim phrase hit is a
    /// false negative worth avoiding. The two policies are asymmetric ON PURPOSE, for opposite
    /// reasons — do not "tidy" them into agreement.
    ///
    /// The price anh Khôi accepted: a filler word now dilutes the coverage denominator, so
    /// "xong vụ hợp đồng rồi" against "...hợp đồng thuê văn phòng" lands as a CANDIDATE rather
    /// than a one-tap. Wide at the candidate tier, narrow at one-tap — the same trade the rest of
    /// this file already makes (see <see cref="DistinctiveIdf"/>'s remarks).
    ///
    /// <see cref="QueryContext.Tokens"/> now comes back empty only when the utterance was entirely
    /// cue words. The "every remaining word is unknown to the corpus" case no longer short-circuits
    /// here — it flows through scoring and lands at coverage 0, i.e. the same "done-phrase present
    /// but nothing matched" outcome by the honest route.
    ///
    /// <see cref="QueryContext.PhraseMatchEligible"/> requires at least 2 surviving needle tokens:
    /// a single word trivially "contains" itself as a phrase, and letting a lone word (however
    /// common — "gọi", "làm") trigger the same shortcut that a real multi-word phrase hit does
    /// would drag in unrelated tasks and could even collapse them to a false one-tap.
    /// </remarks>
    private static QueryContext BuildQueryContext(
        IReadOnlyList<string> orderedReferenceTokens,
        IReadOnlyDictionary<string, int> documentFrequency,
        int corpusSize)
    {
        var tokens = new HashSet<string>(orderedReferenceTokens, StringComparer.Ordinal);
        var sumIdf = tokens.Sum(token => Idf(token, documentFrequency, corpusSize));

        var needleOrdered = orderedReferenceTokens.Where(documentFrequency.ContainsKey).ToList();
        var needleTokens = new HashSet<string>(needleOrdered, StringComparer.Ordinal);
        var phrase = string.Join(' ', needleOrdered);

        return new QueryContext(tokens, sumIdf, phrase, needleTokens.Count >= 2);
    }

    /// <summary>
    /// Scores one candidate text (a task title, or a single external description) against
    /// <paramref name="query"/>: the exact-phrase-containment shortcut first, then the IDF
    /// containment fallback.
    /// </summary>
    /// <remarks>
    /// Exact-phrase shortcut: when the user names a phrase verbatim ("xong cái hợp đồng thuê văn
    /// phòng rồi" against a title ending "...hợp đồng thuê văn phòng") that is high-precision,
    /// cheap-to-check evidence — there is no reason to route it through the fuzzy IDF gates and
    /// hope it clears them. If <paramref name="query"/>'s scorable phrase appears verbatim,
    /// contiguously, inside this candidate's own normalized phrase (both sides built the same way
    /// <see cref="ScoredTitleCandidates"/>/<see cref="ScoredExternalCandidates"/> already fold
    /// diacritics and case, so "hop dong thue van phong" — no diacritics, as ASR often produces —
    /// still matches a "Hợp đồng thuê văn phòng" title), the resulting score is floored up to
    /// <see cref="HighConfidenceThreshold"/> (never lowered if the IDF score was already higher,
    /// never pushed past 1.0). Gated by <see cref="QueryContext.PhraseMatchEligible"/> (query has
    /// at least 2 scorable tokens) so a single common word can't ride this shortcut to a one-tap.
    ///
    /// IDF containment (see <see cref="ScoreCandidate"/>): coverage = the fraction of the
    /// (IDF-weighted) query explained by this candidate, gated by a one-tap distinctiveness guard
    /// (<see cref="DistinctiveIdf"/>).
    /// </remarks>
    private static (double Score, double MatchRatio, bool IsPhraseMatch) ScoreAgainstText(
        string text,
        QueryContext query,
        IReadOnlyDictionary<string, int> documentFrequency,
        int corpusSize)
    {
        var tokens = NormalizedTokens(text);
        var candidateTokens = new HashSet<string>(tokens, StringComparer.Ordinal);

        var (score, ratio) = ScoreCandidate(query.Tokens, query.SumIdf, candidateTokens, documentFrequency, corpusSize);

        var isPhraseMatch = query.PhraseMatchEligible &&
            string.Join(' ', tokens).Contains(query.Phrase, StringComparison.Ordinal);
        if (isPhraseMatch)
        {
            score = Math.Min(1.0, Math.Max(score, HighConfidenceThreshold));
        }

        return (score, ratio, isPhraseMatch);
    }

    /// <summary>
    /// The IDF containment fallback: <c>coverage = Σ idf(matched) / Σ idf(query)</c> — the fraction
    /// of the query's IDF-weighted mass that this candidate's token set covers. The query side is
    /// UNFILTERED: a <c>df == 0</c> token carries maximum idf and weighs on the denominator alone,
    /// which is what stops an utterance about something else from reaching full coverage on a
    /// shared common word (see <see cref="BuildQueryContext"/>'s TWO POLICIES remarks). Also returns <c>MatchRatio = Σ idf(matched) / Σ idf(candidateTokens)</c>,
    /// <see cref="SelectCandidates"/>'s tie-break signal (how little of the CANDIDATE, not the
    /// query, is unmatched filler — a tighter, more specific title ranks above a looser one at the
    /// same coverage).
    /// </summary>
    /// <remarks>
    /// One safety gate, required because containment (by construction) never penalizes a candidate
    /// for extra unmatched words: the one-tap guard — a match resting on exactly one token only
    /// clears <see cref="HighConfidenceThreshold"/> when that token is itself near-unique
    /// (<see cref="DistinctiveIdf"/>); two-or-more matched tokens corroborate each other and always
    /// qualify. A single-token match that clears coverage 0.8 without clearing this guard is clamped
    /// to just under the bar (<see cref="HighConfidenceGuardMargin"/>) rather than zeroed — it's a
    /// real candidate, just not a safe one-tap. (An earlier second gate, an absolute floor on
    /// <c>Σ idf(matched)</c>, was deleted — see <see cref="DistinctiveIdf"/>'s remarks for why.)
    /// </remarks>
    private static (double Score, double MatchRatio) ScoreCandidate(
        IReadOnlySet<string> scorableQuery,
        double sumIdfQuery,
        IReadOnlySet<string> candidateTokens,
        IReadOnlyDictionary<string, int> documentFrequency,
        int corpusSize)
    {
        var matchedCount = 0;
        var sumIdfMatched = 0.0;
        foreach (var token in scorableQuery)
        {
            if (!candidateTokens.Contains(token))
            {
                continue;
            }
            matchedCount++;
            sumIdfMatched += Idf(token, documentFrequency, corpusSize);
        }

        if (matchedCount == 0)
        {
            return (0.0, 0.0);
        }

        var coverage = sumIdfMatched / sumIdfQuery;

        var distinctiveEnough = matchedCount >= 2 || sumIdfMatched >= DistinctiveIdf(corpusSize);
        if (coverage >= HighConfidenceThreshold && !distinctiveEnough)
        {
            coverage = HighConfidenceThreshold - HighConfidenceGuardMargin;
        }

        var sumIdfCandidate = candidateTokens.Sum(token => Idf(token, documentFrequency, corpusSize));
        var matchRatio = sumIdfMatched / sumIdfCandidate;
        return (coverage, matchRatio);
    }
}
