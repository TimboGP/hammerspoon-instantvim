# instantvim — Wishlist

Ideas considered and deliberately deferred, kept here instead of as an issue
so the rationale for *why* it's not done stays next to the idea.

## Formatted (rich text) content

Selection-scoped editing (see README) is plain-text only *by default*: editing
a selection inside Word, Pages, Notes, Mail's rich compose, etc. round-trips
through nvim as plain text and loses any bold/italic/links/etc. within the
replaced range. instantvim's whole model is plain-text-in-nvim.

### Shipped

The sketch below is implemented — see [`richtext.lua`](richtext.lua),
[`slack.lua`](slack.lua), and `contentTypeByBundleID` in the README:

- **Gated, off by default.** The whole path is behind `config.enableRichText`
  (default `false`); enabling it — in config or via the menu-bar toggle —
  runs a `pandoc` check and notifies if it's missing. When on,
  `config.contentTypeByBundleID` maps a bundle ID to a converter profile;
  apps not listed keep the plain-text behavior — plain text stays the
  universal fallback.
- **Two profiles, each an ordered list of representations.** `rtf`
  (`public.rtf`, native Cocoa — TextEdit is the tested target) and `html`
  (`public.html`, web/Electron `contentEditable` — the common browsers and
  Apple Mail ship mapped to it). Each profile lists both reps; they differ
  only in which one they prefer.
- **Capture:** copy the field to the pasteboard, then pick the *richest
  representation the app actually published* (first present rep in priority
  order — so an app mapped to one profile still works if it only publishes
  the other's UTI), read it, and convert → Markdown (gfm) via `pandoc`.
- **Write-back:** convert edited Markdown back via `pandoc` into *every* rep
  the profile knows, and write them all — plus a plain-text rep — with
  `writeAllData`, so the target picks whichever it understands (native field
  → RTF, web field → HTML, from one write). RTF auto-synthesizes plain text;
  HTML does not, so the plain rep is always written explicitly.
- **Always Tier B.** As predicted below, live (Tier A) rich write-back is
  impossible — `AXValue`/`AXSelectedText` are plain strings — so a rich
  round-trip goes through the paste path (on quit only) even for fields that
  would otherwise be Tier A. If pandoc is missing or a conversion fails, the
  field degrades cleanly to the plain-text path.
- **Bespoke adapters for apps with proprietary clipboards.** A rep may carry a
  custom `captureFn` and/or a `post` hook instead of relying on a standard UTI
  + pandoc, and a profile may split `captureReps` from `writeReps`. **Slack**
  ([`slack.lua`](slack.lua), verified end-to-end) is the first: its composer
  publishes only `public.utf8-plain-text` (formatting stripped) plus Chromium
  internals — the real formatting is a Quill Delta under a `slack/texty` custom
  MIME type inside `org.chromium.web-custom-data`. **Capture** is bespoke:
  unwrap the Chromium pickle, pull out `slack/texty`, convert the Delta →
  Markdown (bold/italic/strike/underline/code/link, bullet + ordered lists,
  code blocks, blockquote). **Write-back** is asymmetric and reuses the `html`
  path — Slack's Quill converts pasted HTML back into its own format — with one
  fixup: Quill wants `<s>` for strikethrough where pandoc emits `<del>`.

### Still deferred

- **Broaden verified apps.** The RTF path is verified end-to-end against
  TextEdit and Microsoft Word; the HTML path against a live browser. (Word,
  notably, publishes `public.rtf`, `public.html`, `com.apple.flat-rtfd`, and
  `com.adobe.pdf` all at once; the priority list picks the cleanest,
  `public.rtf`.) Notes is a plausible-but-untested `rtf` candidate.
- **Named paragraph styles don't round-trip (Pages).** `Pages`
  (`com.apple.Pages`, checked) captures fine via `public.rtf`, but write-back
  is broken enough to be worse than not mapping it, so it is deliberately
  left out. Pages documents are built on *named paragraph styles* (Body,
  Title, Heading N) that have no Markdown equivalent — they're dropped at
  capture and can't be reconstructed. On write-back, pandoc's RTF carries
  only direct formatting (`\b`, `\fs36`) and no stylesheet, so pasting it into
  Pages keeps the paste point's paragraph style and layers our formatting as
  overrides: a mixed-style selection **collapses onto the first word's style**
  (shown as e.g. `Body*`, the asterisk meaning "modified"). Fine for
  single-style (all-Body) content; damaging for anything with headings/titles.
  A real fix needs an iWork-aware representation that preserves named styles —
  out of scope for the Markdown-based prototype. Anyone who only edits
  uniform-style Pages text can opt in with `["com.apple.Pages"] = "rtf"`.
- **More proprietary-clipboard apps.** Slack now has a bespoke adapter (see
  Shipped), but other Electron apps (Notion, Discord) may each use their own
  clipboard format rather than standard `public.html` — probe each before
  assuming `html` works, and add a `slack.lua`-style adapter where it doesn't.
- **Slack write-back is HTML-based, not Delta-based.** Capture parses Slack's
  Quill Delta, but write-back leans on Slack's own HTML→Delta paste conversion
  rather than reconstructing a `slack/texty` Delta + Chromium pickle. That's
  simpler and works, but means write-back fidelity is bounded by what Slack's
  paste importer accepts (it's why strikethrough needed the `<del>`→`<s>`
  fixup). Synthesizing the Delta directly would be higher-fidelity but is
  fragile, proprietary work — deferred unless HTML paste proves insufficient.
- **Fidelity edge cases.** Some formatting (nested styles, tables, comments,
  tracked changes) won't round-trip cleanly through Markdown regardless of
  converter. The prototype accepts this; a general solution would need a
  richer intermediate representation than gfm.
- **Selection re-highlight precision.** After a rich write-back the
  re-highlight is sized off pandoc's plain-text rendering of the Markdown,
  which can drift from the app's own rendered length; it's cosmetic and
  best-effort, same as the plain path.
