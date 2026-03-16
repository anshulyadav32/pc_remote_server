import 'dart:async';
import 'dart:convert';
import 'dart:math';
import 'dart:io';

import 'package:flutter/services.dart';
import 'package:web_socket_channel/status.dart' as status;
import 'package:web_socket_channel/web_socket_channel.dart';

import 'device_identity_service.dart';
import 'trust_store_service.dart';

class WebSocketService {
  static const List<String> _capabilities = <String>[
    'ping',
    'clipboard',
    'media',
    'browser',
    'window',
    'remote_input',
    'text_input',
  ];

  WebSocketChannel? _channel;
  StreamSubscription<dynamic>? _subscription;

  final StreamController<bool> _connectionController =
      StreamController<bool>.broadcast();
  final StreamController<Map<String, dynamic>> _messageController =
      StreamController<Map<String, dynamic>>.broadcast();
  final StreamController<String> _requestStatusController =
      StreamController<String>.broadcast();

  String? _lastServerUrl;
  int _lastServerPort = 8765;
  int _lastClientPort = 8766;
  String _lastDeviceName = 'Flutter Device';
  String _lastDeviceId = '';
  Timer? _autoClipboardPollTimer;
  String _lastLocalClipboardText = '';
  bool _isConnected = false;
  bool _isDisposed = false;

  Stream<bool> get connectionStream => _connectionController.stream;
  Stream<Map<String, dynamic>> get messageStream => _messageController.stream;
  Stream<String> get requestStatusStream => _requestStatusController.stream;
  bool get isConnected => _isConnected;

  Uri _parseServerUri(String serverUrl) {
    final uri = Uri.parse(
        serverUrl.startsWith('http') ? serverUrl : 'http://$serverUrl');
    if (uri.host.isEmpty) {
      throw const FormatException('Invalid server URL');
    }
    return uri;
  }

  Future<bool> connect(
    String serverUrl, {
    int serverPort = 8765,
    int clientPort = 8766,
    String deviceName = 'Flutter Device',
  }) async {
    try {
      if (_isConnected) {
        await disconnect();
      }

      final uri = _parseServerUri(serverUrl);
      final resolvedDeviceName =
          deviceName.trim().isEmpty ? _defaultClientName() : deviceName.trim();
      final identity = await DeviceIdentityService.loadOrCreate(
        defaultName: resolvedDeviceName,
        deviceType: _defaultDeviceType(),
        capabilities: _capabilities,
      );

      final wsScheme = uri.scheme == 'https' ? 'wss' : 'ws';
      final wsUri = Uri(
        scheme: wsScheme,
        host: uri.host,
        port: serverPort,
        path: '/ws',
      );

      _channel = WebSocketChannel.connect(wsUri);
      _isConnected = true;
      _lastServerUrl = serverUrl;
      _lastServerPort = serverPort;
      _lastClientPort = clientPort;
      _lastDeviceName = identity.deviceName;
      _lastDeviceId = identity.deviceId;
      _addConnectionState(true);

      _sendRaw({
        'type': 'pair',
        'deviceName': _lastDeviceName,
        'deviceId': _lastDeviceId,
        'deviceType': identity.deviceType,
        'protocolVersion': identity.protocolVersion,
        'capabilities': identity.capabilities,
      });

      sendConnectionRequest(
        clientPort: clientPort,
        deviceName: _lastDeviceName,
        deviceId: _lastDeviceId,
      );

      _subscription = _channel!.stream.listen(
        (data) {
          try {
            final message = jsonDecode(data.toString()) as Map<String, dynamic>;
            _messageController.add(message);
            _handleSystemMessage(message);
          } catch (_) {}
        },
        onError: (_) => _handleDisconnection(),
        onDone: _handleDisconnection,
      );

      return true;
    } catch (_) {
      _handleDisconnection();
      return false;
    }
  }

  Future<void> disconnect() async {
    _stopAutoClipboardSync(notifyServer: true);

    await _subscription?.cancel();
    _subscription = null;

    final channel = _channel;
    _channel = null;
    await channel?.sink.close(status.normalClosure);

    _handleDisconnection();
  }

  void _handleDisconnection() {
    _stopAutoClipboardSync();

    _isConnected = false;
    _addConnectionState(false);
    _addRequestStatus('disconnected');
  }

  void _addConnectionState(bool connected) {
    if (_isDisposed || _connectionController.isClosed) {
      return;
    }
    _connectionController.add(connected);
  }

  void _addRequestStatus(String status) {
    if (_isDisposed || _requestStatusController.isClosed) {
      return;
    }
    _requestStatusController.add(status);
  }

  void _sendRaw(Map<String, dynamic> payload) {
    if (_channel == null || !_isConnected) {
      return;
    }
    _channel!.sink.add(jsonEncode(payload));
  }

  void _handleSystemMessage(Map<String, dynamic> message) {
    final type = message['type']?.toString() ?? '';

    if (type == 'clipboard.update' || type == 'clipboard_content') {
      final text = (message['text'] ?? message['content'] ?? '').toString();
      unawaited(_applyRemoteClipboard(text));
      return;
    }

    if (type == 'connect.pending') {
      _addRequestStatus('pending');
      return;
    }
    if (type == 'connect.accepted') {
      _addRequestStatus('accepted');
      unawaited(_rememberTrustedServer(message));
      unawaited(_startAutoClipboardSync());
      return;
    }
    if (type == 'connect.rejected') {
      _addRequestStatus('rejected');
      _stopAutoClipboardSync(notifyServer: true);
      return;
    }
  }

  Future<void> _startAutoClipboardSync() async {
    if (_autoClipboardPollTimer != null || !_isConnected) {
      return;
    }

    final existing = await Clipboard.getData('text/plain');
    _lastLocalClipboardText = existing?.text ?? '';

    _sendRaw({'type': 'enable_auto_clipboard'});
    _sendRaw({'type': 'get_clipboard'});

    _autoClipboardPollTimer = Timer.periodic(
      const Duration(seconds: 1),
      (_) => unawaited(_syncLocalClipboardToRemote()),
    );
  }

  Future<void> _syncLocalClipboardToRemote() async {
    if (!_isConnected) {
      _stopAutoClipboardSync();
      return;
    }

    final data = await Clipboard.getData('text/plain');
    final text = data?.text ?? '';
    if (text == _lastLocalClipboardText) {
      return;
    }

    _lastLocalClipboardText = text;
    _sendRaw({'type': 'clipboard.set', 'text': text});
  }

  Future<void> _applyRemoteClipboard(String text) async {
    if (text == _lastLocalClipboardText) {
      return;
    }

    _lastLocalClipboardText = text;
    await Clipboard.setData(ClipboardData(text: text));
  }

  void _stopAutoClipboardSync({bool notifyServer = false}) {
    if (notifyServer && _isConnected) {
      _sendRaw({'type': 'disable_auto_clipboard'});
    }
    _autoClipboardPollTimer?.cancel();
    _autoClipboardPollTimer = null;
  }

  void sendConnectionRequest({
    required int clientPort,
    String? deviceName,
    String? deviceId,
  }) {
    if (_channel == null || !_isConnected) {
      return;
    }

    final nowSeconds = DateTime.now().millisecondsSinceEpoch ~/ 1000;

    _addRequestStatus('sending');
    final resolvedDeviceId = (deviceId ?? _lastDeviceId).trim();
    _sendRaw({
      'type': 'pair.request',
      'deviceName': (deviceName ?? _lastDeviceName).trim().isEmpty
          ? _defaultClientName()
          : (deviceName ?? _lastDeviceName).trim(),
      'deviceId': resolvedDeviceId,
      'pairCode': _buildPairCode(resolvedDeviceId),
      'deviceType': _defaultDeviceType(),
      'protocolVersion': DeviceIdentityService.protocolVersion,
      'capabilities': _capabilities,
      'clientPort': clientPort,
      'nonce': _generateNonce(),
      'timestamp': nowSeconds,
    });
  }

  String _defaultDeviceType() {
    if (Platform.isAndroid || Platform.isIOS) {
      return 'phone';
    }
    if (Platform.isWindows || Platform.isLinux || Platform.isMacOS) {
      return 'desktop';
    }
    return 'unknown';
  }

  String _defaultClientName() {
    if (Platform.isAndroid) {
      return 'Android Phone';
    }
    if (Platform.isIOS) {
      return 'iPhone';
    }
    if (Platform.isWindows) {
      return 'Windows Device';
    }
    if (Platform.isMacOS) {
      return 'Mac Device';
    }
    if (Platform.isLinux) {
      return 'Linux Device';
    }
    return 'Flutter Device';
  }

  String _generateNonce() {
    final random = Random.secure();
    final bytes = List<int>.generate(12, (_) => random.nextInt(256));
    return bytes.map((value) => value.toRadixString(16).padLeft(2, '0')).join();
  }

  String _buildPairCode(String deviceId) {
    final cleaned =
        deviceId.replaceAll(RegExp(r'[^a-zA-Z0-9]'), '').toUpperCase();
    if (cleaned.length >= 6) {
      return cleaned.substring(cleaned.length - 6);
    }
    return cleaned.padLeft(6, '0');
  }

  Future<void> _rememberTrustedServer(Map<String, dynamic> message) async {
    final serverDeviceId = (message['serverDeviceId'] ?? '').toString().trim();
    if (serverDeviceId.isEmpty) {
      return;
    }

    final rawCapabilities = message['serverCapabilities'];
    final caps = rawCapabilities is List
        ? rawCapabilities.map((item) => item.toString()).toList()
        : <String>[];

    final trusted = await TrustStoreService.load();
    final serverPairCode =
        (message['serverPairCode'] ?? '').toString().trim();
    trusted[serverDeviceId] = TrustedDeviceRecord(
      deviceId: serverDeviceId,
      pairCode:
          serverPairCode.isEmpty ? _buildPairCode(serverDeviceId) : serverPairCode,
      deviceName:
          (message['serverDeviceName'] ?? 'PCRemote Server').toString(),
      deviceType: (message['serverDeviceType'] ?? 'desktop').toString(),
      protocolVersion: int.tryParse('${message['serverProtocolVersion']}') ??
          DeviceIdentityService.protocolVersion,
      capabilities: caps,
      permissions: const TrustedPermissions(),
      updatedAtEpochSeconds: DateTime.now().millisecondsSinceEpoch ~/ 1000,
    );

    await TrustStoreService.save(trusted);
  }

  void sendCommand(Map<String, dynamic> command) {
    if (_channel == null || !_isConnected) {
      return;
    }

    final translated = _translateCommand(command);
    _channel!.sink.add(jsonEncode(translated));
  }

  // Keep client widget commands compatible with server protocol.
  Map<String, dynamic> _translateCommand(Map<String, dynamic> command) {
    final type = command['type']?.toString() ?? '';

    if (type == 'move') {
      return {
        'type': 'mouse',
        'action': 'move',
        'deltaX': command['dx'] ?? 0,
        'deltaY': command['dy'] ?? 0,
      };
    }

    if (type == 'click') {
      return {
        'type': 'mouse',
        'action': 'click',
        'button': command['button'] ?? 'left',
        'kind': command['kind'],
      };
    }

    if (type == 'wheel') {
      return {
        'type': 'mouse',
        'action': 'wheel',
        'delta': command['delta'] ?? 0,
      };
    }

    if (type == 'set_clipboard') {
      return {
        'type': 'clipboard.set',
        'text': command['text'] ?? '',
      };
    }

    return command;
  }

  Future<void> reconnect() async {
    if (_lastServerUrl != null) {
      await connect(
        _lastServerUrl!,
        serverPort: _lastServerPort,
        clientPort: _lastClientPort,
        deviceName: _lastDeviceName,
      );
    }
  }

  void dispose() {
    _isDisposed = true;
    _stopAutoClipboardSync();

    final subscription = _subscription;
    _subscription = null;
    if (subscription != null) {
      unawaited(subscription.cancel());
    }

    final channel = _channel;
    _channel = null;
    if (channel != null) {
      unawaited(channel.sink.close(status.normalClosure));
    }

    _isConnected = false;
    _connectionController.close();
    _messageController.close();
    _requestStatusController.close();
  }
}
