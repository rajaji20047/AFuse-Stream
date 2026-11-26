import 'package:flutter_test/flutter_test.dart';
import 'package:raja/features/sources/presentation/source_sheet_widgets.dart';

/// The quality groups both source sheets filter by: the groups are
/// disjoint, cover every score, and match the badges the rows wear
/// ('4K' ≥ 2160, '2K' ≥ 1440, then the stated height; 0 states none).
void main() {
  test('groups are disjoint and cover every score', () {
    for (final score in [0, 1, 240, 360, 479, 480, 719, 720, 1079, 1080, 1439, 1440, 2159, 2160, 4320]) {
      final matched = SourceQualityFilter.values
          .where((f) => f != SourceQualityFilter.all)
          .where((f) => f.matchesScore(score))
          .toList();
      expect(matched, hasLength(1), reason: 'score $score');
    }
    expect(SourceQualityFilter.all.matchesScore(0), isTrue);
    expect(SourceQualityFilter.all.matchesScore(2160), isTrue);
  });

  test('each group matches its own badge range', () {
    expect(SourceQualityFilter.q4k.matchesScore(2160), isTrue);
    expect(SourceQualityFilter.q4k.matchesScore(1440), isFalse);
    expect(SourceQualityFilter.q2k.matchesScore(1440), isTrue);
    expect(SourceQualityFilter.q2k.matchesScore(2160), isFalse);
    expect(SourceQualityFilter.q1080.matchesScore(1080), isTrue);
    expect(SourceQualityFilter.q1080.matchesScore(720), isFalse);
    expect(SourceQualityFilter.q720.matchesScore(720), isTrue);
    expect(SourceQualityFilter.q720.matchesScore(1080), isFalse);
    expect(SourceQualityFilter.q480.matchesScore(480), isTrue);
    expect(SourceQualityFilter.q480.matchesScore(360), isFalse);
    expect(SourceQualityFilter.q360.matchesScore(360), isTrue);
    expect(SourceQualityFilter.q360.matchesScore(0), isFalse);
    expect(SourceQualityFilter.auto.matchesScore(0), isTrue);
    expect(SourceQualityFilter.auto.matchesScore(360), isFalse);
  });

  test('labels are the chip texts, in chip order', () {
    expect(
      [
        for (final f in SourceQualityFilter.values) f.label,
      ],
      ['All', 'Auto', '360p', '480p', '720p', '1080p', '2K', '4K'],
    );
  });
}
