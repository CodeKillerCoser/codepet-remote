import 'dart:convert';
import 'dart:io';

import 'package:integration_test/integration_test_driver_extended.dart';

Future<void> main() async {
  final output = Directory(
    Platform.environment['CODEPET_QA_OUTPUT'] ?? 'artifacts/protocol-joint',
  );
  await output.create(recursive: true);
  await integrationDriver(
    onScreenshot: (name, image, [args]) async {
      if (!RegExp(r'^[a-z0-9-]+$').hasMatch(name) || image.isEmpty) {
        return false;
      }
      await File('${output.path}/$name.png').writeAsBytes(image);
      return true;
    },
    responseDataCallback: (data) async {
      final summary = <String, dynamic>{...?data}..remove('screenshots');
      await File('${output.path}/result.json')
          .writeAsString(jsonEncode(summary));
    },
    writeResponseOnFailure: true,
  );
}
