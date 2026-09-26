# Halo caption glyph limit (UNICODE_LIMIT)

State of the caption compositor: **EMULATED_PREPARED** — layout verified on the
official halo-emulator (framebuffer checks, Lua 5.4 oracle), never on
hardware.

## Limitation

The Halo display fonts in the pinned SDK (Dogica, Dogica Bold) draw printable
ASCII (0x20–0x7E) only; the firmware skips any other code point. HORIZON does
**not** support Unicode captions. What it does instead is degrade them
visibly and report the loss:

| Input | Shown on the HUD | Reported as |
|---|---|---|
| ASCII | as is | — |
| Accented Latin and common punctuation (`á`, `ñ`, `ß`, `¿`, `€`, `“”`) | folded to ASCII (`a`, `n`, `ss`, `?`, `EUR`, `""`) | `folded` |
| Anything else (CJK, Cyrillic, Greek, Arabic, emoji, …) | `?` per character | `replaced` |

`?` is a placeholder for a lost character, not a rendering of it. A caption
with any `replaced` character is not readable in that language.

## Where it is exposed

- Composer: `HaloCaptionComposition.foldedChars` / `unrenderableChars`.
- Device result: `page:1/N;folded:<n>;replaced:<n>` (suffixes only when > 0).
- `CaptionDelivery.foldedGlyphs` / `replacedGlyphs`, and `reason`
  `glyphsReplaced` (takes precedence) or `glyphsFolded` on a delivered caption.
- Runtime event stream: the caption `reason` field (coded, no text).
- Engineering Console: "Captions degraded by the HUD font (ASCII only)".

## What would remove it

Rendering non-ASCII text needs glyphs on the device (bitmap sprites or a
custom font uploaded through the SDK). That is new work, not a fix, and is
not planned in this branch.
