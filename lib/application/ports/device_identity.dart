import '../../core/domain/models.dart';

abstract interface class DeviceDescriptorProvider {
  Future<DeviceDescriptor> load();
}

abstract interface class DebugAndroidEmulatorProvider {
  Future<bool> isDebugAndroidEmulator();
}
