import 'package:flutter/gestures.dart';
import 'package:flutter/material.dart';

import '../services/websocket_service.dart';

class MouseControlPanel extends StatefulWidget {
  final WebSocketService wsService;

  const MouseControlPanel({super.key, required this.wsService});

  @override
  State<MouseControlPanel> createState() => _MouseControlPanelState();
}

class _MouseControlPanelState extends State<MouseControlPanel> {
  // Multi-touch tracking
  final Map<int, Offset> _activePointers = {};
  Offset? _lastPanPosition;
  bool _isDragging = false;
  int _peakPointerCount = 0;

  double _sensitivity = 1.5;

  void _sendCommand(Map<String, dynamic> command) {
    widget.wsService.sendCommand(command);
  }

  void _onPointerDown(PointerDownEvent e) {
    _activePointers[e.pointer] = e.localPosition;
    if (_activePointers.length > _peakPointerCount) {
      _peakPointerCount = _activePointers.length;
    }
    if (_activePointers.length == 1) {
      _lastPanPosition = e.localPosition;
      _isDragging = false;
    } else {
      // Second finger cancels any ongoing drag
      _lastPanPosition = null;
    }
  }

  void _onPointerMove(PointerMoveEvent e) {
    _activePointers[e.pointer] = e.localPosition;
    if (_activePointers.length == 1 && _lastPanPosition != null) {
      final dx = (e.localPosition.dx - _lastPanPosition!.dx) * _sensitivity;
      final dy = (e.localPosition.dy - _lastPanPosition!.dy) * _sensitivity;
      if (!_isDragging && (dx.abs() + dy.abs()) > 3) {
        _isDragging = true;
      }
      if (_isDragging) {
        _sendCommand({'type': 'move', 'dx': dx.round(), 'dy': dy.round()});
      }
      _lastPanPosition = e.localPosition;
    }
  }

  void _onPointerUp(PointerUpEvent e) {
    _activePointers.remove(e.pointer);
    if (_activePointers.isEmpty) {
      if (!_isDragging) {
        // Tap — decide left or right based on peak finger count
        if (_peakPointerCount >= 2) {
          _sendCommand({'type': 'click', 'button': 'right'});
        } else {
          _sendCommand({'type': 'click', 'button': 'left'});
        }
      }
      _peakPointerCount = 0;
      _isDragging = false;
      _lastPanPosition = null;
    }
  }

  void _onPointerCancel(PointerCancelEvent e) {
    _activePointers.remove(e.pointer);
    if (_activePointers.isEmpty) {
      _peakPointerCount = 0;
      _isDragging = false;
      _lastPanPosition = null;
    }
  }

  @override
  Widget build(BuildContext context) {
    return LayoutBuilder(
      builder: (context, constraints) {
        final isNarrow = constraints.maxWidth < 700;
        final pad = isNarrow ? 12.0 : 20.0;
        final trackpadHeight =
            (constraints.maxHeight * 0.62).clamp(280.0, 560.0);
        final colorScheme = Theme.of(context).colorScheme;

        return Padding(
          padding: EdgeInsets.all(pad),
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.stretch,
            children: [
              // ── Trackpad card ──────────────────────────────────────────
              Card(
                elevation: 4,
                clipBehavior: Clip.hardEdge,
                child: SizedBox(
                  height: trackpadHeight,
                  child: Column(
                    children: [
                      // Touch surface
                      Expanded(
                        child: Listener(
                          onPointerDown: _onPointerDown,
                          onPointerMove: _onPointerMove,
                          onPointerUp: _onPointerUp,
                          onPointerCancel: _onPointerCancel,
                          onPointerSignal: (event) {
                            if (event is PointerScrollEvent) {
                              _sendCommand({
                                'type': 'wheel',
                                'delta': event.scrollDelta.dy.round(),
                              });
                            }
                          },
                          child: Container(
                            width: double.infinity,
                            decoration: BoxDecoration(
                              gradient: LinearGradient(
                                begin: Alignment.topLeft,
                                end: Alignment.bottomRight,
                                colors: [
                                  colorScheme.surfaceContainerHighest,
                                  colorScheme.surface,
                                ],
                              ),
                            ),
                            child: Column(
                              mainAxisAlignment: MainAxisAlignment.center,
                              children: [
                                Icon(
                                  Icons.touch_app_rounded,
                                  size: isNarrow ? 52 : 68,
                                  color: colorScheme.primary
                                      .withValues(alpha: 0.4),
                                ),
                                const SizedBox(height: 10),
                                Text(
                                  'Drag to move',
                                  style: Theme.of(context)
                                      .textTheme
                                      .titleMedium
                                      ?.copyWith(
                                        color: colorScheme.onSurface
                                            .withValues(alpha: 0.6),
                                      ),
                                ),
                                const SizedBox(height: 4),
                                Text(
                                  '1 finger → left click  ·  2 fingers → right click',
                                  textAlign: TextAlign.center,
                                  style: Theme.of(context)
                                      .textTheme
                                      .bodySmall
                                      ?.copyWith(
                                        color: colorScheme.onSurface
                                            .withValues(alpha: 0.45),
                                      ),
                                ),
                              ],
                            ),
                          ),
                        ),
                      ),

                      // ── Embedded click buttons ─────────────────────────
                      Divider(
                          height: 1,
                          thickness: 1,
                          color: colorScheme.outline.withValues(alpha: 0.3)),
                      IntrinsicHeight(
                        child: Row(
                          children: [
                            Expanded(
                              child: _ClickButton(
                                label: 'Left Click',
                                icon: Icons.mouse,
                                color: colorScheme.primary,
                                onPressed: () => _sendCommand(
                                    {'type': 'click', 'button': 'left'}),
                              ),
                            ),
                            VerticalDivider(
                                width: 1,
                                thickness: 1,
                                color:
                                    colorScheme.outline.withValues(alpha: 0.3)),
                            Expanded(
                              child: _ClickButton(
                                label: 'Right Click',
                                icon: Icons.mouse_outlined,
                                color: Colors.orange,
                                onPressed: () => _sendCommand(
                                    {'type': 'click', 'button': 'right'}),
                              ),
                            ),
                            VerticalDivider(
                                width: 1,
                                thickness: 1,
                                color:
                                    colorScheme.outline.withValues(alpha: 0.3)),
                            Expanded(
                              child: _ClickButton(
                                label: 'Double',
                                icon: Icons.double_arrow_rounded,
                                color: Colors.purple,
                                onPressed: () => _sendCommand({
                                  'type': 'click',
                                  'button': 'left',
                                  'kind': 'double',
                                }),
                              ),
                            ),
                          ],
                        ),
                      ),
                    ],
                  ),
                ),
              ),

              const SizedBox(height: 12),

              // ── Sensitivity slider at bottom ───────────────────────────
              Card(
                child: Padding(
                  padding:
                      const EdgeInsets.symmetric(horizontal: 16, vertical: 10),
                  child: Row(
                    children: [
                      const Icon(Icons.speed, size: 18),
                      const SizedBox(width: 8),
                      Text(
                        'Sensitivity',
                        style: Theme.of(context).textTheme.bodyMedium?.copyWith(
                              fontWeight: FontWeight.w600,
                            ),
                      ),
                      Expanded(
                        child: Slider(
                          value: _sensitivity,
                          min: 0.5,
                          max: 5.0,
                          divisions: 18,
                          label: _sensitivity.toStringAsFixed(1),
                          onChanged: (v) => setState(() => _sensitivity = v),
                        ),
                      ),
                      SizedBox(
                        width: 36,
                        child: Text(
                          '${_sensitivity.toStringAsFixed(1)}×',
                          style: Theme.of(context).textTheme.bodySmall,
                          textAlign: TextAlign.right,
                        ),
                      ),
                    ],
                  ),
                ),
              ),
            ],
          ),
        );
      },
    );
  }
}

class _ClickButton extends StatelessWidget {
  final String label;
  final IconData icon;
  final Color color;
  final VoidCallback onPressed;

  const _ClickButton({
    required this.label,
    required this.icon,
    required this.color,
    required this.onPressed,
  });

  @override
  Widget build(BuildContext context) {
    return InkWell(
      onTap: onPressed,
      child: Padding(
        padding: const EdgeInsets.symmetric(vertical: 14),
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            Icon(icon, color: color, size: 20),
            const SizedBox(height: 4),
            Text(
              label,
              style: TextStyle(
                fontSize: 11,
                fontWeight: FontWeight.w600,
                color: color,
              ),
            ),
          ],
        ),
      ),
    );
  }
}
