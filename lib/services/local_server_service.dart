import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:flutter/foundation.dart';

import 'device_identity_service.dart';
import 'host_controller_service.dart';
import 'trust_store_service.dart';

class LocalServerService {
  static const List<String> _capabilities = <String>[
    'ping',
    'clipboard',
    'media',
    'browser',
    'window',
    'remote_input',
    'text_input',
  ];

  HttpServer? _server;
  RawDatagramSocket? _discoverySocket;

  final Map<String, WebSocket> _clients = <String, WebSocket>{};
  final Map<String, String> _clientNames = <String, String>{};
  final Map<String, ConnectionRequest> _pendingRequests =
      <String, ConnectionRequest>{};
  final Map<String, PairedDevice> _pairedDevices = <String, PairedDevice>{};
  Map<String, TrustedDeviceRecord> _trustedDevices =
      <String, TrustedDeviceRecord>{};
  final Set<String> _seenNonces = <String>{};
  final Set<String> _autoClipboardClients = <String>{};
  final HostControllerService _hostController = HostControllerService();

  final StreamController<bool> _runningController =
      StreamController<bool>.broadcast();
  final StreamController<int> _clientCountController =
      StreamController<int>.broadcast();
  final StreamController<String> _logController =
      StreamController<String>.broadcast();
  final StreamController<List<ConnectionRequest>> _pendingRequestsController =
      StreamController<List<ConnectionRequest>>.broadcast();
  final StreamController<List<PairedDevice>> _pairedDevicesController =
      StreamController<List<PairedDevice>>.broadcast();

  int _port = 8765;
  String _localIp = '127.0.0.1';
  DeviceIdentity? _identity;
  Timer? _clipboardPollTimer;
  String _lastClipboardText = '';

  Stream<bool> get runningStream => _runningController.stream;
  Stream<int> get clientCountStream => _clientCountController.stream;
  Stream<String> get logStream => _logController.stream;
  Stream<List<ConnectionRequest>> get pendingRequestsStream =>
      _pendingRequestsController.stream;
  Stream<List<PairedDevice>> get pairedDevicesStream =>
      _pairedDevicesController.stream;
  List<ConnectionRequest> get currentPendingRequests =>
      _pendingRequests.values.toList();
  List<PairedDevice> get currentPairedDevices => _pairedDevices.values.toList();

  bool get isRunning => _server != null;
  int get port => _port;
  String get localIp => _localIp;
  String get deviceId => _identity?.deviceId ?? '';
  String get wsUrl => 'ws://$localIp:$port/ws';

  Future<bool> start({required int port}) async {
    if (isRunning) {
      await stop();
    }

    try {
      _port = port;
      _localIp = await _resolveLocalIp();
      _identity = await DeviceIdentityService.loadOrCreate(
        defaultName: _defaultServerName(),
        deviceType: _defaultDeviceType(),
        capabilities: _capabilities,
      );
      _trustedDevices = await TrustStoreService.load();

      _server = await _bindHttpServerWithFallback(_port);
      _port = _server!.port;
      await _startDiscovery();
      await _ensureWindowsFirewallPermission();
      _addRunning(true);
      _log('Server started on ws://$_localIp:$_port/ws');

      unawaited(_server!.forEach(_handleHttpRequest));
      return true;
    } catch (e) {
      _log('Failed to start server: $e');
      _addRunning(false);
      return false;
    }
  }

  Future<HttpServer> _bindHttpServerWithFallback(int preferredPort) async {
    final candidates = <int>[
      preferredPort,
      for (var i = 1; i <= 5; i++) preferredPort + i,
    ];

    SocketException? lastAddressInUse;

    for (final candidate in candidates) {
      try {
        final server =
            await HttpServer.bind(InternetAddress.anyIPv4, candidate);
        if (candidate != preferredPort) {
          _log('Port $preferredPort busy, using fallback port $candidate');
        }
        return server;
      } on SocketException catch (e) {
        if (_isAddressInUse(e)) {
          lastAddressInUse = e;
          continue;
        }
        rethrow;
      }
    }

    if (lastAddressInUse != null) {
      _log('Preferred ports are busy, choosing an available dynamic port');
    }
    return HttpServer.bind(InternetAddress.anyIPv4, 0);
  }

  bool _isAddressInUse(SocketException error) {
    final code = error.osError?.errorCode;
    if (code == 48 || code == 98 || code == 10048) {
      return true;
    }

    final text = error.toString().toLowerCase();
    return text.contains('address already in use');
  }

  Future<void> _ensureWindowsFirewallPermission() async {
    if (!Platform.isWindows) {
      return;
    }

    final exePath = Platform.resolvedExecutable;
    final ruleBase = 'PCRemote';

    final commands = <List<String>>[
      <String>[
        'advfirewall',
        'firewall',
        'add',
        'rule',
        'name=$ruleBase TCP In',
        'dir=in',
        'action=allow',
        'protocol=TCP',
        'localport=$_port',
        'program=$exePath',
      ],
      <String>[
        'advfirewall',
        'firewall',
        'add',
        'rule',
        'name=$ruleBase UDP Discovery In',
        'dir=in',
        'action=allow',
        'protocol=UDP',
        'localport=8766',
        'program=$exePath',
      ],
      <String>[
        'advfirewall',
        'firewall',
        'add',
        'rule',
        'name=$ruleBase UDP Discovery Out',
        'dir=out',
        'action=allow',
        'protocol=UDP',
        'localport=8766',
        'program=$exePath',
      ],
    ];

    var allOk = true;
    for (final args in commands) {
      try {
        final result = await Process.run('netsh', args);
        // "already exists" is still fine on repeated starts.
        final output =
            '${result.stdout}\n${result.stderr}'.toLowerCase().trim();
        final ok = result.exitCode == 0 || output.contains('already exists');
        allOk = allOk && ok;
      } catch (_) {
        allOk = false;
      }
    }

    if (allOk) {
      _log('Windows firewall rules verified for PCRemote');
    } else {
      _log(
          'Windows firewall permission may be blocked. Run app as Administrator once or allow PCRemote in Windows Firewall.');
    }
  }

  Future<void> stop() async {
    for (final socket in _clients.values) {
      await socket.close();
    }
    _clients.clear();
    _clientNames.clear();
    _pendingRequests.clear();
    _pairedDevices.clear();
    _autoClipboardClients.clear();
    _emitPendingRequests();
    _emitPairedDevices();
    _stopDiscovery();
    _stopClipboardPolling();

    await _server?.close(force: true);
    _server = null;

    _addClientCount(0);
    _addRunning(false);
    _log('Server stopped');
  }

  Future<void> _handleHttpRequest(HttpRequest request) async {
    if (request.uri.path == '/ws') {
      await _handleWebSocketUpgrade(request);
      return;
    }

    if (request.uri.path == '/health') {
      request.response.statusCode = HttpStatus.ok;
      request.response.write('ok');
      await request.response.close();
      return;
    }

    request.response.statusCode = HttpStatus.notFound;
    await request.response.close();
  }

  Future<void> _startDiscovery() async {
    _stopDiscovery();

    try {
      _discoverySocket = await RawDatagramSocket.bind(
        InternetAddress.anyIPv4,
        8766,
        reuseAddress: true,
      );
      _discoverySocket!.broadcastEnabled = true;

      _discoverySocket!.listen((event) {
        if (event != RawSocketEvent.read) {
          return;
        }

        final datagram = _discoverySocket?.receive();
        if (datagram == null) {
          return;
        }

        _handleDiscoveryPacket(datagram);
      });

      _log('LAN discovery listening on UDP 8766');
    } catch (e) {
      _log('LAN discovery unavailable: $e');
    }
  }

  void _stopDiscovery() {
    _discoverySocket?.close();
    _discoverySocket = null;
  }

  void _handleDiscoveryPacket(Datagram datagram) {
    try {
      final parsed = jsonDecode(utf8.decode(datagram.data));
      if (parsed is! Map<String, dynamic>) {
        return;
      }

      if (parsed['type']?.toString() != 'discover') {
        return;
      }

      final payload = jsonEncode({
        'type': 'discover-ack',
        'name': _identity?.deviceName ?? 'PCRemote Server',
        'deviceId': _identity?.deviceId ?? '',
        'deviceType': _identity?.deviceType ?? 'desktop',
        'protocolVersion': _identity?.protocolVersion ?? 1,
        'capabilities': _identity?.capabilities ?? _capabilities,
        'tcp': _port.toString(),
        'udp': '8766',
        'ws': 'ws://$_localIp:$_port/ws',
      });

      _discoverySocket?.send(
        utf8.encode(payload),
        datagram.address,
        datagram.port,
      );
    } catch (_) {}
  }

  Future<void> _handleWebSocketUpgrade(HttpRequest request) async {
    try {
      final socket = await WebSocketTransformer.upgrade(request);
      final clientId = DateTime.now().microsecondsSinceEpoch.toString();

      _clients[clientId] = socket;
      _clientNames[clientId] = 'Unknown Device';
      _addClientCount(_clients.length);
      _log('Client connected ($clientId)');

      _send(socket, {
        'type': 'hello',
        'id': clientId,
        'server': 'pcremote',
        'serverDeviceId': _identity?.deviceId ?? '',
        'serverDeviceName': _identity?.deviceName ?? 'PCRemote Server',
        'protocolVersion': _identity?.protocolVersion ?? 1,
        'capabilities': _identity?.capabilities ?? _capabilities,
      });

      socket.listen(
        (dynamic message) => unawaited(_onClientMessage(clientId, message)),
        onDone: () => _removeClient(clientId),
        onError: (_) => _removeClient(clientId),
      );
    } catch (e) {
      request.response.statusCode = HttpStatus.internalServerError;
      await request.response.close();
      _log('WebSocket upgrade failed: $e');
    }
  }

  Future<void> _onClientMessage(String clientId, dynamic raw) async {
    Map<String, dynamic>? message;
    try {
      message = jsonDecode(raw.toString()) as Map<String, dynamic>;
    } catch (_) {
      return;
    }

    final type = message['type']?.toString() ?? '';

    if (type == 'pair') {
      final name = message['deviceName']?.toString() ?? 'Unknown Device';
      _clientNames[clientId] = name;
      _log('Paired $name ($clientId)');

      final socket = _clients[clientId];
      if (socket != null) {
        _send(socket, {'type': 'pair-ack', 'id': clientId, 'paired': true});
      }
      return;
    }

    if (type == 'pair.request') {
      final name = message['deviceName']?.toString() ?? 'Unknown Device';
      final clientPort =
          int.tryParse(message['clientPort']?.toString() ?? '') ?? 0;
      final deviceId = message['deviceId']?.toString() ?? '';
      final pairCode = message['pairCode']?.toString() ?? '';
      final deviceType = message['deviceType']?.toString() ?? 'unknown';
      final protocolVersion =
          int.tryParse(message['protocolVersion']?.toString() ?? '') ?? 1;
      final nonce = message['nonce']?.toString() ?? '';
      final timestamp =
          int.tryParse(message['timestamp']?.toString() ?? '') ?? 0;
      final rawCapabilities = message['capabilities'];
      final capabilities = rawCapabilities is List
          ? rawCapabilities.map((item) => item.toString()).toList()
          : <String>[];

      if (deviceId.isNotEmpty && deviceId == this.deviceId) {
        final socket = _clients[clientId];
        if (socket != null) {
          _send(socket, {
            'type': 'connect.rejected',
            'id': clientId,
            'message': 'This device cannot pair with itself',
          });
        }
        _log('Rejected self-pair request from $name ($clientId)');
        return;
      }

      if (!_isPairRequestFresh(timestamp, nonce)) {
        final socket = _clients[clientId];
        if (socket != null) {
          _send(socket, {
            'type': 'connect.rejected',
            'id': clientId,
            'message': 'Pair request expired or replayed',
          });
        }
        _log('Rejected stale/replayed pair request from $name ($clientId)');
        return;
      }

      await _reloadTrustedDevices();

      final trusted =
          _trustedDevices[deviceId] ?? _findTrustedByPairCode(pairCode);
      if (trusted != null && trusted.deviceId.isNotEmpty) {
        final resolvedDeviceId =
            deviceId.isNotEmpty ? deviceId : trusted.deviceId;
        final resolvedPairCode =
            pairCode.isNotEmpty ? pairCode : trusted.pairCode;
        _pairedDevices[clientId] = PairedDevice(
          clientId: clientId,
          deviceId: resolvedDeviceId,
          pairCode: resolvedPairCode,
          deviceName: trusted.deviceName,
          deviceType: trusted.deviceType,
          protocolVersion: trusted.protocolVersion,
          capabilities: trusted.capabilities,
          clientPort: clientPort,
          pairedAt: DateTime.now(),
          permissions: DevicePermissions(
            clipboard: trusted.permissions.clipboard,
            media: trusted.permissions.media,
            browser: trusted.permissions.browser,
            window: trusted.permissions.window,
            remoteInput: trusted.permissions.remoteInput,
            textInput: trusted.permissions.textInput,
          ),
        );
        if (resolvedDeviceId.isNotEmpty) {
          _trustedDevices[resolvedDeviceId] = TrustedDeviceRecord(
            deviceId: resolvedDeviceId,
            pairCode: resolvedPairCode,
            deviceName: trusted.deviceName,
            deviceType: trusted.deviceType,
            protocolVersion: trusted.protocolVersion,
            capabilities: trusted.capabilities,
            permissions: trusted.permissions,
            updatedAtEpochSeconds:
                DateTime.now().millisecondsSinceEpoch ~/ 1000,
          );
          unawaited(TrustStoreService.save(_trustedDevices));
        }
        _emitPairedDevices();

        final socket = _clients[clientId];
        if (socket != null) {
          final serverId = _identity?.deviceId ?? '';
          _send(socket, {
            'type': 'connect.accepted',
            'id': clientId,
            'message': 'Previously trusted device auto-approved',
            'serverDeviceId': serverId,
            'serverPairCode': _buildPairCode(serverId),
            'serverDeviceName': _identity?.deviceName ?? _defaultServerName(),
            'serverDeviceType': _identity?.deviceType ?? _defaultDeviceType(),
            'serverProtocolVersion':
                _identity?.protocolVersion ?? DeviceIdentityService.protocolVersion,
            'serverCapabilities': _identity?.capabilities ?? _capabilities,
          });
        }
        _log('Auto-approved trusted device $name ($clientId)');
        return;
      }

      _clientNames[clientId] = name;

      _pendingRequests[clientId] = ConnectionRequest(
        clientId: clientId,
        deviceId: deviceId,
        pairCode: pairCode,
        deviceName: name,
        deviceType: deviceType,
        protocolVersion: protocolVersion,
        capabilities: capabilities,
        nonce: nonce,
        timestamp: timestamp,
        clientPort: clientPort,
        requestedAt: DateTime.now(),
      );
      _emitPendingRequests();

      _log('Connection request from $name ($clientId)');
      final socket = _clients[clientId];
      if (socket != null) {
        _send(socket, {
          'type': 'connect.pending',
          'id': clientId,
          'message': 'Request sent. Waiting for server acceptance.',
        });
      }
      return;
    }

    if (type == 'ping') {
      final socket = _clients[clientId];
      if (socket != null) {
        _send(socket, {
          'type': 'pong',
          'timestamp': DateTime.now().toIso8601String(),
        });
      }
      return;
    }

    final plugin = _pluginForMessage(type);
    if (!_canProcessPlugin(clientId, plugin)) {
      final socket = _clients[clientId];
      if (socket != null) {
        _send(socket, {
          'type': 'error',
          'code': 'not-authorized',
          'message': 'Device is not paired or plugin is disabled',
          'plugin': plugin,
        });
      }
      _log('Blocked $plugin command from untrusted client $clientId');
      return;
    }

    if (type == 'clipboard.set') {
      final text = message['text']?.toString() ?? '';
      await _hostController.writeClipboardText(text);
      _lastClipboardText = text;
      _broadcastClipboardUpdate(text, includeClientId: clientId);
      _log('Clipboard updated from $clientId');
      return;
    }

    if (type == 'get_clipboard') {
      final socket = _clients[clientId];
      if (socket != null) {
        final text = await _hostController.readClipboardText();
        _send(socket, {'type': 'clipboard_content', 'content': text});
      }
      return;
    }

    if (type == 'enable_auto_clipboard') {
      _autoClipboardClients.add(clientId);
      await _ensureClipboardPolling();
      _log('Enabled auto clipboard for $clientId');
      return;
    }

    if (type == 'disable_auto_clipboard') {
      _autoClipboardClients.remove(clientId);
      if (_autoClipboardClients.isEmpty) {
        _stopClipboardPolling();
      }
      _log('Disabled auto clipboard for $clientId');
      return;
    }

    if (_hostController.handleCommand(message)) {
      _log('Executed $type for $clientId');
      return;
    }

    _broadcast({...message, 'from': clientId}, excludeClientId: clientId);
  }

  void _removeClient(String clientId) {
    _clients.remove(clientId);
    final name = _clientNames.remove(clientId) ?? clientId;
    _pendingRequests.remove(clientId);
    _pairedDevices.remove(clientId);
    _autoClipboardClients.remove(clientId);
    if (_autoClipboardClients.isEmpty) {
      _stopClipboardPolling();
    }
    _emitPendingRequests();
    _emitPairedDevices();
    _addClientCount(_clients.length);
    _log('Client disconnected ($name)');
  }

  Future<void> acceptRequest(String clientId) async {
    final request = _pendingRequests.remove(clientId);
    _emitPendingRequests();

    if (request == null) {
      return;
    }

    final socket = _clients[clientId];
    if (socket == null) {
      _log('Request $clientId not found: client disconnected');
      return;
    }

    final serverId = _identity?.deviceId ?? '';
    _send(socket, {
      'type': 'connect.accepted',
      'id': clientId,
      'message': 'Connection request accepted by server',
      'serverDeviceId': serverId,
      'serverPairCode': _buildPairCode(serverId),
      'serverDeviceName': _identity?.deviceName ?? _defaultServerName(),
      'serverDeviceType': _identity?.deviceType ?? _defaultDeviceType(),
      'serverProtocolVersion':
          _identity?.protocolVersion ?? DeviceIdentityService.protocolVersion,
      'serverCapabilities': _identity?.capabilities ?? _capabilities,
    });
    final paired = PairedDevice(
      clientId: clientId,
      deviceId: request.deviceId,
      pairCode: request.pairCode,
      deviceName: request.deviceName,
      deviceType: request.deviceType,
      protocolVersion: request.protocolVersion,
      capabilities: request.capabilities,
      clientPort: request.clientPort,
      pairedAt: DateTime.now(),
      permissions: const DevicePermissions(),
    );
    _pairedDevices[clientId] = paired;
    _trustedDevices[paired.deviceId] = TrustedDeviceRecord(
      deviceId: paired.deviceId,
      pairCode: paired.pairCode,
      deviceName: paired.deviceName,
      deviceType: paired.deviceType,
      protocolVersion: paired.protocolVersion,
      capabilities: paired.capabilities,
      permissions: TrustedPermissions(
        clipboard: paired.permissions.clipboard,
        media: paired.permissions.media,
        browser: paired.permissions.browser,
        window: paired.permissions.window,
        remoteInput: paired.permissions.remoteInput,
        textInput: paired.permissions.textInput,
      ),
      updatedAtEpochSeconds: DateTime.now().millisecondsSinceEpoch ~/ 1000,
    );
    unawaited(TrustStoreService.save(_trustedDevices));

    _emitPairedDevices();
    _log('Accepted request from ${request.deviceName} ($clientId)');
  }

  Future<void> rejectRequest(String clientId) async {
    final request = _pendingRequests.remove(clientId);
    _emitPendingRequests();

    if (request == null) {
      return;
    }

    final socket = _clients[clientId];
    if (socket == null) {
      _log('Request $clientId not found: client disconnected');
      return;
    }

    _send(socket, {
      'type': 'connect.rejected',
      'id': clientId,
      'message': 'Connection request rejected by server',
    });
    _log('Rejected request from ${request.deviceName} ($clientId)');
  }

  Future<void> updatePermissions(
    String clientId,
    DevicePermissions permissions,
  ) async {
    final paired = _pairedDevices[clientId];
    if (paired == null) {
      return;
    }

    final updated = paired.copyWith(permissions: permissions);
    _pairedDevices[clientId] = updated;

    _trustedDevices[updated.deviceId] = TrustedDeviceRecord(
      deviceId: updated.deviceId,
      pairCode: updated.pairCode,
      deviceName: updated.deviceName,
      deviceType: updated.deviceType,
      protocolVersion: updated.protocolVersion,
      capabilities: updated.capabilities,
      permissions: TrustedPermissions(
        clipboard: updated.permissions.clipboard,
        media: updated.permissions.media,
        browser: updated.permissions.browser,
        window: updated.permissions.window,
        remoteInput: updated.permissions.remoteInput,
        textInput: updated.permissions.textInput,
      ),
      updatedAtEpochSeconds: DateTime.now().millisecondsSinceEpoch ~/ 1000,
    );
    await TrustStoreService.save(_trustedDevices);

    _emitPairedDevices();
    _log('Updated permissions for ${updated.deviceName}');
  }

  Future<void> unpairDevice(String clientId) async {
    final paired = _pairedDevices.remove(clientId);
    if (paired == null) {
      return;
    }

    _trustedDevices.remove(paired.deviceId);
    await TrustStoreService.save(_trustedDevices);

    final socket = _clients[clientId];
    if (socket != null) {
      _send(socket, {
        'type': 'connect.rejected',
        'id': clientId,
        'message': 'Device was unpaired by server',
      });
      await socket.close();
    }

    _autoClipboardClients.remove(clientId);
    if (_autoClipboardClients.isEmpty) {
      _stopClipboardPolling();
    }

    _emitPairedDevices();
    _log('Unpaired ${paired.deviceName} ($clientId)');
  }

  void _send(WebSocket socket, Map<String, dynamic> data) {
    socket.add(jsonEncode(data));
  }

  void _broadcast(Map<String, dynamic> data, {String? excludeClientId}) {
    final payload = jsonEncode(data);
    for (final entry in _clients.entries) {
      if (excludeClientId != null && entry.key == excludeClientId) {
        continue;
      }
      entry.value.add(payload);
    }
  }

  Future<String> _resolveLocalIp() async {
    try {
      final interfaces = await NetworkInterface.list(
        includeLoopback: false,
        type: InternetAddressType.IPv4,
      );
      for (final interface in interfaces) {
        for (final address in interface.addresses) {
          if (!address.isLoopback) {
            return address.address;
          }
        }
      }
    } catch (_) {}

    return '127.0.0.1';
  }

  void _log(String message) {
    if (kDebugMode) {
      debugPrint('[LocalServer] $message');
    }
    if (!_logController.isClosed) {
      _logController.add(message);
    }
  }

  void _addRunning(bool value) {
    if (!_runningController.isClosed) {
      _runningController.add(value);
    }
  }

  void _addClientCount(int value) {
    if (!_clientCountController.isClosed) {
      _clientCountController.add(value);
    }
  }

  void _emitPendingRequests() {
    if (!_pendingRequestsController.isClosed) {
      _pendingRequestsController.add(currentPendingRequests);
    }
  }

  void _emitPairedDevices() {
    if (!_pairedDevicesController.isClosed) {
      _pairedDevicesController.add(currentPairedDevices);
    }
  }

  Future<void> _ensureClipboardPolling() async {
    if (_clipboardPollTimer != null) {
      return;
    }

    _lastClipboardText = await _hostController.readClipboardText();
    _clipboardPollTimer = Timer.periodic(
      const Duration(seconds: 1),
      (_) => unawaited(_pollClipboard()),
    );
  }

  void _stopClipboardPolling() {
    _clipboardPollTimer?.cancel();
    _clipboardPollTimer = null;
  }

  Future<void> _pollClipboard() async {
    if (_autoClipboardClients.isEmpty) {
      _stopClipboardPolling();
      return;
    }

    final text = await _hostController.readClipboardText();
    if (text == _lastClipboardText) {
      return;
    }

    _lastClipboardText = text;
    _broadcastClipboardUpdate(text, autoOnly: true);
  }

  void _broadcastClipboardUpdate(
    String text, {
    bool autoOnly = false,
    String? includeClientId,
  }) {
    for (final entry in _clients.entries) {
      final paired = _pairedDevices[entry.key];
      if (paired == null || !paired.permissions.clipboard) {
        continue;
      }
      if (autoOnly && !_autoClipboardClients.contains(entry.key)) {
        continue;
      }
      if (includeClientId != null &&
          entry.key != includeClientId &&
          autoOnly == false &&
          !_autoClipboardClients.contains(entry.key)) {
        continue;
      }
      _send(entry.value, {'type': 'clipboard.update', 'text': text});
    }
  }

  bool _isPairRequestFresh(int timestampSeconds, String nonce) {
    if (nonce.isEmpty || timestampSeconds <= 0) {
      return false;
    }

    final nowSeconds = DateTime.now().millisecondsSinceEpoch ~/ 1000;
    if ((nowSeconds - timestampSeconds).abs() > 120) {
      return false;
    }

    if (_seenNonces.contains(nonce)) {
      return false;
    }

    _seenNonces.add(nonce);
    if (_seenNonces.length > 3000) {
      _seenNonces.clear();
    }
    return true;
  }

  String _defaultServerName() {
    if (Platform.isAndroid) {
      return 'Android Phone';
    }
    if (Platform.isIOS) {
      return 'iPhone';
    }
    if (Platform.isWindows) {
      return 'Windows PC';
    }
    if (Platform.isMacOS) {
      return 'Mac';
    }
    if (Platform.isLinux) {
      return 'Linux PC';
    }

    final host = Platform.localHostname.trim();
    return host.isEmpty ? 'PCRemote Server' : host;
  }

  String _defaultDeviceType() {
    if (Platform.isWindows || Platform.isLinux || Platform.isMacOS) {
      return 'desktop';
    }
    if (Platform.isAndroid || Platform.isIOS) {
      return 'phone';
    }
    return 'unknown';
  }

  String _pluginForMessage(String type) {
    if (type == 'mouse' ||
        type == 'move' ||
        type == 'click' ||
        type == 'wheel') {
      return 'remote_input';
    }
    if (type.startsWith('browser_') ||
        type == 'previous_tab' ||
        type == 'next_tab' ||
        type == 'new_tab' ||
        type == 'close_tab') {
      return 'browser';
    }
    if (type.startsWith('media_') ||
        type.startsWith('seek_') ||
        type.startsWith('volume_') ||
        type == 'space') {
      return 'media';
    }
    if (type == 'send_text' || type == 'key_press' || type == 'key_combo') {
      return 'text_input';
    }
    if (type.startsWith('clipboard') ||
        type == 'get_clipboard' ||
        type == 'enable_auto_clipboard' ||
        type == 'disable_auto_clipboard' ||
        type.startsWith('set_clipboard')) {
      return 'clipboard';
    }
    if (type.contains('window') ||
        type == 'alt_tab' ||
        type == 'toggle_fullscreen') {
      return 'window';
    }
    return 'generic';
  }

  bool _canProcessPlugin(String clientId, String plugin) {
    if (plugin == 'generic') {
      return true;
    }

    final paired = _pairedDevices[clientId];
    if (paired == null) {
      return false;
    }

    return paired.permissions.allows(plugin);
  }

  TrustedDeviceRecord? _findTrustedByPairCode(String pairCode) {
    if (pairCode.isEmpty) {
      return null;
    }

    for (final record in _trustedDevices.values) {
      if (record.pairCode == pairCode) {
        return record;
      }
    }

    return null;
  }

  Future<void> _reloadTrustedDevices() async {
    try {
      _trustedDevices = await TrustStoreService.load();
    } catch (_) {
      // Ignore transient read failures and continue using in-memory cache.
    }
  }

  String _buildPairCode(String deviceId) {
    final cleaned =
        deviceId.replaceAll(RegExp(r'[^a-zA-Z0-9]'), '').toUpperCase();
    if (cleaned.length >= 6) {
      return cleaned.substring(cleaned.length - 6);
    }
    return cleaned.padLeft(6, '0');
  }

  void dispose() {
    final server = _server;
    _server = null;

    for (final socket in _clients.values) {
      unawaited(socket.close());
    }
    _clients.clear();
    _clientNames.clear();
    _pendingRequests.clear();
    _pairedDevices.clear();
    _seenNonces.clear();
    _autoClipboardClients.clear();
    _stopDiscovery();
    _stopClipboardPolling();

    if (server != null) {
      unawaited(server.close(force: true));
    }

    _runningController.close();
    _clientCountController.close();
    _logController.close();
    _pendingRequestsController.close();
    _pairedDevicesController.close();
  }
}

class ConnectionRequest {
  final String clientId;
  final String deviceId;
  final String pairCode;
  final String deviceName;
  final String deviceType;
  final int protocolVersion;
  final List<String> capabilities;
  final String nonce;
  final int timestamp;
  final int clientPort;
  final DateTime requestedAt;

  const ConnectionRequest({
    required this.clientId,
    required this.deviceId,
    this.pairCode = '',
    required this.deviceName,
    required this.deviceType,
    required this.protocolVersion,
    required this.capabilities,
    required this.nonce,
    required this.timestamp,
    required this.clientPort,
    required this.requestedAt,
  });
}

class PairedDevice {
  final String clientId;
  final String deviceId;
  final String pairCode;
  final String deviceName;
  final String deviceType;
  final int protocolVersion;
  final List<String> capabilities;
  final int clientPort;
  final DateTime pairedAt;
  final DevicePermissions permissions;

  const PairedDevice({
    required this.clientId,
    required this.deviceId,
    this.pairCode = '',
    required this.deviceName,
    required this.deviceType,
    required this.protocolVersion,
    required this.capabilities,
    required this.clientPort,
    required this.pairedAt,
    required this.permissions,
  });

  PairedDevice copyWith({
    DevicePermissions? permissions,
  }) {
    return PairedDevice(
      clientId: clientId,
      deviceId: deviceId,
      pairCode: pairCode,
      deviceName: deviceName,
      deviceType: deviceType,
      protocolVersion: protocolVersion,
      capabilities: capabilities,
      clientPort: clientPort,
      pairedAt: pairedAt,
      permissions: permissions ?? this.permissions,
    );
  }
}

class DevicePermissions {
  final bool clipboard;
  final bool media;
  final bool browser;
  final bool window;
  final bool remoteInput;
  final bool textInput;

  const DevicePermissions({
    this.clipboard = true,
    this.media = true,
    this.browser = true,
    this.window = true,
    this.remoteInput = true,
    this.textInput = true,
  });

  Map<String, dynamic> toJson() {
    return {
      'clipboard': clipboard,
      'media': media,
      'browser': browser,
      'window': window,
      'remoteInput': remoteInput,
      'textInput': textInput,
    };
  }

  factory DevicePermissions.fromJson(Map<String, dynamic> json) {
    return DevicePermissions(
      clipboard: json['clipboard'] != false,
      media: json['media'] != false,
      browser: json['browser'] != false,
      window: json['window'] != false,
      remoteInput: json['remoteInput'] != false,
      textInput: json['textInput'] != false,
    );
  }

  DevicePermissions copyWith({
    bool? clipboard,
    bool? media,
    bool? browser,
    bool? window,
    bool? remoteInput,
    bool? textInput,
  }) {
    return DevicePermissions(
      clipboard: clipboard ?? this.clipboard,
      media: media ?? this.media,
      browser: browser ?? this.browser,
      window: window ?? this.window,
      remoteInput: remoteInput ?? this.remoteInput,
      textInput: textInput ?? this.textInput,
    );
  }

  bool allows(String plugin) {
    switch (plugin) {
      case 'clipboard':
        return clipboard;
      case 'media':
        return media;
      case 'browser':
        return browser;
      case 'window':
        return window;
      case 'remote_input':
        return remoteInput;
      case 'text_input':
        return textInput;
      default:
        return false;
    }
  }
}
