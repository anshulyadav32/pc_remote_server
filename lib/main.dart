import 'dart:io';
import 'dart:convert';
import 'dart:math';
import 'dart:async';
import 'dart:ffi' hide Size;
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:permission_handler/permission_handler.dart';
import 'package:qr_flutter/qr_flutter.dart';
import 'package:wifi_iot/wifi_iot.dart';
import 'package:win32/win32.dart';
import 'package:ffi/ffi.dart';
import 'package:window_manager/window_manager.dart';
import 'package:flutter_blue_plus/flutter_blue_plus.dart';
import 'package:pc_remote_server/modules/bluetooth_module.dart';

void main() async {
  WidgetsFlutterBinding.ensureInitialized();
  await windowManager.ensureInitialized();

  windowManager.waitUntilReadyToShow(null, () async {
    await windowManager.setTitle('PC Remote Server');
    await windowManager.setSize(const Size(500, 700));
    await windowManager.setMinimumSize(const Size(500, 700));
    await windowManager.center();
    await windowManager.show();
    await windowManager.focus();
  });

  runApp(PCRemoteServerApp());
}

class PCRemoteServerApp extends StatelessWidget {
  const PCRemoteServerApp({super.key});

  @override
  Widget build(BuildContext context) {
    return MaterialApp(
      title: 'PC Remote Server',
      debugShowCheckedModeBanner: false,
      theme: ThemeData(
        primarySwatch: Colors.blue,
        useMaterial3: true,
      ),
      home: PCRemoteServerHomePage(),
    );
  }
}

class PCRemoteServerHomePage extends StatefulWidget {
  const PCRemoteServerHomePage({super.key});

  @override
  State<PCRemoteServerHomePage> createState() =>
      _PCRemoteServerHomePageState();
}

class _PCRemoteServerHomePageState extends State<PCRemoteServerHomePage>
    with WindowListener {
  static const int _tcpPort = 8765;
  static const int _udpDiscoveryPort = 8766;

  HttpServer? _server;
  RawDatagramSocket? _discoverySocket;
  RawDatagramSocket? _discoveryClientSocket;
  Timer? _discoveryClientTimeout;
  final Map<String, WebSocket> _webSocketClients = <String, WebSocket>{};
  final Map<String, String> _webSocketNames = <String, String>{};
  WebSocket? _peerWebSocket;
  String _peerConnectionStatus = 'Not connected';
  final Map<String, Map<String, String>> _discoveredServers =
      <String, Map<String, String>>{};
  bool _isRunning = false;
  bool _isDiscoveringServers = false;
  String _serverUrl = '';
  int _connectedClients = 0;
  String _localIP = '';

  // WiFi First: Start with Home (index 0)
  int _currentIndex = 0;

  // Bluetooth state
  bool _isBluetoothEnabled = false;
  late final bool _isBluetoothSupportedPlatform;
  late final bool _showBluetoothUi;
  final List<BluetoothScanDevice> _bluetoothDevices = [];
  final Map<String, String> _bluetoothDeviceNames = {};
  final Set<String> _connectedDeviceIds = <String>{};
  bool _isScanning = false;
  bool _autoConnectingFirstTwo = false;
  StreamSubscription? _scanSubscription;
  StreamSubscription? _adapterStateSubscription;
  bool _autoScanStarted = false;
  bool _wifiAutoPromptShown = false;

  // Clipboard history
  final List<String> _clipboardHistory = [];
  Timer? _clipboardTimer;
  String _lastClipboardContent = '';

  @override
  void initState() {
    super.initState();
    _isBluetoothSupportedPlatform = BluetoothModule.isSupportedPlatform;
    _showBluetoothUi = BluetoothModule.isBluetoothUiEnabled;
    windowManager.addListener(this);
    _getLocalIP();
    if (_showBluetoothUi) {
      _initBluetooth();
      _scheduleAutoScanOnLaunch();
    }
    _scheduleWifiAutoScanOnLaunch();
    _startClipboardPolling();
    _autoStartServer(); // Automatically start WiFi server
    Future.delayed(Duration(seconds: 2), () {
      if (mounted) {
        _discoverServersOnLan();
      }
    });
  }

  void _scheduleAutoScanOnLaunch() {
    if (_autoScanStarted || !_isBluetoothSupportedPlatform) {
      return;
    }

    _autoScanStarted = true;
    Future.delayed(Duration(seconds: 2), () {
      if (!mounted || _isScanning) {
        return;
      }
      _startBluetoothScan();
    });
  }

  void _scheduleWifiAutoScanOnLaunch() {
    if (_wifiAutoPromptShown || !Platform.isAndroid) {
      return;
    }

    _wifiAutoPromptShown = true;
    Future.delayed(Duration(seconds: 3), () async {
      if (!mounted) {
        return;
      }
      await _autoScanAndPromptWifiConnect();
    });
  }

  @override
  void dispose() {
    windowManager.removeListener(this);
    _disconnectPeerWebSocket();
    _stopServer();
    _clipboardTimer?.cancel();
    _scanSubscription?.cancel();
    _adapterStateSubscription?.cancel();
    _discoveryClientTimeout?.cancel();
    _discoveryClientSocket?.close();
    BluetoothModule.dispose();
    super.dispose();
  }

  void _startClipboardPolling() {
    _clipboardTimer = Timer.periodic(Duration(seconds: 1), (timer) async {
      try {
        final data = await Clipboard.getData('text/plain');
        if (data != null && data.text != null && data.text!.isNotEmpty) {
          final content = data.text!;
          if (content != _lastClipboardContent) {
            _lastClipboardContent = content;
            _addToClipboardHistory(content);
            _broadcastJson({
              'type': 'clipboard.update',
              'text': content,
              'timestamp': DateTime.now().toIso8601String(),
            });
          }
        }
      } catch (e) {
        debugPrint('Clipboard polling failed: $e');
      }
    });
  }

  void _getLocalIP() async {
    try {
      for (var interface in await NetworkInterface.list()) {
        for (var addr in interface.addresses) {
          if (addr.type == InternetAddressType.IPv4 && !addr.isLoopback) {
            if (mounted) {
              setState(() => _localIP = addr.address);
            }
            break;
          }
        }
      }
    } catch (e) {
      debugPrint('Failed to get local IP: $e');
    }
  }

  void _startServer() async {
    if (_isRunning) return;
    try {
      _server = await HttpServer.bind(InternetAddress.anyIPv4, _tcpPort);
      _serverUrl =
          'http://${_localIP.isEmpty ? "localhost" : _localIP}:$_tcpPort';
      if (mounted) {
        setState(() => _isRunning = true);
      }
      _server!.listen((HttpRequest request) => _handleHttpRequest(request));
      await _startUdpDiscovery();
      _showMessage('Server started: $_serverUrl');
    } catch (e) {
      _showMessage('Failed to start server: $e');
    }
  }

  void _stopServer() async {
    _stopUdpDiscovery();
    _disconnectPeerWebSocket();

    for (final socket in _webSocketClients.values) {
      await socket.close();
    }
    _webSocketClients.clear();
    _webSocketNames.clear();

    await _server?.close();
    if (mounted) {
      setState(() {
        _isRunning = false;
        _connectedClients = 0;
      });
    }
  }

  Future<void> _startUdpDiscovery() async {
    if (_discoverySocket != null) {
      return;
    }

    try {
      _discoverySocket = await RawDatagramSocket.bind(
          InternetAddress.anyIPv4, _udpDiscoveryPort);
      _discoverySocket!.broadcastEnabled = true;
      _discoverySocket!.listen((event) {
        if (event != RawSocketEvent.read) {
          return;
        }

        final datagram = _discoverySocket!.receive();
        if (datagram == null) {
          return;
        }

        _handleUdpDiscoveryPacket(datagram);
      });
    } catch (_) {
      _showMessage('UDP discovery unavailable on this network');
    }
  }

  void _stopUdpDiscovery() {
    _discoverySocket?.close();
    _discoverySocket = null;
  }

  void _handleUdpDiscoveryPacket(Datagram datagram) {
    try {
      final text = utf8.decode(datagram.data);
      final parsed = jsonDecode(text);
      if (parsed is! Map<String, dynamic>) {
        return;
      }

      final type = parsed['type']?.toString() ?? '';
      if (type != 'discover') {
        return;
      }

      final host = _localIP.isEmpty ? 'localhost' : _localIP;
      final payload = jsonEncode({
        'type': 'discover-ack',
        'name': 'PC Remote Server',
        'tcp': '$_tcpPort',
        'udp': '$_udpDiscoveryPort',
        'http': 'http://$host:$_tcpPort',
        'ws': 'ws://$host:$_tcpPort/ws',
      });

      _discoverySocket?.send(
        utf8.encode(payload),
        datagram.address,
        datagram.port,
      );
    } catch (_) {}
  }

  Future<void> _discoverServersOnLan() async {
    if (_isDiscoveringServers) {
      return;
    }

    _discoveryClientTimeout?.cancel();
    _discoveryClientSocket?.close();

    setState(() {
      _isDiscoveringServers = true;
      _discoveredServers.clear();
    });

    try {
      _discoveryClientSocket =
          await RawDatagramSocket.bind(InternetAddress.anyIPv4, 0);
      _discoveryClientSocket!.broadcastEnabled = true;
      _discoveryClientSocket!.listen((event) {
        if (event != RawSocketEvent.read) {
          return;
        }

        final datagram = _discoveryClientSocket?.receive();
        if (datagram == null) {
          return;
        }

        _handleDiscoveryAck(datagram);
      });

      final request = utf8.encode(jsonEncode({'type': 'discover'}));
      _discoveryClientSocket!
          .send(request, InternetAddress('255.255.255.255'), _udpDiscoveryPort);

      _discoveryClientTimeout = Timer(Duration(seconds: 3), () {
        _discoveryClientSocket?.close();
        _discoveryClientSocket = null;
        if (mounted) {
          setState(() => _isDiscoveringServers = false);
        }
      });
    } catch (_) {
      if (mounted) {
        setState(() => _isDiscoveringServers = false);
      }
      _showMessage('LAN discovery failed');
    }
  }

  void _handleDiscoveryAck(Datagram datagram) {
    try {
      final text = utf8.decode(datagram.data);
      final parsed = jsonDecode(text);
      if (parsed is! Map<String, dynamic>) {
        return;
      }

      if (parsed['type']?.toString() != 'discover-ack') {
        return;
      }

      final httpUrl = parsed['http']?.toString() ?? '';
      if (httpUrl.isEmpty) {
        return;
      }

      final key = parsed['ws']?.toString().isNotEmpty == true
          ? parsed['ws']!.toString()
          : httpUrl;

      final name = parsed['name']?.toString() ?? 'Unknown Server';
      final wsUrl = parsed['ws']?.toString() ?? '';
      final hostIp = datagram.address.address;

      if (!mounted) {
        return;
      }

      setState(() {
        _discoveredServers[key] = {
          'name': name,
          'http': httpUrl,
          'ws': wsUrl,
          'ip': hostIp,
        };
      });
    } catch (_) {}
  }

  void _useDiscoveredServer(Map<String, String> server) {
    final http = server['http'] ?? '';
    if (http.isEmpty) {
      return;
    }

    setState(() => _serverUrl = http);
    _showMessage('Selected server: $http');
    _connectPeerWebSocket(server);
  }

  Future<void> _connectPeerWebSocket(Map<String, String> server) async {
    final wsUrl = server['ws'] ?? '';
    if (wsUrl.isEmpty) {
      _showMessage('Discovered server has no WebSocket endpoint');
      return;
    }

    _disconnectPeerWebSocket();
    setState(() => _peerConnectionStatus = 'Connecting to peer...');

    try {
      final socket = await WebSocket.connect(wsUrl);
      _peerWebSocket = socket;
      setState(() => _peerConnectionStatus = 'Connected to peer');

      _sendJson(socket, {
        'type': 'pair',
        'deviceName': 'PC Remote App',
      });
      _sendJson(socket, {'type': 'ping'});

      socket.listen(
        (dynamic raw) => _handlePeerWebSocketMessage(raw),
        onDone: () {
          if (mounted) {
            setState(() => _peerConnectionStatus = 'Peer disconnected');
          }
          _peerWebSocket = null;
        },
        onError: (_) {
          if (mounted) {
            setState(() => _peerConnectionStatus = 'Peer connection error');
          }
          _peerWebSocket = null;
        },
      );
    } catch (e) {
      setState(() => _peerConnectionStatus = 'Failed peer connect');
      _showMessage('Failed to connect peer WebSocket');
    }
  }

  void _disconnectPeerWebSocket() {
    _peerWebSocket?.close();
    _peerWebSocket = null;
  }

  void _handlePeerWebSocketMessage(dynamic raw) {
    try {
      final parsed = jsonDecode(raw.toString());
      if (parsed is! Map<String, dynamic>) {
        return;
      }

      final type = parsed['type']?.toString() ?? '';
      if (type == 'clipboard.update') {
        final text = parsed['text']?.toString() ?? '';
        if (text.isNotEmpty) {
          Clipboard.setData(ClipboardData(text: text));
          _addToClipboardHistory(text);
        }
      }
    } catch (_) {}
  }

  void _handleHttpRequest(HttpRequest request) {
    final uri = request.uri;
    if (uri.path == '/' || uri.path == '/device/login') {
      _serveWebInterface(request);
    } else if (uri.path == '/ws') {
      _handleWebSocketUpgrade(request);
    } else if (uri.path == '/api/mouse') {
      _handleMouseCommand(request);
    } else {
      request.response.statusCode = 404;
      request.response.close();
    }
  }

  void _handleWebSocketUpgrade(HttpRequest request) async {
    try {
      final socket = await WebSocketTransformer.upgrade(request);
      final clientId = _createClientId();
      _webSocketClients[clientId] = socket;
      _webSocketNames[clientId] = 'Unknown Device';

      if (mounted) {
        setState(() => _connectedClients = _webSocketClients.length);
      }

      _sendJson(socket, {
        'type': 'hello',
        'id': clientId,
        'server': 'pc_remote_server',
        'protocol': 'json-websocket-v1'
      });

      socket.listen(
        (dynamic message) => _handleWebSocketMessage(clientId, message),
        onDone: () => _removeWebSocketClient(clientId),
        onError: (_) => _removeWebSocketClient(clientId),
      );
    } catch (e) {
      request.response.statusCode = HttpStatus.internalServerError;
      request.response.write('WebSocket upgrade failed');
      await request.response.close();
    }
  }

  void _removeWebSocketClient(String clientId) {
    _webSocketClients.remove(clientId);
    _webSocketNames.remove(clientId);
    if (mounted) {
      setState(() => _connectedClients = _webSocketClients.length);
    }
  }

  void _handleWebSocketMessage(String clientId, dynamic rawMessage) {
    try {
      final parsed = jsonDecode(rawMessage.toString());
      if (parsed is! Map<String, dynamic>) {
        return;
      }

      final type = parsed['type']?.toString() ?? '';
      switch (type) {
        case 'pair':
          final deviceName =
              parsed['deviceName']?.toString() ?? 'Unknown Device';
          _webSocketNames[clientId] = deviceName;
          final socket = _webSocketClients[clientId];
          if (socket != null) {
            _sendJson(
                socket, {'type': 'pair-ack', 'id': clientId, 'paired': true});
          }
          break;
        case 'ping':
          final socket = _webSocketClients[clientId];
          if (socket != null) {
            _sendJson(socket, {
              'type': 'pong',
              'timestamp': DateTime.now().toIso8601String()
            });
          }
          break;
        case 'clipboard.set':
          final text = parsed['text']?.toString() ?? '';
          Clipboard.setData(ClipboardData(text: text));
          _addToClipboardHistory(text);
          _broadcastJson(
              {'type': 'clipboard.update', 'text': text, 'from': clientId});
          break;
        case 'mouse':
          final action = parsed['action']?.toString() ?? '';
          if (action == 'move') {
            final dx = double.tryParse(parsed['deltaX'].toString()) ?? 0;
            final dy = double.tryParse(parsed['deltaY'].toString()) ?? 0;
            _moveMouse(dx, dy);
          } else if (action == 'click') {
            _clickMouse(parsed['button']?.toString() ?? 'left');
          }
          break;
      }
    } catch (_) {}
  }

  void _sendJson(WebSocket socket, Map<String, dynamic> message) {
    socket.add(jsonEncode(message));
  }

  void _broadcastJson(Map<String, dynamic> message) {
    final payload = jsonEncode(message);
    for (final socket in _webSocketClients.values) {
      socket.add(payload);
    }
  }

  String _createClientId() {
    final timestamp = DateTime.now().millisecondsSinceEpoch;
    final randomPart = Random().nextInt(999999).toString().padLeft(6, '0');
    return '$timestamp-$randomPart';
  }

  void _serveWebInterface(HttpRequest request) {
    final response = request.response;
    response.headers.contentType = ContentType.html;
    response.headers.add('Access-Control-Allow-Origin', '*');

    final html = '''
<!DOCTYPE html>
<html>
<head>
    <title>PC Remote</title>
    <meta name="viewport" content="width=device-width, initial-scale=1.0">
    <style>
        body { font-family: sans-serif; margin: 0; padding: 20px; background: #f0f2f5; display: flex; flex-direction: column; align-items: center; }
        .card { background: white; padding: 20px; border-radius: 15px; box-shadow: 0 4px 6px rgba(0,0,0,0.1); width: 100%; max-width: 400px; }
        .touchpad { width: 100%; height: 250px; background: #e9ecef; border-radius: 10px; margin: 20px 0; display: flex; align-items: center; justify-content: center; color: #6c757d; font-weight: bold; user-select: none; touch-action: none; }
        .btn-group { display: flex; gap: 10px; width: 100%; }
        .btn { flex: 1; padding: 15px; border: none; border-radius: 8px; background: #007bff; color: white; font-weight: bold; font-size: 16px; }
        .btn:active { background: #0056b3; transform: scale(0.98); }
    </style>
</head>
<body>
    <div class="card">
        <h2 style="text-align: center; margin-top: 0;">🖱️ PC Control</h2>
        <div class="touchpad" id="tp">TOUCHPAD</div>
        <div class="btn-group">
            <button class="btn" onclick="clickM('left')">LEFT</button>
            <button class="btn" onclick="clickM('right')">RIGHT</button>
        </div>
    </div>
    <script>
      const wsProtocol = location.protocol === 'https:' ? 'wss:' : 'ws:';
      const socket = new WebSocket(`\${wsProtocol}//\${location.host}/ws`);
      socket.onopen = () => {
        socket.send(JSON.stringify({ type: 'pair', deviceName: 'Web Controller' }));
        socket.send(JSON.stringify({ type: 'ping' }));
      };

        let lx = 0, ly = 0;
        const tp = document.getElementById('tp');
        tp.addEventListener('touchstart', e => { lx = e.touches[0].clientX; ly = e.touches[0].clientY; });
        tp.addEventListener('touchmove', e => {
            e.preventDefault();
            const dx = e.touches[0].clientX - lx;
            const dy = e.touches[0].clientY - ly;
            fetch('/api/mouse', { method: 'POST', body: JSON.stringify({ action: 'move', deltaX: dx, deltaY: dy }) });
            lx = e.touches[0].clientX; ly = e.touches[0].clientY;
        });
        function clickM(b) { fetch('/api/mouse', { method: 'POST', body: JSON.stringify({ action: 'click', button: b }) }); }
    </script>
</body>
</html>
''';
    response.write(html);
    response.close();
  }

  void _handleMouseCommand(HttpRequest request) async {
    try {
      if (request.method == 'POST') {
        final body = await utf8.decoder.bind(request).join();
        final data = jsonDecode(body);
        if (data['action'] == 'move') {
          _moveMouse(double.tryParse(data['deltaX'].toString()) ?? 0,
              double.tryParse(data['deltaY'].toString()) ?? 0);
        } else if (data['action'] == 'click') {
          _clickMouse(data['button']);
        }
      }
      request.response.statusCode = 200;
      request.response.close();
    } catch (e) {
      request.response.close();
    }
  }

  void _moveMouse(double dx, double dy) {
    final inputs = calloc<INPUT>(1);
    inputs[0].type = INPUT_TYPE.INPUT_MOUSE;
    inputs[0].mi.dx = (dx * 2).toInt();
    inputs[0].mi.dy = (dy * 2).toInt();
    inputs[0].mi.dwFlags = MOUSE_EVENT_FLAGS.MOUSEEVENTF_MOVE;

    SendInput(1, inputs, sizeOf<INPUT>());
    free(inputs);
  }

  void _clickMouse(String b) {
    final inputs = calloc<INPUT>(2);
    int down = b == 'left'
        ? MOUSE_EVENT_FLAGS.MOUSEEVENTF_LEFTDOWN
        : MOUSE_EVENT_FLAGS.MOUSEEVENTF_RIGHTDOWN;
    int up = b == 'left'
        ? MOUSE_EVENT_FLAGS.MOUSEEVENTF_LEFTUP
        : MOUSE_EVENT_FLAGS.MOUSEEVENTF_RIGHTUP;

    inputs[0].type = INPUT_TYPE.INPUT_MOUSE;
    inputs[0].mi.dwFlags = down;

    inputs[1].type = INPUT_TYPE.INPUT_MOUSE;
    inputs[1].mi.dwFlags = up;

    SendInput(2, inputs, sizeOf<INPUT>());
    free(inputs);
  }

  void _showMessage(String m) {
    if (!mounted) return;
    ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(content: Text(m), duration: Duration(seconds: 1)));
  }

  void _addToClipboardHistory(String t) {
    if (t.trim().isEmpty || _clipboardHistory.contains(t)) return;
    if (mounted) {
      setState(() {
        _clipboardHistory.insert(0, t);
        if (_clipboardHistory.length > 50) _clipboardHistory.removeLast();
      });
    }
  }

  void _autoStartServer() async {
    await Future.delayed(Duration(seconds: 1));
    if (!_isRunning) _startServer();
  }

  @override
  Widget build(BuildContext context) {
    final navItems = <BottomNavigationBarItem>[
      BottomNavigationBarItem(icon: Icon(Icons.home), label: 'Home'),
      if (_showBluetoothUi)
        BottomNavigationBarItem(icon: Icon(Icons.bluetooth), label: 'Connect'),
      BottomNavigationBarItem(icon: Icon(Icons.history), label: 'Clipboard'),
      BottomNavigationBarItem(icon: Icon(Icons.settings), label: 'Settings'),
    ];

    return Scaffold(
      appBar: AppBar(
        title: Text('PC Remote Server'),
        backgroundColor: Colors.blue,
        foregroundColor: Colors.white,
        centerTitle: true,
      ),
      body: _getCurrentPage(),
      bottomNavigationBar: BottomNavigationBar(
        currentIndex: _currentIndex,
        onTap: (index) {
          if (mounted) {
            setState(() => _currentIndex = index);
          }
          final bluetoothTabIndex = _showBluetoothUi ? 1 : -1;
          if (index == bluetoothTabIndex && !_isScanning) {
            _startBluetoothScan();
          } else if (index == 1 && !_showBluetoothUi) {
            _showMessage('Bluetooth scan is not supported on this platform');
          }
        },
        selectedItemColor: Colors.blue,
        unselectedItemColor: Colors.grey,
        type: BottomNavigationBarType.fixed,
        items: navItems,
      ),
    );
  }

  Widget _getCurrentPage() {
    if (_showBluetoothUi) {
      switch (_currentIndex) {
        case 0:
          return _buildHomePage();
        case 1:
          return _buildConnectivityPage();
        case 2:
          return _buildClipboardHistoryPage();
        case 3:
          return _buildSettingsPage();
        default:
          return _buildHomePage();
      }
    }

    switch (_currentIndex) {
      case 0:
        return _buildHomePage();
      case 1:
        return _buildClipboardHistoryPage();
      case 2:
        return _buildSettingsPage();
      default:
        return _buildHomePage();
    }
  }

  Widget _buildHomePage() {
    final connectedBluetoothNames = _connectedDeviceIds
        .map((id) => _bluetoothDeviceNames[id] ?? 'Unknown Device')
        .toList(growable: false);

    return SingleChildScrollView(
      padding: EdgeInsets.all(20),
      child: Center(
        child: Column(
          mainAxisAlignment: MainAxisAlignment.center,
          children: [
            _serverUrl.isNotEmpty
                ? QrImageView(data: _serverUrl, size: 200)
                : CircularProgressIndicator(),
            SizedBox(height: 20),
            Text('WiFi Control Ready',
                style: TextStyle(fontSize: 18, fontWeight: FontWeight.bold)),
            SizedBox(height: 5),
            Text('Scan to control your PC',
                style: TextStyle(color: Colors.grey)),
            SizedBox(height: 10),
            Text(_serverUrl,
                style:
                    TextStyle(color: Colors.blue, fontWeight: FontWeight.bold)),
            SizedBox(height: 6),
            Text('Connected devices: $_connectedClients',
                style: TextStyle(color: Colors.black54)),
            SizedBox(height: 4),
            Text('Peer link: $_peerConnectionStatus',
                style: TextStyle(color: Colors.black54)),
            if (connectedBluetoothNames.isNotEmpty) ...[
              SizedBox(height: 8),
              Align(
                alignment: Alignment.centerLeft,
                child: Text('Connected Bluetooth:',
                    style: TextStyle(fontWeight: FontWeight.w600)),
              ),
              SizedBox(height: 4),
              Wrap(
                spacing: 6,
                runSpacing: 6,
                children: connectedBluetoothNames
                    .map((name) => Chip(label: Text(name)))
                    .toList(),
              ),
            ],
            SizedBox(height: 12),
            ElevatedButton.icon(
              onPressed: _isDiscoveringServers ? null : _discoverServersOnLan,
              icon: Icon(Icons.wifi_find),
              label: Text(_isDiscoveringServers
                  ? 'Discovering LAN...'
                  : 'Discover LAN Servers'),
            ),
            if (_discoveredServers.isNotEmpty) ...[
              SizedBox(height: 12),
              Align(
                alignment: Alignment.centerLeft,
                child: Text('Found Servers',
                    style:
                        TextStyle(fontSize: 16, fontWeight: FontWeight.bold)),
              ),
              SizedBox(height: 8),
              ..._discoveredServers.values.map((server) {
                final name = server['name'] ?? 'Unknown Server';
                final ip = server['ip'] ?? '';
                final http = server['http'] ?? '';
                return Card(
                  margin: EdgeInsets.only(bottom: 8),
                  child: ListTile(
                    leading: Icon(Icons.devices),
                    title: Text(name),
                    subtitle: Text(ip.isEmpty ? http : '$ip\n$http'),
                    isThreeLine: ip.isNotEmpty,
                    trailing: TextButton(
                      onPressed: () => _useDiscoveredServer(server),
                      child: Text('Use'),
                    ),
                  ),
                );
              }),
            ],
            SizedBox(height: 18),
            ElevatedButton(
              onPressed: _isRunning ? _stopServer : _startServer,
              style: ElevatedButton.styleFrom(
                backgroundColor: _isRunning ? Colors.red : Colors.green,
                foregroundColor: Colors.white,
                padding: EdgeInsets.symmetric(horizontal: 40, vertical: 15),
              ),
              child: Text(_isRunning ? 'Stop Server' : 'Start Server'),
            ),
          ],
        ),
      ),
    );
  }

  Widget _buildConnectivityPage() {
    if (!_isBluetoothSupportedPlatform) {
      return Padding(
        padding: EdgeInsets.all(20),
        child: Center(
          child: Text(
            'Bluetooth is not supported on this platform.\nUse Android or iOS for Bluetooth pairing.',
            textAlign: TextAlign.center,
            style: TextStyle(color: Colors.grey, fontSize: 16),
          ),
        ),
      );
    }

    return Padding(
      padding: EdgeInsets.all(20),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          Row(
            mainAxisAlignment: MainAxisAlignment.spaceBetween,
            children: [
              Text('Bluetooth Devices',
                  style: TextStyle(fontSize: 22, fontWeight: FontWeight.bold)),
              if (_isScanning) CircularProgressIndicator(strokeWidth: 2),
            ],
          ),
          SizedBox(height: 10),
          Text(
            _isBluetoothEnabled ? 'Adapter: ON' : 'Adapter: OFF',
            style: TextStyle(
                color: _isBluetoothEnabled ? Colors.green : Colors.orange),
          ),
          SizedBox(height: 10),
          Row(
            children: [
              Expanded(
                child: ElevatedButton.icon(
                  onPressed: _isScanning ? null : _startBluetoothScan,
                  icon: Icon(Icons.search),
                  label: Text('Scan for Devices'),
                ),
              ),
              SizedBox(width: 10),
              IconButton(
                onPressed: _stopBluetoothScan,
                icon: Icon(Icons.stop, color: Colors.red),
                tooltip: 'Stop Scan',
              ),
            ],
          ),
          SizedBox(height: 10),
          ElevatedButton.icon(
            onPressed: _isScanning || _bluetoothDevices.length < 2
                ? null
                : _connectFirstTwoDevices,
            icon: Icon(Icons.link),
            label: Text('Connect First 2 Devices'),
          ),
          SizedBox(height: 20),
          Expanded(
            child: _bluetoothDevices.isEmpty
                ? Center(
                    child: Text('No devices found.\nMake sure Bluetooth is on.',
                        textAlign: TextAlign.center,
                        style: TextStyle(color: Colors.grey)))
                : ListView.builder(
                    itemCount: _bluetoothDevices.length,
                    itemBuilder: (context, index) {
                      final d = _bluetoothDevices[index];
                      final name =
                          _bluetoothDeviceNames[d.id] ?? 'Unknown Device';
                      return Card(
                        margin: EdgeInsets.only(bottom: 10),
                        child: ListTile(
                          leading: Icon(Icons.bluetooth, color: Colors.blue),
                          title: Row(
                            children: [
                              Expanded(child: Text(name)),
                              if (_connectedDeviceIds.contains(d.id))
                                Container(
                                  padding: EdgeInsets.symmetric(
                                      horizontal: 8, vertical: 2),
                                  decoration: BoxDecoration(
                                    color: Colors.green.shade100,
                                    borderRadius: BorderRadius.circular(12),
                                  ),
                                  child: Text(
                                    'Connected',
                                    style: TextStyle(
                                      color: Colors.green.shade800,
                                      fontSize: 11,
                                      fontWeight: FontWeight.w600,
                                    ),
                                  ),
                                ),
                            ],
                          ),
                          subtitle: Text('Bluetooth device'),
                          trailing: ElevatedButton(
                            onPressed: () => _connectBluetoothDevice(d),
                            child: Text(_connectedDeviceIds.contains(d.id)
                                ? 'Reconnect'
                                : 'Connect'),
                          ),
                        ),
                      );
                    },
                  ),
          ),
        ],
      ),
    );
  }

  Widget _buildClipboardHistoryPage() {
    return Column(
      children: [
        Padding(
          padding: EdgeInsets.all(16),
          child: Row(
            mainAxisAlignment: MainAxisAlignment.spaceBetween,
            children: [
              Text('Clipboard History',
                  style: TextStyle(fontSize: 20, fontWeight: FontWeight.bold)),
              IconButton(
                  icon: Icon(Icons.delete_sweep),
                  onPressed: () => setState(() => _clipboardHistory.clear())),
            ],
          ),
        ),
        Expanded(
          child: _clipboardHistory.isEmpty
              ? Center(
                  child: Text('History is empty',
                      style: TextStyle(color: Colors.grey)))
              : ListView.builder(
                  itemCount: _clipboardHistory.length,
                  itemBuilder: (context, index) => ListTile(
                    leading: Icon(Icons.content_paste),
                    title: Text(_clipboardHistory[index],
                        maxLines: 1, overflow: TextOverflow.ellipsis),
                    onTap: () {
                      Clipboard.setData(
                          ClipboardData(text: _clipboardHistory[index]));
                      _showMessage('Copied to system clipboard');
                    },
                    trailing: IconButton(
                        icon: Icon(Icons.delete_outline),
                        onPressed: () =>
                            setState(() => _clipboardHistory.removeAt(index))),
                  ),
                ),
        ),
      ],
    );
  }

  Widget _buildSettingsPage() {
    return ListView(
      padding: EdgeInsets.all(20),
      children: [
        ListTile(
          leading: Icon(Icons.info_outline),
          title: Text('App Version'),
          subtitle: Text('1.0.0'),
        ),
        ListTile(
          leading: Icon(Icons.security),
          title: Text('Firewall Check'),
          subtitle: Text('Check if port 8765 is open'),
          onTap: () async {
            try {
              final t = await HttpServer.bind(InternetAddress.anyIPv4, 8765);
              await t.close();
              _showMessage('✅ Port 8765 is available');
            } catch (e) {
              _showMessage('❌ Port 8765 might be blocked');
            }
          },
        ),
        if (Platform.isAndroid)
          ListTile(
            leading: Icon(Icons.wifi_find),
            title: Text('WiFi Auto Scan & Connect'),
            subtitle: Text('Scan WiFi and ask to connect with key'),
            onTap: _autoScanAndPromptWifiConnect,
          ),
      ],
    );
  }

  Future<void> _autoScanAndPromptWifiConnect() async {
    if (!Platform.isAndroid) {
      return;
    }

    final permissionStatus = await Permission.locationWhenInUse.request();
    if (!permissionStatus.isGranted && !permissionStatus.isLimited) {
      _showMessage('Location permission is required for WiFi scan');
      return;
    }

    final wifiEnabled = await WiFiForIoTPlugin.isEnabled();
    if (!wifiEnabled) {
      _showMessage('Turn on WiFi to scan networks');
      return;
    }

    // ignore: deprecated_member_use
    final networks = await WiFiForIoTPlugin.loadWifiList();
    if (networks.isEmpty) {
      _showMessage('No WiFi networks found');
      return;
    }

    networks.removeWhere((n) => (n.ssid ?? '').trim().isEmpty);
    if (networks.isEmpty) {
      _showMessage('No visible WiFi SSID found');
      return;
    }

    networks.sort((a, b) {
      final left = int.tryParse('${a.level}') ?? -200;
      final right = int.tryParse('${b.level}') ?? -200;
      return right.compareTo(left);
    });

    final ssid = networks.first.ssid;
    if (ssid == null || ssid.trim().isEmpty) {
      _showMessage('No valid WiFi SSID found');
      return;
    }
    final key = await _showWifiConnectPopup(ssid);
    if (key == null) {
      _showMessage('WiFi connect canceled');
      return;
    }

    if (key.trim().isEmpty) {
      _showMessage('WiFi key is required');
      return;
    }

    final connected = await WiFiForIoTPlugin.connect(
      ssid,
      password: key.trim(),
      security: NetworkSecurity.WPA,
      joinOnce: false,
    );

    _showMessage(
      connected ? 'Connected to $ssid' : 'Failed to connect to $ssid',
    );
  }

  Future<String?> _showWifiConnectPopup(String ssid) async {
    final keyController = TextEditingController();

    final result = await showDialog<String>(
      context: context,
      builder: (context) {
        return AlertDialog(
          title: Text('WiFi Auto Connect'),
          content: Column(
            mainAxisSize: MainAxisSize.min,
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Text('Found network: $ssid'),
              SizedBox(height: 10),
              Text('Connect to this network? (Yes/No)'),
              SizedBox(height: 10),
              TextField(
                controller: keyController,
                obscureText: true,
                decoration: InputDecoration(
                  labelText: 'WiFi key / code',
                  border: OutlineInputBorder(),
                ),
              ),
            ],
          ),
          actions: [
            TextButton(
              onPressed: () => Navigator.of(context).pop(),
              child: Text('No'),
            ),
            ElevatedButton(
              onPressed: () => Navigator.of(context).pop(keyController.text),
              child: Text('Yes'),
            ),
          ],
        );
      },
    );

    keyController.dispose();
    return result;
  }

  void _initBluetooth() async {
    if (!_isBluetoothSupportedPlatform) {
      return;
    }

    try {
      final hasPermissions = await BluetoothModule.requestPermissions();
      if (!hasPermissions) {
        _showMessage('Bluetooth permissions are required');
        return;
      }

      _adapterStateSubscription =
          BluetoothModule.adapterStateStream.listen((state) {
        if (mounted) {
          setState(
              () => _isBluetoothEnabled = state == BluetoothAdapterState.on);
        }
      });
    } catch (e) {
      _showMessage('Bluetooth is unavailable on this device');
    }
  }

  void _startBluetoothScan() async {
    if (!_isBluetoothSupportedPlatform) {
      _showMessage('Bluetooth scan is not supported on this platform');
      return;
    }

    try {
      final hasPermissions = await BluetoothModule.requestPermissions();
      if (!hasPermissions) {
        _showMessage('Please grant Bluetooth permissions to scan devices');
        return;
      }

      if (!await BluetoothModule.isSupported) {
        _showMessage('BT not supported');
        return;
      }
    } catch (e) {
      _showMessage('Bluetooth is unavailable on this device');
      return;
    }
    if (mounted) {
      setState(() {
        _isScanning = true;
        _bluetoothDevices.clear();
        _bluetoothDeviceNames.clear();
        _connectedDeviceIds.clear();
      });
    }
    _scanSubscription?.cancel();
    _scanSubscription = BluetoothModule.scanResultsStream.listen((results) {
      if (!mounted) return;
      setState(() {
        _bluetoothDevices
          ..clear()
          ..addAll(results);
        for (final device in results) {
          _bluetoothDeviceNames[device.id] = device.name;
        }
      });
    });
    try {
      await BluetoothModule.startScan();
    } catch (e) {
      debugPrint('Bluetooth scan start failed: $e');
    }
    Future.delayed(Duration(seconds: 15), () {
      if (mounted) {
        setState(() => _isScanning = false);
        if (_bluetoothDevices.length >= 2 && !_autoConnectingFirstTwo) {
          _connectFirstTwoDevices(silent: true);
        }
      }
    });
  }

  void _stopBluetoothScan() async {
    if (!_isBluetoothSupportedPlatform) {
      return;
    }

    try {
      await BluetoothModule.stopScan();
    } catch (e) {
      _showMessage('Unable to stop Bluetooth scan');
    }
    if (mounted) {
      setState(() => _isScanning = false);
    }
  }

  Future<void> _connectBluetoothDevice(BluetoothScanDevice device) async {
    if (!_isBluetoothSupportedPlatform) {
      _showMessage('Bluetooth connect is not supported on this platform');
      return;
    }

    try {
      final hasPermissions = await BluetoothModule.requestPermissions();
      if (!hasPermissions) {
        _showMessage('Please grant Bluetooth permissions to connect');
        return;
      }

      _showMessage('Connecting...');
      await BluetoothModule.connectDevice(device);
      if (mounted) {
        setState(() => _connectedDeviceIds.add(device.id));
      }
      _showMessage('Connected to ${_bluetoothDeviceNames[device.id]}');
    } catch (e) {
      _showMessage('Connection failed');
    }
  }

  Future<void> _connectFirstTwoDevices({bool silent = false}) async {
    if (_bluetoothDevices.length < 2) {
      if (!silent) {
        _showMessage('Need at least 2 Bluetooth devices in scan results');
      }
      return;
    }

    _autoConnectingFirstTwo = true;
    try {
      if (!silent) {
        _showMessage('Connecting first 2 devices...');
      }
      await _connectBluetoothDevice(_bluetoothDevices[0]);
      await Future.delayed(Duration(milliseconds: 300));
      await _connectBluetoothDevice(_bluetoothDevices[1]);
    } finally {
      _autoConnectingFirstTwo = false;
    }
  }
}
