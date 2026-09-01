import 'package:codepet_remote/devices/local_device_descriptor.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  test('enables the Host alias only for debug Android emulators', () {
    expect(
      shouldUseAndroidEmulatorHostAlias(
        buildMode: CodePetBuildMode.debug,
        isAndroid: true,
        isPhysicalDevice: false,
      ),
      isTrue,
    );
  });

  test('disables the Host alias outside debug Android emulators', () {
    for (final buildMode in [
      CodePetBuildMode.profile,
      CodePetBuildMode.release,
    ]) {
      expect(
        shouldUseAndroidEmulatorHostAlias(
          buildMode: buildMode,
          isAndroid: true,
          isPhysicalDevice: false,
        ),
        isFalse,
      );
    }
    expect(
      shouldUseAndroidEmulatorHostAlias(
        buildMode: CodePetBuildMode.debug,
        isAndroid: true,
        isPhysicalDevice: true,
      ),
      isFalse,
    );
    expect(
      shouldUseAndroidEmulatorHostAlias(
        buildMode: CodePetBuildMode.debug,
        isAndroid: false,
        isPhysicalDevice: false,
      ),
      isFalse,
    );
  });
}
