# instantvim — Wishlist

Ideas considered and deliberately deferred, kept here instead of as an issue
so the rationale for *why* it's not done stays next to the idea.

## Formatted (rich text) content

Selection-scoped editing (see README) is plain-text only: editing a
selection inside Word, Pages, Notes, Mail's rich compose, etc. round-trips
through nvim as plain text and loses any bold/italic/links/etc. within the
replaced range. This is intentional for now — instantvim's whole model is
plain-text-in-nvim.

Sketch of one way to tackle it later, if it's worth the complexity:

- **Capture:** read the selection off the pasteboard as `public.rtf` /
  `public.html` (whichever UTI the app publishes) instead of plain text,
  convert to Markdown (e.g. via `pandoc`) for editing.
- **Write-back:** convert edited Markdown back to RTF/HTML, write it to the
  pasteboard under the UTI the target app expects, then paste — most Cocoa
  rich-text views apply rich pasteboard data automatically on `⌘V`.
- This is inherently **per-app**: apps differ in which UTI they
  publish/accept and how faithfully they round-trip through Markdown. Model
  it like `tierOverrideByBundleID` — a `contentTypeByBundleID` table picking
  a converter profile per app, plain text as the universal fallback.
- Tradeoffs: adds a real dependency (pandoc or similar), needs per-app
  fidelity testing, and some formatting (nested styles, tables, comments)
  won't round-trip cleanly regardless. Live (Tier A) rich write-back isn't
  possible at all — `AXSelectedText`/`AXValue` are plain-string attributes,
  so any rich round-trip would have to go through the paste path (Tier B
  behavior, on quit only) even for fields that are otherwise Tier A.
