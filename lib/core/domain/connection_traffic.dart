/// Application payload bytes for one connection, viewed from this device.
class ConnectionTraffic {
  const ConnectionTraffic({
    required this.channel,
    this.sentBytes = 0,
    this.receivedBytes = 0,
    this.sentBytesPerSecond = 0,
    this.receivedBytesPerSecond = 0,
  });
  final String channel;
  final int sentBytes, receivedBytes;
  final double sentBytesPerSecond, receivedBytesPerSecond;
  int get totalBytes => sentBytes + receivedBytes;
}
