part of 'device_session.dart';

class DeviceSessionRuntimeLease {
  const DeviceSessionRuntimeLease._({
    required this.generation,
    required this._client,
  });

  final int generation;
  final GatewayClient _client;

  bool sameRuntime(DeviceSessionRuntimeLease? other) =>
      other != null &&
      other.generation == generation &&
      identical(other._client, _client);

  int get runtimeIdentityHash =>
      Object.hash(generation, identityHashCode(_client));

  ConversationInputQueueGatewayClient? get inputQueue =>
      _client is ConversationInputQueueGatewayClient
      ? _client as ConversationInputQueueGatewayClient
      : null;
  TerminalGateway? get terminalGateway => _client is TerminalGatewayHost
      ? (_client as TerminalGatewayHost).terminalGateway : null;

  GatewayEventWindow openEventWindow() => _client.openEventWindow();

  Future<ConversationSnapshot> getConversation(
    ConversationSummary conversation,
  ) => _client.getConversation(conversation);

  Future<ConversationSnapshot> getConversationPage(
    ConversationSummary conversation, {
    required String cursor,
  }) => (_client as ConversationHistoryGatewayClient).getConversationPage(
    conversation,
    cursor: cursor,
  );

  Future<ConversationInteraction> acquireInteraction(
    ConversationSummary conversation,
  ) => _client.acquireInteraction(conversation);

  bool get supportsConversationResume =>
      _client is ConversationResumeGatewayClient;

  Future<ConversationResumeResult> resumeConversation(
    ConversationSummary conversation, {
    bool force = false,
  }) => (_client as ConversationResumeGatewayClient).resumeConversation(
    conversation,
    force: force,
  );

  bool get supportsConversationRelease =>
      _client is ConversationReleaseGatewayClient;

  Future<void> releaseConversation(ConversationSummary conversation) =>
      (_client as ConversationReleaseGatewayClient).releaseConversation(
        conversation,
      );

  Future<ConversationPage> searchConversations({
    required String providerId,
    required String searchTerm,
    String? cursor,
    int limit = 50,
  }) => _client.searchConversations(
    providerId: providerId,
    searchTerm: searchTerm,
    cursor: cursor,
    limit: limit,
  );

  Future<TurnSendReceipt> sendTurn({
    required String providerId,
    required ConversationSummary conversation,
    required String clientRequestId,
    required String capabilityRevision,
    required String text,
    required TurnSendSelection selection,
  }) => _client.sendTurn(
    providerId: providerId,
    conversation: conversation,
    clientRequestId: clientRequestId,
    capabilityRevision: capabilityRevision,
    text: text,
    selection: selection,
  );

  bool get supportsConversationControl =>
      _client is ConversationControlGatewayClient;

  Future<TurnTask> interruptTurn({
    required ConversationSummary conversation,
    required TurnTask turn,
  }) => (_client as ConversationControlGatewayClient).interruptTurn(
    conversation: conversation,
    turn: turn,
  );

  Future<GatewayMessage> resolveApproval({
    required GatewayMessage approval,
    required ApprovalDecision decision,
  }) => (_client as ConversationControlGatewayClient).resolveApproval(
    approval: approval,
    decision: decision,
  );
}
