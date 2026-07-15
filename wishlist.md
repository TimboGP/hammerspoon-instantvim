# instantvim — Wishlist

Ideas considered and deliberately deferred, kept here instead of as an issue
so the rationale for *why* it's not done stays next to the idea.

## Formatted (rich text) content

Selection-scoped editing (see README) is plain-text only *by default*: editing
a selection inside Word, Pages, Notes, Mail's rich compose, etc. round-trips
through nvim as plain text and loses any bold/italic/links/etc. within the
replaced range. instantvim's whole model is plain-text-in-nvim.

### Prototype (shipped): RTF via pandoc

A first slice of the sketch below is now implemented — see
[`richtext.lua`](richtext.lua) and `contentTypeByBundleID` in the README:

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

### Still deferred

- **Live per-app fidelity testing.** The RTF path is verified end-to-end
  against TextEdit; the HTML path is verified at the conversion + pasteboard
  level but its live `contentEditable` round-trip (browsers, Electron) is not
  yet confirmed on real apps. Each app differs in which UTI it
  publishes/accepts and how faithfully it round-trips through Markdown.
- **Fidelity edge cases.** Some formatting (nested styles, tables, comments,
  tracked changes) won't round-trip cleanly through Markdown regardless of
  converter. The prototype accepts this; a general solution would need a
  richer intermediate representation than gfm.
- **Selection re-highlight precision.** After a rich write-back the
  re-highlight is sized off pandoc's plain-text rendering of the Markdown,
  which can drift from the app's own rendered length; it's cosmetic and
  best-effort, same as the plain path.
