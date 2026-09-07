import 'dart:async';

import 'package:flutter/material.dart';

import '../../application/conversations/conversation_search_controller.dart';
import '../../application/sessions/device_session.dart';
import '../../core/domain/models.dart';
import '../common/app_toast.dart';
import '../connection/device_connection_notice.dart';
import 'conversation_detail_screen.dart';
import 'widgets/conversation_list_item.dart';

class ConversationSearchScreen extends StatefulWidget {
  const ConversationSearchScreen({
    super.key,
    required this.session,
    this.project,
    this.standaloneOnly = false,
  });

  final DeviceSession session;
  final RoutedResourceId? project;
  final bool standaloneOnly;

  @override
  State<ConversationSearchScreen> createState() =>
      _ConversationSearchScreenState();
}

class _ConversationSearchScreenState extends State<ConversationSearchScreen> {
  final TextEditingController _searchController = TextEditingController();
  late ConversationSearchController _controller;

  List<GatewayProvider> get _providers => _controller.providers;
  List<ConversationSummary> get _conversations => _controller.conversations;
  String? get _query => _controller.query;
  String? get _error => _controller.error;
  String? get _validationError => _controller.validationError;
  bool get _hasSearched => _controller.hasSearched;
  bool get _isLoading => _controller.isLoading;
  int get _visibleCount => _controller.visibleCount;
  bool get _canLoadMore => _controller.hasRemoteMore;

  @override
  void initState() {
    super.initState();
    _controller = ConversationSearchController(
      session: widget.session,
      project: widget.project,
      standaloneOnly: widget.standaloneOnly,
    )..addListener(_changed);
  }

  @override
  void didUpdateWidget(ConversationSearchScreen oldWidget) {
    super.didUpdateWidget(oldWidget);
    if (oldWidget.session == widget.session &&
        oldWidget.project == widget.project &&
        oldWidget.standaloneOnly == widget.standaloneOnly) {
      return;
    }
    _controller
      ..removeListener(_changed)
      ..dispose();
    _controller = ConversationSearchController(
      session: widget.session,
      project: widget.project,
      standaloneOnly: widget.standaloneOnly,
    )..addListener(_changed);
  }

  @override
  void dispose() {
    _controller
      ..removeListener(_changed)
      ..dispose();
    _searchController.dispose();
    super.dispose();
  }

  void _changed() {
    if (mounted) setState(() {});
  }

  Future<void> _search() async {
    await _controller.search(_searchController.text);
  }

  Future<void> _loadMore() async {
    await _controller.loadMore();
  }

  void _openConversation(ConversationSummary conversation) {
    if (!_controller.resultsAreCurrent) {
      AppToast.show(
        type: AppToastType.warning,
        content: const TextSpan(
          children: [
            TextSpan(
              text: '搜索结果已失效',
              style: TextStyle(fontWeight: FontWeight.w600),
            ),
            TextSpan(text: '，请重新搜索'),
          ],
        ),
      );
      return;
    }
    Navigator.of(context).push<void>(
      MaterialPageRoute(
        builder: (_) => ConversationDetailScreen(
          session: widget.session,
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
                labelText: widget.standaloneOnly
                    ? '搜索聊天分组的会话'
                    : widget.project == null
                        ? '搜索 Host 上的会话'
                        : '搜索当前项目的会话',
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
      return Center(
        key: const Key('search-offline'),
        child: Padding(
          padding: const EdgeInsets.all(24),
          child: DeviceConnectionNotice(session: widget.session),
        ),
      );
    }
    if (!supported) {
      return _SearchMessage(
        key: Key('search-unsupported'),
        icon: Icons.search_off_outlined,
        title: '当前 Provider 不支持会话搜索',
        message: widget.session.selectedProvider == null
            ? '当前设备没有可选择的 Provider。'
            : '${widget.session.selectedProvider!.displayName} '
                '没有广告 conversation.search 能力。',
      );
    }
    if (!_hasSearched) {
      return const _SearchMessage(
        icon: Icons.manage_search_outlined,
        title: '搜索远程会话',
        message: '搜索由当前选中的 Provider 执行，结果不会加入首页会话列表。',
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
    return ConversationList(
      key: const Key('search-results'),
      padding: const EdgeInsets.fromLTRB(16, 4, 16, 24),
      conversations: _conversations.take(visibleCount).toList(growable: false),
      itemKey: (conversation) => Key(
        'search-result-${conversationRoutingKey(conversation)}',
      ),
      onTap: _openConversation,
      leading: [
        Text(
          '${_conversations.length}${_canLoadMore ? '+' : ''} 个结果',
          key: const Key('search-count'),
          style: Theme.of(context).textTheme.bodySmall,
        ),
        if (_error != null) _InlineError(message: _error!),
      ],
      trailing: [
        if (hasMore) _SearchPagination(loading: _isLoading, onPressed: _loadMore),
      ],
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
