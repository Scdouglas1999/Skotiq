// ignore_for_file: unused_local_variable

import 'package:flutter_riverpod/flutter_riverpod.dart';
import '../database/database.dart';
import '../database/daos/images_dao.dart';
import '../providers/database_provider.dart';

/// Paginated image loader for efficient loading of large image sets
///
/// This class manages pagination state and lazy loading to avoid
/// memory pressure from loading thousands of images at once.
class PaginatedImageLoader {
  static const int defaultPageSize = 50;

  final ImagesDao _imagesDao;
  final int? _sessionId;
  final int pageSize;

  int _currentPage = 0;
  bool _hasMore = true;
  final List<CapturedImage> _loadedImages = [];

  PaginatedImageLoader({
    required ImagesDao imagesDao,
    int? sessionId,
    this.pageSize = defaultPageSize,
  }) : _imagesDao = imagesDao,
       _sessionId = sessionId;

  /// Load the next page of images
  Future<List<CapturedImage>> loadNextPage() async {
    if (!_hasMore) {
      return [];
    }

    final offset = _currentPage * pageSize;

    final List<CapturedImage> page;
    if (_sessionId != null) {
      page = await _imagesDao.getImagesForSessionPaginated(
        sessionId: _sessionId,
        limit: pageSize,
        offset: offset,
      );
    } else {
      page = await _imagesDao.getAllImagesPaginated(
        limit: pageSize,
        offset: offset,
      );
    }

    if (page.length < pageSize) {
      _hasMore = false;
    }

    _loadedImages.addAll(page);
    _currentPage++;

    return page;
  }

  /// Load a specific page (1-indexed)
  Future<List<CapturedImage>> loadPage(int page) async {
    if (page < 1) {
      throw ArgumentError.value(page, 'page', 'Page numbers are 1-indexed');
    }

    final offset = (page - 1) * pageSize;
    final totalCount = await getTotalCount();

    final pageImages = _sessionId != null
        ? await _imagesDao.getImagesForSessionPaginated(
            sessionId: _sessionId,
            limit: pageSize,
            offset: offset,
          )
        : await _imagesDao.getAllImagesPaginated(
            limit: pageSize,
            offset: offset,
          );

    _loadedImages
      ..clear()
      ..addAll(pageImages);
    _currentPage = page;
    _hasMore = offset + pageImages.length < totalCount;
    return pageImages;
  }

  /// Get all currently loaded images
  List<CapturedImage> get loadedImages => List.unmodifiable(_loadedImages);

  /// Check if more pages are available
  bool get hasMore => _hasMore;

  /// Get current page number (0-indexed)
  int get currentPage => _currentPage;

  /// Get total number of loaded images
  int get loadedCount => _loadedImages.length;

  /// Reset pagination state
  void reset() {
    _currentPage = 0;
    _hasMore = true;
    _loadedImages.clear();
  }

  /// Get total image count
  Future<int> getTotalCount() async {
    if (_sessionId != null) {
      return _imagesDao.getImageCountForSession(_sessionId);
    } else {
      return _imagesDao.getImageCount();
    }
  }

  /// Calculate total pages
  Future<int> getTotalPages() async {
    final totalCount = await getTotalCount();
    return (totalCount + pageSize - 1) ~/ pageSize;
  }
}

/// State notifier for paginated image loading
class PaginatedImageState {
  final List<CapturedImage> images;
  final bool isLoading;
  final bool hasMore;
  final int currentPage;
  final int totalCount;
  final String? error;

  const PaginatedImageState({
    required this.images,
    required this.isLoading,
    required this.hasMore,
    required this.currentPage,
    required this.totalCount,
    this.error,
  });

  factory PaginatedImageState.initial() => const PaginatedImageState(
    images: [],
    isLoading: false,
    hasMore: true,
    currentPage: 0,
    totalCount: 0,
  );

  PaginatedImageState copyWith({
    List<CapturedImage>? images,
    bool? isLoading,
    bool? hasMore,
    int? currentPage,
    int? totalCount,
    String? error,
  }) {
    return PaginatedImageState(
      images: images ?? this.images,
      isLoading: isLoading ?? this.isLoading,
      hasMore: hasMore ?? this.hasMore,
      currentPage: currentPage ?? this.currentPage,
      totalCount: totalCount ?? this.totalCount,
      error: error ?? this.error,
    );
  }
}

/// State notifier for managing paginated images
class PaginatedImageNotifier extends StateNotifier<PaginatedImageState> {
  final PaginatedImageLoader _loader;

  PaginatedImageNotifier(this._loader) : super(PaginatedImageState.initial()) {
    _initialize();
  }

  Future<void> _initialize() async {
    final totalCount = await _loader.getTotalCount();
    state = state.copyWith(totalCount: totalCount);
  }

  /// Load next page
  Future<void> loadNextPage() async {
    if (state.isLoading || !state.hasMore) {
      return;
    }

    state = state.copyWith(isLoading: true, error: null);

    try {
      await _loader.loadNextPage();

      state = state.copyWith(
        images: _loader.loadedImages,
        isLoading: false,
        hasMore: _loader.hasMore,
        currentPage: _loader.currentPage,
      );
    } catch (e) {
      state = state.copyWith(isLoading: false, error: e.toString());
    }
  }

  /// Load a specific page
  Future<void> loadPage(int page) async {
    if (state.isLoading) {
      return;
    }

    state = state.copyWith(isLoading: true, error: null);

    try {
      final pageImages = await _loader.loadPage(page);

      state = state.copyWith(
        images: pageImages,
        isLoading: false,
        hasMore: _loader.hasMore,
        currentPage: page,
      );
    } catch (e) {
      state = state.copyWith(isLoading: false, error: e.toString());
    }
  }

  /// Refresh current view
  Future<void> refresh() async {
    _loader.reset();
    final totalCount = await _loader.getTotalCount();
    state = PaginatedImageState.initial().copyWith(totalCount: totalCount);
    await loadNextPage();
  }

  /// Reset to initial state
  void reset() {
    _loader.reset();
    state = PaginatedImageState.initial();
  }
}

/// Provider for paginated session images
final paginatedSessionImagesProvider =
    StateNotifierProvider.family<
      PaginatedImageNotifier,
      PaginatedImageState,
      int?
    >((ref, sessionId) {
      final database = ref.watch(databaseProvider);
      final loader = PaginatedImageLoader(
        imagesDao: database.imagesDao,
        sessionId: sessionId,
      );
      return PaginatedImageNotifier(loader);
    });
