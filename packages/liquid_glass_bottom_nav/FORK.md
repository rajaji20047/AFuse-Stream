# liquid_glass_bottom_nav fork (Fuse)

Fork of `liquid_glass_bottom_nav` 0.0.14 (pub.dev), vendored under
`packages/liquid_glass_bottom_nav` and wired through `dependency_overrides`
in the app's `pubspec.yaml`. Everything is byte-identical to 0.0.14 except
the changes below.

## The change — guard the OpenGL ES Y-flips for engine >= 3.44

On some Android phones Impeller falls back to OpenGL ES (no Vulkan). On
those phones the nav pill rendered a vertically-mirrored copy of the screen
content inside itself ("Fuse" mirrored as "Σoιιe", the bolt smeared like a
flame, search/settings icons mirrored as a stray "8") — on every screen, and
only on those phones. iPhone (Metal) and Vulkan Android phones never showed
it.

Root cause: Flutter's OpenGLES coordinate-system unification (engine after
3.44.0, in stable 3.47) made render-to-texture content top-down on every
backend, which turned the shaders' manual Y-flips under
`IMPELLER_TARGET_OPENGLES` into a double flip. The sibling package
`liquid_glass_easy` fixed the identical bug the same way (changelog 4.3.4),
and Flutter's own breaking-change doc
("OpenGL ES render-to-texture content is stored top-down") prescribes this
guard.

All six `IMPELLER_TARGET_OPENGLES` Y-flip sites are now guarded with
`#if defined(IMPELLER_TARGET_OPENGLES) &&
!defined(IMPELLER_OPENGLES_UNFLIPPED_DEPRECATED)`, so the flip still runs
on engines < 3.44 that need it and is skipped on engines >= 3.44 where the
engine defines the macro:

- `liquid_glass_final_render.frag` — `screenUV` flip and `geometryUV` flip
  (the render path the nav bar actually uses: `LiquidGlassLayer` /
  `LiquidGlassFilter` load this shader; the geometry texture comes from
  `liquid_glass_geometry_blended.frag`)
- `liquid_glass_filter.frag` — `screenUV` flip
- `liquid_glass_geometry_blended.frag` — `screenUV` flip (dead code there,
  guarded for consistency)
- `shared.glsl` / `render.glsl` — `computeY()` flip (used by
  `liquid_glass_arbitrary.frag`)

The `transformedCoord` reassignment under `#ifdef
IMPELLER_TARGET_OPENGLES` in `liquid_glass_arbitrary.frag` is left alone:
once `computeY()` stops flipping, it is a no-op on new engines and it
preserves the old behaviour on old engines.

No Dart code changed. No look change: on Vulkan/Metal the guarded code is
not compiled at all, and on new-engine GLES the pill now samples the
backdrop the right way up. The pill stays clear liquid-glass (no blur/tint
added).

## Updating

To rebase onto a newer liquid_glass_bottom_nav: copy the new version over
this directory, re-apply the six guards above (search for
`IMPELLER_TARGET_OPENGLES` in `lib/src/liquid_glass_renderer/assets/shaders/`)
and the Zenith-style changes in the section below, and keep this note
current. If upstream ever ships the guard itself, only the Zenith section
still needs re-applying.

## Zenith-style bar (2026-11-25)

The user asked for the Zenith nav bar (from his Zenith recording) in Fuse.
Shape and motion, not just colours — in
`lib/liquid_glass_bottom_nav.dart` and the app's
`lib/shared/widgets/custom_bottom_nav.dart`:

- Pill: full stadium (`borderRadius` 34, the package default), side gutter
  19 pt, foot 21 dp off the edge (Zenith's sideMargin / bottomLift).
- Indicator: the resting bubble is the accent at 14% in both modes (was:
  black 0.45 in dark, accent 0.15 in light).
- Travel: ~1/3 s, one soft overshoot (`easeOutBack`) instead of the
  multi-bounce `elasticOut`; the selected glyph pops to 1.08 on the same
  spring.
- Haptics: a selection tick on a tab change by tap or by drag.
- Icons 28 dp, labels 10 sp / 0.5 tracking; unselected tabs are the
  content colour at 65% on dark glass.

NOT copied (needs new wiring, not a restyle): Zenith's mini-player pill
above the bar (Fuse has no audio mini-player) and the scroll-collapse to
a single inline tab (Fuse pages feed no scroll into the bar). The
indicator's stretch-while-travelling (scaleX 1 + lag x 0.16) is also
not in: the package animates the bubble with AnimatedPositioned, and a
true lag stretch needs a controller-driven position. The drag squash
(scaleY on drag velocity) already in the package stays.
