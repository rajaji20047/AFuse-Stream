/// AddonStreamRequest.copyWith: a resolved TMDB id replaces the request's
/// id without touching anything else, and a null override keeps the
/// request's own id (the detail page's Play paths pass the resolved id
/// this way; a failed resolution must leave the request as it was).
library;

import 'package:flutter_test/flutter_test.dart';
import 'package:raja/core/addons/data/addon_stream_service.dart';

void main() {
  const request = AddonStreamRequest(
    type: 'movie',
    contentId: 'moviesmod:bull-run',
    imdbId: 'tt1234567',
    title: 'Bull Run',
    year: 2025,
  );

  test('copyWith sets the resolved tmdbId and keeps the rest', () {
    final copied = request.copyWith(tmdbId: 12345);

    expect(copied.tmdbId, 12345);
    expect(copied.type, 'movie');
    expect(copied.contentId, 'moviesmod:bull-run');
    expect(copied.imdbId, 'tt1234567');
    expect(copied.title, 'Bull Run');
    expect(copied.year, 2025);
    expect(request.tmdbId, isNull);
  });

  test('copyWith with a null tmdbId keeps the request id', () {
    final withId = request.copyWith(tmdbId: 12345);

    expect(withId.copyWith().tmdbId, 12345);
    expect(withId.copyWith(tmdbId: null).tmdbId, 12345);
  });
}
