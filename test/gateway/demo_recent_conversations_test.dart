import 'package:codepet_remote/application/errors/application_failures.dart';
import 'package:codepet_remote/gateway/demo_gateway_client.dart';
import 'package:codepet_remote/core/domain/models.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  test('demo pages its complete old active set before normal recent history', () async {
    final client = DemoGatewayClient(profileId: 'recent');
    addTearDown(client.close);
    var page = await client.recentConversations(providerId: 'codex-demo');
    final revision = page.revision;
    final all = [...page.conversations];
    while (page.nextCursor != null) {
      page = await client.recentConversations(providerId: 'codex-demo', cursor: page.nextCursor);
      expect(page.revision, revision);
      expect(page.conversations.length, lessThanOrEqualTo(20));
      all.addAll(page.conversations);
    }
    expect(all.where((item) => item.id.startsWith('demo-old-active-')), hasLength(125));
    expect(all.last.id, 'demo-idle');
  });

  test('demo changes expire a former snapshot cursor', () async {
    final client = DemoGatewayClient(profileId: 'recent');
    addTearDown(client.close);
    final page = await client.recentConversations(providerId: 'codex-demo');
    await client.createConversation(providerId: 'codex-demo', title: 'new',
      permissionLevel: PermissionLevel.readOnly);
    await expectLater(client.recentConversations(providerId: 'codex-demo', cursor: page.nextCursor),
      throwsA(isA<GatewayProtocolException>().having((error) => error.code, 'code', 'recent_cursor_expired')));
  });
}
