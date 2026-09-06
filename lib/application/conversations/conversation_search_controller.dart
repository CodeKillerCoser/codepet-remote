import '../../core/domain/models.dart';
import '../sessions/device_session.dart';
import '../support/application_notifier.dart';

class ConversationSearchController extends ApplicationNotifier {
  ConversationSearchController({
    required DeviceSession session,
    this.project,
    this.pageSize = 20,
  }) : _session = session {
    _observedLease = session.runtimeLease;
    session.addListener(_sessionChanged);
  }

  final RoutedResourceId? project;
  final int pageSize;
  DeviceSession _session;
  final Map<String, String?> _cursors = {};
  List<ConversationSummary> _conversations = const [];
  String? _query;
  String? _error;
  String? _validationError;
  bool _hasSearched = false;
  bool _isLoading = false;
  int _visibleCount = 20;
  int _requestGeneration = 0;
  bool _disposed = false;
  DeviceSessionRuntimeLease? _observedLease;
  DeviceSessionRuntimeLease? _resultsLease;

  DeviceSession get session => _session;
  List<ConversationSummary> get conversations => _conversations;
  String? get query => _query;
  String? get error => _error;
  String? get validationError => _validationError;
  bool get hasSearched => _hasSearched;
  bool get isLoading => _isLoading;
  int get visibleCount =>
      _visibleCount < _conversations.length
          ? _visibleCount
          : _conversations.length;
  bool get canLoadMore =>
      _cursors.values.any((cursor) => cursor != null) ||
      visibleCount < _conversations.length;
  bool get hasRemoteMore =>
      _cursors.values.any((cursor) => cursor != null);
  bool get online =>
      _session.connectionState == DeviceConnectionState.online;
  bool get supported => online && providers.isNotEmpty;

  List<GatewayProvider> get providers {
    final provider = _session.selectedProvider;
    if (provider == null ||
        !provider.methods.contains('conversation.search')) {
      return const [];
    }
    return [provider];
  }

  void replaceSession(DeviceSession session) {
    if (identical(_session, session)) return;
    _session.removeListener(_sessionChanged);
    _session = session;
    _session.addListener(_sessionChanged);
    _observedLease = _session.runtimeLease;
    _requestGeneration++;
    _clearRuntimeState();
    notifyApplicationListeners();
  }

  void _sessionChanged() {
    final nextLease = _session.runtimeLease;
    if (_sameLease(_observedLease, nextLease)) {
      if (_refreshConversationProjections()) {
        notifyApplicationListeners();
      }
      return;
    }
    _observedLease = nextLease;
    _requestGeneration++;
    _clearRuntimeState();
    notifyApplicationListeners();
  }

  bool _refreshConversationProjections() {
    if (_conversations.isEmpty || _session.conversations.isEmpty) return false;
    // Search controls membership; the session remains the live source for each
    // matching conversation's title, preview, status, and turn projection.
    final currentByKey = {
      for (final conversation in _session.conversations)
        conversationRoutingKey(conversation): conversation,
    };
    var changed = false;
    final next = <ConversationSummary>[];
    for (final conversation in _conversations) {
      final replacement = currentByKey[conversationRoutingKey(conversation)];
      if (replacement != null && !identical(conversation, replacement)) {
        next.add(replacement);
        changed = true;
      } else {
        next.add(conversation);
      }
    }
    if (changed) {
      _conversations = sortRecentConversations(next);
    }
    return changed;
  }

  void _clearRuntimeState() {
    _query = null;
    _error = null;
    _validationError = null;
    _hasSearched = false;
    _isLoading = false;
    _visibleCount = pageSize;
    _resultsLease = null;
    _conversations = const [];
    _cursors.clear();
  }

  bool _sameLease(
    DeviceSessionRuntimeLease? left,
    DeviceSessionRuntimeLease? right,
  ) => left?.sameRuntime(right) ?? right == null;

  bool _acceptsResult(
    int requestGeneration,
    DeviceSessionRuntimeLease lease,
    String query,
  ) =>
      !_disposed &&
      requestGeneration == _requestGeneration &&
      _query == query &&
      _session.ownsRuntimeLease(lease);

  Future<void> search(String rawQuery) async {
    final query = rawQuery.trim();
    if (query.isEmpty) {
      _validationError = '请输入搜索关键词';
      notifyApplicationListeners();
      return;
    }
    final lease = _session.runtimeLease;
    if (lease == null || providers.isEmpty || _isLoading) return;

    final selectedProviders = providers;
    final requestGeneration = ++_requestGeneration;
    _query = query;
    _validationError = null;
    _error = null;
    _hasSearched = true;
    _isLoading = true;
    _visibleCount = pageSize;
    _resultsLease = null;
    _conversations = const [];
    _cursors.clear();
    final stopwatch = Stopwatch()..start();
    _session.logger.fine(
      'Conversation search started for device ${_session.device.deviceId} '
      'providerCount=${selectedProviders.length} queryLength=${query.length}',
    );
    notifyApplicationListeners();
    try {
      final pages = await Future.wait([
        for (final provider in selectedProviders)
          lease.searchConversations(
            providerId: provider.id,
            searchTerm: query,
            limit: pageSize,
          ),
      ]);
      if (!_acceptsResult(requestGeneration, lease, query)) return;
      var conversations = const <ConversationSummary>[];
      final cursors = <String, String?>{};
      for (var index = 0; index < pages.length; index++) {
        conversations = mergeRoutedConversations(
          conversations,
          _inScope(pages[index].conversations),
        );
        cursors[selectedProviders[index].id] = pages[index].nextCursor;
      }
      _resultsLease = lease;
      _conversations = conversations;
      _cursors
        ..clear()
        ..addAll(cursors);
      _session.mergeDiscoveredConversations(
        pages.expand((page) => page.conversations),
        lease: lease,
      );
      _session.logger.fine(
        'Conversation search completed for device '
        '${_session.device.deviceId} results=${conversations.length} '
        'elapsedMs=${stopwatch.elapsedMilliseconds}',
      );
    } catch (error, stackTrace) {
      if (_acceptsResult(requestGeneration, lease, query)) {
        _error = error.toString();
        _session.logger.warning(
          'Conversation search failed for device ${_session.device.deviceId} '
          'providerCount=${selectedProviders.length} '
          'queryLength=${query.length} '
          'elapsedMs=${stopwatch.elapsedMilliseconds}',
          error: error,
          stackTrace: stackTrace,
        );
      }
    } finally {
      if (_acceptsResult(requestGeneration, lease, query)) {
        _isLoading = false;
        notifyApplicationListeners();
      }
    }
  }

  Future<void> loadMore() async {
    if (_isLoading) return;
    final lease = _session.runtimeLease;
    if (lease == null ||
        _resultsLease == null ||
        !_sameLease(lease, _resultsLease) ||
        !_session.ownsRuntimeLease(lease)) {
      _clearRuntimeState();
      notifyApplicationListeners();
      return;
    }
    final pendingRoutes = _cursors.entries
        .where((entry) => entry.value != null)
        .toList(growable: false);
    if (pendingRoutes.isEmpty) {
      if (_visibleCount < _conversations.length) {
        _visibleCount += pageSize;
        notifyApplicationListeners();
      }
      return;
    }
    final query = _query;
    if (query == null) return;

    final requestGeneration = ++_requestGeneration;
    _isLoading = true;
    _error = null;
    final stopwatch = Stopwatch()..start();
    notifyApplicationListeners();
    try {
      final pages = await Future.wait([
        for (final entry in pendingRoutes)
          lease.searchConversations(
            providerId: entry.key,
            searchTerm: query,
            cursor: entry.value,
            limit: pageSize,
          ),
      ]);
      if (!_acceptsResult(requestGeneration, lease, query)) return;
      var conversations = _conversations;
      final cursors = Map<String, String?>.from(_cursors);
      for (var index = 0; index < pages.length; index++) {
        conversations = mergeRoutedConversations(
          conversations,
          _inScope(pages[index].conversations),
        );
        cursors[pendingRoutes[index].key] = pages[index].nextCursor;
      }
      _resultsLease = lease;
      _conversations = conversations;
      _cursors
        ..clear()
        ..addAll(cursors);
      _session.mergeDiscoveredConversations(
        pages.expand((page) => page.conversations),
        lease: lease,
      );
      _visibleCount += pageSize;
      _session.logger.fine(
        'Conversation search page loaded for device '
        '${_session.device.deviceId} routes=${pendingRoutes.length} '
        'total=${conversations.length} '
        'elapsedMs=${stopwatch.elapsedMilliseconds}',
      );
    } catch (error, stackTrace) {
      if (_acceptsResult(requestGeneration, lease, query)) {
        _error = error.toString();
        _session.logger.warning(
          'Conversation search pagination failed for device '
          '${_session.device.deviceId} routes=${pendingRoutes.length} '
          'elapsedMs=${stopwatch.elapsedMilliseconds}',
          error: error,
          stackTrace: stackTrace,
        );
      }
    } finally {
      if (_acceptsResult(requestGeneration, lease, query)) {
        _isLoading = false;
        notifyApplicationListeners();
      }
    }
  }

  bool get resultsAreCurrent {
    final lease = _session.runtimeLease;
    return lease != null &&
        _resultsLease != null &&
        _sameLease(lease, _resultsLease) &&
        _session.ownsRuntimeLease(lease);
  }

  Iterable<ConversationSummary> _inScope(
    Iterable<ConversationSummary> conversations,
  ) {
    final project = this.project;
    return project == null
        ? conversations
        : conversations.where(
            (conversation) => conversation.project == project,
          );
  }

  @override
  void dispose() {
    _disposed = true;
    _requestGeneration++;
    _session.removeListener(_sessionChanged);
    _cursors.clear();
    _conversations = const [];
    super.dispose();
  }
}
