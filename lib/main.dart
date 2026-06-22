import 'dart:math' as math;

import 'package:confetti/confetti.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_tts/flutter_tts.dart';
import 'package:package_info_plus/package_info_plus.dart';
import 'package:permission_handler/permission_handler.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:wakelock_plus/wakelock_plus.dart';

// Brand colours
const _kBgTop    = Color(0xFF0D0D1A);
const _kBgBottom = Color(0xFF1A0D2E);
const _kAccent   = Color(0xFF7C4DFF);
const _kAccentLo = Color(0xFF4A148C);

const _aecChannel        = MethodChannel('com.vel.micify/aec');
const _audioRouteChannel = MethodChannel('com.vel.micify/audio_route');
const _relayChannel      = MethodChannel('com.vel.micify/relay_service');

enum _MicSource { builtin, wired, bluetooth }

extension _MicSourceExt on _MicSource {
  String get id => name;
  String get label => switch (this) {
    _MicSource.builtin   => 'Built-in',
    _MicSource.wired     => 'Wired',
    _MicSource.bluetooth => 'Bluetooth',
  };
  IconData get icon => switch (this) {
    _MicSource.builtin   => Icons.mic_rounded,
    _MicSource.wired     => Icons.headset_rounded,
    _MicSource.bluetooth => Icons.bluetooth_audio_rounded,
  };
}

// Voice effects for Kids mode
class _VoiceEffect {
  final String label;
  final double rate;
  final IconData icon;
  final Color color;
  const _VoiceEffect(this.label, this.rate, this.icon, this.color);
}

const _voiceEffects = [
  _VoiceEffect('Normal',   1.00, Icons.mic_rounded,       Color(0xFFFFFFFF)),
  _VoiceEffect('Kid',      1.60, Icons.child_care,         Color(0xFFFFC107)),
  _VoiceEffect('Chipmunk', 1.80, Icons.pets,               Color(0xFFFF9800)),
  _VoiceEffect('Adult',    0.75, Icons.person,             Color(0xFF42A5F5)),
  _VoiceEffect('Monster',  0.60, Icons.whatshot_rounded,   Color(0xFFFF5722)),
  _VoiceEffect('Robot',    0.70, Icons.smart_toy_rounded,  Color(0xFF26C6DA)),
];

void main() {
  runApp(const MicifyApp());
}

class MicifyApp extends StatelessWidget {
  const MicifyApp({super.key});

  @override
  Widget build(BuildContext context) {
    return MaterialApp(
      title: 'Micify',
      debugShowCheckedModeBanner: false,
      theme: ThemeData.dark(useMaterial3: true).copyWith(
        colorScheme: ColorScheme.fromSeed(
          seedColor: _kAccent,
          brightness: Brightness.dark,
        ).copyWith(
          surface: _kBgTop,
          primary: _kAccent,
        ),
        sliderTheme: const SliderThemeData(
          activeTrackColor: _kAccent,
          thumbColor: _kAccent,
          overlayColor: Color(0x337C4DFF),
          inactiveTrackColor: Color(0xFF2A2A3A),
        ),
        expansionTileTheme: const ExpansionTileThemeData(
          iconColor: Color(0xFF9E9E9E),
          collapsedIconColor: Color(0xFF9E9E9E),
        ),
      ),
      home: const MicifyHome(),
    );
  }
}

// Gain + voice presets
class _Preset {
  final String label;
  final double gain;
  final double lowCutHz;
  final double maxThreshold;
  final double bassDb;
  final double midDb;
  final double trebleDb;
  const _Preset(this.label, this.gain, this.lowCutHz, this.maxThreshold,
      this.bassDb, this.midDb, this.trebleDb);
}

const _presets = [
  _Preset('Gentle',     1.5, 200, 0.5,  0,  0,  0),
  _Preset('Quiet room', 2.0, 250, 0.9,  0,  0,  2),
  _Preset('Classroom',  3.5, 300, 0.9, -2, -2,  4),
  _Preset('Outdoor',    6.0, 300, 0.9,  3,  2,  0),
  _Preset('Large hall', 8.0, 300, 0.9, -3, -3,  6),
];

class MicifyHome extends StatefulWidget {
  const MicifyHome({super.key});

  @override
  State<MicifyHome> createState() => _MicifyHomeState();
}

class _MicifyHomeState extends State<MicifyHome> with TickerProviderStateMixin {

  // UI state
  bool _isRunning = false;
  bool _permissionGranted = false;
  double _gain = 1.5;
  double _maxAllowedGain = 10.0; // capped to 3.0 by service when on phone speaker
  double _lowCutHz = 300;
  bool _echoCancelEnabled = true;
  bool _noiseSuppressEnabled = true;
  double _maxThreshold = 0.9;
  double _volumeLevel = 0.0;
  bool _feedbackWarning = false;

  // EQ
  double _eqBassDb   = 0.0;
  double _eqMidDb    = 0.0;
  double _eqTrebleDb = 0.0;

  // Voice effect (Kids mode)
  double _pitchRate = 1.0;

  // Kids mode volume (independent from Relay gain)
  double _kidsGain = 5.0;

  // Bottom nav tab
  int _activeTab = 0;

  // Kids mode extras
  final _tts = FlutterTts();
  late final ConfettiController _confetti;
  late final ConfettiController _stars;
  late final AnimationController _flashCtrl;
  late final Animation<double> _flashAnim;

  // Mic source selection
  _MicSource _micSource = _MicSource.builtin;
  List<_MicSource> _availableSources = [_MicSource.builtin, _MicSource.wired];

  @override
  void initState() {
    super.initState();
    _confetti = ConfettiController(duration: const Duration(seconds: 2));
    _stars = ConfettiController(duration: const Duration(seconds: 3));
    _flashCtrl = AnimationController(
      vsync: this,
      duration: const Duration(milliseconds: 600),
    );
    _flashAnim = Tween<double>(begin: 0, end: 0.35).animate(
      CurvedAnimation(parent: _flashCtrl, curve: Curves.easeOut),
    );
    _tts.setSpeechRate(0.45);
    _tts.setPitch(1.4);
    _requestPermissions();
    _loadAvailableSources();
    HardwareKeyboard.instance.addHandler(_onKey);
    SystemChrome.setEnabledSystemUIMode(SystemUiMode.immersiveSticky);
    _relayChannel.setMethodCallHandler((call) async {
      if (!mounted) return;
      switch (call.method) {
        case 'onLevel':
          final raw = call.arguments as double;
          if (raw < 0) {
            // Silence timeout sentinel from the audio thread
            _showSilenceNudge();
          } else {
            final level = raw.clamp(0.0, 1.0);
            if ((level - _volumeLevel).abs() > 0.02) {
              setState(() => _volumeLevel = level);
            }
          }
        case 'onMaxGain':
          final max = (call.arguments as double).clamp(1.0, 10.0);
          setState(() {
            _maxAllowedGain = max;
            if (_gain > max) _gain = max;
          });
        case 'onBluetoothConnected':
          // Auto-restart relay when BT speaker reconnects
          if (!_isRunning) _start();
        case 'onBluetoothDisconnected':
          // Nothing needed — Android re-routes output automatically
          break;
        case 'onRelayInterruptedByCall':
          if (mounted) setState(() { _isRunning = false; _volumeLevel = 0; });
        case 'onRelayResumedAfterCall':
          if (mounted) setState(() => _isRunning = true);
      }
    });
    WidgetsBinding.instance.addPostFrameCallback((_) => _maybeShowTip());
  }

  void _showSilenceNudge() {
    if (!mounted || !_isRunning) return;
    ScaffoldMessenger.of(context).showSnackBar(
      SnackBar(
        content: const Text('Still relaying? Tap to continue or stop.'),
        duration: const Duration(seconds: 6),
        action: SnackBarAction(label: 'Stop', onPressed: _stop),
        backgroundColor: const Color(0xFF2D2040),
        behavior: SnackBarBehavior.floating,
      ),
    );
  }

  Future<void> _maybeShowTip() async {
    final prefs = await SharedPreferences.getInstance();
    final seen = prefs.getBool('tip_speaker_distance') ?? false;
    if (seen || !mounted) return;
    await prefs.setBool('tip_speaker_distance', true);
    if (!mounted) return;
    showModalBottomSheet(
      context: context,
      backgroundColor: const Color(0xFF13102A),
      shape: const RoundedRectangleBorder(
        borderRadius: BorderRadius.vertical(top: Radius.circular(24)),
      ),
      builder: (_) => Padding(
        padding: const EdgeInsets.fromLTRB(28, 20, 28, 40),
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            Center(
              child: Container(
                width: 36, height: 4,
                decoration: BoxDecoration(
                  color: Colors.white.withOpacity(0.15),
                  borderRadius: BorderRadius.circular(2),
                ),
              ),
            ),
            const SizedBox(height: 24),
            const Icon(Icons.spatial_audio_off_rounded, color: _kAccent, size: 48),
            const SizedBox(height: 16),
            const Text('Best results',
              style: TextStyle(
                color: Colors.white,
                fontSize: 18,
                fontWeight: FontWeight.w700,
              )),
            const SizedBox(height: 12),
            Text(
              'Keep the speaker at least 1 m away from the phone to avoid echo. '
              'Use a Bluetooth speaker for the clearest relay.',
              textAlign: TextAlign.center,
              style: TextStyle(
                color: Colors.white.withOpacity(0.6),
                fontSize: 14,
                height: 1.5,
              ),
            ),
            const SizedBox(height: 28),
            FilledButton(
              onPressed: () => Navigator.pop(_),
              style: FilledButton.styleFrom(
                backgroundColor: _kAccent,
                minimumSize: const Size(200, 48),
              ),
              child: const Text('Got it'),
            ),
          ],
        ),
      ),
    );
  }

  bool _onKey(KeyEvent event) {
    if (event is KeyDownEvent &&
        (event.logicalKey == LogicalKeyboardKey.audioVolumeUp ||
         event.logicalKey == LogicalKeyboardKey.audioVolumeDown)) {
      if (_permissionGranted) {
        _isRunning ? _stop() : _start();
        return true;
      }
    }
    return false;
  }

  Future<void> _loadAvailableSources() async {
    try {
      final result = await _audioRouteChannel.invokeMethod<List>('getAvailableSources');
      if (result != null && mounted) {
        setState(() {
          _availableSources = result
              .map((s) => _MicSource.values.firstWhere(
                    (e) => e.id == s,
                    orElse: () => _MicSource.builtin,
                  ))
              .toSet()
              .toList();
        });
      }
    } catch (_) {}
  }

  Future<void> _setMicSource(_MicSource source) async {
    try {
      await _audioRouteChannel.invokeMethod('setMicSource', {'source': source.id});
    } catch (_) {}
    setState(() => _micSource = source);
  }

  Future<void> _requestPermissions() async {
    final statuses = await [
      Permission.microphone,
      Permission.bluetooth,
      Permission.bluetoothConnect,
      Permission.phone,
    ].request();
    final micGranted = statuses[Permission.microphone]?.isGranted ?? false;
    if (mounted) setState(() => _permissionGranted = micGranted);
  }

  Map<String, dynamic> get _currentSettings => {
    'gain':         _activeTab == 1 ? _kidsGain : _gain,
    'lowCutHz':     _lowCutHz,
    'maxThreshold': _maxThreshold,
    'bassDb':       _eqBassDb,
    'midDb':        _eqMidDb,
    'trebleDb':     _eqTrebleDb,
    'echoCancel':   _echoCancelEnabled,
    'noiseSuppress':_noiseSuppressEnabled,
    'pitchRate':    _pitchRate,
  };

  Future<void> _start() async {
    if (!_permissionGranted) {
      await _requestPermissions();
      if (!_permissionGranted) return;
    }
    HapticFeedback.mediumImpact();
    await WakelockPlus.enable();
    await _relayChannel.invokeMethod('start', _currentSettings);
    if (mounted) setState(() => _isRunning = true);
  }

  Future<void> _stop() async {
    HapticFeedback.mediumImpact();
    await _relayChannel.invokeMethod('stop');
    await WakelockPlus.disable();
    if (mounted) setState(() { _isRunning = false; _volumeLevel = 0; });
  }

  Future<void> _pushSettings() async {
    if (_isRunning) {
      await _relayChannel.invokeMethod('applySettings', _currentSettings);
    }
  }

  void _applyPreset(_Preset preset) {
    setState(() {
      _gain = preset.gain;
      _lowCutHz = preset.lowCutHz;
      _maxThreshold = preset.maxThreshold;
      _eqBassDb = preset.bassDb;
      _eqMidDb = preset.midDb;
      _eqTrebleDb = preset.trebleDb;
    });
    _pushSettings();
  }

  Future<void> _showAbout(BuildContext context) async {
    final info = await PackageInfo.fromPlatform();
    if (!context.mounted) return;
    showModalBottomSheet(
      context: context,
      backgroundColor: const Color(0xFF13102A),
      shape: const RoundedRectangleBorder(
        borderRadius: BorderRadius.vertical(top: Radius.circular(24)),
      ),
      builder: (_) => Padding(
        padding: const EdgeInsets.fromLTRB(28, 20, 28, 36),
        child: Column(
          mainAxisSize: MainAxisSize.min,
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            // Drag handle
            Center(
              child: Container(
                width: 36, height: 4,
                decoration: BoxDecoration(
                  color: Colors.white.withOpacity(0.15),
                  borderRadius: BorderRadius.circular(2),
                ),
              ),
            ),
            const SizedBox(height: 20),
            // App name + version
            Row(
              children: [
                const Icon(Icons.graphic_eq_rounded, color: _kAccent, size: 28),
                const SizedBox(width: 10),
                Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Text('Micify',
                      style: const TextStyle(
                        color: Colors.white,
                        fontSize: 20,
                        fontWeight: FontWeight.w700,
                        letterSpacing: 1.2,
                      )),
                    Text('Version ${info.version} (${info.buildNumber})',
                      style: TextStyle(
                        color: Colors.white.withOpacity(0.4),
                        fontSize: 12,
                      )),
                  ],
                ),
              ],
            ),
            const SizedBox(height: 16),
            Text(
              'Ultra-low-latency microphone relay and amplification. '
              'No account, no cloud, no setup.',
              style: TextStyle(
                color: Colors.white.withOpacity(0.6),
                fontSize: 13,
                height: 1.5,
              ),
            ),
            const SizedBox(height: 20),
            _AboutDivider(),
            const SizedBox(height: 16),
            _AboutRow(
              icon: Icons.code_rounded,
              label: 'Open-source',
              value: 'MIT Licence',
            ),
            const SizedBox(height: 10),
            _AboutRow(
              icon: Icons.copyright_rounded,
              label: 'Copyright',
              value: '© 2026 Velmurugan R',
            ),
            const SizedBox(height: 10),
            _AboutRow(
              icon: Icons.link_rounded,
              label: 'Source',
              value: 'github.com/velmuruganr/micify',
            ),
            const SizedBox(height: 20),
            _AboutDivider(),
            const SizedBox(height: 16),
            Text(
              'Open-source core released under the MIT Licence. '
              'Contributions welcome.',
              style: TextStyle(
                color: Colors.white.withOpacity(0.3),
                fontSize: 11,
                height: 1.5,
              ),
            ),
          ],
        ),
      ),
    );
  }

  @override
  void dispose() {
    HardwareKeyboard.instance.removeHandler(_onKey);
    _confetti.dispose();
    _stars.dispose();
    _flashCtrl.dispose();
    _tts.stop();
    _stop();
    super.dispose();
  }

  Widget _buildBackground({required Widget child}) => Container(
    decoration: const BoxDecoration(
      gradient: LinearGradient(
        begin: Alignment.topCenter,
        end: Alignment.bottomCenter,
        colors: [_kBgTop, _kBgBottom],
      ),
    ),
    child: child,
  );

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);

    return Scaffold(
      bottomNavigationBar: NavigationBar(
        backgroundColor: const Color(0xFF0D0D1A),
        indicatorColor: _kAccent.withOpacity(0.3),
        selectedIndex: _activeTab,
        onDestinationSelected: (i) {
          setState(() => _activeTab = i);
          if (i == 0 && _pitchRate != 1.0) {
            // Switching to Relay — reset pitch so Kids effects don't bleed through
            setState(() => _pitchRate = 1.0);
          }
          // Push settings so gain + pitch update immediately for the new tab
          _pushSettings();
        },
        destinations: const [
          NavigationDestination(
            icon: Icon(Icons.mic_rounded),
            label: 'Relay',
          ),
          NavigationDestination(
            icon: Icon(Icons.child_care),
            label: 'Kids',
          ),
        ],
      ),
      body: IndexedStack(
        index: _activeTab,
        children: [
          _buildRelayTab(theme),
          _buildKidsTab(theme),
        ],
      ),
    );
  }

  Widget _buildKidsTab(ThemeData theme) {
    final selectedEffect = _voiceEffects.firstWhere(
      (e) => e.rate == _pitchRate,
      orElse: () => _voiceEffects.first,
    );
    return Stack(
      children: [
        // Background colour shift — tints to effect colour when relay is running
        AnimatedContainer(
          duration: const Duration(milliseconds: 500),
          decoration: BoxDecoration(
            gradient: LinearGradient(
              begin: Alignment.topCenter,
              end: Alignment.bottomCenter,
              colors: _isRunning
                  ? [
                      Color.lerp(_kBgTop, selectedEffect.color, 0.18)!,
                      Color.lerp(_kBgBottom, selectedEffect.color, 0.12)!,
                    ]
                  : [_kBgTop, _kBgBottom],
            ),
          ),
        ),
        // Monster flash — red overlay
        AnimatedBuilder(
          animation: _flashAnim,
          builder: (_, __) => _flashAnim.value > 0
              ? Opacity(
                  opacity: _flashAnim.value,
                  child: Container(color: Colors.red),
                )
              : const SizedBox.shrink(),
        ),
        // Star shower — Kid / Chipmunk
        Align(
          alignment: Alignment.topCenter,
          child: ConfettiWidget(
            confettiController: _stars,
            blastDirectionality: BlastDirectionality.explosive,
            numberOfParticles: 30,
            gravity: 0.2,
            colors: const [
              Color(0xFFFFC107), Color(0xFFFFEB3B), Color(0xFFFFFFFF),
              Color(0xFF81D4FA), Color(0xFFF48FB1),
            ],
          ),
        ),
        // Confetti fires from the top-centre on Loud tap
        Align(
          alignment: Alignment.topCenter,
          child: ConfettiWidget(
            confettiController: _confetti,
            blastDirectionality: BlastDirectionality.explosive,
            numberOfParticles: 40,
            gravity: 0.3,
            colors: const [
              Color(0xFF7C4DFF), Color(0xFFFF9800), Color(0xFFFFC107),
              Color(0xFF42A5F5), Color(0xFFFF5722), Color(0xFF66BB6A),
            ],
          ),
        ),
          SafeArea(
        child: Padding(
          padding: const EdgeInsets.symmetric(horizontal: 24, vertical: 28),
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.center,
            children: [
              // Header
              Text('Kids Mode',
                style: theme.textTheme.titleLarge?.copyWith(
                  fontWeight: FontWeight.w700,
                  color: Colors.white,
                  letterSpacing: 1.5,
                )),
              const SizedBox(height: 4),
              Text('Tap an effect, then press Start',
                style: theme.textTheme.bodySmall?.copyWith(
                  color: Colors.white.withOpacity(0.4),
                )),

              const SizedBox(height: 24),

              // Bar visualiser — tints to selected effect colour
              _BarVisualiser(
                level: _volumeLevel,
                isRunning: _isRunning,
                accentColor: _voiceEffects
                    .firstWhere((e) => e.rate == _pitchRate,
                        orElse: () => _voiceEffects.first)
                    .color,
              ),

              const SizedBox(height: 24),

              // Effect grid
              Expanded(
                child: GridView.count(
                  crossAxisCount: 2,
                  mainAxisSpacing: 16,
                  crossAxisSpacing: 16,
                  childAspectRatio: 1.1,
                  children: _voiceEffects.map((e) {
                    final selected = _pitchRate == e.rate;
                    return GestureDetector(
                      onTap: () {
                        setState(() => _pitchRate = e.rate);
                        _pushSettings();
                        _tts.speak(e.label);
                        // Monster — red screen flash
                        if (e.label == 'Monster') {
                          _flashCtrl.forward().then((_) => _flashCtrl.reverse());
                        }
                        // Kid / Chipmunk — star shower
                        if (e.label == 'Kid' || e.label == 'Chipmunk') {
                          _stars.play();
                        }
                      },
                      child: Stack(
                        clipBehavior: Clip.none,
                        children: [
                          // Bouncing emoji above selected card
                          if (selected)
                            Positioned(
                              top: -18,
                              left: 0,
                              right: 0,
                              child: Center(
                                child: _BounceWidget(
                                  key: ValueKey(e.label),
                                  child: Icon(e.icon, size: 20, color: e.color),
                                ),
                              ),
                            ),
                      AnimatedContainer(
                        duration: const Duration(milliseconds: 200),
                        decoration: BoxDecoration(
                          color: selected
                              ? e.color.withOpacity(0.2)
                              : Colors.white.withOpacity(0.05),
                          borderRadius: BorderRadius.circular(20),
                          border: Border.all(
                            color: selected ? e.color : Colors.white.withOpacity(0.1),
                            width: selected ? 2 : 1,
                          ),
                          boxShadow: selected
                              ? [BoxShadow(color: e.color.withOpacity(0.3), blurRadius: 16)]
                              : [],
                        ),
                        child: Column(
                          mainAxisAlignment: MainAxisAlignment.center,
                          children: [
                            Icon(e.icon,
                              size: 42,
                              color: selected ? e.color : Colors.white.withOpacity(0.5)),
                            const SizedBox(height: 10),
                            Text(e.label,
                              style: TextStyle(
                                fontSize: 14,
                                fontWeight: selected ? FontWeight.w700 : FontWeight.w400,
                                color: selected ? e.color : Colors.white.withOpacity(0.6),
                              )),
                          ],
                        ),
                      ),
                        ], // Stack children
                      ), // Stack
                    );
                  }).toList(),
                ),
              ),

              const SizedBox(height: 20),

              // Volume presets
              Text('VOLUME',
                style: theme.textTheme.labelSmall?.copyWith(
                  color: Colors.white.withOpacity(0.4),
                  letterSpacing: 2.0,
                  fontSize: 10,
                )),
              const SizedBox(height: 10),
              Row(
                mainAxisAlignment: MainAxisAlignment.center,
                children: [
                  _KidsVolumePill(label: 'Soft',   gain: 3.0, kidsGain: _kidsGain, onTap: (g) { setState(() => _kidsGain = g); _pushSettings(); }),
                  const SizedBox(width: 12),
                  _KidsVolumePill(label: 'Normal', gain: 5.0, kidsGain: _kidsGain, onTap: (g) { setState(() => _kidsGain = g); _pushSettings(); }),
                  const SizedBox(width: 12),
                  _KidsVolumePill(label: 'Loud',   gain: 9.0, kidsGain: _kidsGain, onTap: (g) { setState(() => _kidsGain = g); _pushSettings(); _confetti.play(); }),
                ],
              ),

              const SizedBox(height: 20),

              // Start / Stop button
              FilledButton.icon(
                onPressed: _permissionGranted
                    ? (_isRunning ? _stop : _start)
                    : _requestPermissions,
                icon: Icon(_isRunning ? Icons.stop_rounded : Icons.mic_rounded),
                label: Text(_isRunning ? 'Stop' : _permissionGranted ? 'Start' : 'Grant Permission'),
                style: FilledButton.styleFrom(
                  backgroundColor: _isRunning ? theme.colorScheme.error : _kAccent,
                  minimumSize: const Size(220, 56),
                ),
              ),

              if (_isRunning) ...[
                const SizedBox(height: 8),
                Text('Screen stays on while relaying',
                  style: TextStyle(color: Colors.white.withOpacity(0.3), fontSize: 11)),
              ],
              const SizedBox(height: 8),
            ],
          ),
        ),
      ),
        ],
      );
  }

  Widget _buildRelayTab(ThemeData theme) {
    return _buildBackground(
      child: SafeArea(
        child: SingleChildScrollView(
          padding: const EdgeInsets.symmetric(horizontal: 24, vertical: 28),
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.center,
              children: [
                // Header
                Row(
                  mainAxisAlignment: MainAxisAlignment.center,
                  children: [
                    const Icon(Icons.graphic_eq_rounded, color: _kAccent, size: 22),
                    const SizedBox(width: 8),
                    Text('Micify',
                      style: theme.textTheme.titleLarge?.copyWith(
                        fontWeight: FontWeight.w700,
                        color: Colors.white,
                        letterSpacing: 1.5,
                      )),
                    const SizedBox(width: 8),
                    GestureDetector(
                      onTap: () => _showAbout(context),
                      child: Icon(Icons.info_outline_rounded,
                        color: Colors.white.withOpacity(0.3), size: 18),
                    ),
                  ],
                ),

                const SizedBox(height: 32),

                // Animated mic button
                _MicButton(
                  isRunning: _isRunning,
                  level: _volumeLevel,
                  onTap: _permissionGranted
                      ? (_isRunning ? _stop : _start)
                      : _requestPermissions,
                ),

                const SizedBox(height: 12),

                // Status text
                Text(
                  _isRunning
                      ? 'Listening...'
                      : _permissionGranted ? 'Tap to start' : 'Permission required',
                  style: theme.textTheme.bodySmall?.copyWith(
                    color: _isRunning
                        ? _kAccent
                        : Colors.white.withOpacity(0.4),
                    letterSpacing: 1.0,
                  ),
                ),

                const SizedBox(height: 28),

                // Bar visualiser
                _BarVisualiser(level: _volumeLevel, isRunning: _isRunning),

                const SizedBox(height: 28),

                // Mic source selector
                Align(
                  alignment: Alignment.centerLeft,
                  child: Text('MIC SOURCE',
                    style: theme.textTheme.labelSmall?.copyWith(
                      color: Colors.white.withOpacity(0.4),
                      letterSpacing: 2.0,
                      fontSize: 10,
                    )),
                ),
                const SizedBox(height: 10),
                Row(
                  children: _MicSource.values
                      .where((s) => _availableSources.contains(s))
                      .map((s) {
                    final selected = _micSource == s;
                    return Padding(
                      padding: const EdgeInsets.only(right: 8),
                      child: GestureDetector(
                        onTap: _isRunning ? null : () => _setMicSource(s),
                        child: AnimatedContainer(
                          duration: const Duration(milliseconds: 200),
                          padding: const EdgeInsets.symmetric(horizontal: 14, vertical: 8),
                          decoration: BoxDecoration(
                            color: selected ? _kAccent : Colors.white.withOpacity(0.07),
                            borderRadius: BorderRadius.circular(20),
                            border: Border.all(
                              color: selected ? _kAccent : Colors.white.withOpacity(0.15),
                            ),
                          ),
                          child: Row(
                            mainAxisSize: MainAxisSize.min,
                            children: [
                              Icon(s.icon,
                                size: 14,
                                color: selected ? Colors.white : Colors.white.withOpacity(0.5)),
                              const SizedBox(width: 6),
                              Text(s.label,
                                style: TextStyle(
                                  fontSize: 12,
                                  color: selected ? Colors.white : Colors.white.withOpacity(0.6),
                                  fontWeight: selected ? FontWeight.w600 : FontWeight.normal,
                                )),
                            ],
                          ),
                        ),
                      ),
                    );
                  }).toList(),
                ),

                const SizedBox(height: 24),

                // Room preset — horizontal scroll
                Align(
                  alignment: Alignment.centerLeft,
                  child: Text('ROOM',
                    style: theme.textTheme.labelSmall?.copyWith(
                      color: Colors.white.withOpacity(0.4),
                      letterSpacing: 2.0,
                      fontSize: 10,
                    )),
                ),
                const SizedBox(height: 10),
                SizedBox(
                  height: 38,
                  child: ListView.separated(
                    scrollDirection: Axis.horizontal,
                    itemCount: _presets.length,
                    separatorBuilder: (_, __) => const SizedBox(width: 8),
                    itemBuilder: (context, i) {
                      final p = _presets[i];
                      final selected = (_gain == p.gain &&
                          _lowCutHz == p.lowCutHz &&
                          _eqBassDb == p.bassDb);
                      return GestureDetector(
                        onTap: () => _applyPreset(p),
                        child: AnimatedContainer(
                          duration: const Duration(milliseconds: 200),
                          padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 8),
                          decoration: BoxDecoration(
                            color: selected ? _kAccent : Colors.white.withOpacity(0.07),
                            borderRadius: BorderRadius.circular(20),
                            border: Border.all(
                              color: selected ? _kAccent : Colors.white.withOpacity(0.15),
                            ),
                          ),
                          child: Text(p.label,
                            style: TextStyle(
                              fontSize: 13,
                              color: selected ? Colors.white : Colors.white.withOpacity(0.7),
                              fontWeight: selected ? FontWeight.w600 : FontWeight.normal,
                            )),
                        ),
                      );
                    },
                  ),
                ),

                const SizedBox(height: 28),

                // Gain
                Row(
                  mainAxisAlignment: MainAxisAlignment.spaceBetween,
                  children: [
                    Text('GAIN',
                      style: theme.textTheme.labelSmall?.copyWith(
                        color: Colors.white.withOpacity(0.4),
                        letterSpacing: 2.0,
                        fontSize: 10,
                      )),
                    Text('${_gain.toStringAsFixed(1)}×',
                      style: theme.textTheme.titleMedium?.copyWith(
                        color: _kAccent,
                        fontWeight: FontWeight.bold,
                      )),
                  ],
                ),
                Slider(
                  value: _gain.clamp(1.0, _maxAllowedGain),
                  min: 1.0,
                  max: _maxAllowedGain,
                  divisions: ((_maxAllowedGain - 1.0) * 2).toInt().clamp(1, 18),
                  onChanged: (v) {
                    setState(() => _gain = v);
                    _pushSettings();
                  },
                ),
                Row(
                  mainAxisAlignment: MainAxisAlignment.spaceBetween,
                  children: [
                    Text('1×', style: TextStyle(fontSize: 11, color: Colors.white.withOpacity(0.3))),
                    Text(
                      '${_maxAllowedGain.toInt()}×${_maxAllowedGain < 10 ? '  (output limit)' : ''}',
                      style: TextStyle(fontSize: 11, color: Colors.white.withOpacity(0.3)),
                    ),
                  ],
                ),

                if (_feedbackWarning) ...[
                  const SizedBox(height: 16),
                  Container(
                    padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 10),
                    decoration: BoxDecoration(
                      color: Colors.red.withOpacity(0.15),
                      borderRadius: BorderRadius.circular(12),
                      border: Border.all(color: Colors.red.withOpacity(0.4)),
                    ),
                    child: Row(
                      children: [
                        const Icon(Icons.warning_amber_rounded, color: Colors.orange, size: 16),
                        const SizedBox(width: 8),
                        const Expanded(
                          child: Text('Feedback detected — gain reduced.',
                            style: TextStyle(color: Colors.orange, fontSize: 12)),
                        ),
                      ],
                    ),
                  ),
                ],

                const SizedBox(height: 20),

                // Advanced settings
                Theme(
                  data: Theme.of(context).copyWith(dividerColor: Colors.transparent),
                  child: ExpansionTile(
                    title: Text('Advanced',
                      style: theme.textTheme.labelMedium?.copyWith(
                        color: Colors.white.withOpacity(0.4),
                        letterSpacing: 1.0,
                      )),
                    tilePadding: EdgeInsets.zero,
                    childrenPadding: const EdgeInsets.only(top: 8),
                    children: [
                      _LabeledSlider(
                        label: 'Low-cut',
                        value: _lowCutHz,
                        min: 100,
                        max: 400,
                        divisions: 30,
                        displayValue: '${_lowCutHz.toInt()} Hz',
                        minLabel: '100 Hz',
                        maxLabel: '400 Hz',
                        onChanged: (v) {
                          setState(() => _lowCutHz = v);
                          _pushSettings();
                        },
                      ),
                      const SizedBox(height: 4),
                      _LabeledSlider(
                        label: 'Max volume',
                        value: _maxThreshold,
                        min: 0.3,
                        max: 1.0,
                        divisions: 14,
                        displayValue: '${(_maxThreshold * 100).toInt()}%',
                        minLabel: '30%',
                        maxLabel: '100%',
                        onChanged: (v) {
                          setState(() => _maxThreshold = v);
                          _pushSettings();
                        },
                      ),
                      const SizedBox(height: 12),
                      Align(
                        alignment: Alignment.centerLeft,
                        child: Text('EQUALIZER',
                          style: theme.textTheme.labelSmall?.copyWith(
                            color: Colors.white.withOpacity(0.4),
                            letterSpacing: 2.0,
                            fontSize: 10,
                          )),
                      ),
                      const SizedBox(height: 4),
                      _EqSlider(
                        label: 'Bass',
                        value: _eqBassDb,
                        onChanged: (v) {
                          setState(() => _eqBassDb = v);
                          _pushSettings();
                        },
                      ),
                      _EqSlider(
                        label: 'Mid',
                        value: _eqMidDb,
                        onChanged: (v) {
                          setState(() => _eqMidDb = v);
                          _pushSettings();
                        },
                      ),
                      _EqSlider(
                        label: 'Treble',
                        value: _eqTrebleDb,
                        onChanged: (v) {
                          setState(() => _eqTrebleDb = v);
                          _pushSettings();
                        },
                      ),
                      const SizedBox(height: 8),
                      _ToggleRow(
                        label: 'Echo cancellation',
                        value: _echoCancelEnabled,
                        onChanged: _isRunning ? null : (v) => setState(() => _echoCancelEnabled = v),
                      ),
                      _ToggleRow(
                        label: 'Noise suppression',
                        value: _noiseSuppressEnabled,
                        onChanged: _isRunning ? null : (v) => setState(() => _noiseSuppressEnabled = v),
                      ),
                      const SizedBox(height: 8),
                    ],
                  ),
                ),
              ],
            ),
          ),
        ),
    );
  }
}  // end _MicifyHomeState

// Animated mic button with pulse ring
class _MicButton extends StatefulWidget {
  const _MicButton({required this.isRunning, required this.level, required this.onTap});
  final bool isRunning;
  final double level;
  final VoidCallback onTap;

  @override
  State<_MicButton> createState() => _MicButtonState();
}

class _MicButtonState extends State<_MicButton> with SingleTickerProviderStateMixin {
  late AnimationController _pulse;

  @override
  void initState() {
    super.initState();
    _pulse = AnimationController(vsync: this, duration: const Duration(milliseconds: 1200))
      ..repeat(reverse: true);
  }

  @override
  void dispose() {
    _pulse.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    return GestureDetector(
      onTap: widget.onTap,
      child: AnimatedBuilder(
        animation: _pulse,
        builder: (context, child) {
          final ringScale = widget.isRunning
              ? 1.0 + 0.15 * _pulse.value + 0.25 * widget.level
              : 1.0;
          final ringOpacity = widget.isRunning ? 0.3 + 0.2 * _pulse.value : 0.0;
          return Stack(
            alignment: Alignment.center,
            children: [
              // Outer pulse ring
              Transform.scale(
                scale: ringScale,
                child: Container(
                  width: 110,
                  height: 110,
                  decoration: BoxDecoration(
                    shape: BoxShape.circle,
                    color: _kAccent.withOpacity(ringOpacity),
                  ),
                ),
              ),
              // Inner glow ring
              Container(
                width: 88,
                height: 88,
                decoration: BoxDecoration(
                  shape: BoxShape.circle,
                  color: widget.isRunning ? _kAccent : const Color(0xFF1E1E2E),
                  boxShadow: widget.isRunning
                      ? [BoxShadow(color: _kAccent.withOpacity(0.5), blurRadius: 24, spreadRadius: 4)]
                      : [],
                  border: Border.all(
                    color: widget.isRunning ? _kAccent : Colors.white.withOpacity(0.15),
                    width: 2,
                  ),
                ),
                child: Icon(
                  widget.isRunning ? Icons.stop_rounded : Icons.mic_rounded,
                  color: Colors.white,
                  size: 36,
                ),
              ),
            ],
          );
        },
      ),
    );
  }
}

// Bar visualiser — 20 bars driven by volume level
class _BarVisualiser extends StatefulWidget {
  const _BarVisualiser({
    required this.level,
    required this.isRunning,
    this.accentColor = _kAccent,
  });
  final double level;
  final bool isRunning;
  final Color accentColor;

  @override
  State<_BarVisualiser> createState() => _BarVisualiserState();
}

class _BarVisualiserState extends State<_BarVisualiser> with SingleTickerProviderStateMixin {
  late AnimationController _idle;
  final _rng = math.Random();
  final List<double> _bars = List.filled(20, 0.05);

  @override
  void initState() {
    super.initState();
    _idle = AnimationController(vsync: this, duration: const Duration(milliseconds: 80))
      ..addListener(_updateBars)
      ..repeat();
  }

  void _updateBars() {
    if (!mounted) return;
    setState(() {
      for (var i = 0; i < _bars.length; i++) {
        if (widget.isRunning) {
          final noise = (_rng.nextDouble() - 0.5) * 0.3;
          final target = (widget.level + noise).clamp(0.05, 1.0);
          _bars[i] = (_bars[i] * 0.6 + target * 0.4);
        } else {
          _bars[i] = (_bars[i] * 0.85).clamp(0.03, 1.0);
        }
      }
    });
  }

  @override
  void dispose() {
    _idle.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    return SizedBox(
      height: 48,
      child: Row(
        mainAxisAlignment: MainAxisAlignment.center,
        crossAxisAlignment: CrossAxisAlignment.end,
        children: List.generate(_bars.length, (i) {
          final h = 8 + _bars[i] * 40;
          final color = Color.lerp(widget.accentColor, Colors.pinkAccent, _bars[i])!
              .withOpacity(0.85);
          return Padding(
            padding: const EdgeInsets.symmetric(horizontal: 2),
            child: AnimatedContainer(
              duration: const Duration(milliseconds: 60),
              width: 6,
              height: h,
              decoration: BoxDecoration(
                color: color,
                borderRadius: BorderRadius.circular(3),
              ),
            ),
          );
        }),
      ),
    );
  }
}

// Gain display

// Reusable labeled slider
class _LabeledSlider extends StatelessWidget {
  const _LabeledSlider({
    required this.label,
    required this.value,
    required this.min,
    required this.max,
    required this.divisions,
    required this.displayValue,
    required this.minLabel,
    required this.maxLabel,
    required this.onChanged,
  });

  final String label;
  final double value;
  final double min;
  final double max;
  final int divisions;
  final String displayValue;
  final String minLabel;
  final String maxLabel;
  final ValueChanged<double> onChanged;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    return Column(
      children: [
        Row(
          mainAxisAlignment: MainAxisAlignment.spaceBetween,
          children: [
            Text(label, style: theme.textTheme.labelMedium),
            Text(displayValue, style: theme.textTheme.labelMedium?.copyWith(
              color: theme.colorScheme.primary)),
          ],
        ),
        Slider(value: value, min: min, max: max, divisions: divisions,
          label: displayValue, onChanged: onChanged),
        Row(
          mainAxisAlignment: MainAxisAlignment.spaceBetween,
          children: [
            Text(minLabel, style: const TextStyle(fontSize: 11, color: Colors.grey)),
            Text(maxLabel, style: const TextStyle(fontSize: 11, color: Colors.grey)),
          ],
        ),
      ],
    );
  }
}

// EQ band slider — centre-notch at 0dB, range ±12dB
class _EqSlider extends StatelessWidget {
  const _EqSlider({
    required this.label,
    required this.value,
    required this.onChanged,
  });

  final String label;
  final double value;
  final ValueChanged<double> onChanged;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final sign = value > 0 ? '+' : '';
    final dbText = '$sign${value.toStringAsFixed(1)} dB';
    final color = value == 0
        ? theme.colorScheme.onSurface.withOpacity(0.4)
        : theme.colorScheme.primary;
    return Row(
      children: [
        SizedBox(
          width: 52,
          child: Text(label, style: theme.textTheme.labelMedium),
        ),
        Expanded(
          child: Slider(
            value: value,
            min: -12,
            max: 12,
            divisions: 24,
            onChanged: onChanged,
          ),
        ),
        SizedBox(
          width: 60,
          child: Text(dbText,
            textAlign: TextAlign.right,
            style: theme.textTheme.labelSmall?.copyWith(color: color)),
        ),
      ],
    );
  }
}

// Kids mode volume pill — Soft / Normal / Loud
class _KidsVolumePill extends StatelessWidget {
  const _KidsVolumePill({
    required this.label,
    required this.gain,
    required this.kidsGain,
    required this.onTap,
  });

  final String label;
  final double gain;
  final double kidsGain;
  final ValueChanged<double> onTap;

  @override
  Widget build(BuildContext context) {
    final selected = kidsGain == gain;
    return GestureDetector(
      onTap: () => onTap(gain),
      child: AnimatedContainer(
        duration: const Duration(milliseconds: 200),
        padding: const EdgeInsets.symmetric(horizontal: 24, vertical: 10),
        decoration: BoxDecoration(
          color: selected ? _kAccent : Colors.white.withOpacity(0.07),
          borderRadius: BorderRadius.circular(24),
          border: Border.all(
            color: selected ? _kAccent : Colors.white.withOpacity(0.15),
          ),
          boxShadow: selected
              ? [BoxShadow(color: _kAccent.withOpacity(0.35), blurRadius: 12)]
              : [],
        ),
        child: Text(label,
          style: TextStyle(
            fontSize: 14,
            fontWeight: selected ? FontWeight.w700 : FontWeight.w400,
            color: selected ? Colors.white : Colors.white.withOpacity(0.6),
          )),
      ),
    );
  }
}

// About screen helpers
class _AboutDivider extends StatelessWidget {
  @override
  Widget build(BuildContext context) => Container(
    height: 1,
    color: Colors.white.withOpacity(0.08),
  );
}

class _AboutRow extends StatelessWidget {
  const _AboutRow({required this.icon, required this.label, required this.value});
  final IconData icon;
  final String label;
  final String value;

  @override
  Widget build(BuildContext context) {
    return Row(
      children: [
        Icon(icon, size: 16, color: _kAccent.withOpacity(0.7)),
        const SizedBox(width: 10),
        Text('$label  ',
          style: TextStyle(color: Colors.white.withOpacity(0.4), fontSize: 12)),
        Text(value,
          style: const TextStyle(color: Colors.white, fontSize: 12,
            fontWeight: FontWeight.w500)),
      ],
    );
  }
}

// Toggle row
class _ToggleRow extends StatelessWidget {
  const _ToggleRow({
    required this.label,
    required this.value,
    required this.onChanged,
  });

  final String label;
  final bool value;
  final ValueChanged<bool>? onChanged;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    return Row(
      mainAxisAlignment: MainAxisAlignment.spaceBetween,
      children: [
        Text(label, style: theme.textTheme.bodyMedium),
        Switch(
          value: value,
          onChanged: onChanged,
          activeColor: theme.colorScheme.primary,
        ),
      ],
    );
  }
}

// Bouncing animation for selected Kids effect icon
class _BounceWidget extends StatefulWidget {
  const _BounceWidget({super.key, required this.child});
  final Widget child;

  @override
  State<_BounceWidget> createState() => _BounceWidgetState();
}

class _BounceWidgetState extends State<_BounceWidget>
    with SingleTickerProviderStateMixin {
  late AnimationController _ctrl;
  late Animation<double> _anim;

  @override
  void initState() {
    super.initState();
    _ctrl = AnimationController(
      vsync: this,
      duration: const Duration(milliseconds: 600),
    )..repeat(reverse: true);
    _anim = Tween<double>(begin: 0, end: -6).animate(
      CurvedAnimation(parent: _ctrl, curve: Curves.easeInOut),
    );
  }

  @override
  void dispose() {
    _ctrl.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    return AnimatedBuilder(
      animation: _anim,
      builder: (_, child) => Transform.translate(
        offset: Offset(0, _anim.value),
        child: child,
      ),
      child: widget.child,
    );
  }
}
