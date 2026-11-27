import 'package:riverpod_annotation/riverpod_annotation.dart';

import '../../../../core/domain/entity/multimedia_item.dart';
import '../../../../core/extensions/extension_manager.dart';
import '../../../../core/extensions/providers/vega_based_provider.dart';
import '../../data/explore_tmdb_provider.dart';
import '../../data/explore_language_provider.dart';
import '../../data/explore_filter_provider.dart';
import '../view_all_screen.dart'; // for ViewAllCategory

part 'view_all_controller.g.dart';

class ViewAllState {
  final ViewAllCategory? category;
  final List<MultimediaItem> items;
  final int page;
  final bool isLoading;
  final bool hasMore;

  /// The provider a providerContent page came from, and the catalog
  /// section title (the Home row title). Null for TMDB categories and for
  /// provider rows that do not paginate.
  final String? providerPackageName;
  final String? sectionTitle;

  const ViewAllState({
    this.category,
    this.items = const [],
    this.page = 1,
    this.isLoading = false,
    this.hasMore = true,
    this.providerPackageName,
    this.sectionTitle,
  });

  ViewAllState copyWith({
    ViewAllCategory? category,
    List<MultimediaItem>? items,
    int? page,
    bool? isLoading,
    bool? hasMore,
    String? providerPackageName,
    String? sectionTitle,
  }) {
    return ViewAllState(
      category: category ?? this.category,
      items: items ?? this.items,
      page: page ?? this.page,
      isLoading: isLoading ?? this.isLoading,
      hasMore: hasMore ?? this.hasMore,
      providerPackageName: providerPackageName ?? this.providerPackageName,
      sectionTitle: sectionTitle ?? this.sectionTitle,
    );
  }
}

@riverpod
class ViewAllController extends _$ViewAllController {
  @override
  ViewAllState build(ViewAllCategory category) {
    ref.watch(languageProvider);
    ref.watch(exploreFilterProvider);
    return ViewAllState(category: category);
  }

  void init(
    List<MultimediaItem> initialItems, {
    String? providerPackageName,
    String? sectionTitle,
  }) {
    if (state.items.isEmpty && state.page == 1) {
      // Provider content has no TMDB pagination. A Vega section paginates
      // through the provider's catalog instead; anything else shows only
      // the initial items.
      final hasMore = category == ViewAllCategory.providerContent
          ? providerPackageName != null &&
              _vegaProvider(providerPackageName) != null
          : true;
      state = state.copyWith(
        items: List.from(initialItems),
        hasMore: hasMore,
        providerPackageName: providerPackageName,
        sectionTitle: sectionTitle,
      );
    }
  }

  /// The installed Vega provider for [packageName], or null when it is not
  /// installed or is not a Vega provider (e.g. a .sky plugin, which has no
  /// catalog paging API).
  VegaBasedProvider? _vegaProvider(String packageName) {
    final provider =
        ref.read(extensionManagerProvider.notifier).getProvider(packageName);
    return provider is VegaBasedProvider ? provider : null;
  }

  Future<void> fetchNextPage() async {
    if (state.isLoading || !state.hasMore) return;

    state = state.copyWith(isLoading: true);

    try {
      final tmdbService = ref.read(tmdbServiceProvider);
      final lang = ref.read(languageProvider);
      final filters = ref.read(exploreFilterProvider);
      final bool isEmpty = state.items.isEmpty;
      final nextPage = isEmpty ? 1 : state.page + 1;
      List<MultimediaItem> newItems = [];

      switch (category) {
        case ViewAllCategory.popularMovies:
          newItems = await tmdbService.getPopularMovies(
            language: lang,
            genreId: filters.selectedGenre?.id,
            year: filters.selectedYear,
            minRating: filters.minRating,
            page: nextPage,
          );
          break;
        case ViewAllCategory.popularTV:
          newItems = await tmdbService.getPopularTV(
            language: lang,
            genreId: filters.selectedGenre?.id,
            year: filters.selectedYear,
            minRating: filters.minRating,
            page: nextPage,
          );
          break;
        case ViewAllCategory.nowPlayingMovies:
          newItems = await tmdbService.getNowPlayingMovies(
            language: lang,
            genreId: filters.selectedGenre?.id,
            year: filters.selectedYear,
            minRating: filters.minRating,
            page: nextPage,
          );
          break;
        case ViewAllCategory.onTheAirTV:
          newItems = await tmdbService.getOnTheAirTV(
            language: lang,
            genreId: filters.selectedGenre?.id,
            year: filters.selectedYear,
            minRating: filters.minRating,
            page: nextPage,
          );
          break;
        case ViewAllCategory.topRatedMovies:
          newItems = await tmdbService.getTopRated(
            language: lang,
            genreId: filters.selectedGenre?.id,
            year: filters.selectedYear,
            minRating: filters.minRating,
            page: nextPage,
          );
          break;
        case ViewAllCategory.topRatedTV:
          newItems = await tmdbService.getTopRatedTV(
            language: lang,
            genreId: filters.selectedGenre?.id,
            year: filters.selectedYear,
            minRating: filters.minRating,
            page: nextPage,
          );
          break;
        case ViewAllCategory.airingTodayTV:
          newItems = await tmdbService.getAiringTodayTV(
            language: lang,
            genreId: filters.selectedGenre?.id,
            year: filters.selectedYear,
            minRating: filters.minRating,
            page: nextPage,
          );
          break;
        case ViewAllCategory.trending:
          newItems = await tmdbService.getTrending(
            language: lang,
            genreId: filters.selectedGenre?.id,
            year: filters.selectedYear,
            minRating: filters.minRating,
            page: nextPage,
          );
          break;
        case ViewAllCategory.trendingTV:
          newItems = await tmdbService.getTrendingTV(
            language: lang,
            genreId: filters.selectedGenre?.id,
            year: filters.selectedYear,
            minRating: filters.minRating,
            page: nextPage,
          );
          break;
        case ViewAllCategory.providerContent:
          final providerPackageName = state.providerPackageName;
          final sectionTitle = state.sectionTitle;
          if (providerPackageName == null || sectionTitle == null) {
            // No paginatable source (e.g. a .sky row): fully loaded at init.
            state = state.copyWith(hasMore: false, isLoading: false);
            return;
          }
          final provider = _vegaProvider(providerPackageName);
          if (provider == null) {
            state = state.copyWith(hasMore: false, isLoading: false);
            return;
          }
          newItems = await provider.getCatalogPage(sectionTitle, nextPage);
          // A provider may repeat items across pages: only new URLs join
          // the list, so a page of pure repeats reads as the end.
          final seenUrls = state.items.map((i) => i.url).toSet();
          newItems = newItems.where((i) => !seenUrls.contains(i.url)).toList();
          break;
      }

      if (newItems.isEmpty) {
        state = state.copyWith(hasMore: false, isLoading: false);
      } else {
        state = state.copyWith(
          items: [...state.items, ...newItems],
          page: nextPage,
          isLoading: false,
        );
      }
    } catch (e) {
      state = state.copyWith(isLoading: false);
    }
  }
}
