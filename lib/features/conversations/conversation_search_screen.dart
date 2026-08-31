import 'dart:async';

import 'package:flutter/material.dart';

import '../../devices/device_session.dart';
import '../../gateway/models.dart';
import 'conversation_detail_screen.dart';

class ConversationSearchScreen extends StatefulWidget {
  const ConversationSearchScreen({
    super.key,
    required this.session,
  });

  final DeviceSession session;

  @override
  State<ConversationSearchScreen> createState() =>
      _ConversationSearchScreenState();
}

class _ConversationSearchScreenState extends State<ConversationSearchScreen> {
  static const int _pageSize = 20;

  final TextEditingController _searchController = TextEditingController();
  final Map<GatewayProviderRoute, String?> _cursors = {};
  List<ConversationSummary> _conversations = const [];
  String? _query;
  String? _error;
  String? _validationError;
  bool _hasSearched = false;
  bool _isLoading = false;
  int _visibleCount = _pageSize;
  int _requestGeneration = 0;
  DeviceSessionRuntimeLease? _observedLease;
  DeviceSessionRuntimeLease? _resultsLease;

  List<GatewayProvider> get _providers =>
      widget.session.conversationSearchProviders;

  bool get _canLoadMore =>
      _cursors.values.any((cursor) => cursor != null);

  @override
  void initState() {
    super.initState();
    _observedLease = widget.session.runtimeLease;
    widget.session.addListener(_sessionChanged);
  }

  @override
  void didUpdateWidget(ConversationSearchScreen oldWidget) {
    super.didUpdateWidget(oldWidget);
    if (oldWidget.session == widget.session) return;
    oldWidget.session.removeListener(_sessionChanged);
    widget.session.addListener(_sessionChanged);
    _observedLease = widget.session.runtimeLease;
    _requestGeneration++;
    _clearRuntimeState();
  }

  @override
  void dispose() {
    widget.session.removeListener(_sessionChanged);
    _requestGeneration++;
    _searchController.dispose();
    _cursors.clear();
    _conversations = const [];
    super.dispose();
  }

  void _sessionChanged() {
    final nextLease = widget.session.runtimeLease;
    if (_sameLease(_observedLease, nextLease)) return;
    _observedLease = nextLease;
    _requestGeneration++;
    if (!mounted) return;
    setState(_clearRuntimeState);
  }

  void _clearRuntimeState() {
    _query = null;
    _error = null;
    _validationError = null;
    _hasSearched = false;
    _isLoading = false;
    _visibleCount = _pageSize;
    _resultsLease = null;
    _conversations = const [];
    _cursors.clear();
  }

  bool _sameLease(
    DeviceSessionRuntimeLease? left,
    DeviceSessionRuntimeLease? right,
  ) =>
      left?.generation == right?.generation &&
      identical(left?.client, right?.client);

  bool _acceptsResult(
    int requestGeneration,
    DeviceSessionRuntimeLease lease,
    String query,
  ) =>
      mounted &&
      requestGeneration == _requestGeneration &&
      _query == query &&
      widget.session.ownsRuntimeLease(lease);

  Future<void> _search() async {
    final query = _searchController.text.trim();
    if (query.isEmpty) {
      setState(() {
        _validationError = '请输入搜索关键词';
      });
      return;
    }
    final lease = widget.session.runtimeLease;
    if (lease == null ||
        _providers.isEmpty ||
        _isLoading) {
      return;
    }

    final providers = _providers;
    final requestGeneration = ++_requestGeneration;
    setState(() {
      _query = query;
      _validationError = null;
      _error = null;
      _hasSearched = true;
      _isLoading = true;
      _visibleCount = _pageSize;
      _resultsLease = null;
      _conversations = const [];
      _cursors.clear();
    });
    try {
      final pages = await Future.wait([
        for (final provider in providers)
          lease.client.searchConversations(
            route: provider.route,
            searchTerm: query,
            limit: _pageSize,
          ),
      ]);
      if (!_acceptsResult(requestGeneration, lease, query)) return;
      var conversations = const <ConversationSummary>[];
      final cursors = <GatewayProviderRoute, String?>{};
      for (var index = 0; index < pages.length; index++) {
        conversations = mergeRoutedConversations(
          conversations,
          pages[index].conversations,
        );
        cursors[providers[index].route] = pages[index].nextCursor;
      }
      setState(() {
        _resultsLease = lease;
        _conversations = conversations;
        _cursors
          ..clear()
          ..addAll(cursors);
      });
    } catch (value) {
      if (_acceptsResult(requestGeneration, lease, query)) {
        setState(() {
          _error = value.toString();
        });
      }
    } finally {
      if (_acceptsResult(requestGeneration, lease, query)) {
        setState(() {
          _isLoading = false;
        });
      }
    }
  }

  Future<void> _loadMore() async {
    if (_isLoading) return;
    final lease = widget.session.runtimeLease;
    if (lease == null ||
        _resultsLease == null ||
        !_sameLease(lease, _resultsLease) ||
        !widget.session.ownsRuntimeLease(lease)) {
      setState(_clearRuntimeState);
      return;
    }
    final pendingRoutes = _cursors.entries
        .where((entry) => entry.value != null)
        .toList(growable: false);
    if (pendingRoutes.isEmpty) {
      if (_visibleCount < _conversations.length) {
        setState(() {
          _visibleCount += _pageSize;
        });
      }
      return;
    }
    final query = _query;
    if (query == null) return;

    final requestGeneration = ++_requestGeneration;
    setState(() {
      _isLoading = true;
      _error = null;
    });
    try {
      final pages = await Future.wait([
        for (final entry in pendingRoutes)
          lease.client.searchConversations(
            route: entry.key,
            searchTerm: query,
            cursor: entry.value,
            limit: _pageSize,
          ),
      ]);
      if (!_acceptsResult(requestGeneration, lease, query)) return;
      var conversations = _conversations;
      final cursors = Map<GatewayProviderRoute, String?>.from(_cursors);
      for (var index = 0; index < pages.length; index++) {
        conversations = mergeRoutedConversations(
          conversations,
          pages[index].conversations,
        );
        cursors[pendingRoutes[index].key] = pages[index].nextCursor;
      }
      setState(() {
        _resultsLease = lease;
        _conversations = conversations;
        _cursors
          ..clear()
          ..addAll(cursors);
        _visibleCount += _pageSize;
      });
    } catch (value) {
      if (_acceptsResult(requestGeneration, lease, query)) {
        setState(() {
          _error = value.toString();
        });
      }
    } finally {
      if (_acceptsResult(requestGeneration, lease, query)) {
        setState(() {
          _isLoading = false;
        });
      }
    }
  }

  void _openConversation(ConversationSummary conversation) {
    final lease = widget.session.runtimeLease;
    if (lease == null ||
        _resultsLease == null ||
        !_sameLease(lease, _resultsLease) ||
        !widget.session.ownsRuntimeLease(lease)) {
      ScaffoldMessenger.of(context).showSnackBar(
        const SnackBar(content: Text('搜索结果已失效，请重新搜索')),
      );
      return;
    }
    Navigator.of(context).push<void>(
      MaterialPageRoute(
        builder: (_) => ConversationDetailScreen(
          client: lease.client,
          conversation: conversation,
        ),
      ),
    );
  }

  @override
  Widget build(BuildContext context) {
    final online =
        widget.session.connectionState == DeviceConnectionState.online;
    final supported = online && _providers.isNotEmpty;
    return Scaffold(
      appBar: AppBar(
        title: const Text('搜索会话'),
        actions: [
          if (_hasSearched)
            IconButton(
              key: const Key('search-refresh'),
              tooltip: '重新搜索',
              onPressed: _isLoading ? null : () => unawaited(_search()),
              icon: const Icon(Icons.refresh),
            ),
        ],
      ),
      body: Column(
        children: [
          Padding(
            padding: const EdgeInsets.fromLTRB(16, 8, 16, 12),
            child: TextField(
              key: const Key('search-input'),
              controller: _searchController,
              enabled: supported,
              textInputAction: TextInputAction.search,
              autofocus: supported,
              decoration: InputDecoration(
                labelText: '搜索 Host 上的会话',
                hintText: '输入标题或会话内容关键词',
                errorText: _validationError,
                prefixIcon: const Icon(Icons.search),
                suffixIcon: IconButton(
                  key: const Key('search-submit'),
                  tooltip: '搜索',
                  onPressed:
                      supported && !_isLoading ? () => unawaited(_search()) : null,
                  icon: const Icon(Icons.arrow_forward),
                ),
              ),
              onSubmitted: (_) => unawaited(_search()),
            ),
          ),
          Expanded(child: _buildBody(online: online, supported: supported)),
        ],
      ),
    );
  }

  Widget _buildBody({required bool online, required bool supported}) {
    if (!online) {
      return const _SearchMessage(
        key: Key('search-offline'),
        icon: Icons.link_off_outlined,
        title: '设备未连接',
        message: '连接设备后才能搜索 Host 上的会话。',
      );
    }
    if (!supported) {
      return const _SearchMessage(
        key: Key('search-unsupported'),
        icon: Icons.search_off_outlined,
        title: '此设备不支持会话搜索',
        message: 'Host 上没有 Provider 广告 conversation.search 能力。',
      );
    }
    if (!_hasSearched) {
      return const _SearchMessage(
        icon: Icons.manage_search_outlined,
        title: '搜索远程会话',
        message: '搜索由各 Provider 在 Host 上执行，结果不会加入首页最近列表。',
      );
    }
    if (_isLoading && _conversations.isEmpty) {
      return const Center(child: CircularProgressIndicator());
    }
    if (_error != null && _conversations.isEmpty) {
      return _SearchMessage(
        key: const Key('search-error'),
        icon: Icons.error_outline,
        title: '搜索失败',
        message: _error!,
        actionLabel: '重试',
        onAction: () => unawaited(_search()),
      );
    }

    final visibleCount = _visibleCount < _conversations.length
        ? _visibleCount
        : _conversations.length;
    final hasMore = _canLoadMore || visibleCount < _conversations.length;
    if (_conversations.isEmpty) {
      return ListView(
        physics: const AlwaysScrollableScrollPhysics(),
        padding: const EdgeInsets.all(16),
        children: [
          const SizedBox(height: 80),
          _SearchMessage(
            key: const Key('search-empty'),
            icon: Icons.forum_outlined,
            title: '没有搜索结果',
            message: '没有找到与“$_query”匹配的会话。',
          ),
          if (_error != null) _InlineError(message: _error!),
          if (hasMore) _SearchPagination(loading: _isLoading, onPressed: _loadMore),
        ],
      );
    }
    return ListView.separated(
      key: const Key('search-results'),
      padding: const EdgeInsets.fromLTRB(16, 4, 16, 24),
      itemCount: visibleCount + 1 + (hasMore ? 1 : 0) + (_error == null ? 0 : 1),
      separatorBuilder: (_, _) => const SizedBox(height: 8),
      itemBuilder: (context, index) {
        if (index == 0) {
          return Text(
            '${_conversations.length}${_canLoadMore ? '+' : ''} 个结果',
            key: const Key('search-count'),
            style: Theme.of(context).textTheme.bodySmall,
          );
        }
        var dataIndex = index - 1;
        if (_error != null) {
          if (dataIndex == 0) return _InlineError(message: _error!);
          dataIndex--;
        }
        if (dataIndex < visibleCount) {
          final conversation = _conversations[dataIndex];
          return Card(
            key: Key('search-result-${conversationRoutingKey(conversation)}'),
            margin: EdgeInsets.zero,
            elevation: 0,
            child: ListTile(
              leading: const Icon(Icons.chat_bubble_outline),
              title: Text(
                conversation.title,
                maxLines: 1,
                overflow: TextOverflow.ellipsis,
              ),
              subtitle: Text(
                conversation.preview ??
                    conversation.workspaceRoot ??
                    '无 workspaceRoot',
                maxLines: 1,
                overflow: TextOverflow.ellipsis,
              ),
              onTap: () => _openConversation(conversation),
            ),
          );
        }
        return _SearchPagination(
          loading: _isLoading,
          onPressed: _loadMore,
        );
      },
    );
  }
}

class _SearchPagination extends StatelessWidget {
  const _SearchPagination({
    required this.loading,
    required this.onPressed,
  });

  final bool loading;
  final VoidCallback onPressed;

  @override
  Widget build(BuildContext context) => Center(
        child: TextButton.icon(
          key: const Key('search-show-more'),
          onPressed: loading ? null : onPressed,
          icon: loading
              ? const SizedBox.square(
                  dimension: 16,
                  child: CircularProgressIndicator(strokeWidth: 2),
                )
              : const Icon(Icons.expand_more),
          label: Text(loading ? '加载中…' : '显示更多'),
        ),
      );
}

class _InlineError extends StatelessWidget {
  const _InlineError({required this.message});

  final String message;

  @override
  Widget build(BuildContext context) => Text(
        '加载失败：$message',
        key: const Key('search-inline-error'),
        textAlign: TextAlign.center,
        style: TextStyle(color: Theme.of(context).colorScheme.error),
      );
}

class _SearchMessage extends StatelessWidget {
  const _SearchMessage({
    super.key,
    required this.icon,
    required this.title,
    required this.message,
    this.actionLabel,
    this.onAction,
  });

  final IconData icon;
  final String title;
  final String message;
  final String? actionLabel;
  final VoidCallback? onAction;

  @override
  Widget build(BuildContext context) => Center(
        child: Padding(
          padding: const EdgeInsets.all(24),
          child: Column(
            mainAxisSize: MainAxisSize.min,
            children: [
              Icon(icon, size: 44),
              const SizedBox(height: 12),
              Text(
                title,
                style: Theme.of(context).textTheme.titleMedium,
                textAlign: TextAlign.center,
              ),
              const SizedBox(height: 6),
              Text(message, textAlign: TextAlign.center),
              if (onAction != null) ...[
                const SizedBox(height: 12),
                TextButton(onPressed: onAction, child: Text(actionLabel!)),
              ],
            ],
          ),
        ),
      );
}
