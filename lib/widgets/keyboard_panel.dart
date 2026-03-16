import 'package:flutter/material.dart';

import '../services/websocket_service.dart';

class KeyboardPanel extends StatefulWidget {
  final WebSocketService wsService;

  const KeyboardPanel({super.key, required this.wsService});

  @override
  State<KeyboardPanel> createState() => _KeyboardPanelState();
}

class _KeyboardPanelState extends State<KeyboardPanel> {
  bool _shifted = false;
  bool _capsLock = false;
  bool _ctrlHeld = false;
  bool _altHeld = false;
  int _page = 0; // 0=QWERTY  1=Fn+Nav  2=Numpad

  // ─── VK constants ────────────────────────────────────────────────────
  static const int _vkBack = 0x08;
  static const int _vkTab = 0x09;
  static const int _vkReturn = 0x0D;
  static const int _vkEsc = 0x1B;
  static const int _vkShift = 0x10;
  static const int _vkControl = 0x11;
  static const int _vkMenu = 0x12; // Alt
  static const int _vkLWin = 0x5B;
  static const int _vkInsert = 0x2D;
  static const int _vkDelete = 0x2E;
  static const int _vkHome = 0x24;
  static const int _vkEnd = 0x23;
  static const int _vkPrior = 0x21; // Page Up
  static const int _vkNext = 0x22; // Page Down
  static const int _vkLeft = 0x25;
  static const int _vkUp = 0x26;
  static const int _vkRight = 0x27;
  static const int _vkDown = 0x28;
  static const int _vkF1 = 0x70; // F1–F12 are sequential: 0x70–0x7B
  static const int _vkNumpad0 = 0x60; // Numpad 0–9 are 0x60–0x69
  static const int _vkMultiply = 0x6A;
  static const int _vkAdd = 0x6B;
  static const int _vkSubtract = 0x6D;
  static const int _vkDecimal = 0x6E;
  static const int _vkDivide = 0x6F;

  /// Maps lowercase character to VK code (used when Ctrl/Alt is active).
  static const Map<String, int> _charVk = {
    'a': 0x41,
    'b': 0x42,
    'c': 0x43,
    'd': 0x44,
    'e': 0x45,
    'f': 0x46,
    'g': 0x47,
    'h': 0x48,
    'i': 0x49,
    'j': 0x4A,
    'k': 0x4B,
    'l': 0x4C,
    'm': 0x4D,
    'n': 0x4E,
    'o': 0x4F,
    'p': 0x50,
    'q': 0x51,
    'r': 0x52,
    's': 0x53,
    't': 0x54,
    'u': 0x55,
    'v': 0x56,
    'w': 0x57,
    'x': 0x58,
    'y': 0x59,
    'z': 0x5A,
    '0': 0x30,
    '1': 0x31,
    '2': 0x32,
    '3': 0x33,
    '4': 0x34,
    '5': 0x35,
    '6': 0x36,
    '7': 0x37,
    '8': 0x38,
    '9': 0x39,
    ' ': 0x20,
  };

  bool get _effShift => _shifted || _capsLock;

  // ─── input helpers ───────────────────────────────────────────────────

  /// Tap on a character key (letters, numbers, symbols, space).
  void _onChar(String lo, String hi) {
    if (_ctrlHeld || _altHeld) {
      // Modifier combo — resolve a VK code and send combo
      final vk = _charVk[lo.toLowerCase()];
      if (vk != null) {
        _doCombo(
          [if (_ctrlHeld) _vkControl, if (_altHeld) _vkMenu],
          vk,
        );
      }
      setState(() {
        _ctrlHeld = false;
        _altHeld = false;
        if (_shifted) _shifted = false;
      });
      return;
    }
    // Plain text — honour shift/caps state
    widget.wsService.sendCommand({
      'type': 'send_text',
      'text': _effShift ? hi : lo,
    });
    if (_shifted) setState(() => _shifted = false);
  }

  /// Tap on a special/function key (VK-based).
  void _onVk(int vk) {
    final mods = <int>[
      if (_ctrlHeld) _vkControl,
      if (_altHeld) _vkMenu,
      if (_shifted) _vkShift,
    ];
    if (mods.isEmpty) {
      widget.wsService.sendCommand({'type': 'key_press', 'vk': vk});
    } else {
      _doCombo(mods, vk);
      setState(() {
        _ctrlHeld = false;
        _altHeld = false;
        if (_shifted) _shifted = false;
      });
    }
  }

  void _doCombo(List<int> mods, int vk) {
    widget.wsService.sendCommand({
      'type': 'key_combo',
      'modifiers': mods,
      'vk': vk,
    });
  }

  // ─── build ────────────────────────────────────────────────────────────

  @override
  Widget build(BuildContext context) {
    return Column(
      children: [
        Padding(
          padding: const EdgeInsets.fromLTRB(8, 6, 8, 2),
          child: SegmentedButton<int>(
            segments: const [
              ButtonSegment(
                value: 0,
                icon: Icon(Icons.keyboard, size: 15),
                label: Text('QWERTY'),
              ),
              ButtonSegment(
                value: 1,
                icon: Icon(Icons.functions, size: 15),
                label: Text('Fn / Nav'),
              ),
              ButtonSegment(
                value: 2,
                icon: Icon(Icons.calculate, size: 15),
                label: Text('Numpad'),
              ),
            ],
            selected: {_page},
            onSelectionChanged: (s) => setState(() => _page = s.first),
            style: SegmentedButton.styleFrom(
              padding: const EdgeInsets.symmetric(horizontal: 2),
              visualDensity: VisualDensity.compact,
            ),
          ),
        ),
        Expanded(
          child: IndexedStack(
            index: _page,
            children: [_qwerty(), _fnNav(), _numpad()],
          ),
        ),
      ],
    );
  }

  // ─── QWERTY layout ───────────────────────────────────────────────────

  Widget _qwerty() {
    return Padding(
      padding: const EdgeInsets.fromLTRB(2, 2, 2, 4),
      child: Column(
        children: [
          // Row 1 — numbers
          _kRow([
            _ck('`', '~'),
            _ck('1', '!'),
            _ck('2', '@'),
            _ck('3', '#'),
            _ck('4', r'$'),
            _ck('5', '%'),
            _ck('6', '^'),
            _ck('7', '&'),
            _ck('8', '*'),
            _ck('9', '('),
            _ck('0', ')'),
            _ck('-', '_'),
            _ck('=', '+'),
            _sk('⌫', () => _onVk(_vkBack), flex: 15),
          ]),
          // Row 2 — qwerty
          _kRow([
            _sk('Tab', () => _onVk(_vkTab), flex: 15),
            _ck('q', 'Q'),
            _ck('w', 'W'),
            _ck('e', 'E'),
            _ck('r', 'R'),
            _ck('t', 'T'),
            _ck('y', 'Y'),
            _ck('u', 'U'),
            _ck('i', 'I'),
            _ck('o', 'O'),
            _ck('p', 'P'),
            _ck('[', '{'),
            _ck(']', '}'),
            _ck('\\', '|', flex: 15),
          ]),
          // Row 3 — asdf
          _kRow([
            _mk('Caps', () => setState(() => _capsLock = !_capsLock), _capsLock,
                flex: 17),
            _ck('a', 'A'),
            _ck('s', 'S'),
            _ck('d', 'D'),
            _ck('f', 'F'),
            _ck('g', 'G'),
            _ck('h', 'H'),
            _ck('j', 'J'),
            _ck('k', 'K'),
            _ck('l', 'L'),
            _ck(';', ':'),
            _ck("'", '"'),
            _sk('↵', () => _onVk(_vkReturn), flex: 17),
          ]),
          // Row 4 — zxcv
          _kRow([
            _mk('⇧', () => setState(() => _shifted = !_shifted), _shifted,
                flex: 20),
            _ck('z', 'Z'),
            _ck('x', 'X'),
            _ck('c', 'C'),
            _ck('v', 'V'),
            _ck('b', 'B'),
            _ck('n', 'N'),
            _ck('m', 'M'),
            _ck(',', '<'),
            _ck('.', '>'),
            _ck('/', '?'),
            _mk('⇧', () => setState(() => _shifted = !_shifted), _shifted,
                flex: 20),
          ]),
          // Row 5 — bottom
          _kRow([
            _mk('Ctrl', () => setState(() => _ctrlHeld = !_ctrlHeld), _ctrlHeld,
                flex: 14),
            _sk('⊞', () => _onVk(_vkLWin), flex: 12),
            _mk('Alt', () => setState(() => _altHeld = !_altHeld), _altHeld,
                flex: 12),
            _ck(' ', ' ', flex: 42),
            _sk('Esc', () => _onVk(_vkEsc), flex: 12),
            _sk('←', () => _onVk(_vkLeft), flex: 10),
            _sk('↑', () => _onVk(_vkUp), flex: 10),
            _sk('↓', () => _onVk(_vkDown), flex: 10),
            _sk('→', () => _onVk(_vkRight), flex: 10),
          ]),
        ],
      ),
    );
  }

  // ─── Fn + Navigation layout ──────────────────────────────────────────

  Widget _fnNav() {
    return Padding(
      padding: const EdgeInsets.fromLTRB(2, 2, 2, 4),
      child: Column(
        children: [
          // Esc + F1–F12
          _kRow([
            _sk('Esc', () => _onVk(_vkEsc)),
            for (var i = 0; i < 12; i++)
              _sk('F${i + 1}', () => _onVk(_vkF1 + i)),
          ]),
          // Navigation cluster
          _kRow([
            _sk('Ins', () => _onVk(_vkInsert)),
            _sk('Del', () => _onVk(_vkDelete)),
            _sk('Home', () => _onVk(_vkHome)),
            _sk('End', () => _onVk(_vkEnd)),
            _sk('PgUp', () => _onVk(_vkPrior)),
            _sk('PgDn', () => _onVk(_vkNext)),
          ]),
          // Arrow keys — fill remaining space
          Expanded(
            flex: 3,
            child: Center(
              child: Column(
                mainAxisSize: MainAxisSize.min,
                children: [
                  Row(
                    mainAxisAlignment: MainAxisAlignment.center,
                    children: [
                      _arrowBtn('↑', () => _onVk(_vkUp)),
                    ],
                  ),
                  Row(
                    mainAxisAlignment: MainAxisAlignment.center,
                    children: [
                      _arrowBtn('←', () => _onVk(_vkLeft)),
                      _arrowBtn('↓', () => _onVk(_vkDown)),
                      _arrowBtn('→', () => _onVk(_vkRight)),
                    ],
                  ),
                ],
              ),
            ),
          ),
        ],
      ),
    );
  }

  // ─── Numpad layout ───────────────────────────────────────────────────

  Widget _numpad() {
    return Center(
      child: ConstrainedBox(
        constraints: const BoxConstraints(maxWidth: 280),
        child: Padding(
          padding: const EdgeInsets.symmetric(vertical: 8, horizontal: 4),
          child: Column(
            mainAxisAlignment: MainAxisAlignment.center,
            children: [
              _npRow([
                _sk('7', () => _onVk(_vkNumpad0 + 7)),
                _sk('8', () => _onVk(_vkNumpad0 + 8)),
                _sk('9', () => _onVk(_vkNumpad0 + 9)),
                _sk('/', () => _onVk(_vkDivide)),
              ]),
              _npRow([
                _sk('4', () => _onVk(_vkNumpad0 + 4)),
                _sk('5', () => _onVk(_vkNumpad0 + 5)),
                _sk('6', () => _onVk(_vkNumpad0 + 6)),
                _sk('×', () => _onVk(_vkMultiply)),
              ]),
              _npRow([
                _sk('1', () => _onVk(_vkNumpad0 + 1)),
                _sk('2', () => _onVk(_vkNumpad0 + 2)),
                _sk('3', () => _onVk(_vkNumpad0 + 3)),
                _sk('−', () => _onVk(_vkSubtract)),
              ]),
              _npRow([
                _sk('0', () => _onVk(_vkNumpad0), flex: 20),
                _sk('.', () => _onVk(_vkDecimal)),
                _sk('+', () => _onVk(_vkAdd)),
                _sk('↵', () => _onVk(_vkReturn)),
              ]),
            ],
          ),
        ),
      ),
    );
  }

  // ─── key factory helpers ─────────────────────────────────────────────

  /// Character key — sends Unicode text, respects shift/caps.
  Widget _ck(String lo, String hi, {int flex = 10}) => Expanded(
        flex: flex,
        child: _KeyBtn(
          label: _effShift ? hi : lo,
          onTap: () => _onChar(lo, hi),
        ),
      );

  /// Special/VK key.
  Widget _sk(String label, VoidCallback onTap, {int flex = 10}) => Expanded(
        flex: flex,
        child: _KeyBtn(label: label, onTap: onTap, special: true),
      );

  /// Sticky modifier key (highlights when active).
  Widget _mk(
    String label,
    VoidCallback onTap,
    bool active, {
    int flex = 10,
  }) =>
      Expanded(
        flex: flex,
        child:
            _KeyBtn(label: label, onTap: onTap, special: true, active: active),
      );

  /// Full-height keyboard row (used in QWERTY + Fn/Nav).
  Widget _kRow(List<Widget> keys) => Expanded(
        child: Row(
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: keys,
        ),
      );

  /// Fixed-height numpad row.
  Widget _npRow(List<Widget> keys) => SizedBox(
        height: 62,
        child: Row(
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: keys,
        ),
      );

  /// Large directional arrow button for the Fn/Nav panel.
  Widget _arrowBtn(String label, VoidCallback onTap) => SizedBox(
        width: 60,
        height: 60,
        child: _KeyBtn(label: label, onTap: onTap, special: false),
      );
}

// ─── Key button widget ────────────────────────────────────────────────────────

class _KeyBtn extends StatelessWidget {
  final String label;
  final VoidCallback onTap;
  final bool special;
  final bool active;

  const _KeyBtn({
    required this.label,
    required this.onTap,
    this.special = false,
    this.active = false,
  });

  @override
  Widget build(BuildContext context) {
    final cs = Theme.of(context).colorScheme;

    final Color bg;
    final Color fg;
    if (active) {
      bg = cs.primary;
      fg = cs.onPrimary;
    } else if (special) {
      bg = cs.surfaceContainerHigh;
      fg = cs.onSurface;
    } else {
      bg = cs.surfaceContainer;
      fg = cs.onSurface;
    }

    final fontSize = label.length > 3
        ? 9.0
        : label.length > 2
            ? 11.0
            : 13.0;

    return Padding(
      padding: const EdgeInsets.all(1.5),
      child: Material(
        color: bg,
        borderRadius: BorderRadius.circular(5),
        child: InkWell(
          onTap: onTap,
          borderRadius: BorderRadius.circular(5),
          child: Center(
            child: Text(
              label,
              style: TextStyle(
                fontSize: fontSize,
                fontWeight: FontWeight.w500,
                color: fg,
                height: 1.0,
              ),
              maxLines: 1,
              overflow: TextOverflow.clip,
              textAlign: TextAlign.center,
            ),
          ),
        ),
      ),
    );
  }
}
