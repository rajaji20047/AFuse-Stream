import 'package:dio/dio.dart';
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:raja/core/cloudstream/cloudstream_repository.dart';
import 'package:raja/core/domain/entity/multimedia_item.dart';
import 'package:raja/core/extensions/base_provider.dart';
import 'package:raja/core/extensions/extension_manager.dart';
import 'package:raja/core/extensions/models/extension_plugin.dart';
import 'package:raja/core/extensions/models/extension_repository.dart';
import 'package:raja/core/providers/device_info_provider.dart';
import 'package:raja/features/extensions/providers/extensions_controller.dart';
import 'package:raja/features/home/presentation/home_provider.dart';
import 'package:raja/features/home/presentation/home_screen.dart';
import 'package:raja/features/home/presentation/home_state.dart';
import 'package:raja/l10n/generated/app_localizations.dart';

/// Enough rows to overflow the dialog so the list can actually fling.
const int _providerCount = 40;

class _FakeProvider extends SkyStreamProvider {
  final int index;
  _FakeProvider(this.index);

  @override
  String get packageName => 'fake.provider.$index';
  @override
  String get name => 'Provider $index';
  @override
  String get mainUrl => 'https://fake.test/$index';
  @override
  String get version => '1.0.0';
  @override
  List<String> get languages => const ['en'];
  @override
  Set<ProviderType> get supportedTypes =>
      index.isEven ? {ProviderType.movie} : {ProviderType.series};

  @override
  Future<List<MultimediaItem>> search(
    String query, {
    CancelToken? cancelToken,
  }) => throw UnimplementedError();
  @override
  Future<Map<String, List<MultimediaItem>>> getHome() =>
      throw UnimplementedError();
  @override
  Future<MultimediaItem> getDetails(String url) => throw UnimplementedError();
  @override
  Future<List<StreamResult>> loadStreams(String url) =>
      throw UnimplementedError();
}

/// The real notifiers reach for Hive-backed storage on every write; these
/// keep the state transitions and drop the persistence.
class _FakeHomeFilter extends HomeFilter {
  @override
  ProviderType? build() => null;

  @override
  Future<void> setFilter(ProviderType? type) async {
    state = type;
  }
}

class _FakeActiveProvider extends ActiveProvider {
  @override
  SkyStreamProvider? build() => null;

  @override
  Future<void> set(SkyStreamProvider? provider) async {
    state = provider;
  }
}

class _FakeHomeData extends HomeData {
  @override
  HomeState build() => const HomeNoProvider();
}

class _FakeExtensionsController extends ExtensionsController {
  final List<ExtensionPlugin> plugins;
  final List<ExtensionRepository> repos;

  _FakeExtensionsController({
    this.plugins = const [],
    this.repos = const [],
  });

  @override
  ExtensionsState build() => ExtensionsSuccess(
    installedPlugins: plugins,
    repositories: repos,
    availablePlugins: {},
    availableUpdates: {},
  );

  @override
  Future<void> ensureInitialized() async {}
}

/// The dialog also watches the CloudStream repositories for the row
/// subtitle; the real one starts a load on build, so it is faked with no
/// repos, like the extensions controller above.
class _FakeCloudStreamRepository extends CloudStreamRepository {
  @override
  CloudStreamState build() => const CloudStreamState();
}

class _Host extends StatelessWidget {
  final VoidCallback onClosed;
  const _Host({required this.onClosed});

  @override
  Widget build(BuildContext context) => Scaffold(
    body: Center(
      child: TextButton(
        onPressed: () async {
          await showProviderSelectorDialog(
            context,
            providers: List.generate(_providerCount, _FakeProvider.new),
            activeProvider: null,
          );
          onClosed();
        },
        child: const Text('open'),
      ),
    ),
  );
}

Future<ProviderContainer> _pumpHost(
  WidgetTester tester, {
  required VoidCallback onClosed,
  List<ExtensionPlugin> installedPlugins = const [],
  List<ExtensionRepository> repositories = const [],
}) async {
  final container = ProviderContainer(
    overrides: [
      homeFilterProvider.overrideWith(_FakeHomeFilter.new),
      activeProviderProvider.overrideWith(_FakeActiveProvider.new),
      homeDataProvider.overrideWith(_FakeHomeData.new),
      extensionsControllerProvider.overrideWith(
        () => _FakeExtensionsController(
          plugins: installedPlugins,
          repos: repositories,
        ),
      ),
      cloudStreamRepositoryProvider.overrideWith(
        _FakeCloudStreamRepository.new,
      ),
      deviceProfileProvider.overrideWithValue(
        const AsyncValue.data(DeviceProfile()),
      ),
    ],
  );
  addTearDown(container.dispose);

  await tester.pumpWidget(
    UncontrolledProviderScope(
      container: container,
      child: MaterialApp(
        localizationsDelegates: AppLocalizations.localizationsDelegates,
        supportedLocales: AppLocalizations.supportedLocales,
        home: _Host(onClosed: onClosed),
      ),
    ),
  );
  await tester.tap(find.text('open'));
  await tester.pumpAndSettle();
  return container;
}

void main() {
  // Build 111 (user 2026-11-21 04:04: "provider se lightning effect
  // hatao"): the bolt is gone — the dialog is plain, the list renders
  // and nothing keeps animating behind it.
  testWidgets('no lightning behind the list', (tester) async {
    await _pumpHost(tester, onClosed: () {});
    expect(find.text('None'), findsOneWidget);
    expect(find.text('Select Provider'), findsOneWidget);
    await tester.pumpAndSettle();
    expect(tester.hasRunningAnimations, isFalse);
  });

  testWidgets('closing during a fling survives the exit transition', (
    tester,
  ) async {
    var closed = false;
    await _pumpHost(tester, onClosed: () => closed = true);

    // A disposed ScrollController drops off its positions, so it only bites
    // once a Scrollable re-attaches to it. Every Scrollable does exactly that
    // when the device pixel ratio changes - a window crossing to another
    // display - and the ballistic fling still in flight then notifies the
    // dead controller on the next frame. With the dialog already popped, a
    // controller disposed in `.then` of `showDialog` died right here.
    await tester.fling(find.byType(ListView), const Offset(0, -300), 2000);
    await tester.tap(find.text('Close'));
    addTearDown(tester.view.reset);
    tester.view.devicePixelRatio = 2.0;

    await tester.pump();
    expect(tester.takeException(), isNull);
    await tester.pump();
    expect(tester.takeException(), isNull);

    await tester.pumpAndSettle();
    expect(closed, isTrue);
    expect(find.byType(AlertDialog), findsNothing);
  });

  testWidgets('filtering then picking a provider selects it and pops', (
    tester,
  ) async {
    var closed = false;
    final container = await _pumpHost(tester, onClosed: () => closed = true);

    // 'None' is the auto-focused row when nothing is active, which is the
    // D-pad landing spot on TV.
    expect(Focus.of(tester.element(find.text('None'))).hasFocus, isTrue);

    await tester.fling(
      // The type chips' own row: the dialog now has a second horizontal
      // row (the add-on grouping chips), so the bare SingleChildScrollView
      // finder matches two.
      find.ancestor(
        of: find.text('Movies'),
        matching: find.byType(SingleChildScrollView),
      ),
      const Offset(-200, 0),
      1500,
    );
    await tester.pumpAndSettle();
    await tester.tap(find.text('Movies'));
    await tester.pumpAndSettle();
    expect(find.text('None'), findsNothing);
    expect(find.text('Provider 1'), findsNothing);

    // Read while the dialog still watches it: the filter is autoDispose and
    // resets once its last listener goes away with the route.
    expect(container.read(homeFilterProvider), ProviderType.movie);

    await tester.tap(find.text('Provider 2'));
    await tester.pump();
    expect(tester.takeException(), isNull);
    await tester.pumpAndSettle();

    expect(closed, isTrue);
    expect(
      container.read(activeProviderProvider)?.packageName,
      'fake.provider.2',
    );
  });

  testWidgets(
    'each row falls back to its add-on under the provider when it has no repository',
    (tester) async {
      await _pumpHost(tester, onClosed: () {});

      // No plugins are installed in the test, so no fake provider has a
      // repository recorded — each falls back to its package name as its
      // add-on, shown as the row subtitle, not in the grouping chip row
      // above the list.
      expect(
        find.descendant(
          of: find.byType(ListView),
          matching: find.text('fake.provider.2'),
        ),
        findsOneWidget,
      );
    },
  );

  testWidgets('each row names its repository under the provider', (
    tester,
  ) async {
    await _pumpHost(
      tester,
      onClosed: () {},
      installedPlugins: [
        ExtensionPlugin(
          packageName: 'fake.provider.2',
          name: 'Provider 2',
          repositoryId: 'example',
          repositoryUrl: 'https://example.com/repo.json',
          sourceUrl: 'https://example.com/plugin.zip',
          version: 1,
        ),
      ],
      repositories: [
        ExtensionRepository(
          name: 'Example Repo',
          url: 'https://example.com/repo.json',
          pluginLists: const [],
        ),
      ],
    );

    // Provider 2's plugin was installed from Example Repo, so the row
    // subtitle names the repo — not the add-on, which would repeat the
    // provider's own name here.
    expect(
      find.descendant(
        of: find.byType(ListView),
        matching: find.text('Example Repo'),
      ),
      findsOneWidget,
    );
    expect(
      find.descendant(
        of: find.byType(ListView),
        matching: find.text('fake.provider.2'),
      ),
      findsNothing,
    );
  });

  testWidgets('grouping by add-on filters the list, re-tap clears it', (
    tester,
  ) async {
    await _pumpHost(tester, onClosed: () {});

    final chip = find.widgetWithText(FilterChip, 'fake.provider.2');
    await tester.ensureVisible(chip);
    await tester.pumpAndSettle();
    await tester.tap(chip);
    await tester.pumpAndSettle();
    expect(find.text('Provider 2'), findsOneWidget);
    expect(find.text('Provider 3'), findsNothing);
    // The None row belongs to no add-on, so it hides with a grouping on.
    expect(find.text('None'), findsNothing);

    await tester.tap(chip);
    await tester.pumpAndSettle();
    expect(find.text('None'), findsOneWidget);
    expect(find.text('Provider 3'), findsOneWidget);
  });
}
