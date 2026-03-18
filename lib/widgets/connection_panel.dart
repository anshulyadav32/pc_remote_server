import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:flutter/material.dart';
import 'package:flutter_blue_plus/flutter_blue_plus.dart';

import '../modules/bluetooth_module.dart';
import '../services/local_server_service.dart';
import '../services/websocket_service.dart';

class ConnectionPanel extends StatefulWidget {
  final LocalServerService serverService;
  final WebSocketService wsService;

  const ConnectionPanel({
    super.key,
    required this.serverService,
    required this.wsService,
  });

  @override
  State<ConnectionPanel> createState() => _ConnectionPanelState();
}

class _ConnectionPanelState extends State<ConnectionPanel> {
  static const Duration _requestTimeout = Duration(minutes: 1);

  final Map<String, _DiscoveredDevice> _discoveredDevices =
      <String, _DiscoveredDevice>{};

  List<ConnectionRequest> _pendingRequests = <ConnectionRequest>[];
  List<PairedDevice> _serverPairedDevices = <PairedDevice>[];
  List<PairedDevice> _remotePairedDevices = <PairedDevice>[];
  bool _isConnecting = false;
  bool _isDiscovering = false;
  bool _isBluetoothDiscovering = false;
  bool _isBluetoothConnecting = false;
  bool _isBluetoothSupported = false;
  bool _isBluetoothPermissionsGranted = false;
  BluetoothAdapterState _bluetoothAdapterState = BluetoothAdapterState.unknown;
  String? _bluetoothError;
  String? _activeBluetoothDeviceId;
  String? _connectedBluetoothDeviceName;
  List<BluetoothScanDevice> _bluetoothDevices = <BluetoothScanDevice>[];
  String _outgoingRequestStatus = 'idle';
  DateTime? _requestDeadline;
  _DiscoveredDevice? _lastRequestedDevice;
  Timer? _requestCountdownTimer;
  StreamSubscription<List<ConnectionRequest>>? _pendingSub;
  StreamSubscription<List<PairedDevice>>? _serverPairedSub;
  StreamSubscription<List<PairedDevice>>? _remotePairedSub;
  StreamSubscription<String>? _requestStatusSub;
  StreamSubscription<BluetoothAdapterState>? _bluetoothAdapterSub;
  StreamSubscription<List<BluetoothScanDevice>>? _bluetoothScanSub;

  @override
  void initState() {
    super.initState();
    _pendingRequests = widget.serverService.currentPendingRequests;
    _serverPairedDevices = widget.serverService.currentPairedDevices;
    _remotePairedDevices = widget.wsService.currentPairedDevices;
    _pendingSub = widget.serverService.pendingRequestsStream.listen((pending) {
      if (!mounted) {
        return;
      }
      setState(() => _pendingRequests = pending);
    });
    _serverPairedSub =
        widget.serverService.pairedDevicesStream.listen((paired) {
      if (!mounted) {
        return;
      }
      setState(() {
        _serverPairedDevices = paired;
        _pruneDiscoveredPaired();
      });
    });
    _remotePairedSub = widget.wsService.pairedDevicesStream.listen((paired) {
      if (!mounted) {
        return;
      }
      setState(() {
        _remotePairedDevices = paired;
        _pruneDiscoveredPaired();
      });
    });
    _requestStatusSub = widget.wsService.requestStatusStream.listen((status) {
      if (!mounted) {
        return;
      }
      _updateOutgoingRequestStatus(status, fromStream: true);
    });

    if (BluetoothModule.isBluetoothUiEnabled) {
      unawaited(_initializeBluetooth());
    }

    WidgetsBinding.instance.addPostFrameCallback((_) {
      _discoverDevices();
    });
  }

  @override
  void dispose() {
    _pendingSub?.cancel();
    _serverPairedSub?.cancel();
    _remotePairedSub?.cancel();
    _requestStatusSub?.cancel();
    _requestCountdownTimer?.cancel();
    _bluetoothAdapterSub?.cancel();
    _bluetoothScanSub?.cancel();
    unawaited(BluetoothModule.stopScan());
    super.dispose();
  }

  Future<void> _initializeBluetooth() async {
    try {
      final supported = await BluetoothModule.isSupported;
      if (!mounted) {
        return;
      }

      setState(() {
        _isBluetoothSupported = supported;
        _bluetoothError = supported ? null : 'Bluetooth is unavailable.';
      });

      if (!supported) {
        return;
      }

      _bluetoothAdapterSub =
          BluetoothModule.adapterStateStream.listen((state) {
        if (!mounted) {
          return;
        }

        setState(() {
          _bluetoothAdapterState = state;
        });
      });

      _bluetoothScanSub =
          BluetoothModule.scanResultsStream.listen((devices) {
        if (!mounted) {
          return;
        }

        setState(() {
          _bluetoothDevices = devices;
        });
      });
    } catch (_) {
      if (!mounted) {
        return;
      }
      setState(() {
        _bluetoothError = 'Failed to initialize Bluetooth.';
      });
    }
  }

  Future<void> _scanBluetoothDevices() async {
    if (_isBluetoothDiscovering || !_isBluetoothSupported) {
      return;
    }

    setState(() {
      _isBluetoothDiscovering = true;
      _bluetoothError = null;
      _bluetoothDevices = <BluetoothScanDevice>[];
    });

    try {
      final granted = await BluetoothModule.requestPermissions();
      if (!mounted) {
        return;
      }

      if (!granted) {
        setState(() {
          _isBluetoothPermissionsGranted = false;
          _isBluetoothDiscovering = false;
          _bluetoothError = 'Bluetooth permission denied.';
        });
        return;
      }

      setState(() {
        _isBluetoothPermissionsGranted = true;
      });

      await BluetoothModule.startScan(timeout: const Duration(seconds: 10));

      // Windows scanning is callback-based and stop is scheduled internally.
      if (Platform.isWindows) {
        await Future<void>.delayed(const Duration(seconds: 11));
      }
    } catch (_) {
      if (!mounted) {
        return;
      }
      setState(() {
        _bluetoothError = 'Bluetooth scan failed.';
      });
    } finally {
      if (mounted) {
        setState(() {
          _isBluetoothDiscovering = false;
        });
      }
    }
  }

  Future<void> _connectBluetoothDevice(BluetoothScanDevice device) async {
    if (_isBluetoothConnecting) {
      return;
    }

    setState(() {
      _isBluetoothConnecting = true;
      _activeBluetoothDeviceId = device.id;
      _bluetoothError = null;
    });

    try {
      await BluetoothModule.connectDevice(device);
      if (!mounted) {
        return;
      }
      setState(() {
        _connectedBluetoothDeviceName = device.name;
      });
      _showMessage('Bluetooth connected to ${device.name}');
    } catch (_) {
      if (!mounted) {
        return;
      }
      setState(() {
        _bluetoothError = 'Failed to connect ${device.name}.';
      });
      _showMessage('Bluetooth connection failed for ${device.name}',
          isError: true);
    } finally {
      if (mounted) {
        setState(() {
          _isBluetoothConnecting = false;
          _activeBluetoothDeviceId = null;
        });
      }
    }
  }

  String _bluetoothStateLabel() {
    switch (_bluetoothAdapterState) {
      case BluetoothAdapterState.on:
        return 'On';
      case BluetoothAdapterState.off:
        return 'Off';
      case BluetoothAdapterState.turningOn:
        return 'Turning on';
      case BluetoothAdapterState.turningOff:
        return 'Turning off';
      case BluetoothAdapterState.unavailable:
        return 'Unavailable';
      case BluetoothAdapterState.unauthorized:
        return 'Unauthorized';
      case BluetoothAdapterState.unknown:
        return 'Unknown';
    }
  }

  Widget _buildBluetoothSection(bool isNarrow) {
    if (!BluetoothModule.isBluetoothUiEnabled) {
      return const SizedBox.shrink();
    }

    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        const SizedBox(height: 12),
        Card(
          color: Colors.blue.withValues(alpha: 0.06),
          child: Padding(
            padding: const EdgeInsets.all(12),
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Row(
                  children: [
                    const Icon(Icons.bluetooth),
                    const SizedBox(width: 8),
                    Text(
                      'Bluetooth',
                      style: Theme.of(context).textTheme.titleMedium?.copyWith(
                            fontWeight: FontWeight.bold,
                          ),
                    ),
                    const Spacer(),
                    Text('State: ${_bluetoothStateLabel()}'),
                  ],
                ),
                if (_connectedBluetoothDeviceName != null) ...[
                  const SizedBox(height: 8),
                  Container(
                    padding:
                        const EdgeInsets.symmetric(horizontal: 10, vertical: 6),
                    decoration: BoxDecoration(
                      color: Colors.green.withValues(alpha: 0.12),
                      borderRadius: BorderRadius.circular(24),
                    ),
                    child: Row(
                      mainAxisSize: MainAxisSize.min,
                      children: [
                        const Icon(
                          Icons.bluetooth_connected,
                          size: 16,
                          color: Colors.green,
                        ),
                        const SizedBox(width: 6),
                        Text(
                          'Connected: $_connectedBluetoothDeviceName',
                          style:
                              Theme.of(context).textTheme.bodySmall?.copyWith(
                                    color: Colors.green.shade800,
                                    fontWeight: FontWeight.w600,
                                  ),
                        ),
                      ],
                    ),
                  ),
                ],
                const SizedBox(height: 8),
                if (_bluetoothError != null)
                  Padding(
                    padding: const EdgeInsets.only(bottom: 8),
                    child: Text(
                      _bluetoothError!,
                      style: const TextStyle(color: Colors.red),
                    ),
                  ),
                if (!_isBluetoothSupported)
                  const Text('Bluetooth not available on this device.')
                else
                  Wrap(
                    spacing: 8,
                    runSpacing: 8,
                    crossAxisAlignment: WrapCrossAlignment.center,
                    children: [
                      FilledButton.icon(
                        onPressed:
                            _isBluetoothDiscovering ? null : _scanBluetoothDevices,
                        icon: _isBluetoothDiscovering
                            ? const SizedBox(
                                width: 14,
                                height: 14,
                                child: CircularProgressIndicator(strokeWidth: 2),
                              )
                            : const Icon(Icons.search),
                        label: Text(_isBluetoothDiscovering
                            ? 'Scanning...'
                            : 'Scan Bluetooth'),
                      ),
                      if (_isBluetoothPermissionsGranted)
                        Text(
                          'Permissions granted',
                          style: Theme.of(context)
                              .textTheme
                              .bodySmall
                              ?.copyWith(color: Colors.green.shade700),
                        ),
                    ],
                  ),
                const SizedBox(height: 8),
                if (_bluetoothDevices.isEmpty && !_isBluetoothDiscovering)
                  const Text('No Bluetooth devices discovered yet.')
                else
                  ..._bluetoothDevices.map((device) {
                    final connecting = _isBluetoothConnecting &&
                        _activeBluetoothDeviceId == device.id;

                    return Card(
                      margin: const EdgeInsets.only(top: 8),
                      child: ListTile(
                        dense: isNarrow,
                        leading: const Icon(Icons.devices_other),
                        title: Text(device.name),
                        subtitle: Text(device.id),
                        trailing: FilledButton(
                          onPressed: _isBluetoothConnecting
                              ? null
                              : () => _connectBluetoothDevice(device),
                          child: Text(connecting ? 'Connecting...' : 'Connect'),
                        ),
                      ),
                    );
                  }),
              ],
            ),
          ),
        ),
      ],
    );
  }

  List<PairedDevice> _allPairedDevices() {
    final merged = <String, PairedDevice>{};

    for (final device in _serverPairedDevices) {
      final key = device.deviceId.isEmpty ? device.clientId : device.deviceId;
      merged[key] = device;
    }

    for (final device in _remotePairedDevices) {
      final key = device.deviceId.isEmpty ? device.clientId : device.deviceId;
      merged[key] = device;
    }

    return merged.values.toList();
  }

  Future<void> _unpairDevice(PairedDevice device) async {
    if (device.clientId.startsWith('remote:')) {
      await widget.wsService.unpairCurrentDevice();
      _showMessage('Unpaired ${device.deviceName}');
      unawaited(_discoverDevices());
      return;
    }

    await widget.serverService.unpairDevice(device.clientId);
    _showMessage('Unpaired ${device.deviceName}');
    unawaited(_discoverDevices());
  }

  String _defaultDeviceName() {
    if (Platform.isAndroid) {
      return 'Android Phone';
    }
    if (Platform.isWindows) {
      return 'Windows Device';
    }
    return 'Flutter Device';
  }

  Future<void> _pairWithDiscoveredDevice(_DiscoveredDevice device) async {
    setState(() => _isConnecting = true);
    _lastRequestedDevice = device;
    _updateOutgoingRequestStatus('sending');

    final success = await widget.wsService.connect(
      device.host,
      serverPort: device.serverPort,
      clientPort: 8766,
      deviceName: _defaultDeviceName(),
    );

    if (!mounted) {
      return;
    }

    setState(() {
      _isConnecting = false;
      if (success) {
        _discoveredDevices.remove(device.key);
        _pruneDiscoveredPaired();
      }
    });

    if (!success) {
      _updateOutgoingRequestStatus('failed');
    }

    _showMessage(
      success
          ? 'Request sent to ${device.name}'
          : 'Failed to send request to ${device.name}',
      isError: !success,
    );
  }

  Future<void> _discoverDevices() async {
    if (_isDiscovering) {
      return;
    }

    setState(() {
      _isDiscovering = true;
      _discoveredDevices.clear();
    });

    RawDatagramSocket? socket;
    StreamSubscription<RawSocketEvent>? sub;

    try {
      socket = await RawDatagramSocket.bind(
        InternetAddress.anyIPv4,
        0,
        reuseAddress: true,
      );
      socket.broadcastEnabled = true;

      sub = socket.listen((event) {
        if (event != RawSocketEvent.read) {
          return;
        }

        final datagram = socket?.receive();
        if (datagram == null) {
          return;
        }

        _handleDiscoveryResponse(datagram);
      });

      final payload = utf8.encode(jsonEncode({'type': 'discover'}));
      final targets = await _discoveryTargets();

      Future<void> sendProbe() async {
        for (final target in targets) {
          socket?.send(payload, target, 8766);
        }
      }

      // Send multiple probes to improve discovery on slower/restricted WLANs.
      await sendProbe();
      await Future<void>.delayed(const Duration(milliseconds: 700));
      await sendProbe();
      await Future<void>.delayed(const Duration(milliseconds: 700));
      await sendProbe();

      await Future<void>.delayed(const Duration(seconds: 2));
    } catch (_) {
      _showMessage('Unable to scan devices on this WLAN', isError: true);
    } finally {
      await sub?.cancel();
      socket?.close();
      if (mounted) {
        setState(() => _isDiscovering = false);
      }
    }
  }

  Future<List<InternetAddress>> _discoveryTargets() async {
    final targets = <InternetAddress>{
      InternetAddress('255.255.255.255'),
    };

    try {
      final interfaces = await NetworkInterface.list(
        includeLoopback: false,
        type: InternetAddressType.IPv4,
      );

      for (final interface in interfaces) {
        for (final address in interface.addresses) {
          final host = address.address;
          final parts = host.split('.');
          if (parts.length != 4) {
            continue;
          }

          final last = int.tryParse(parts[3]);
          if (last == null) {
            continue;
          }

          // Best-effort /24 broadcast target for common home WLANs.
          targets
              .add(InternetAddress('${parts[0]}.${parts[1]}.${parts[2]}.255'));
        }
      }
    } catch (_) {}

    return targets.toList();
  }

  void _handleDiscoveryResponse(Datagram datagram) {
    try {
      final parsed = jsonDecode(utf8.decode(datagram.data));
      if (parsed is! Map<String, dynamic>) {
        return;
      }

      if (parsed['type']?.toString() != 'discover-ack') {
        return;
      }

      final name = parsed['name']?.toString() ?? 'Remote Device';
      final deviceId = parsed['deviceId']?.toString() ?? '';

      String host = datagram.address.address;
      int serverPort = 8765;

      final ws = parsed['ws']?.toString() ?? '';
      if (ws.isNotEmpty) {
        final wsUri = Uri.tryParse(ws);
        if (wsUri != null) {
          if (wsUri.host.isNotEmpty) {
            host = wsUri.host;
          }
          if (wsUri.hasPort) {
            serverPort = wsUri.port;
          }
        }
      } else {
        final tcpValue = parsed['tcp']?.toString();
        final tcpPort = int.tryParse(tcpValue ?? '');
        if (tcpPort != null) {
          serverPort = tcpPort;
        }
      }

      if (_isOwnServer(
        deviceId: deviceId,
        host: host,
        serverPort: serverPort,
      )) {
        return;
      }

      if (_isPairedDevice(deviceId)) {
        return;
      }

      final key = '$host:$serverPort';
      if (!mounted) {
        return;
      }

      setState(() {
        _discoveredDevices[key] = _DiscoveredDevice(
          key: key,
          name: name,
          deviceId: deviceId,
          host: host,
          serverPort: serverPort,
        );
      });
    } catch (_) {}
  }

  bool _isOwnServer({
    required String deviceId,
    required String host,
    required int serverPort,
  }) {
    if (deviceId.isNotEmpty && deviceId == widget.serverService.deviceId) {
      return true;
    }

    final localIp = widget.serverService.localIp;
    return serverPort == widget.serverService.port &&
        (host == localIp || host == '127.0.0.1' || host == 'localhost');
  }

  bool _isPairedDevice(String deviceId) {
    if (deviceId.isEmpty) {
      return false;
    }

    return _allPairedDevices().any((device) => device.deviceId == deviceId);
  }

  void _pruneDiscoveredPaired() {
    final pairedIds = _allPairedDevices()
        .map((device) => device.deviceId)
        .where((id) => id.isNotEmpty)
        .toSet();
    if (pairedIds.isEmpty) {
      return;
    }

    _discoveredDevices.removeWhere((_, device) {
      return device.deviceId.isNotEmpty && pairedIds.contains(device.deviceId);
    });
  }

  String _deviceAddressLabel(_DiscoveredDevice device) {
    var host = device.host;
    if (host == 'localhost' || host == '127.0.0.1') {
      host = widget.serverService.localIp;
    }

    return '$host:${device.serverPort}';
  }

  void _showMessage(String message, {bool isError = false}) {
    if (!mounted) {
      return;
    }

    ScaffoldMessenger.of(context).showSnackBar(
      SnackBar(
        content: Text(message),
        backgroundColor: isError ? Colors.red : Colors.green,
        duration: const Duration(seconds: 2),
      ),
    );
  }

  int _remainingRequestSeconds() {
    final deadline = _requestDeadline;
    if (deadline == null) {
      return 0;
    }

    final remaining = deadline.difference(DateTime.now()).inSeconds;
    return remaining > 0 ? remaining : 0;
  }

  void _startRequestCountdown() {
    _requestCountdownTimer?.cancel();
    _requestCountdownTimer = Timer.periodic(const Duration(seconds: 1), (_) {
      if (!mounted) {
        return;
      }

      if (_remainingRequestSeconds() == 0 &&
          (_outgoingRequestStatus == 'sending' ||
              _outgoingRequestStatus == 'pending')) {
        _updateOutgoingRequestStatus('timeout');
        return;
      }

      setState(() {});
    });
  }

  void _stopRequestCountdown() {
    _requestCountdownTimer?.cancel();
    _requestCountdownTimer = null;
  }

  void _updateOutgoingRequestStatus(
    String status, {
    bool fromStream = false,
  }) {
    final waiting = status == 'sending' || status == 'pending';

    setState(() {
      _outgoingRequestStatus = status;
      if (waiting) {
        _requestDeadline = DateTime.now().add(_requestTimeout);
      } else {
        _requestDeadline = null;
      }
    });

    if (waiting) {
      _startRequestCountdown();
    } else {
      _stopRequestCountdown();
    }

    if (fromStream && status == 'timeout') {
      _showMessage('Request timed out after 1 minute. Send again.',
          isError: true);
    }
  }

  Future<void> _resendLastRequest() async {
    final device = _lastRequestedDevice;
    if (device == null) {
      _showMessage('No previous request to resend.', isError: true);
      return;
    }
    await _pairWithDiscoveredDevice(device);
  }

  Widget _buildOutgoingRequestCard() {
    if (_outgoingRequestStatus == 'idle') {
      return const SizedBox.shrink();
    }

    final deviceName = _lastRequestedDevice?.name ?? 'Device';
    final remaining = _remainingRequestSeconds();

    String message;
    Color tint;

    switch (_outgoingRequestStatus) {
      case 'sending':
      case 'pending':
        message =
            'Request sent to $deviceName. Wait up to 1 minute to accept. ${remaining}s left.';
        tint = Colors.amber;
        break;
      case 'accepted':
        message = 'Accepted by $deviceName. Configuring both devices...';
        tint = Colors.green;
        break;
      case 'rejected':
        message = '$deviceName rejected the request. Send again.';
        tint = Colors.red;
        break;
      case 'timeout':
        message =
            'No response from $deviceName within 1 minute. Request timed out.';
        tint = Colors.red;
        break;
      case 'disconnected':
      case 'failed':
      default:
        message = 'Request failed/disconnected. Send again.';
        tint = Colors.red;
        break;
    }

    final canResend = _lastRequestedDevice != null &&
        (_outgoingRequestStatus == 'timeout' ||
            _outgoingRequestStatus == 'rejected' ||
            _outgoingRequestStatus == 'disconnected' ||
            _outgoingRequestStatus == 'failed');

    return Card(
      margin: const EdgeInsets.only(bottom: 10),
      color: tint.withValues(alpha: 0.1),
      child: Padding(
        padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 10),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Row(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Icon(Icons.hourglass_top, color: tint),
                const SizedBox(width: 10),
                Expanded(child: Text(message)),
              ],
            ),
            if (canResend) ...[
              const SizedBox(height: 10),
              Align(
                alignment: Alignment.centerRight,
                child: FilledButton(
                  onPressed: _isConnecting ? null : _resendLastRequest,
                  child: const Text('Send Again'),
                ),
              ),
            ],
          ],
        ),
      ),
    );
  }

  @override
  Widget build(BuildContext context) {
    final isNarrow = MediaQuery.of(context).size.width < 560;

    return SingleChildScrollView(
      padding: const EdgeInsets.all(16),
      child: Center(
        child: ConstrainedBox(
          constraints: const BoxConstraints(maxWidth: 720),
          child: Card(
            child: Padding(
              padding: const EdgeInsets.all(16),
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.stretch,
                children: [
                  _buildOutgoingRequestCard(),
                  OutlinedButton.icon(
                    onPressed: _isDiscovering ? null : _discoverDevices,
                    icon: _isDiscovering
                        ? const SizedBox(
                            width: 16,
                            height: 16,
                            child: CircularProgressIndicator(strokeWidth: 2),
                          )
                        : const Icon(Icons.wifi_find),
                    label: Text(
                      _isDiscovering ? 'Scanning WLAN...' : 'Scan WLAN devices',
                    ),
                  ),
                  _buildBluetoothSection(isNarrow),
                  const SizedBox(height: 14),
                  Text(
                    'Devices',
                    style: Theme.of(context).textTheme.titleLarge?.copyWith(
                          fontWeight: FontWeight.bold,
                        ),
                  ),
                  const SizedBox(height: 10),
                  if (_pendingRequests.isEmpty && _discoveredDevices.isEmpty)
                    const Padding(
                      padding: EdgeInsets.symmetric(vertical: 12),
                      child: Text(
                        'No devices found yet. Tap Scan WLAN devices.',
                      ),
                    ),
                  ..._pendingRequests.map(
                    (request) => Card(
                      margin: const EdgeInsets.only(bottom: 8),
                      color: Colors.orange.withValues(alpha: 0.08),
                      child: ListTile(
                        leading: const Icon(Icons.mark_email_unread_outlined),
                        title: Text(request.deviceName),
                        subtitle: Column(
                          crossAxisAlignment: CrossAxisAlignment.start,
                          children: [
                            Text(
                              'Incoming request',
                              style: Theme.of(context).textTheme.bodySmall,
                            ),
                            if (isNarrow) ...[
                              const SizedBox(height: 8),
                              Wrap(
                                spacing: 6,
                                runSpacing: 6,
                                children: [
                                  FilledButton(
                                    onPressed: () async {
                                      await widget.serverService
                                          .acceptRequest(request.clientId);
                                      _showMessage(
                                        'Accepted ${request.deviceName}',
                                      );
                                    },
                                    child: const Text('Accept'),
                                  ),
                                  OutlinedButton(
                                    onPressed: () async {
                                      await widget.serverService
                                          .rejectRequest(request.clientId);
                                      _showMessage(
                                        'Rejected ${request.deviceName}',
                                      );
                                    },
                                    child: const Text('Reject'),
                                  ),
                                ],
                              ),
                            ],
                          ],
                        ),
                        trailing: isNarrow
                            ? null
                            : Wrap(
                                spacing: 6,
                                children: [
                                  FilledButton(
                                    onPressed: () async {
                                      await widget.serverService
                                          .acceptRequest(request.clientId);
                                      _showMessage(
                                        'Accepted ${request.deviceName}',
                                      );
                                    },
                                    child: const Text('Accept'),
                                  ),
                                  OutlinedButton(
                                    onPressed: () async {
                                      await widget.serverService
                                          .rejectRequest(request.clientId);
                                      _showMessage(
                                        'Rejected ${request.deviceName}',
                                      );
                                    },
                                    child: const Text('Reject'),
                                  ),
                                ],
                              ),
                      ),
                    ),
                  ),
                  ..._discoveredDevices.values.map(
                    (device) => Card(
                      margin: const EdgeInsets.only(bottom: 8),
                      child: ListTile(
                        leading: const Icon(Icons.devices),
                        title: Text(device.name),
                        subtitle: Text(_deviceAddressLabel(device)),
                        trailing: FilledButton(
                          onPressed: _isConnecting
                              ? null
                              : () => _pairWithDiscoveredDevice(device),
                          child: const Text('Send request'),
                        ),
                      ),
                    ),
                  ),
                  const SizedBox(height: 10),
                  Text(
                    'Paired devices',
                    style: Theme.of(context).textTheme.titleMedium?.copyWith(
                          fontWeight: FontWeight.bold,
                        ),
                  ),
                  const SizedBox(height: 8),
                  if (_allPairedDevices().isEmpty)
                    const Padding(
                      padding: EdgeInsets.symmetric(vertical: 8),
                      child: Text('No paired devices yet.'),
                    ),
                  ..._allPairedDevices().map(
                    (device) => Card(
                      margin: const EdgeInsets.only(bottom: 8),
                      color: Colors.green.withValues(alpha: 0.07),
                      child: ListTile(
                        leading: const Icon(Icons.verified_user),
                        title: Text(device.deviceName),
                        subtitle: Text(
                          device.pairCode.isEmpty
                              ? 'Paired'
                              : 'Pair code: ${device.pairCode}',
                        ),
                        trailing: OutlinedButton(
                          onPressed: () => _unpairDevice(device),
                          child: const Text('Unpair'),
                        ),
                      ),
                    ),
                  ),
                ],
              ),
            ),
          ),
        ),
      ),
    );
  }
}

class _DiscoveredDevice {
  final String key;
  final String name;
  final String deviceId;
  final String host;
  final int serverPort;

  const _DiscoveredDevice({
    required this.key,
    required this.name,
    required this.deviceId,
    required this.host,
    required this.serverPort,
  });
}
