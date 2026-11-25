/// The owner's repo as its own "Fuse" section: the same TojiX repo.json,
/// shown as "Fuse Repo" above the "Fuse (SkyStream)" section — and NOT in
/// the CloudStream section, which keeps only the official repository.
/// The repo stays in the CloudStream store (the .cs3 install / update
/// flow runs through it); only its display grouping moved, so an
/// installed Anikoto keeps working and updating.
library;

// A test's ProviderScope is its root scope; the rule only recognises one
// passed to runApp.
// ignore_for_file: riverpod_lint/scoped_providers_should_specify_dependencies

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:zorox/core/cloudstream/cloudstream_models.dart';
import 'package:zorox/core/cloudstream/cloudstream_repository.dart';
import 'package:zorox/core/extensions/base_provider.dart';
import 'package:zorox/core/extensions/extension_manager.dart';
import 'package:zorox/core/extensions/models/extension_plugin.dart';
import 'package:zorox/features/extensions/providers/extensions_controller.dart';
import 'package:zorox/features/extensions/screens/extensions_screen.dart';
import 'package:zorox/features/extensions/widgets/cloudstream_plugin_section.dart';
import 'package:zorox/l10n/generated/app_localizations.dart';

const String _tojiXUrl =
    'https://raw.githubusercontent.com/sezkc16/TojiX/main/repo.json';
const String _officialUrl =
    'https://raw.githubusercontent.com/recloudstream/extensions/master/repo.json';
const String _otherUrl = 'https://example.com/repo.json';

/// A CloudStream store that is already loaded, holding [state]: the real
/// one never finishes loading in the harness (its SharedPreferences /
/// engine-host work has no test backing).
class _LoadedCloudStream extends CloudStreamRepository {
  _LoadedCloudStream(this._state);

  final CloudStreamState _state;

  @override
  CloudStreamState build() => _state;
}

CsRepository _repo(String url, String name) =>
    CsRepository(url: url, name: name);

Widget _hosted(Widget child, CloudStreamState csState) => ProviderScope(
  overrides: [
    cloudStreamRepositoryProvider.overrideWith(
      () => _LoadedCloudStream(csState),
    ),
  ],
  child: MaterialApp(
    localizationsDelegates: AppLocalizations.localizationsDelegates,
    supportedLocales: AppLocalizations.supportedLocales,
    home: Scaffold(body: child),
  ),
);

class _MockExtensionsController extends ExtensionsController {
  _MockExtensionsController(this._initial);

  final ExtensionsState _initial;

  @override
  ExtensionsState build() => _initial;

  @override
  Future<void> ensureInitialized() async {}
}

class _MockExtensionManager extends ExtensionManager {
  @override
  List<SkyStreamProvider> build() => [];

  @override
  List<PluginSubProvider> getProvidersForPlugin(ExtensionPlugin plugin) =>
      [];

  @override
  Future<List<PluginSettingDefinition>> getSettingsForPlugin(
    ExtensionPlugin plugin,
  ) async => [];
}

void main() {
  group('displayNameFor', () {
    test('the owner repo is "Fuse Repo", not its manifest name', () {
      expect(
        CloudStreamRepository.displayNameFor(_repo(_tojiXUrl, 'TojiX Repo')),
        'Fuse Repo',
      );
    });

    test('the official repository stays "CloudStream"', () {
      expect(
        CloudStreamRepository.displayNameFor(
          _repo(_officialUrl, 'CloudStream Repo'),
        ),
        'CloudStream',
      );
    });

    test('any other repository keeps its manifest name', () {
      expect(
        CloudStreamRepository.displayNameFor(_repo(_otherUrl, 'Some Repo')),
        'Some Repo',
      );
    });

    test('isFuseRepository only matches the owner URL', () {
      expect(CloudStreamRepository.isFuseRepository(_tojiXUrl), isTrue);
      expect(CloudStreamRepository.isFuseRepository(_officialUrl), isFalse);
      expect(CloudStreamRepository.isFuseRepository(_otherUrl), isFalse);
    });
  });

  group('FuseRepositorySection', () {
    testWidgets('shows the Fuse header and the Fuse Repo card', (tester) async {
      await tester.pumpWidget(
        _hosted(
          const FuseRepositorySection(),
          CloudStreamState(
            isLoading: false,
            repositories: [_repo(_tojiXUrl, 'TojiX Repo')],
          ),
        ),
      );
      await tester.pumpAndSettle();

      expect(find.text('Fuse'), findsOneWidget);
      expect(find.text('Fuse Repo'), findsOneWidget);
      expect(find.text('TojiX Repo'), findsNothing);
    });

    testWidgets('hides entirely when the repository is not stored', (
      tester,
    ) async {
      await tester.pumpWidget(
        _hosted(
          const FuseRepositorySection(),
          const CloudStreamState(isLoading: false),
        ),
      );
      await tester.pumpAndSettle();

      expect(find.text('Fuse'), findsNothing);
      expect(find.text('Fuse Repo'), findsNothing);
    });
  });

  group('CloudStreamRepositoriesSection', () {
    testWidgets('lists the official repository, never the owner repo', (
      tester,
    ) async {
      await tester.pumpWidget(
        _hosted(
          const CloudStreamRepositoriesSection(showAddRow: false),
          CloudStreamState(
            isLoading: false,
            repositories: [
              _repo(_tojiXUrl, 'TojiX Repo'),
              _repo(_officialUrl, 'CloudStream Repo'),
            ],
          ),
        ),
      );
      await tester.pumpAndSettle();

      // The section header plus the official repository's card.
      expect(find.text('CloudStream'), findsNWidgets(2));
      expect(find.text('Fuse Repo'), findsNothing);
      expect(find.text('TojiX Repo'), findsNothing);
    });
  });

  testWidgets(
    'Extensions screen: Fuse Repo above Fuse (SkyStream), TojiX gone',
    (tester) async {
      tester.view.physicalSize = const Size(800, 2400);
      tester.view.devicePixelRatio = 1.0;
      final empty = ExtensionsSuccess(
        repositories: const [],
        installedPlugins: const [],
        availablePlugins: const {},
        availableUpdates: const {},
        installingPlugins: const {},
      );
      await tester.pumpWidget(
        ProviderScope(
          overrides: [
            extensionsControllerProvider.overrideWith(
              () => _MockExtensionsController(empty),
            ),
            extensionManagerProvider.overrideWith(
              () => _MockExtensionManager(),
            ),
            cloudStreamRepositoryProvider.overrideWith(
              () => _LoadedCloudStream(
                const CloudStreamState(
                  isLoading: false,
                  repositories: [
                    CsRepository(url: _tojiXUrl, name: 'TojiX Repo'),
                  ],
                ),
              ),
            ),
          ],
          child: const MaterialApp(
            localizationsDelegates: AppLocalizations.localizationsDelegates,
            supportedLocales: AppLocalizations.supportedLocales,
            home: ExtensionsScreen(),
          ),
        ),
      );
      await tester.pumpAndSettle();

      // v5: the repository sections live under the "Add Plugins" segment.
      await tester.tap(find.byKey(const ValueKey('plugins-segment-add')));
      await tester.pumpAndSettle();

      expect(find.text('Fuse Repo'), findsOneWidget);
      expect(find.text('Fuse (SkyStream)'), findsOneWidget);
      expect(find.text('TojiX Repo'), findsNothing);
      // No .sky repositories stored: the SkyStream section's empty state
      // names SkyStream now, not Fuse (the Fuse Repo sits above it).
      expect(find.text('No SkyStream repos yet'), findsOneWidget);

      // The Fuse Repo card sits above the SkyStream header.
      final fuseRepo = tester.getTopLeft(find.text('Fuse Repo'));
      final skyHeader = tester.getTopLeft(find.text('Fuse (SkyStream)'));
      expect(fuseRepo.dy, lessThan(skyHeader.dy));
    },
  );
}
