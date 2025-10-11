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
// import 'package:web_socket_channel/server.dart';

void main() async {
  WidgetsFlutterBinding.ensureInitialized();
  
  // Initialize window manager
  await windowManager.ensureInitialized();
  
  // Configure window
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

  @override
  void initState() {
    super.initState();
    windowManager.addListener(this);
    _initSystemTray();
    _getLocalIP();
  }

  @override
  void dispose() {
    windowManager.removeListener(this);
    _stopServer();
    super.dispose();
  }

  void _initSystemTray() async {
    _systemTray = SystemTray();
    
    // Create system tray menu
    final menu = Menu(
      items: [
        MenuItem(
          key: 'show',
          label: 'Show PC Remote Server',
          onClicked: () => windowManager.show(),
        ),
        MenuItem(
          key: 'start_server',
          label: 'Start Server',
          onClicked: _startServer,
        ),
        MenuItem(
          key: 'stop_server',
          label: 'Stop Server',
          onClicked: _stopServer,
        ),
        MenuItem(
          key: 'quit',
          label: 'Quit',
          onClicked: () => exit(0),
        ),
      ],
    );

    await _systemTray!.setContextMenu(menu);
    // await _systemTray!.setIcon('assets/icon.ico');
    await _systemTray!.setToolTip('PC Remote Server');
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

  void _startServer() async {
    if (_isRunning) return;

    try {
      // Generate connection token
      _connectionToken = _generateToken();
      
      // Start HTTP server
      _server = await HttpServer.bind(InternetAddress.anyIPv4, 8080);
      _serverUrl = 'http://$_localIP:8080';
      
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
    final uri = request.uri;
    
    if (uri.path == '/') {
      _serveWebInterface(request);
    } else if (uri.path == '/ws') {
      _handleWebSocket(request);
    } else if (uri.path == '/api/mouse') {
      _handleMouseCommand(request);
    } else if (uri.path == '/api/keyboard') {
      _handleKeyboardCommand(request);
    } else {
      request.response.statusCode = 404;
      request.response.close();
    }
  }

  void _serveWebInterface(HttpRequest request) {
    final response = request.response;
    response.headers.contentType = ContentType.html;
    
    final html = '''
<!DOCTYPE html>
<html>
<head>
    <title>PC Remote Control</title>
    <meta name="viewport" content="width=device-width, initial-scale=1.0">
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
    </style>
</head>
<body>
    <div class="container">
        <div class="header">
            <h2>🖥️ PC Remote Control</h2>
            <p>Control your PC remotely</p>
        </div>
        
        <div class="status" id="status">Connected to PC</div>
        
        <div class="touchpad" id="touchpad" onmousedown="handleMouseDown(event)" onmousemove="handleMouseMove(event)" onmouseup="handleMouseUp(event)" ontouchstart="handleTouchStart(event)" ontouchmove="handleTouchMove(event)" ontouchend="handleTouchEnd(event)">
            <div style="text-align: center; padding-top: 80px; color: #666;">Touch/Mouse Pad</div>
        </div>
        
        <div class="buttons">
            <button class="btn" onclick="sendMouseClick('left')">Left Click</button>
            <button class="btn" onclick="sendMouseClick('right')">Right Click</button>
        </div>
        
        <div class="buttons">
            <button class="btn" onclick="sendKey('space')">Space</button>
            <button class="btn" onclick="sendKey('enter')">Enter</button>
        </div>
        
        <div class="buttons">
            <button class="btn" onclick="sendKey('escape')">Escape</button>
            <button class="btn" onclick="sendKey('tab')">Tab</button>
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
    if (request.method == 'POST') {
      final body = await utf8.decoder.bind(request).join();
      final data = jsonDecode(body);
      
      if (data['action'] == 'move') {
        _moveMouse(data['deltaX'], data['deltaY']);
      } else if (data['action'] == 'click') {
        _clickMouse(data['button']);
      }
    }
    
    request.response.statusCode = 200;
    request.response.close();
  }

  void _handleKeyboardCommand(HttpRequest request) async {
    if (request.method == 'POST') {
      final body = await utf8.decoder.bind(request).join();
      final data = jsonDecode(body);
      
      _sendKey(data['key']);
    }
    
    request.response.statusCode = 200;
    request.response.close();
  }

  void _moveMouse(double deltaX, double deltaY) {
    // Get current cursor position
    final point = calloc<POINT>();
    GetCursorPos(point);
    
    // Move cursor
    SetCursorPos(
      (point.ref.x + deltaX).round(),
      (point.ref.y + deltaY).round(),
    );
    
    free(point);
  }

  void _clickMouse(String button) {
    if (button == 'left') {
      mouse_event(MOUSEEVENTF_LEFTDOWN, 0, 0, 0, 0);
      mouse_event(MOUSEEVENTF_LEFTUP, 0, 0, 0, 0);
    } else if (button == 'right') {
      mouse_event(MOUSEEVENTF_RIGHTDOWN, 0, 0, 0, 0);
      mouse_event(MOUSEEVENTF_RIGHTUP, 0, 0, 0, 0);
    }
  }

  void _sendKey(String key) {
    int vkCode = _getVirtualKeyCode(key);
    if (vkCode != 0) {
      keybd_event(vkCode, 0, 0, 0);
      keybd_event(vkCode, 0, KEYEVENTF_KEYUP, 0);
    }
  }

  int _getVirtualKeyCode(String key) {
    switch (key.toLowerCase()) {
      case 'space': return VK_SPACE;
      case 'enter': return VK_RETURN;
      case 'escape': return VK_ESCAPE;
      case 'tab': return VK_TAB;
      case 'backspace': return VK_BACK;
      case 'delete': return VK_DELETE;
      case 'up': return VK_UP;
      case 'down': return VK_DOWN;
      case 'left': return VK_LEFT;
      case 'right': return VK_RIGHT;
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

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: AppBar(
        title: Text('PC Remote Server'),
        backgroundColor: Colors.blue,
        foregroundColor: Colors.white,
      ),
      body: Padding(
        padding: EdgeInsets.all(20),
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
                    ],
                  ],
                ),
              ),
            ),
            
            SizedBox(height: 20),
            
            // Server Controls
            Row(
              children: [
                Expanded(
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
                Expanded(
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
                          Expanded(
                            child: Text('Server URL:'),
                          ),
                          IconButton(
                            onPressed: () => _copyToClipboard(_serverUrl),
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
                      Row(
                        children: [
                          Expanded(
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
            
            Spacer(),
            
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
}