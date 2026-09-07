import 'dart:convert';
import 'dart:io';

import 'package:codepet_gateway_sdk/codepet_gateway_sdk.dart' as sdk;
import 'package:flutter_test/flutter_test.dart';

Map<String, dynamic> fixture(String name) => jsonDecode(
  File('test/fixtures/gateway_v1/$name.json').readAsStringSync(),
) as Map<String, dynamic>;

void main() {
  test('canonical v1 recent pages decode with independent revision and fence', () {
    final first = sdk.ConversationRecentResponse.fromJson(fixture('conversation-recent-response')['result']);
    final end = sdk.ConversationRecentResponse.fromJson(fixture('conversation-recent-end-response')['result']);
    expect(first.pageInfo.nextCursor, isNotNull);
    expect(end.pageInfo.nextCursor, isNull);
    expect(first.revision, end.revision);
    expect(first.revision, isNot(first.snapshotCursor));
    expect(first.conversations.first.readState?.unread, isTrue);
  });

  test('canonical recentChanged envelope is decoded by the generated SDK', () {
    final event = sdk.ProtocolEventEnvelope.fromJson(fixture('conversation-recent-changed-event'));
    expect(event.event, sdk.ProtocolEventName.conversationRecentChanged);
    expect(event.payload, isA<sdk.ConversationRecentChangedEvent>());
  });

  test('recent rejects an injected scope, missing fence and missing revision', () {
    expect(() => sdk.ConversationRecentRequest.fromJson({
      'providerId': 'codex-work', 'readerScope': 'other-reader',
    }), throwsA(isA<sdk.ProtocolCodecException>()));
    final page = Map<String, dynamic>.from(fixture('conversation-recent-response')['result'] as Map);
    page.remove('snapshotCursor');
    expect(() => sdk.ConversationRecentResponse.fromJson(page), throwsA(isA<sdk.ProtocolCodecException>()));
    page['snapshotCursor'] = 'fence';
    page.remove('revision');
    expect(() => sdk.ConversationRecentResponse.fromJson(page), throwsA(isA<sdk.ProtocolCodecException>()));
  });
}
