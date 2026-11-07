import 'dart:io';

import 'package:codepet_remote/diagnostics/app_log.dart';
import 'package:codepet_remote/diagnostics/local_log_store.dart';
import 'package:codepet_remote/diagnostics/network_environment.dart';
import 'package:codepet_remote/gateway/webrtc/rtc_diagnostics.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:integration_test/integration_test.dart';

void main() {
  IntegrationTestWidgetsFlutterBinding.ensureInitialized();

  testWidgets('Android network bridge writes a redacted plain-text snapshot', (
    tester,
  ) async {
    const environment = SystemNetworkEnvironment();
    final snapshot = await environment.snapshot();
    expect(snapshot['source'], 'androidConnectivityManager');
    expect(snapshot.containsKey('httpProxyConfigured'), true);
    final networks = snapshot['networks'] as List;
    expect(networks, isNotEmpty);
    expect(networks.any((n) => (n as Map)['isDefault'] == true), true);
    final directory = await Directory.systemTemp.createTemp(
      'network-log-probe-',
    );
    try {
      final store = await LocalLogStore.open(rootDirectory: directory);
      await AppLog.initialize(store: store);
      await RtcDiagnostics(networkEnvironment: environment)
          .networkSnapshot('nativeProbe');
      await AppLog.flush();
      final text = await File('${store.logDirectory.path}/codepet.log')
          .readAsString();
      expect(text, contains('network.snapshot'));
      expect(text, contains('source=androidConnectivityManager'));
      expect(text, contains('networkAddressId='));
      expect(text, isNot(contains('snapshotUnavailable')));
      expect(text, contains('pid='));
      expect(text, contains('thread='));
      expect(text, isNot(contains('"networks":')));
      for (final network in networks.cast<Map>()) {
        for (final address
            in (network['addresses'] as List? ?? []).cast<Map>()) {
          expect(text, isNot(contains(address['address'] as String)));
        }
      }
    } finally {
      await AppLog.resetForTesting();
      await directory.delete(recursive: true);
    }
  });
}
