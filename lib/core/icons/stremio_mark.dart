import 'package:flutter/widgets.dart';
import 'package:flutter_svg/flutter_svg.dart';

/// The Stremio brand mark, as a one-colour icon.
///
/// Source: Simple Icons' `stremio.svg` (CC0, public domain) — a diamond
/// with a play-triangle cutout. Drawn the same way as [ReiconIcon]: a
/// 24x24 SVG painted with `currentColor`, so the nav bar's IconTheme
/// colours it like the other tabs (accent when selected, white 65%
/// otherwise) at the same 28 dp size and 1.08 selection pop.
class StremioMarkIcon extends StatelessWidget {
  const StremioMarkIcon({required this.color, this.size = 28, super.key});

  final Color color;
  final double size;

  @override
  Widget build(BuildContext context) => SvgPicture.string(
    '<svg xmlns="http://www.w3.org/2000/svg" viewBox="0 0 24 24" '
    'fill="none">'
    '<path d="M12 0a1.2 1.2 0 0 0-.85.354L.353 11.15c-.47.47-.47 1.227 0 1.697L11.15 23.647a1.2 1.2 0 0 0 1.7 0l10.797-10.8c.47-.47.47-1.226 0-1.696L12.85.354A1.2 1.2 0 0 0 12 0zm-1.674 7.586a.2.2 0 0 1 .002 0 .2.2 0 0 1 .129.04l5.729 4.214a.2.2 0 0 1 0 .323l-5.73 4.213a.2.2 0 0 1-.317-.16v-8.43a.2.2 0 0 1 .187-.2z" fill="currentColor"/>'
    '</svg>',
    width: size,
    height: size,
    // The mark paints with `currentColor`.
    theme: SvgTheme(currentColor: color),
    colorFilter: ColorFilter.mode(color, BlendMode.srcIn),
    excludeFromSemantics: true,
  );
}
