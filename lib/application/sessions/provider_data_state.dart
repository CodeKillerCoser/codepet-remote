part of 'device_session.dart';

enum ProviderDataKind { capabilities, projects, conversations }

enum ProviderDataStatus { idle, loading, ready, failed }

/// Read-only business loading state, independent of the device connection.
class ProviderDataState {
  const ProviderDataState({this.status = ProviderDataStatus.idle, this.error});

  final ProviderDataStatus status;
  final String? error;
}
