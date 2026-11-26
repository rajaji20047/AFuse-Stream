import 'package:flutter_test/flutter_test.dart';
import 'package:raja/core/network/link_probe_service.dart';
import 'package:raja/features/player/domain/hls_quality.dart';

void main() {
  group('qualityLadderOf', () {
    test('each height once, tallest first', () {
      // Apple's sample lists 1080p six times over: three audio groups, two
      // bitrates each.
      expect(
        qualityLadderOf(const [
          HlsVariant(height: 540, bandwidth: 2227464),
          HlsVariant(height: 1080, bandwidth: 8178040),
          HlsVariant(height: 1080, bandwidth: 6453202),
          HlsVariant(height: 720, bandwidth: 3289288),
          HlsVariant(height: 540, bandwidth: 2448841),
        ]),
        [1080, 720, 540],
      );
    });

    test('a variant with no RESOLUTION is left out, so a master without '
        'them offers no choice', () {
      expect(
        qualityLadderOf(const [
          HlsVariant(bandwidth: 1),
          HlsVariant(bandwidth: 2),
        ]),
        isEmpty,
      );
      expect(qualityLadderOf(const [HlsVariant(height: 720), HlsVariant()]), [
        720,
      ]);
    });

    test('read straight off a master playlist', () {
      // Mux's test stream. NAME says 380 where RESOLUTION says 288, and
      // RESOLUTION is the picture.
      const mux =
          '#EXTM3U\n'
          '#EXT-X-STREAM-INF:PROGRAM-ID=1,BANDWIDTH=2149280,RESOLUTION=1280x720,NAME="720"\n'
          'url_0/hd.m3u8\n'
          '#EXT-X-STREAM-INF:PROGRAM-ID=1,BANDWIDTH=246440,RESOLUTION=320x184,NAME="240"\n'
          'url_2/ld.m3u8\n'
          '#EXT-X-STREAM-INF:PROGRAM-ID=1,BANDWIDTH=460560,RESOLUTION=512x288,NAME="380"\n'
          'url_4/sd.m3u8\n'
          '#EXT-X-STREAM-INF:PROGRAM-ID=1,BANDWIDTH=836280,RESOLUTION=848x480,NAME="480"\n'
          'url_6/hq.m3u8\n'
          '#EXT-X-STREAM-INF:PROGRAM-ID=1,BANDWIDTH=6221600,RESOLUTION=1920x1080,NAME="1080"\n'
          'url_8/fhd.m3u8\n';

      expect(qualityLadderOf(hlsVariantsOf(mux)), [1080, 720, 480, 288, 184]);
    });
  });

  group('heightUnderCap', () {
    const ladder = [1080, 720, 480];

    test('the tallest at or below the cap', () {
      expect(heightUnderCap(1080, ladder), 1080);
      expect(heightUnderCap(900, ladder), 720);
      expect(heightUnderCap(2160, ladder), 1080);
    });

    test('the lowest, when every height is above the cap', () {
      expect(heightUnderCap(360, ladder), 480);
    });

    test('nothing, for no ladder', () {
      expect(heightUnderCap(720, const []), isNull);
    });
  });

  group('nearestLadderHeight', () {
    const ladder = [1080, 720, 540];

    test('the rung the picture is', () {
      expect(nearestLadderHeight(1088, ladder), 1080);
      expect(nearestLadderHeight(534, ladder), 540);
      expect(nearestLadderHeight(720, ladder), 720);
    });

    test('nothing before the engine reports a size', () {
      expect(nearestLadderHeight(null, ladder), isNull);
      expect(nearestLadderHeight(0, ladder), isNull);
      expect(nearestLadderHeight(1080, const []), isNull);
    });
  });

  group('bitrateCapForPick', () {
    const variants = [
      HlsVariant(height: 1080, bandwidth: 6221600),
      HlsVariant(height: 1080, bandwidth: 8178040),
      HlsVariant(height: 720, bandwidth: 2149280),
      HlsVariant(height: 480, bandwidth: 836280),
    ];
    const ladder = [1080, 720, 480];

    test('Auto is 0: no limit, so it lifts a pick', () {
      expect(bitrateCapForPick(null, ladder, variants), 0);
    });

    test('a pick caps at the playing rendition, highest bitrate at it', () {
      // 1080p is listed twice: the higher bitrate is the one the player
      // would take, so it is the cap.
      expect(bitrateCapForPick(1080, ladder, variants), 8178040);
      expect(bitrateCapForPick(720, ladder, variants), 2149280);
    });

    test('a pick between rungs caps at the rung below it', () {
      // 900p is no rung: 720p plays, so its bandwidth caps it.
      expect(bitrateCapForPick(900, ladder, variants), 2149280);
      // Below the lowest rung the lowest plays.
      expect(bitrateCapForPick(100, ladder, variants), 836280);
    });

    test('null when there is nothing to cap on', () {
      expect(bitrateCapForPick(720, const [], variants), isNull);
      // The playing rung's variants carry no bandwidth at all.
      expect(
        bitrateCapForPick(720, ladder, const [
          HlsVariant(height: 720),
          HlsVariant(height: 480, bandwidth: 836280),
        ]),
        isNull,
      );
    });
  });
}
