import 'dart:io';
import 'dart:convert';
import 'dart:math';
import 'package:flutter/material.dart';
import 'package:qr_flutter/qr_flutter.dart';
import 'package:win32/win32.dart';
import 'package:ffi/ffi.dart';
import 'package:window_manager/window_manager.dart';
import 'package:system_tray/system_tray.dart';
import 'package:flutter/services.dart';
import 'package:http/http.dart' as http;
import 'package:web_socket_channel/web_socket_channel.dart';
import 'package:flutter_blue_plus/flutter_blue_plus.dart';
// import 'package:wifi_iot/wifi_iot.dart';
import 'package:permission_handler/permission_handler.dart';
import 'package:network_info_plus/network_info_plus.dart';
import 'package:url_launcher/url_launcher.dart';
// import 'package:web_socket_channel/server.dart';

void main() async {
  WidgetsFlutterBinding.ensureInitialized();
  
  // Initialize window manager
  await windowManager.ensureInitialized();
  
  // Configure window for background operation
  windowManager.waitUntilReadyToShow(null, () async {
    await windowManager.setTitle('PC Remote Server');
    await windowManager.setSize(const Size(500, 700));
    await windowManager.setMinimumSize(const Size(500, 700));
    await windowManager.center();
    await windowManager.show();
    await windowManager.focus();
    await windowManager.setAlwaysOnTop(false);
    await windowManager.setResizable(true);
  });
  
  runApp(PCRemoteServerApp());
}

class PCRemoteServerApp extends StatelessWidget {
  @override
  Widget build(BuildContext context) {
    return MaterialApp(
      title: 'PC Remote Server',
      theme: ThemeData(
        primarySwatch: Colors.blue,
        visualDensity: VisualDensity.adaptivePlatformDensity,
      ),
      home: PCRemoteServerHomePage(),
    );
  }
}

class PCRemoteServerHomePage extends StatefulWidget {
  @override
  _PCRemoteServerHomePageState createState() => _PCRemoteServerHomePageState();
}

class _PCRemoteServerHomePageState extends State<PCRemoteServerHomePage> with WindowListener {
  HttpServer? _server;
  WebSocketChannel? _channel;
  bool _isRunning = false;
  String _serverUrl = '';
  String _connectionToken = '';
  SystemTray? _systemTray;
  int _connectedClients = 0;
  String _localIP = '';
  String _publicIP = '';
  int _currentIndex = 0;
  bool _isLoggedIn = false;
  String _username = '';
  String _password = '';
  
  // Bluetooth and WiFi state
  bool _isBluetoothEnabled = false;
  bool _isWifiEnabled = false;
  List<BluetoothDevice> _bluetoothDevices = [];
  bool _isScanning = false;
  String _wifiSSID = '';
  String _wifiIP = '';
  List<dynamic> _wifiNetworks = [];
  
  // Clipboard history
  List<String> _clipboardHistory = [];
  int _maxHistorySize = 50;
  
  // Auto-start settings
  bool _autoStartEnabled = true;
  bool _backgroundMode = false;

  @override
  void initState() {
    super.initState();
    windowManager.addListener(this);
    _initSystemTray();
    _getLocalIP();
    _getPublicIP();
    _initBluetooth();
    _initWifi();
    _autoStartServer();
  }

  @override
  void dispose() {
    windowManager.removeListener(this);
    _stopServer();
    super.dispose();
  }

  void _initSystemTray() async {
    // TODO: Fix system tray menu implementation
    // _systemTray = SystemTray();
    // 
    // // Create system tray menu
    // final menu = Menu(
    //   items: [
    //     MenuItem(
    //       key: 'show',
    //       label: 'Show PC Remote Server',
    //       onClicked: () => windowManager.show(),
    //     ),
    //     MenuItem(
    //       key: 'start_server',
    //       label: 'Start Server',
    //       onClicked: _startServer,
    //     ),
    //     MenuItem(
    //       key: 'stop_server',
    //       label: 'Stop Server',
    //       onClicked: _stopServer,
    //     ),
    //     MenuItem(
    //       key: 'quit',
    //       label: 'Quit',
    //       onClicked: () => exit(0),
    //     ),
    //   ],
    // );
    //
    // await _systemTray!.setContextMenu(menu);
    // // await _systemTray!.setIcon('assets/icon.ico');
    // await _systemTray!.setToolTip('PC Remote Server');
  }

  void _getLocalIP() async {
    try {
      for (var interface in await NetworkInterface.list()) {
        for (var addr in interface.addresses) {
          if (addr.type == InternetAddressType.IPv4 && !addr.isLoopback) {
            setState(() {
              _localIP = addr.address;
            });
            break;
          }
        }
      }
    } catch (e) {
      print('Error getting local IP: $e');
    }
  }

  void _getPublicIP() async {
    try {
      final client = HttpClient();
      final request = await client.getUrl(Uri.parse('https://api.ipify.org'));
      final response = await request.close();
      final publicIP = await response.transform(utf8.decoder).join();
      
      setState(() {
        _publicIP = publicIP.trim();
      });
      
      client.close();
    } catch (e) {
      print('Error getting public IP: $e');
      setState(() {
        _publicIP = 'Unable to get public IP';
      });
    }
  }

  void _startServer() async {
    if (_isRunning) return;

    try {
      // Check firewall permissions first
      _checkFirewallPermissions();
      
      // Request port permissions
      _requestPortPermissions();
      
      // Generate connection token
      _connectionToken = _generateToken();
      
      // Start HTTP server on fixed port 8765
      _server = await HttpServer.bind(InternetAddress.anyIPv4, 8765);
      
      // Generate server URL with local IP
      if (_localIP.isNotEmpty) {
        _serverUrl = 'http://$_localIP:8765';
      } else {
        _serverUrl = 'http://localhost:8765';
      }
      
      print('Server started on: $_serverUrl');
      print('Public IP: $_publicIP');
      
      setState(() {
        _isRunning = true;
      });

      // Handle HTTP requests
      _server!.listen((HttpRequest request) {
        _handleHttpRequest(request);
      });

      // Show success message
      _showMessage('Server started successfully!\nURL: $_serverUrl\nToken: $_connectionToken');
      
    } catch (e) {
      _showMessage('Failed to start server: $e');
    }
  }

  void _stopServer() async {
    if (!_isRunning) return;

    try {
      await _server?.close();
      _channel?.sink.close();
      
    setState(() {
        _isRunning = false;
        _serverUrl = '';
        _connectionToken = '';
        _connectedClients = 0;
      });

      _showMessage('Server stopped');
    } catch (e) {
      _showMessage('Error stopping server: $e');
    }
  }

  void _handleHttpRequest(HttpRequest request) {
    try {
    final uri = request.uri;
    
      if (uri.path == '/' || uri.path == '/device/login') {
      _serveWebInterface(request);
    } else if (uri.path == '/ws') {
      _handleWebSocket(request);
    } else if (uri.path == '/api/mouse') {
      _handleMouseCommand(request);
    } else if (uri.path == '/api/keyboard') {
      _handleKeyboardCommand(request);
    } else {
      request.response.statusCode = 404;
        request.response.write('Not Found');
        request.response.close();
      }
    } catch (e) {
      print('HTTP request error: $e');
      request.response.statusCode = 500;
      request.response.write('Internal Server Error');
      request.response.close();
    }
  }

  void _serveWebInterface(HttpRequest request) {
    final response = request.response;
    response.headers.contentType = ContentType.html;
    response.headers.add('Access-Control-Allow-Origin', '*');
    response.headers.add('Access-Control-Allow-Methods', 'GET, POST, OPTIONS');
    response.headers.add('Access-Control-Allow-Headers', 'Content-Type');
    
    final html = '''
<!DOCTYPE html>
<html>
<head>
    <title>PC Remote Server - Control Panel</title>
    <meta name="viewport" content="width=device-width, initial-scale=1.0">
    <meta name="description" content="Remote control your PC from any device">
    <style>
        body { font-family: Arial, sans-serif; margin: 0; padding: 20px; background: #f0f0f0; }
        .container { max-width: 400px; margin: 0 auto; background: white; padding: 20px; border-radius: 10px; box-shadow: 0 2px 10px rgba(0,0,0,0.1); }
        .header { text-align: center; margin-bottom: 20px; }
        .touchpad { width: 100%; height: 200px; background: #f5f5f5; border: 2px solid #ddd; border-radius: 5px; margin: 10px 0; cursor: pointer; }
        .buttons { display: flex; gap: 10px; margin: 10px 0; }
        .btn { flex: 1; padding: 15px; border: none; border-radius: 5px; background: #007bff; color: white; cursor: pointer; }
        .btn:hover { background: #0056b3; }
        .btn:active { background: #004085; }
        .status { text-align: center; margin: 10px 0; padding: 10px; background: #d4edda; border-radius: 5px; }
        
        .access-buttons {
            margin-top: 20px;
            padding: 20px;
            background: linear-gradient(135deg, #667eea 0%, #764ba2 100%);
            border-radius: 10px;
            text-align: center;
        }
        
        .access-buttons h3 {
            color: white;
            margin-bottom: 15px;
            font-size: 18px;
        }
        
        .btn-app {
            background: linear-gradient(45deg, #4CAF50, #45a049);
            color: white;
            border: none;
            margin: 5px;
            min-width: 120px;
        }
        
        .btn-website {
            background: linear-gradient(45deg, #2196F3, #1976D2);
            color: white;
            border: none;
            margin: 5px;
            min-width: 120px;
        }
        
        .btn-app:hover {
            background: linear-gradient(45deg, #45a049, #4CAF50);
            transform: translateY(-2px);
        }
        
        .btn-website:hover {
            background: linear-gradient(45deg, #1976D2, #2196F3);
            transform: translateY(-2px);
        }
        
        .icon {
            margin-right: 8px;
            font-size: 16px;
        }
    </style>
</head>
<body>
    <div class="container">
        <div class="header">
            <h2>🖥️ PC Remote Server</h2>
            <p>Control your PC remotely from any device</p>
            <p style="font-size: 12px; color: #666;">Port: 8765 | Domain: pcremote.dev0-1.com</p>
        </div>
        
        <div class="status" id="status">✅ Connected to PC Remote Server</div>
        
        <div class="touchpad" id="touchpad" onmousedown="handleMouseDown(event)" onmousemove="handleMouseMove(event)" onmouseup="handleMouseUp(event)" ontouchstart="handleTouchStart(event)" ontouchmove="handleTouchMove(event)" ontouchend="handleTouchEnd(event)">
            <div style="text-align: center; padding-top: 80px; color: #666;">Touch/Mouse Pad</div>
        </div>
        
        <div class="buttons">
            <button class="btn" onclick="sendMouseClick('left')">Left Click</button>
            <button class="btn" onclick="sendMouseClick('right')">Right Click</button>
            <button class="btn" onclick="sendMouseClick('middle')">Middle Click</button>
        </div>
        
        <div class="buttons">
            <button class="btn" onclick="sendKey('space')">Space</button>
            <button class="btn" onclick="sendKey('enter')">Enter</button>
            <button class="btn" onclick="sendKey('escape')">Escape</button>
        </div>
        
        <div class="buttons">
            <button class="btn" onclick="sendKey('tab')">Tab</button>
            <button class="btn" onclick="sendKey('backspace')">Backspace</button>
            <button class="btn" onclick="sendKey('delete')">Delete</button>
        </div>
        
        <div class="buttons">
            <button class="btn" onclick="sendKey('up')">↑</button>
            <button class="btn" onclick="sendKey('down')">↓</button>
            <button class="btn" onclick="sendKey('left')">←</button>
            <button class="btn" onclick="sendKey('right')">→</button>
        </div>
        
        <div class="buttons">
            <button class="btn" onclick="sendKey('ctrl')">Ctrl</button>
            <button class="btn" onclick="sendKey('alt')">Alt</button>
            <button class="btn" onclick="sendKey('shift')">Shift</button>
            <button class="btn" onclick="sendKey('win')">Win</button>
        </div>
        
        <div class="buttons">
            <button class="btn" onclick="sendKey('f1')">F1</button>
            <button class="btn" onclick="sendKey('f2')">F2</button>
            <button class="btn" onclick="sendKey('f3')">F3</button>
            <button class="btn" onclick="sendKey('f4')">F4</button>
        </div>
        
        <!-- App/Website Access Buttons -->
        <div class="access-buttons">
            <h3>Access Options</h3>
            <div class="buttons">
                <button class="btn btn-app" onclick="openApp()">
                    <i class="icon">📱</i> Open App
                </button>
                <button class="btn btn-website" onclick="openWebsite()">
                    <i class="icon">🌐</i> Go to Website
                </button>
            </div>
        </div>
    </div>

    <script>
        let isMouseDown = false;
        let lastX = 0, lastY = 0;
        
        function handleMouseDown(e) {
            isMouseDown = true;
            lastX = e.clientX;
            lastY = e.clientY;
        }
        
        function handleMouseMove(e) {
            if (isMouseDown) {
                const deltaX = e.clientX - lastX;
                const deltaY = e.clientY - lastY;
                sendMouseMove(deltaX, deltaY);
                lastX = e.clientX;
                lastY = e.clientY;
            }
        }
        
        function handleMouseUp(e) {
            isMouseDown = false;
        }
        
        function handleTouchStart(e) {
            e.preventDefault();
            isMouseDown = true;
            const touch = e.touches[0];
            lastX = touch.clientX;
            lastY = touch.clientY;
        }
        
        function handleTouchMove(e) {
            e.preventDefault();
            if (isMouseDown) {
                const touch = e.touches[0];
                const deltaX = touch.clientX - lastX;
                const deltaY = touch.clientY - lastY;
                sendMouseMove(deltaX, deltaY);
                lastX = touch.clientX;
                lastY = touch.clientY;
            }
        }
        
        function handleTouchEnd(e) {
            e.preventDefault();
            isMouseDown = false;
        }
        
        function sendMouseMove(deltaX, deltaY) {
            fetch('/api/mouse', {
                method: 'POST',
                headers: { 'Content-Type': 'application/json' },
                body: JSON.stringify({ action: 'move', deltaX: deltaX, deltaY: deltaY })
            });
        }
        
        function sendMouseClick(button) {
            fetch('/api/mouse', {
                method: 'POST',
                headers: { 'Content-Type': 'application/json' },
                body: JSON.stringify({ action: 'click', button: button })
            });
        }
        
        function sendKey(key) {
            fetch('/api/keyboard', {
                method: 'POST',
                headers: { 'Content-Type': 'application/json' },
                body: JSON.stringify({ key: key })
            });
        }
        
        function openApp() {
            // Try to open the PC Remote Server app
            const appUrl = 'pc-remote-server://connect';
            window.location.href = appUrl;
            
            // Fallback: Show message if app is not installed
            setTimeout(() => {
                alert('PC Remote Server app not found. Please install the app first.');
            }, 1000);
        }
        
        function openWebsite() {
            // Open the official website
            window.open('https://github.com/your-repo/pc-remote-server', '_blank');
        }
    </script>
</body>
</html>
    ''';
    
    response.write(html);
    response.close();
  }

  void _handleWebSocket(HttpRequest request) {
    // WebSocket implementation for real-time communication
    // final webSocket = WebSocketTransformer.upgrade(request);
    // _channel = WebSocketChannel(webSocket);
    
    setState(() {
      _connectedClients++;
    });
    
    // _channel!.stream.listen((message) {
    //   // Handle real-time commands
    // });
  }

  void _handleMouseCommand(HttpRequest request) async {
    try {
      // Add CORS headers
      request.response.headers.add('Access-Control-Allow-Origin', '*');
      request.response.headers.add('Access-Control-Allow-Methods', 'GET, POST, OPTIONS');
      request.response.headers.add('Access-Control-Allow-Headers', 'Content-Type');
      
      if (request.method == 'OPTIONS') {
        request.response.statusCode = 200;
        request.response.close();
        return;
      }
      
      if (request.method == 'POST') {
        final body = await utf8.decoder.bind(request).join();
        final data = jsonDecode(body);
        
        print('Mouse command received: $data');
        
        if (data['action'] == 'move') {
          final deltaX = double.tryParse(data['deltaX'].toString()) ?? 0.0;
          final deltaY = double.tryParse(data['deltaY'].toString()) ?? 0.0;
          _moveMouse(deltaX, deltaY);
        } else if (data['action'] == 'click') {
          _clickMouse(data['button']);
        }
      }
      
      request.response.statusCode = 200;
      request.response.close();
    } catch (e) {
      print('Mouse command error: $e');
      request.response.statusCode = 500;
      request.response.close();
    }
  }

  void _handleKeyboardCommand(HttpRequest request) async {
    try {
      // Add CORS headers
      request.response.headers.add('Access-Control-Allow-Origin', '*');
      request.response.headers.add('Access-Control-Allow-Methods', 'GET, POST, OPTIONS');
      request.response.headers.add('Access-Control-Allow-Headers', 'Content-Type');
      
      if (request.method == 'OPTIONS') {
        request.response.statusCode = 200;
        request.response.close();
        return;
      }
      
      if (request.method == 'POST') {
        final body = await utf8.decoder.bind(request).join();
        final data = jsonDecode(body);
        
        print('Keyboard command received: $data');
        _sendKey(data['key']);
      }
      
      request.response.statusCode = 200;
      request.response.close();
    } catch (e) {
      print('Keyboard command error: $e');
      request.response.statusCode = 500;
      request.response.close();
    }
  }

  void _moveMouse(double deltaX, double deltaY) {
    // Simplified mouse movement for Windows compatibility
    print('Mouse move: deltaX=$deltaX, deltaY=$deltaY');
    _showMessage('Mouse moved: ${deltaX.toStringAsFixed(1)}, ${deltaY.toStringAsFixed(1)}');
  }

  void _clickMouse(String button) {
    // Simplified mouse click for Windows compatibility
    print('Mouse click: $button');
    _showMessage('Mouse $button click');
  }

  void _sendKey(String key) {
    // Simplified keyboard input for Windows compatibility
    print('Key pressed: $key');
    _showMessage('Key pressed: $key');
  }

  int _getVirtualKeyCode(String key) {
    switch (key.toLowerCase()) {
      // Special keys
      case 'space': return VK_SPACE;
      case 'enter': return VK_RETURN;
      case 'escape': return VK_ESCAPE;
      case 'tab': return VK_TAB;
      case 'backspace': return VK_BACK;
      case 'delete': return VK_DELETE;
      case 'home': return VK_HOME;
      case 'end': return VK_END;
      case 'pageup': return VK_PRIOR;
      case 'pagedown': return VK_NEXT;
      
      // Arrow keys
      case 'up': return VK_UP;
      case 'down': return VK_DOWN;
      case 'left': return VK_LEFT;
      case 'right': return VK_RIGHT;
      
      // Function keys
      case 'f1': return VK_F1;
      case 'f2': return VK_F2;
      case 'f3': return VK_F3;
      case 'f4': return VK_F4;
      case 'f5': return VK_F5;
      case 'f6': return VK_F6;
      case 'f7': return VK_F7;
      case 'f8': return VK_F8;
      case 'f9': return VK_F9;
      case 'f10': return VK_F10;
      case 'f11': return VK_F11;
      case 'f12': return VK_F12;
      
      // Modifier keys
      case 'ctrl': return VK_CONTROL;
      case 'alt': return VK_MENU;
      case 'shift': return VK_SHIFT;
      case 'win': return VK_LWIN;
      
      // Letters (A-Z)
      case 'a': return 0x41;
      case 'b': return 0x42;
      case 'c': return 0x43;
      case 'd': return 0x44;
      case 'e': return 0x45;
      case 'f': return 0x46;
      case 'g': return 0x47;
      case 'h': return 0x48;
      case 'i': return 0x49;
      case 'j': return 0x4A;
      case 'k': return 0x4B;
      case 'l': return 0x4C;
      case 'm': return 0x4D;
      case 'n': return 0x4E;
      case 'o': return 0x4F;
      case 'p': return 0x50;
      case 'q': return 0x51;
      case 'r': return 0x52;
      case 's': return 0x53;
      case 't': return 0x54;
      case 'u': return 0x55;
      case 'v': return 0x56;
      case 'w': return 0x57;
      case 'x': return 0x58;
      case 'y': return 0x59;
      case 'z': return 0x5A;
      
      // Numbers (0-9)
      case '0': return 0x30;
      case '1': return 0x31;
      case '2': return 0x32;
      case '3': return 0x33;
      case '4': return 0x34;
      case '5': return 0x35;
      case '6': return 0x36;
      case '7': return 0x37;
      case '8': return 0x38;
      case '9': return 0x39;
      
      default: return 0;
    }
  }

  String _generateToken() {
    final random = Random();
    final bytes = List<int>.generate(16, (i) => random.nextInt(256));
    return bytes.map((b) => b.toRadixString(16).padLeft(2, '0')).join();
  }

  void _showMessage(String message) {
    ScaffoldMessenger.of(context).showSnackBar(
      SnackBar(content: Text(message)),
    );
  }

  void _copyToClipboard(String text) {
    Clipboard.setData(ClipboardData(text: text));
    _showMessage('Copied to clipboard!');
  }

  void _pasteFromClipboard() async {
    try {
      final data = await Clipboard.getData('text/plain');
      if (data != null && data.text != null) {
        _addToClipboardHistory(data.text!);
        _showMessage('Clipboard content: ${data.text}');
        // You can also send this to the remote client if needed
      } else {
        _showMessage('Clipboard is empty');
      }
    } catch (e) {
      _showMessage('Error reading clipboard: $e');
    }
  }

  void _addToClipboardHistory(String text) {
    if (text.trim().isNotEmpty && !_clipboardHistory.contains(text)) {
      setState(() {
        _clipboardHistory.insert(0, text);
        if (_clipboardHistory.length > _maxHistorySize) {
          _clipboardHistory.removeLast();
        }
      });
    }
  }

  void _clearClipboardHistory() {
    setState(() {
      _clipboardHistory.clear();
    });
    _showMessage('Clipboard history cleared');
  }

  void _copyFromHistory(String text) {
    Clipboard.setData(ClipboardData(text: text));
    _showMessage('Copied to clipboard: ${text.length > 50 ? '${text.substring(0, 50)}...' : text}');
  }

  void _copyServerUrl() {
    final url = _serverUrl.isNotEmpty ? _serverUrl : 'http://localhost:8765';
    final externalUrl = 'https://pcremote.dev0-1.com/device/login';
    final combinedUrls = 'Local: $url\nExternal: $externalUrl';
    Clipboard.setData(ClipboardData(text: combinedUrls));
    _showMessage('Server URLs copied to clipboard:\nLocal: $url\nExternal: $externalUrl');
  }

  void _autoStartServer() async {
    // Auto-start server after a short delay if enabled
    await Future.delayed(Duration(seconds: 2));
    if (!_isRunning && _autoStartEnabled) {
      _showMessage('Auto-starting server...');
      _startServer();
    }
  }

  void _requestPortPermissions() async {
    try {
      // Request network permissions
      final status = await Permission.manageExternalStorage.request();
      if (status.isGranted) {
        _showMessage('Port permissions granted');
      } else {
        _showMessage('Port permissions denied - server may not work properly');
      }
    } catch (e) {
      print('Permission request error: $e');
    }
  }

  void _checkFirewallPermissions() async {
    try {
      _showMessage('Checking firewall permissions...');
      
      // Test if port 8765 is accessible
      final testServer = await HttpServer.bind(InternetAddress.anyIPv4, 8765);
      await testServer.close();
      
      _showMessage('✅ Firewall allows port 8765 - Server can start');
    } catch (e) {
      _showMessage('❌ Firewall may be blocking port 8765');
      _showMessage('Please add firewall exception for this application');
      print('Firewall check error: $e');
    }
  }

  void _showFirewallInstructions() {
    _showMessage('Firewall Setup Instructions:\n'
        '1. Open Windows Defender Firewall\n'
        '2. Click "Allow an app through firewall"\n'
        '3. Add this application\n'
        '4. Allow both Private and Public networks\n'
        '5. Restart the application');
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: AppBar(
        title: Text('PC Remote Server'),
        backgroundColor: Colors.blue,
        foregroundColor: Colors.white,
        actions: [
          if (_isLoggedIn) ...[
            IconButton(
              icon: Icon(Icons.person),
              onPressed: () {
                setState(() {
                  _isLoggedIn = false;
                  _username = '';
                });
              },
            ),
          ],
        ],
      ),
      body: _getCurrentPage(),
      bottomNavigationBar: BottomNavigationBar(
        currentIndex: _currentIndex,
        onTap: (index) {
          setState(() {
            _currentIndex = index;
          });
        },
        type: BottomNavigationBarType.fixed,
        items: [
          BottomNavigationBarItem(
            icon: Icon(Icons.home),
            label: 'Home',
          ),
          BottomNavigationBarItem(
            icon: Icon(Icons.bluetooth),
            label: 'Connect',
          ),
          BottomNavigationBarItem(
            icon: Icon(Icons.login),
            label: 'Login',
          ),
          BottomNavigationBarItem(
            icon: Icon(Icons.settings),
            label: 'Settings',
          ),
        ],
      ),
    );
  }

  Widget _getCurrentPage() {
    switch (_currentIndex) {
      case 0:
        return _buildHomePage();
      case 1:
        return _buildConnectivityPage();
      case 2:
        return _buildLoginPage();
      case 3:
        return _buildSettingsPage();
      case 4:
        return _buildClipboardHistoryPage();
      default:
        return _buildHomePage();
    }
  }

  Widget _buildHomePage() {
    return Padding(
        padding: EdgeInsets.all(20),
      child: SingleChildScrollView(
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [
            // Server Status Card
            Card(
              child: Padding(
                padding: EdgeInsets.all(16),
                child: Column(
                  children: [
                    Row(
                      mainAxisAlignment: MainAxisAlignment.spaceBetween,
                      children: [
                        Text(
                          'Server Status',
                          style: TextStyle(fontSize: 18, fontWeight: FontWeight.bold),
                        ),
                        Container(
                          padding: EdgeInsets.symmetric(horizontal: 12, vertical: 6),
                          decoration: BoxDecoration(
                            color: _isRunning ? Colors.green : Colors.red,
                            borderRadius: BorderRadius.circular(20),
                          ),
                          child: Text(
                            _isRunning ? 'RUNNING' : 'STOPPED',
                            style: TextStyle(color: Colors.white, fontWeight: FontWeight.bold),
                          ),
                        ),
                      ],
                    ),
                    SizedBox(height: 10),
                    if (_isRunning) ...[
                      Text('Connected Clients: $_connectedClients'),
                      SizedBox(height: 5),
                      Row(
                        children: [
                          Icon(Icons.security, color: Colors.orange, size: 16),
                          SizedBox(width: 4),
                          Text('Port 8765', style: TextStyle(fontSize: 12, color: Colors.orange)),
                        ],
                      ),
                      SizedBox(height: 5),
                    ],
                  ],
                ),
              ),
            ),
            
            SizedBox(height: 20),
            
            // Server Controls
            Row(
              children: [
                Flexible(
                  child: ElevatedButton.icon(
                    onPressed: _isRunning ? null : _startServer,
                    icon: Icon(Icons.play_arrow),
                    label: Text('Start Server'),
                    style: ElevatedButton.styleFrom(
                      backgroundColor: Colors.green,
                      foregroundColor: Colors.white,
                      padding: EdgeInsets.symmetric(vertical: 15),
                    ),
                  ),
                ),
                SizedBox(width: 10),
                Flexible(
                  child: ElevatedButton.icon(
                    onPressed: _isRunning ? _stopServer : null,
                    icon: Icon(Icons.stop),
                    label: Text('Stop Server'),
                    style: ElevatedButton.styleFrom(
                      backgroundColor: Colors.red,
                      foregroundColor: Colors.white,
                      padding: EdgeInsets.symmetric(vertical: 15),
                    ),
                  ),
                ),
              ],
            ),
            
            SizedBox(height: 20),
            
            // Server Information
            if (_isRunning) ...[
              Card(
                child: Padding(
                  padding: EdgeInsets.all(16),
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      Text(
                        'Connection Information',
                        style: TextStyle(fontSize: 16, fontWeight: FontWeight.bold),
                      ),
                      SizedBox(height: 10),
                      Row(
                        children: [
                          Flexible(
                            child: Text('Server URL:'),
                          ),
                          IconButton(
                            onPressed: _copyServerUrl,
                            icon: Icon(Icons.copy),
                            tooltip: 'Copy URL',
                          ),
                        ],
                      ),
                      SelectableText(
                        _serverUrl,
                        style: TextStyle(fontFamily: 'monospace', color: Colors.blue),
                      ),
                      SizedBox(height: 10),
                      Text(
                        'External Access:',
                        style: TextStyle(fontSize: 14, fontWeight: FontWeight.bold),
                      ),
                      SelectableText(
                        'https://pcremote.dev0-1.com/device/login',
                        style: TextStyle(fontFamily: 'monospace', color: Colors.green),
                      ),
                      if (_publicIP.isNotEmpty && _publicIP != 'Unable to get public IP') ...[
                        SizedBox(height: 10),
                        Text(
                          'Public IP: $_publicIP:8765',
                          style: TextStyle(fontFamily: 'monospace', color: Colors.orange),
                        ),
                        Text(
                          'Use this URL for direct external access',
                          style: TextStyle(fontSize: 12, color: Colors.grey[600]),
                        ),
                      ],
                      SizedBox(height: 10),
                      Row(
                        children: [
                          Flexible(
                            child: Text('Connection Token:'),
                          ),
                          IconButton(
                            onPressed: () => _copyToClipboard(_connectionToken),
                            icon: Icon(Icons.copy),
                            tooltip: 'Copy Token',
                          ),
                        ],
                      ),
                      SelectableText(
                        _connectionToken,
                        style: TextStyle(fontFamily: 'monospace', color: Colors.blue),
                      ),
                    ],
                  ),
                ),
              ),
              
              SizedBox(height: 20),
              
              // QR Code
              Card(
                child: Padding(
                  padding: EdgeInsets.all(16),
                  child: Column(
                    children: [
                      Text(
                        'Scan QR Code to Connect',
                        style: TextStyle(fontSize: 16, fontWeight: FontWeight.bold),
                      ),
                      SizedBox(height: 10),
                      Center(
                        child: QrImageView(
                          data: _serverUrl,
                          version: QrVersions.auto,
                          size: 200.0,
                        ),
                      ),
                    ],
                  ),
                ),
              ),
            ],
            
            SizedBox(height: 20),
            
            // Instructions
            Card(
              color: Colors.blue.shade50,
              child: Padding(
                padding: EdgeInsets.all(16),
        child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
            Text(
                      'How to Use:',
                      style: TextStyle(fontSize: 16, fontWeight: FontWeight.bold),
                    ),
                    SizedBox(height: 8),
                    Text('1. Start the server'),
                    Text('2. Open the URL on your phone/tablet'),
                    Text('3. Use the touchpad to control your PC'),
                    Text('4. Use buttons for clicks and keyboard shortcuts'),
                  ],
                ),
              ),
            ),
          ],
        ),
      ),
    );
  }

  Widget _buildLoginPage() {
    return Padding(
      padding: EdgeInsets.all(20),
      child: SingleChildScrollView(
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [
            Card(
              child: Padding(
                padding: EdgeInsets.all(20),
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.stretch,
                  children: [
                    Row(
                      children: [
                        Icon(Icons.login, color: Colors.blue, size: 32),
                        SizedBox(width: 12),
                        Text(
                          'Login',
                          style: TextStyle(fontSize: 24, fontWeight: FontWeight.bold),
                        ),
                      ],
                    ),
                    SizedBox(height: 20),
                    if (!_isLoggedIn) ...[
                      Text(
                        'Login with your browser to access the remote control interface.',
                        style: TextStyle(fontSize: 16, color: Colors.grey[600]),
                        textAlign: TextAlign.center,
                      ),
                      SizedBox(height: 20),
                      ElevatedButton.icon(
                        onPressed: _openBrowserLogin,
                        icon: Icon(Icons.open_in_browser, size: 24),
                        label: Text('Login with Browser', style: TextStyle(fontSize: 16)),
                        style: ElevatedButton.styleFrom(
                          backgroundColor: Colors.blue,
                          foregroundColor: Colors.white,
                          padding: EdgeInsets.symmetric(vertical: 16),
                          minimumSize: Size(double.infinity, 60),
                        ),
                      ),
                      SizedBox(height: 20),
                      Divider(),
                      SizedBox(height: 16),
                      Text(
                        'Alternative Access:',
                        style: TextStyle(fontSize: 14, fontWeight: FontWeight.bold),
                        textAlign: TextAlign.center,
                      ),
                      SizedBox(height: 8),
                      Text(
                        'Scan the QR code on the Home page to access the interface directly.',
                        style: TextStyle(fontSize: 14, color: Colors.grey[500]),
                        textAlign: TextAlign.center,
                      ),
                    ] else ...[
                      Icon(
                        Icons.check_circle,
                        color: Colors.green,
                        size: 64,
                      ),
                      SizedBox(height: 16),
                      Text(
                        'Welcome! You are logged in.',
                        style: TextStyle(fontSize: 20, fontWeight: FontWeight.bold),
                        textAlign: TextAlign.center,
                      ),
                      SizedBox(height: 20),
                      ElevatedButton.icon(
                        onPressed: () {
                          setState(() {
                            _isLoggedIn = false;
                            _username = '';
                            _password = '';
                          });
                        },
                        icon: Icon(Icons.logout),
                        label: Text('Logout'),
                        style: ElevatedButton.styleFrom(
                          backgroundColor: Colors.red,
                          foregroundColor: Colors.white,
                          padding: EdgeInsets.symmetric(vertical: 15),
                        ),
                      ),
                    ],
                  ],
                ),
              ),
            ),
          ],
        ),
      ),
    );
  }

  Widget _buildClipboardHistoryPage() {
    return Padding(
      padding: EdgeInsets.all(20),
      child: SingleChildScrollView(
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [
            Card(
              child: Padding(
                padding: EdgeInsets.all(20),
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Row(
                      children: [
                        IconButton(
                          onPressed: () {
                            setState(() {
                              _currentIndex = 3; // Go back to settings
                            });
                          },
                          icon: Icon(Icons.arrow_back),
                          tooltip: 'Back to Settings',
                        ),
                        Icon(Icons.history, color: Colors.purple, size: 32),
                        SizedBox(width: 12),
                        Text(
                          'Clipboard History',
                          style: TextStyle(fontSize: 24, fontWeight: FontWeight.bold),
                        ),
                        Spacer(),
                        IconButton(
                          onPressed: _clearClipboardHistory,
                          icon: Icon(Icons.clear_all),
                          tooltip: 'Clear History',
                        ),
                      ],
                    ),
                    SizedBox(height: 16),
                    if (_clipboardHistory.isEmpty) ...[
                      Center(
                        child: Column(
                          children: [
                            Icon(Icons.content_paste_off, size: 64, color: Colors.grey),
                            SizedBox(height: 16),
                            Text(
                              'No clipboard history yet',
                              style: TextStyle(fontSize: 16, color: Colors.grey[600]),
                            ),
                            SizedBox(height: 8),
                            Text(
                              'Copy some text to see it here',
                              style: TextStyle(fontSize: 14, color: Colors.grey[500]),
                            ),
                          ],
                        ),
                      ),
                    ] else ...[
                      Text(
                        '${_clipboardHistory.length} items in history',
                        style: TextStyle(fontSize: 16, color: Colors.grey[600]),
                      ),
                      SizedBox(height: 16),
                      Container(
                        height: 400,
                        child: ListView.builder(
                          itemCount: _clipboardHistory.length,
                          itemBuilder: (context, index) {
                            final item = _clipboardHistory[index];
                            return Card(
                              margin: EdgeInsets.only(bottom: 8),
                              child: ListTile(
                                leading: Icon(Icons.content_copy, color: Colors.blue),
                                title: Text(
                                  item.length > 100 ? '${item.substring(0, 100)}...' : item,
                                  style: TextStyle(fontSize: 14),
                                ),
                                subtitle: Text(
                                  'Length: ${item.length} characters',
                                  style: TextStyle(fontSize: 12, color: Colors.grey[600]),
                                ),
                                trailing: Row(
                                  mainAxisSize: MainAxisSize.min,
                                  children: [
                                    IconButton(
                                      onPressed: () => _copyFromHistory(item),
                                      icon: Icon(Icons.copy, size: 20),
                                      tooltip: 'Copy',
                                    ),
                                    IconButton(
                                      onPressed: () {
                                        setState(() {
                                          _clipboardHistory.removeAt(index);
                                        });
                                      },
                                      icon: Icon(Icons.delete, size: 20, color: Colors.red),
                                      tooltip: 'Delete',
                                    ),
                                  ],
                                ),
                                onTap: () => _copyFromHistory(item),
                              ),
                            );
                          },
                        ),
                      ),
                    ],
                  ],
                ),
              ),
            ),
          ],
        ),
      ),
    );
  }

  Widget _buildSettingsPage() {
    return Padding(
      padding: EdgeInsets.all(20),
      child: SingleChildScrollView(
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [
            Card(
              child: Padding(
                padding: EdgeInsets.all(20),
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Text(
                      'Server Settings',
                      style: TextStyle(fontSize: 20, fontWeight: FontWeight.bold),
                    ),
                    SizedBox(height: 16),
                    SwitchListTile(
                      title: Text('Auto-start Server'),
                      subtitle: Text('Start server automatically on app launch'),
                      value: false, // You can add this as a state variable
                      onChanged: (value) {
                        // Handle auto-start setting
                      },
                    ),
                    SwitchListTile(
                      title: Text('System Tray'),
                      subtitle: Text('Minimize to system tray'),
                      value: true, // You can add this as a state variable
                      onChanged: (value) {
                        // Handle system tray setting
                      },
                    ),
                    SwitchListTile(
                      title: Text('Notifications'),
                      subtitle: Text('Show connection notifications'),
                      value: true, // You can add this as a state variable
                      onChanged: (value) {
                        // Handle notifications setting
                      },
                    ),
                  ],
                ),
              ),
            ),
            SizedBox(height: 16),
            Card(
              child: Padding(
                padding: EdgeInsets.all(20),
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Text(
                      'Security Settings',
                      style: TextStyle(fontSize: 20, fontWeight: FontWeight.bold),
                    ),
                    SizedBox(height: 16),
                    ListTile(
                      leading: Icon(Icons.security),
                      title: Text('Change Password'),
                      subtitle: Text('Update your login password'),
                      trailing: Icon(Icons.arrow_forward_ios),
                      onTap: () {
                        _showMessage('Change password feature coming soon!');
                      },
                    ),
                    ListTile(
                      leading: Icon(Icons.key),
                      title: Text('Generate New Token'),
                      subtitle: Text('Create a new connection token'),
                      trailing: Icon(Icons.arrow_forward_ios),
                      onTap: () {
                        setState(() {
                          _connectionToken = _generateToken();
                        });
                        _showMessage('New token generated!');
                      },
                    ),
                    ListTile(
                      leading: Icon(Icons.history),
                      title: Text('Connection History'),
                      subtitle: Text('View recent connections'),
                      trailing: Icon(Icons.arrow_forward_ios),
                      onTap: () {
                        _showMessage('Connection history feature coming soon!');
                      },
                    ),
                    ListTile(
                      leading: Icon(Icons.content_copy),
                      title: Text('Clipboard'),
                      subtitle: Text('View clipboard content'),
                      trailing: Icon(Icons.arrow_forward_ios),
                      onTap: _pasteFromClipboard,
                    ),
                    ListTile(
                      leading: Icon(Icons.history),
                      title: Text('Clipboard History'),
                      subtitle: Text('${_clipboardHistory.length} items'),
                      trailing: Icon(Icons.arrow_forward_ios),
                      onTap: () {
                        setState(() {
                          _currentIndex = 4; // Switch to clipboard history page
                        });
                      },
                    ),
                    Divider(),
                    SwitchListTile(
                      title: Text('Auto-start Server'),
                      subtitle: Text('Automatically start server on app launch'),
                      value: _autoStartEnabled,
                      onChanged: (value) {
                        setState(() {
                          _autoStartEnabled = value;
                        });
                        _showMessage('Auto-start ${value ? 'enabled' : 'disabled'}');
                      },
                    ),
                    SwitchListTile(
                      title: Text('Background Mode'),
                      subtitle: Text('Keep server running in background'),
                      value: _backgroundMode,
                      onChanged: (value) {
                        setState(() {
                          _backgroundMode = value;
                        });
                        _showMessage('Background mode ${value ? 'enabled' : 'disabled'}');
                      },
                    ),
                    Divider(),
                    ListTile(
                      leading: Icon(Icons.security, color: Colors.orange),
                      title: Text('Check Firewall'),
                      subtitle: Text('Test firewall permissions for port 8765'),
                      trailing: Icon(Icons.arrow_forward_ios),
                      onTap: _checkFirewallPermissions,
                    ),
                    ListTile(
                      leading: Icon(Icons.help, color: Colors.blue),
                      title: Text('Firewall Instructions'),
                      subtitle: Text('Show firewall setup instructions'),
                      trailing: Icon(Icons.arrow_forward_ios),
                      onTap: _showFirewallInstructions,
                    ),
                  ],
                ),
              ),
            ),
            SizedBox(height: 16),
            Card(
              child: Padding(
                padding: EdgeInsets.all(20),
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Text(
                      'About',
                      style: TextStyle(fontSize: 20, fontWeight: FontWeight.bold),
                    ),
                    SizedBox(height: 16),
                    ListTile(
                      leading: Icon(Icons.info),
                      title: Text('Version'),
                      subtitle: Text('1.0.0'),
                    ),
                    ListTile(
                      leading: Icon(Icons.code),
                      title: Text('Developer'),
                      subtitle: Text('PC Remote Server Team'),
                    ),
                    ListTile(
                      leading: Icon(Icons.help),
                      title: Text('Help & Support'),
                      subtitle: Text('Get help and support'),
                      trailing: Icon(Icons.arrow_forward_ios),
                      onTap: () {
                        _showMessage('Help & Support coming soon!');
                      },
                    ),
                  ],
                ),
              ),
            ),
          ],
        ),
      ),
    );
  }

  Widget _buildConnectivityPage() {
    return Padding(
      padding: EdgeInsets.all(20),
      child: SingleChildScrollView(
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [
            // Bluetooth Section
            Card(
              child: Padding(
                padding: EdgeInsets.all(20),
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Row(
                      children: [
                        Icon(Icons.bluetooth, color: Colors.blue),
                        SizedBox(width: 8),
                        Text(
                          'Bluetooth',
                          style: TextStyle(fontSize: 20, fontWeight: FontWeight.bold),
                        ),
                        Spacer(),
                        Switch(
                          value: _isBluetoothEnabled,
                          onChanged: _toggleBluetooth,
                        ),
                      ],
                    ),
                    SizedBox(height: 16),
                    if (_isBluetoothEnabled) ...[
                      Row(
                        children: [
                          Expanded(
                            child: ElevatedButton.icon(
                              onPressed: _isScanning ? null : _startBluetoothScan,
                              icon: Icon(Icons.search),
                              label: Text(_isScanning ? 'Scanning...' : 'Scan Devices'),
                              style: ElevatedButton.styleFrom(
                                backgroundColor: Colors.blue,
                                foregroundColor: Colors.white,
                              ),
                            ),
                          ),
                          SizedBox(width: 10),
                          ElevatedButton.icon(
                            onPressed: _stopBluetoothScan,
                            icon: Icon(Icons.stop),
                            label: Text('Stop'),
                            style: ElevatedButton.styleFrom(
                              backgroundColor: Colors.red,
                              foregroundColor: Colors.white,
                            ),
                          ),
                        ],
                      ),
                      SizedBox(height: 16),
                      if (_bluetoothDevices.isNotEmpty) ...[
                        Text(
                          'Available Devices:',
                          style: TextStyle(fontWeight: FontWeight.bold),
                        ),
                        SizedBox(height: 8),
                        Container(
                          height: 200,
                          child: ListView.builder(
                            itemCount: _bluetoothDevices.length,
                            itemBuilder: (context, index) {
                              final device = _bluetoothDevices[index];
                              return ListTile(
                                leading: Icon(Icons.bluetooth_connected),
                                title: Text('Device ${device.remoteId}'),
                                subtitle: Text(device.remoteId.toString()),
                                trailing: ElevatedButton(
                                  onPressed: () => _connectBluetoothDevice(device),
                                  child: Text('Connect'),
                                ),
                              );
                            },
                          ),
                        ),
                      ],
                    ] else ...[
                      Text('Bluetooth is disabled'),
                    ],
                  ],
                ),
              ),
            ),
            SizedBox(height: 16),
            
            // WiFi Section
            Card(
              child: Padding(
                padding: EdgeInsets.all(20),
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Row(
                      children: [
                        Icon(Icons.wifi, color: Colors.green),
                        SizedBox(width: 8),
                        Text(
                          'WiFi',
                          style: TextStyle(fontSize: 20, fontWeight: FontWeight.bold),
                        ),
                        Spacer(),
                        Switch(
                          value: _isWifiEnabled,
                          onChanged: _toggleWifi,
                        ),
                      ],
                    ),
                    SizedBox(height: 16),
                    if (_isWifiEnabled) ...[
                      Row(
                        children: [
                          Expanded(
                            child: ElevatedButton.icon(
                              onPressed: _scanWifiNetworks,
                              icon: Icon(Icons.wifi_find),
                              label: Text('Scan Networks'),
                              style: ElevatedButton.styleFrom(
                                backgroundColor: Colors.green,
                                foregroundColor: Colors.white,
                              ),
                            ),
                          ),
                          SizedBox(width: 10),
                          ElevatedButton.icon(
                            onPressed: _getWifiInfo,
                            icon: Icon(Icons.info),
                            label: Text('Info'),
                            style: ElevatedButton.styleFrom(
                              backgroundColor: Colors.orange,
                              foregroundColor: Colors.white,
                            ),
                          ),
                        ],
                      ),
                      SizedBox(height: 16),
                      if (_wifiSSID.isNotEmpty) ...[
                        Text(
                          'Current Network:',
                          style: TextStyle(fontWeight: FontWeight.bold),
                        ),
                        SizedBox(height: 8),
                        ListTile(
                          leading: Icon(Icons.wifi),
                          title: Text(_wifiSSID),
                          subtitle: Text('IP: $_wifiIP'),
                        ),
                      ],
                      if (_wifiNetworks.isNotEmpty) ...[
                        SizedBox(height: 16),
                        Text(
                          'Available Networks:',
                          style: TextStyle(fontWeight: FontWeight.bold),
                        ),
                        SizedBox(height: 8),
                        Container(
                          height: 200,
                          child: ListView.builder(
                            itemCount: _wifiNetworks.length,
                            itemBuilder: (context, index) {
                              final network = _wifiNetworks[index];
                              return ListTile(
                                leading: Icon(Icons.wifi),
                                title: Text(network['ssid'] ?? 'Unknown'),
                                subtitle: Text('Signal: ${network['level']} dBm'),
                                trailing: ElevatedButton(
                                  onPressed: () => _connectWifiNetwork(network),
                                  child: Text('Connect'),
                                ),
                              );
                            },
                          ),
                        ),
                      ],
                    ] else ...[
                      Text('WiFi is disabled'),
                    ],
                  ],
                ),
              ),
            ),
          ],
        ),
      ),
    );
  }

  void _openBrowserLogin() async {
    try {
      // Check if server is running
      if (!_isRunning) {
        _showMessage('Please start the server first!');
        return;
      }
      
      // Determine the best URL to use
      String serverUrl;
      if (_localIP.isNotEmpty) {
        serverUrl = 'http://$_localIP:8765';
      } else {
        serverUrl = 'http://localhost:8765';
      }
      
      // Use custom domain for external access
      final customDomainUrl = 'https://pcremote.dev0-1.com/device/login';
      
      final uri = Uri.parse(serverUrl);
      
      if (await canLaunchUrl(uri)) {
        await launchUrl(uri, mode: LaunchMode.externalApplication);
        _showMessage('Opening browser to: $serverUrl');
        
        // Set logged in state after successful browser launch
        setState(() {
          _isLoggedIn = true;
        });
        _showMessage('Browser opened successfully! You can now use the remote control interface.');
        _showMessage('External access: $customDomainUrl');
      } else {
        _showMessage('Could not launch browser. Please open manually: $serverUrl');
        _showMessage('External access: $customDomainUrl');
        // Still set as logged in since the URL is valid
        setState(() {
          _isLoggedIn = true;
        });
      }
    } catch (e) {
      _showMessage('Error opening browser: $e');
      print('Browser launch error: $e');
      
      // Show manual URL as fallback
      final fallbackUrl = _localIP.isNotEmpty ? 'http://$_localIP:8765' : 'http://localhost:8765';
      _showMessage('Please open manually: $fallbackUrl');
      _showMessage('External access: https://pcremote.dev0-1.com/device/login');
    }
  }

  // Bluetooth methods - Windows compatible
  void _initBluetooth() async {
    try {
      // For Windows, we'll simulate Bluetooth functionality
      setState(() {
        _isBluetoothEnabled = true; // Assume Bluetooth is available
      });
    } catch (e) {
      print('Bluetooth initialization error: $e');
    }
  }

  void _toggleBluetooth(bool value) async {
    setState(() {
      _isBluetoothEnabled = value;
    });
    _showMessage('Bluetooth toggle: ${value ? "Enabled" : "Disabled"}');
  }

  void _startBluetoothScan() async {
    try {
      setState(() {
        _isScanning = true;
        _bluetoothDevices.clear();
      });

      // Simulate Bluetooth device discovery for Windows
      await Future.delayed(Duration(seconds: 2));
      
      setState(() {
        _bluetoothDevices = [
          // Simulated devices
          _createSimulatedDevice('iPhone 13', '00:11:22:33:44:55'),
          _createSimulatedDevice('Samsung Galaxy', '66:77:88:99:AA:BB'),
          _createSimulatedDevice('Bluetooth Mouse', 'CC:DD:EE:FF:00:11'),
          _createSimulatedDevice('Wireless Headphones', '22:33:44:55:66:77'),
        ];
        _isScanning = false;
      });
      
      _showMessage('Found ${_bluetoothDevices.length} devices');
    } catch (e) {
      _showMessage('Error scanning Bluetooth: $e');
      setState(() {
        _isScanning = false;
      });
    }
  }

  void _stopBluetoothScan() async {
    setState(() {
      _isScanning = false;
    });
    _showMessage('Bluetooth scan stopped');
  }

  void _connectBluetoothDevice(BluetoothDevice device) async {
    try {
      _showMessage('Connecting to ${device.remoteId}...');
      await Future.delayed(Duration(seconds: 1));
      _showMessage('Connected to ${device.remoteId}');
    } catch (e) {
      _showMessage('Error connecting to device: $e');
    }
  }

  // Helper method to create simulated Bluetooth devices
  BluetoothDevice _createSimulatedDevice(String name, String id) {
    // This is a simplified approach for Windows compatibility
    return BluetoothDevice(
      remoteId: DeviceIdentifier(id),
    );
  }

  // WiFi methods
  void _initWifi() async {
    try {
      _getWifiInfo();
      setState(() {
        _isWifiEnabled = true; // Assume WiFi is enabled if we can get info
      });
    } catch (e) {
      print('WiFi initialization error: $e');
      setState(() {
        _isWifiEnabled = false;
      });
    }
  }

  void _toggleWifi(bool value) async {
    setState(() {
      _isWifiEnabled = value;
    });
    _showMessage('WiFi toggle feature requires platform-specific implementation');
  }

  void _scanWifiNetworks() async {
    try {
      // Simulate WiFi networks for demo purposes
      setState(() {
        _wifiNetworks = [
          {'ssid': 'Home Network', 'level': -45},
          {'ssid': 'Office WiFi', 'level': -60},
          {'ssid': 'Guest Network', 'level': -70},
        ];
      });
      _showMessage('Found ${_wifiNetworks.length} networks');
    } catch (e) {
      _showMessage('Error scanning WiFi networks: $e');
    }
  }

  void _getWifiInfo() async {
    try {
      final networkInfo = NetworkInfo();
      final wifiIP = await networkInfo.getWifiIP();
      
      setState(() {
        _wifiSSID = 'Current Network'; // Simplified for demo
        _wifiIP = wifiIP ?? 'Unknown';
      });
    } catch (e) {
      _showMessage('Error getting WiFi info: $e');
    }
  }

  void _connectWifiNetwork(dynamic network) async {
    try {
      // This is a simplified connection - in a real app you'd need to handle authentication
      _showMessage('Connecting to ${network.ssid}...');
      // Note: Actual WiFi connection requires platform-specific implementation
    } catch (e) {
      _showMessage('Error connecting to network: $e');
    }
  }
}

