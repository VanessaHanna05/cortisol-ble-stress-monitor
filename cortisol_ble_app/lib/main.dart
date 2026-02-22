// lib/main.dart
import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'dart:math';

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_blue_plus/flutter_blue_plus.dart';
import 'package:cortisol_ble_app/ml/stress_engine.dart';
import 'package:path_provider/path_provider.dart';

void main() {
  WidgetsFlutterBinding.ensureInitialized();
  runApp(const CortisolBleApp());
}

class CortisolBleApp extends StatelessWidget {
  const CortisolBleApp({super.key});

  @override
  Widget build(BuildContext context) {
    return MaterialApp(
      title: "Cortisol BLE",
      debugShowCheckedModeBanner: false,
      theme: ThemeData(
        useMaterial3: true,
        colorSchemeSeed: const Color(0xFF3B82F6),
        brightness: Brightness.dark,

        // FIX 1: CardThemeData not CardTheme
        cardTheme: CardThemeData(
          elevation: 0,
          shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(16)),
        ),
      ),
      home: const BleHome(),
    );
  }
}

class BleHome extends StatefulWidget {
  const BleHome({super.key});

  @override
  State<BleHome> createState() => _BleHomeState();
}

enum SessionLabel { unlabeled, rest, stressTask, recovery }

extension SessionLabelX on SessionLabel {
  String get value {
    switch (this) {
      case SessionLabel.unlabeled:
        return "unlabeled";
      case SessionLabel.rest:
        return "rest";
      case SessionLabel.stressTask:
        return "stress_task";
      case SessionLabel.recovery:
        return "recovery";
    }
  }

  String get title {
    switch (this) {
      case SessionLabel.unlabeled:
        return "Unlabeled";
      case SessionLabel.rest:
        return "Rest";
      case SessionLabel.stressTask:
        return "Stress Task";
      case SessionLabel.recovery:
        return "Recovery";
    }
  }
}

class _BleHomeState extends State<BleHome> {
  final Guid knownCharUuid = Guid("abcd1234-5678-1234-5678-abcdef123456");
  final Guid? knownServiceUuid = null;
  static const String _serviceChangedUuid = "00002a0500001000800000805f9b34fb";

  final Map<String, ScanResult> _scanByDeviceId = {};
  StreamSubscription<List<ScanResult>>? _scanSub;

  BluetoothDevice? _device;
  StreamSubscription<BluetoothConnectionState>? _connSub;

  BluetoothCharacteristic? _notifyChar;
  StreamSubscription<List<int>>? _notifySub;
  StreamSubscription<List<int>>? _notifySubAlt;

  bool _scanning = false;
  bool _connecting = false;
  bool _reconnecting = false;
  bool _isConnected = false;
  int _tabIndex = 0;
  bool _mlModelLoaded = false;
  bool _resubscribing = false;
  DateTime? _lastNotifyAt;
  DateTime? _lastAutoReconnectAt;
  Timer? _notifyWatchdog;
  Timer? _autoReconnectTimer;

  String _status = "Idle";
  String _parseStatus = "Waiting";
  String _raw = "";
  String _deviceNameFilter = "ESP32_HealthMonitor";
  String? _lastError;
  late final TextEditingController _filterController;

  final _assembler = JsonChunkAssembler();

  MetricGroup? _bpm;
  MetricGroup? _gsr;
  double? _temp;
  int? _ts;
  StressInferenceResult? _stressResult;
  String? _stressInputIssue;
  final StressEngine _stressEngine = StressEngine();

  final List<double> _bpmHistory = [];
  final List<double> _gsrHistory = [];
  final List<double> _stressHistory = [];
  final List<HistoryEntry> _history = [];
  ScanResult? _lastConnectedScan;
  Map<String, dynamic> _modelInfo = const {};
  Map<String, dynamic> _modelMetrics = const {};
  SessionLabel _sessionLabel = SessionLabel.unlabeled;
  File? _historyCsvFile;
  String? _historyCsvPath;
  int _loggedRows = 0;

  @override
  void initState() {
    super.initState();
    _filterController = TextEditingController(text: _deviceNameFilter);
    _loadMlModel();
    _loadModelMetadata();
    _initHistoryLogging();
    _notifyWatchdog = Timer.periodic(const Duration(seconds: 3), (_) => _watchNotifyHealth());
    _autoReconnectTimer = Timer.periodic(const Duration(seconds: 10), (_) async {
      if (!mounted || !_connected || _connecting || _reconnecting || _resubscribing) return;
      await _silentReconnect();
    });
  }

  Future<void> _initHistoryLogging() async {
    try {
      final dir = await getApplicationDocumentsDirectory();
      final stamp = DateTime.now().toIso8601String().replaceAll(":", "-");
      final file = File("${dir.path}/stress_history_$stamp.csv");
      await file.writeAsString(
        "time_iso,ts,bpm_avg,gsr_avg,temp_avg,stress_prob,cortisol_proxy,stress_level,label,ml_loaded\n",
        mode: FileMode.write,
      );
      if (!mounted) return;
      setState(() {
        _historyCsvFile = file;
        _historyCsvPath = file.path;
        _loggedRows = 0;
      });
    } catch (e) {
      _setError("History logger init failed: $e");
    }
  }

  Future<void> _loadMlModel() async {
    try {
      final raw = await rootBundle.loadString('assets/models/model_flutter.json');
      final jsonMap = json.decode(raw) as Map<String, dynamic>;
      _stressEngine.loadFlutterModel(jsonMap);
      if (!mounted) return;
      setState(() => _mlModelLoaded = true);
    } catch (e) {
      _setError('ML model load failed, using fallback engine: $e');
      if (!mounted) return;
      setState(() => _mlModelLoaded = false);
    }
  }

  Future<void> _loadModelMetadata() async {
    try {
      final infoRaw = await rootBundle.loadString('assets/models/model_info.json');
      final metricsRaw = await rootBundle.loadString('assets/models/metrics.json');
      if (!mounted) return;
      setState(() {
        _modelInfo = json.decode(infoRaw) as Map<String, dynamic>;
        _modelMetrics = json.decode(metricsRaw) as Map<String, dynamic>;
      });
    } catch (_) {
      // keep UI running even if metadata asset is missing
    }
  }

  @override
  void dispose() {
    _scanSub?.cancel();
    _connSub?.cancel();
    _notifySub?.cancel();
    _notifySubAlt?.cancel();
    _notifyWatchdog?.cancel();
    _autoReconnectTimer?.cancel();
    _device?.disconnect();
    _filterController.dispose();
    super.dispose();
  }

  Future<void> _watchNotifyHealth() async {
    if (!mounted || !_connected || _notifyChar == null || _connecting || _reconnecting || _resubscribing) {
      return;
    }
    final last = _lastNotifyAt;
    if (last == null) return;
    final now = DateTime.now();
    final stalled = now.difference(last).inSeconds >= 8;
    if (!stalled) return;
    await _resubscribeNotify();

    // If data is still stale after resubscribe, mimic manual reconnect button.
    final currentLast = _lastNotifyAt;
    final stillStale = currentLast == null || now.difference(currentLast).inSeconds >= 8;
    if (!stillStale) return;
    final canReconnect = _lastAutoReconnectAt == null || now.difference(_lastAutoReconnectAt!).inSeconds >= 15;
    if (!canReconnect) return;
    _lastAutoReconnectAt = now;
    if (mounted) {
      setState(() => _parseStatus = "Auto reconnecting");
    }
    await _silentReconnect();
  }

  Future<void> _resubscribeNotify() async {
    final char = _notifyChar;
    if (char == null || _resubscribing) return;
    _resubscribing = true;
    try {
      await _notifySub?.cancel();
      await _notifySubAlt?.cancel();
      _notifySub = null;
      _notifySubAlt = null;
      try {
        await char.setNotifyValue(false);
      } catch (_) {}
      await Future.delayed(const Duration(milliseconds: 150));
      final ok = await _enableNotifyWithRetry(char);
      if (!ok) return;
      _attachNotifyStreams(char);
      _lastNotifyAt = DateTime.now();
      if (mounted) {
        setState(() {
          _parseStatus = "Resubscribed";
        });
      }
    } finally {
      _resubscribing = false;
    }
  }

  void _attachNotifyStreams(BluetoothCharacteristic target) {
    _notifySub = target.onValueReceived.listen((bytes) {
      if (!mounted || bytes.isEmpty) return;
      _onIncomingBytes(bytes);
    }, onError: (e) {
      _setError("Notify stream error: $e");
    });
    _notifySubAlt = target.lastValueStream.listen((bytes) {
      if (!mounted || bytes.isEmpty) return;
      _onIncomingBytes(bytes);
    }, onError: (e) {
      _setError("Notify stream(lastValue) error: $e");
    });
  }

  String _normGuid(Guid g) => _normGuidText(g.str);
  String _normGuidText(String value) {
    final s = value.toLowerCase().replaceAll("-", "");
    if (s.length == 4) return "0000${s}00001000800000805f9b34fb";
    if (s.length == 8) return "${s}00001000800000805f9b34fb";
    return s;
  }
  bool _isServiceChangedChar(BluetoothCharacteristic c) => _normGuid(c.uuid) == _serviceChangedUuid;
  bool get _connected => _isConnected;

  bool _matchesFilter(ScanResult r) {
    final f = _deviceNameFilter.trim().toLowerCase();
    if (f.isEmpty) return true;
    final name = r.device.platformName.toLowerCase();
    final advName = r.advertisementData.advName.toLowerCase();
    return name.contains(f) || advName.contains(f);
  }

  void _applyFilterToExistingResults() {
    final toRemove = <String>[];
    _scanByDeviceId.forEach((id, result) {
      if (!_matchesFilter(result)) {
        toRemove.add(id);
      }
    });
    for (final id in toRemove) {
      _scanByDeviceId.remove(id);
    }
  }

  void _setError(String message) {
    if (!mounted) return;
    setState(() => _lastError = message);
  }

  Future<void> _showToast(String message) async {
    if (!mounted) return;
    ScaffoldMessenger.of(context).showSnackBar(SnackBar(content: Text(message)));
  }

  Future<void> _appendHistoryLog(HistoryEntry entry) async {
    final f = _historyCsvFile;
    if (f == null) return;
    final row = "${[
      entry.when.toIso8601String(),
      "${entry.ts ?? ""}",
      _csvNum(entry.bpmAvg),
      _csvNum(entry.gsrAvg),
      _csvNum(entry.tempAvg),
      entry.stressProb.toStringAsFixed(6),
      entry.cortisolProxy.toStringAsFixed(3),
      entry.stressLevel,
      entry.label,
      _mlModelLoaded ? "1" : "0",
    ].join(",")}\n";
    try {
      await f.writeAsString(row, mode: FileMode.append);
      if (mounted) {
        setState(() => _loggedRows += 1);
      }
    } catch (e) {
      _setError("History log write failed: $e");
    }
  }

  String _csvNum(double? v) => v == null ? "" : v.toStringAsFixed(4);

  Future<void> _copyHistoryCsvToClipboard() async {
    final f = _historyCsvFile;
    if (f == null) {
      await _showToast("History file not ready");
      return;
    }
    try {
      final content = await f.readAsString();
      await Clipboard.setData(ClipboardData(text: content));
      await _showToast("History CSV copied to clipboard");
    } catch (e) {
      _setError("CSV export failed: $e");
    }
  }

  Future<void> _startScan() async {
    if (_scanning) return;

    setState(() {
      _scanByDeviceId.clear();
      _scanning = true;
      _status = "Scanning";
    });

    try {
      await FlutterBluePlus.stopScan();
    } catch (_) {}

    _scanSub?.cancel();
    _scanSub = FlutterBluePlus.scanResults.listen((results) {
      bool changed = false;
      for (final r in results) {
        if (!_matchesFilter(r)) continue;
        final id = r.device.remoteId.str;
        final prev = _scanByDeviceId[id];
        if (prev == null || r.rssi > prev.rssi) {
          _scanByDeviceId[id] = r;
          changed = true;
        }
      }
      if (changed) setState(() {});
    });
    try {
      await FlutterBluePlus.startScan(
        timeout: const Duration(seconds: 8),
        androidScanMode: AndroidScanMode.lowLatency,
      );
    } catch (e) {
      _setError("Scan failed: $e");
    }

    setState(() {
      _scanning = false;
      _status = "Scan complete";
    });
  }

  Future<void> _stopScan() async {
    try {
      await FlutterBluePlus.stopScan();
    } catch (_) {}
    await _scanSub?.cancel();
    _scanSub = null;
    setState(() {
      _scanning = false;
      _status = "Scan stopped";
    });
  }

  Future<void> _disconnect() async {
    final d = _device;
    if (d == null) return;

    await _notifySub?.cancel();
    await _notifySubAlt?.cancel();
    _notifySub = null;
    _notifySubAlt = null;

    try {
      if (_notifyChar != null) {
        try {
          await _notifyChar!.setNotifyValue(false);
        } catch (_) {}
      }
    } catch (_) {}

    _notifyChar = null;
    _lastNotifyAt = null;

    try {
      await d.disconnect();
    } catch (_) {}

    setState(() {
      _device = null;
      _connecting = false;
      _reconnecting = false;
      _isConnected = false;
      _status = "Disconnected";
    });
  }

  Future<void> _reconnect() async {
    if (_reconnecting || _connecting) return;
    final target = _lastConnectedScan;
    if (target == null) {
      _setError("No previous device to reconnect.");
      return;
    }
    setState(() => _reconnecting = true);
    await _connectTo(target, resetData: false);
    if (mounted) {
      setState(() => _reconnecting = false);
    }
  }

  Future<void> _silentReconnect() async {
    if (_connecting || _reconnecting || _resubscribing) return;
    final target = _lastConnectedScan;
    if (target == null) return;
    await _connectTo(target, resetData: false, silentReconnect: true);
  }

  Future<void> _connectTo(ScanResult r, {bool resetData = true, bool silentReconnect = false}) async {
    if (_connecting) return;

    await _stopScan();

    setState(() {
      _connecting = true;
      _isConnected = false;
      if (!silentReconnect) _status = "Connecting";
      _lastError = null;
      if (resetData) {
        _raw = "";
        _parseStatus = "Waiting";
        _bpm = null;
        _gsr = null;
        _temp = null;
        _ts = null;
        _stressResult = null;
        _bpmHistory.clear();
        _gsrHistory.clear();
        _stressHistory.clear();
        _assembler.reset();
        _stressEngine.reset();
      }
    });

    final d = r.device;
    _lastConnectedScan = r;
    _lastNotifyAt = null;

    await _notifySub?.cancel();
    await _notifySubAlt?.cancel();
    _notifySub = null;
    _notifySubAlt = null;
    _notifyChar = null;
    await _connSub?.cancel();
    _connSub = null;

    _device = d;

    _connSub = d.connectionState.listen((s) {
      if (!mounted) return;
      setState(() {
        if (!silentReconnect) {
          _status = "Connection: ${s.name}";
        }
        _isConnected = s == BluetoothConnectionState.connected;
      });
      if (s == BluetoothConnectionState.disconnected) {
        _notifySub?.cancel();
        _notifySubAlt?.cancel();
        _notifySub = null;
        _notifySubAlt = null;
        _notifyChar = null;
      }
    });

    try {
      await d.connect(
        timeout: const Duration(seconds: 12),
        autoConnect: false,
        license: License.free,
      );
    } catch (e) {
      final msg = e.toString();
      if (!msg.contains("already connected")) {
        _setError("Connect failed: $e");
      }
    }

    await Future.delayed(const Duration(milliseconds: 400));

    try {
      await d.requestMtu(185);
    } catch (_) {}

    List<BluetoothService> services = await _discoverServicesWithRetry(d);
    if (services.isEmpty) {
      setState(() {
        _connecting = false;
        _status = "Discover services failed";
      });
      _setError("No services discovered.");
      return;
    }

    BluetoothCharacteristic? target;

    for (final s in services) {
      final serviceOk = knownServiceUuid == null || _normGuid(s.uuid) == _normGuid(knownServiceUuid!);
      if (!serviceOk) continue;

      for (final c in s.characteristics) {
        if (_isServiceChangedChar(c)) continue;
        if (_normGuid(c.uuid) == _normGuid(knownCharUuid)) {
          target = c;
          break;
        }
      }
      if (target != null) break;
    }

    target ??= _pickBestNotifiable(services);

    if (target == null) {
      setState(() {
        _connecting = false;
        _status = "No notifiable characteristic found";
      });
      return;
    }

    _notifyChar = target;

    final notifyOk = await _enableNotifyWithRetry(target);
    if (!notifyOk) {
      setState(() {
        _connecting = false;
        _status = "Enable notify failed";
      });
      _setError("Could not enable notifications.");
      return;
    }

    await _notifySub?.cancel();
    await _notifySubAlt?.cancel();
    _attachNotifyStreams(target);
    _lastNotifyAt = DateTime.now();

    // Optional initial read
    try {
      final v = await target.read();
      if (v.isNotEmpty) {
        _onIncomingBytes(v);
      }
    } catch (_) {
      // some devices do not support reads on a notify-only characteristic
    }

    setState(() {
      _connecting = false;
      _isConnected = true;
      if (!silentReconnect) _status = "Connected";
      _parseStatus = "Listening";
    });
  }

  Future<List<BluetoothService>> _discoverServicesWithRetry(BluetoothDevice d) async {
    for (int attempt = 0; attempt < 2; attempt++) {
      try {
        final services = await d.discoverServices();
        if (services.isNotEmpty) return services;
      } catch (_) {
        // retry once
      }
      await Future.delayed(const Duration(milliseconds: 300));
    }
    return const [];
  }

  Future<bool> _enableNotifyWithRetry(BluetoothCharacteristic c) async {
    for (int attempt = 0; attempt < 2; attempt++) {
      try {
        await c.setNotifyValue(true);
        return true;
      } catch (_) {
        await Future.delayed(const Duration(milliseconds: 250));
      }
    }
    return false;
  }

  void _onIncomingBytes(List<int> bytes) {
    final chunk = utf8.decode(bytes, allowMalformed: true);
    if (chunk.isEmpty) return;
    _lastNotifyAt = DateTime.now();

    setState(() {
      _raw += chunk;
      if (_raw.length > 6000) {
        _raw = _raw.substring(_raw.length - 6000);
      }
    });

    final objects = _assembler.push(chunk);
    if (objects.isEmpty) {
      setState(() {
        _parseStatus = _assembler.pendingBytes > 0
            ? "Buffering (${_assembler.pendingBytes} chars)"
            : "Listening";
      });
      return;
    }

    for (final obj in objects) {
      _processJson(obj);
    }
  }

  BluetoothCharacteristic? _pickBestNotifiable(List<BluetoothService> services) {
    BluetoothCharacteristic? best;
    int bestScore = -99999;
    for (final s in services) {
      for (final c in s.characteristics) {
        final canNotify = c.properties.notify || c.properties.indicate;
        if (!canNotify) continue;
        if (_isServiceChangedChar(c)) continue;

        int score = 0;
        if (c.properties.notify) score += 20;
        if (c.properties.indicate) score += 10;
        if (knownServiceUuid != null && _normGuid(s.uuid) == _normGuid(knownServiceUuid!)) {
          score += 5;
        }
        if (score > bestScore) {
          best = c;
          bestScore = score;
        }
      }
    }
    return best;
  }

  void _processJson(Map<String, dynamic> obj) {
    int? ts;
    final tsRaw = obj["ts"] ?? obj["TS"];
    if (tsRaw is num) ts = tsRaw.toInt();
    if (tsRaw is String) ts = int.tryParse(tsRaw);

    MetricGroup? bpm;
    MetricGroup? gsr;
    MetricGroup? tempGroup;
    double? temp;

    final bpmObj = obj["BPM"] ?? obj["bpm"];
    if (bpmObj is Map<String, dynamic>) {
      bpm = MetricGroup.fromMap(bpmObj);
    } else if (bpmObj is Map) {
      bpm = MetricGroup.fromMap(bpmObj.cast<String, dynamic>());
    }

    final gsrObj = obj["GSR"] ?? obj["gsr"];
    if (gsrObj is Map<String, dynamic>) {
      gsr = MetricGroup.fromMap(gsrObj);
    } else if (gsrObj is Map) {
      gsr = MetricGroup.fromMap(gsrObj.cast<String, dynamic>());
    }

    final tempObj = obj["Temp"] ?? obj["TEMP"] ?? obj["temp"] ?? obj["skinTemp"] ?? obj["temperature"];
    if (tempObj is Map<String, dynamic>) {
      tempGroup = MetricGroup.fromMap(tempObj);
      temp = tempGroup.avg;
    } else if (tempObj is Map) {
      tempGroup = MetricGroup.fromMap(tempObj.cast<String, dynamic>());
      temp = tempGroup.avg;
    } else if (tempObj is num) {
      temp = tempObj.toDouble();
    } else if (tempObj is String) {
      temp = double.tryParse(tempObj);
    }

    // Device sometimes streams temperature in deci- or centi-degrees.
    if (temp != null && temp > 80) {
      temp = temp / 10.0;
      if (temp > 80) {
        temp = temp / 10.0;
      }
    }

    if (ts == null && bpm == null && gsr == null && temp == null) {
      setState(() => _parseStatus = "Parsed but no fields");
      return;
    }

    final bpmNow = bpm ?? _bpm;
    final gsrNow = gsr ?? _gsr;
    final tempAvgNow = temp ?? _temp;
    final tsVal = ts ?? _ts;
    final bpmValid = _isValidSignal(bpmNow?.avg);
    final gsrValid = _isValidSignal(gsrNow?.avg);
    final tempValid = _isValidSignal(tempAvgNow);

    String? stressIssue;
    if (!bpmValid) {
      stressIssue = "Stress requires valid heart rate";
    } else if (!gsrValid) {
      stressIssue = "Stress requires valid GSR";
    } else if (!tempValid) {
      stressIssue = "Stress requires valid temperature";
    }

    StressInferenceResult? inference;
    if (stressIssue == null) {
      inference = _stressEngine.addSample(
        ts: tsVal,
        bpmAvg: bpmNow?.avg,
        bpmMin: bpmNow?.min,
        bpmMax: bpmNow?.max,
        bpmStd: bpmNow?.std,
        gsrAvg: gsrNow?.avg,
        gsrMin: gsrNow?.min,
        gsrMax: gsrNow?.max,
        gsrStd: gsrNow?.std,
        tempAvg: tempAvgNow,
        tempMin: tempGroup?.min ?? tempAvgNow,
        tempMax: tempGroup?.max ?? tempAvgNow,
        tempStd: tempGroup?.std ?? 0.0,
      );
    }

    HistoryEntry? createdEntry;

    setState(() {
      _ts = ts ?? _ts;
      _bpm = bpm ?? _bpm;
      _gsr = gsr ?? _gsr;
      _temp = temp ?? _temp;
      _stressInputIssue = stressIssue;
      if (inference != null) {
        _stressResult = inference;
        _stressHistory.add(inference.stressProbability);
        if (_stressHistory.length > 60) _stressHistory.removeAt(0);
        createdEntry = HistoryEntry(
          when: DateTime.now(),
          ts: _ts ?? tsVal,
          bpmAvg: (_bpm ?? bpmNow)?.avg,
          gsrAvg: (_gsr ?? gsrNow)?.avg,
          tempAvg: _temp ?? tempAvgNow,
          stressProb: inference.stressProbability,
          cortisolProxy: inference.cortisolProxy,
          stressLevel: inference.levelText,
          label: _sessionLabel.value,
        );
        _history.add(createdEntry!);
        if (_history.length > 300) _history.removeAt(0);
      } else if (stressIssue != null) {
        _stressResult = null;
      }

      if (bpm?.avg != null) {
        _bpmHistory.add(bpm!.avg!);
        if (_bpmHistory.length > 30) _bpmHistory.removeAt(0);
      }
      if (gsr?.avg != null) {
        _gsrHistory.add(gsr!.avg!);
        if (_gsrHistory.length > 30) _gsrHistory.removeAt(0);
      }

      _parseStatus = "OK";
    });

    if (createdEntry != null) {
      unawaited(_appendHistoryLog(createdEntry!));
    }
  }

  List<ScanResult> get _scanResultsSorted {
    final list = _scanByDeviceId.values.toList();
    list.sort((a, b) => b.rssi.compareTo(a.rssi));
    return list;
  }

  void _clearLiveData() {
    setState(() {
      _raw = "";
      _assembler.reset();
      _bpm = null;
      _gsr = null;
      _temp = null;
      _ts = null;
      _stressResult = null;
      _stressInputIssue = null;
      _bpmHistory.clear();
      _gsrHistory.clear();
      _stressHistory.clear();
      _history.clear();
      _stressEngine.reset();
      _parseStatus = "Cleared";
    });
    unawaited(_initHistoryLogging());
  }

  bool _isValidSignal(double? v) {
    if (v == null) return false;
    if (!v.isFinite) return false;
    return v > 0;
  }

  void _openHistoryPage() {
    Navigator.of(context).push(
      MaterialPageRoute(
        builder: (_) => _HistoryPage(
          entries: _history,
          csvPath: _historyCsvPath,
          loggedRows: _loggedRows,
          onCopyCsv: _copyHistoryCsvToClipboard,
        ),
      ),
    );
  }

  Widget _buildConnectionTab(String? connectedName) {
    return RefreshIndicator(
      onRefresh: _startScan,
      child: ListView(
        padding: const EdgeInsets.all(16),
        children: [
          if (_lastError != null) ...[
            MaterialBanner(
              content: Text(_lastError!),
              leading: const Icon(Icons.error_outline),
              actions: [
                TextButton(
                  onPressed: () => setState(() => _lastError = null),
                  child: const Text("Dismiss"),
                ),
              ],
            ),
            const SizedBox(height: 12),
          ],
          _TopActions(
            scanning: _scanning,
            connecting: _connecting,
            connected: _connected,
            connectedName: connectedName,
            parseStatus: _parseStatus,
            mlModelLoaded: _mlModelLoaded,
            filterController: _filterController,
            onFilterChanged: (value) {
              setState(() {
                _deviceNameFilter = value;
                _applyFilterToExistingResults();
              });
            },
            onScan: _startScan,
            onStopScan: _stopScan,
            onDisconnect: _disconnect,
            onReconnect: _reconnect,
          ),
          const SizedBox(height: 12),
          _CardSection(
            title: "Nearby devices",
            subtitle: "Tap a device to connect. Pull down to rescan.",
            child: _scanResultsSorted.isEmpty
                ? _EmptyState(
                    text: _scanning ? "Scanning..." : "No devices yet. Tap Scan.",
                  )
                : Column(
                    children: _scanResultsSorted.map((r) {
                      final name = r.device.platformName.isNotEmpty ? r.device.platformName : "(no name)";
                      final id = r.device.remoteId.str;
                      return _DeviceTile(
                        name: name,
                        id: id,
                        rssi: r.rssi,
                        onTap: () => _connectTo(r),
                      );
                    }).toList(),
                  ),
          ),
          const SizedBox(height: 24),
        ],
      ),
    );
  }

  Widget _buildDashboardTab() {
    return ListView(
      padding: const EdgeInsets.all(16),
      children: [
        _MetricsGrid(
          ts: _ts,
          bpm: _bpm,
          gsr: _gsr,
          temp: _temp,
          stressResult: _stressResult,
          stressInputIssue: _stressInputIssue,
          mlModelLoaded: _mlModelLoaded,
          calibrationWindows: _stressEngine.baselineCollected,
          calibrationTarget: _stressEngine.baselineTarget,
          windowSamples: _stressEngine.currentWindowSamples,
          windowTarget: _stressEngine.windowTarget,
          calibrationReady: _stressEngine.calibrationReady,
          bpmHistory: _bpmHistory,
          gsrHistory: _gsrHistory,
          stressHistory: _stressHistory,
        ),
        const SizedBox(height: 12),
        _CardSection(
          title: "History summary",
          subtitle: "Recent rolling windows from live session.",
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Text("Session label", style: TextStyle(color: Colors.white.withValues(alpha: 0.8))),
              const SizedBox(height: 8),
              SegmentedButton<SessionLabel>(
                segments: const [
                  ButtonSegment(value: SessionLabel.unlabeled, label: Text("Unlabeled")),
                  ButtonSegment(value: SessionLabel.rest, label: Text("Rest")),
                  ButtonSegment(value: SessionLabel.stressTask, label: Text("Stress")),
                  ButtonSegment(value: SessionLabel.recovery, label: Text("Recovery")),
                ],
                selected: {_sessionLabel},
                onSelectionChanged: (set) {
                  if (set.isEmpty) return;
                  setState(() => _sessionLabel = set.first);
                },
              ),
              const SizedBox(height: 10),
              Wrap(
                spacing: 8,
                runSpacing: 8,
                children: [
                  _MiniPill(text: "Label ${_sessionLabel.title}"),
                  _MiniPill(text: "CSV rows $_loggedRows"),
                  _MiniPill(text: "BPM samples ${_bpmHistory.length}"),
                  _MiniPill(text: "GSR samples ${_gsrHistory.length}"),
                  _MiniPill(text: "Stress samples ${_stressHistory.length}"),
                  _MiniPill(text: _stressHistory.isEmpty ? "Stress avg N/A" : "Stress avg ${(100 * (_stressHistory.reduce((a, b) => a + b) / _stressHistory.length)).toStringAsFixed(1)}%"),
                ],
              ),
              const SizedBox(height: 10),
              FilledButton.icon(
                onPressed: _openHistoryPage,
                icon: const Icon(Icons.table_chart),
                label: const Text("View history"),
              ),
            ],
          ),
        ),
        const SizedBox(height: 24),
      ],
    );
  }

  Widget _buildRawTab() {
    return ListView(
      padding: const EdgeInsets.all(16),
      children: [
        Card(
          child: Padding(
            padding: const EdgeInsets.all(14),
            child: Wrap(
              spacing: 10,
              runSpacing: 10,
              children: [
                FilledButton.icon(
                  onPressed: () async {
                    await Clipboard.setData(ClipboardData(text: _raw));
                    if (!mounted) return;
                    await _showToast("Copied raw to clipboard");
                  },
                  icon: const Icon(Icons.copy),
                  label: const Text("Copy raw"),
                ),
                OutlinedButton.icon(
                  onPressed: _clearLiveData,
                  icon: const Icon(Icons.delete_outline),
                  label: const Text("Clear all data"),
                ),
                _MiniPill(text: "Buffer: ${_assembler.pendingBytes}"),
                _MiniPill(text: "Parse: $_parseStatus"),
              ],
            ),
          ),
        ),
        const SizedBox(height: 12),
        _CardSection(
          title: "Raw BLE stream",
          subtitle: "Latest payload text for debugging parser and packet boundaries.",
          child: Container(
            padding: const EdgeInsets.all(12),
            decoration: BoxDecoration(
              color: Colors.black.withValues(alpha: 0.25),
              borderRadius: BorderRadius.circular(12),
              border: Border.all(color: Colors.white.withValues(alpha: 0.08)),
            ),
            child: SelectableText(
              _raw.isEmpty ? "(empty)" : _raw,
              style: const TextStyle(fontFamily: "monospace", fontSize: 12),
            ),
          ),
        ),
        const SizedBox(height: 24),
      ],
    );
  }

  Widget _buildAboutTab() {
    String s(dynamic v) => v == null ? "N/A" : v.toString();
    final accuracy = _modelMetrics["accuracy"];
    final f1 = _modelMetrics["f1"];
    final auc = _modelMetrics["roc_auc"];
    return ListView(
      padding: const EdgeInsets.all(16),
      children: [
        _CardSection(
          title: "Open source",
          subtitle: "Transparency and model provenance",
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Text(s(_modelInfo["open_source_note"])),
              const SizedBox(height: 10),
              _MiniPill(text: "App ${s(_modelInfo["app_version"])}"),
              const SizedBox(height: 8),
              _MiniPill(text: "Model ${s(_modelInfo["model_version"])}"),
              const SizedBox(height: 8),
              _MiniPill(text: "ML ${_mlModelLoaded ? "ON" : "OFF"}"),
            ],
          ),
        ),
        const SizedBox(height: 12),
        _CardSection(
          title: "Dataset",
          subtitle: "Training dataset metadata",
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Text("Name: ${s(_modelInfo["dataset_name"])}"),
              Text("Source: ${s(_modelInfo["dataset_source"])}"),
              Text("DOI: ${s(_modelInfo["dataset_doi"])}"),
              Text("Version: ${s(_modelInfo["dataset_version"])}"),
              Text("Dataset date: ${s(_modelInfo["dataset_date"])}"),
              Text("Last update: ${s(_modelInfo["dataset_last_update"])}"),
              Text("Subjects: ${s(_modelInfo["dataset_subjects"])}"),
              Text("Instances: ${s(_modelInfo["dataset_instances"])}"),
            ],
          ),
        ),
        const SizedBox(height: 12),
        _CardSection(
          title: "Model performance",
          subtitle: "Exported training metrics",
          child: Wrap(
            spacing: 8,
            runSpacing: 8,
            children: [
              _MiniPill(text: "Accuracy ${accuracy == null ? "N/A" : (accuracy as num).toStringAsFixed(3)}"),
              _MiniPill(text: "F1 ${f1 == null ? "N/A" : (f1 as num).toStringAsFixed(3)}"),
              _MiniPill(text: "AUC ${auc == null ? "N/A" : (auc as num).toStringAsFixed(3)}"),
              _MiniPill(text: "Rows ${s(_modelMetrics["rows_total"])}"),
              _MiniPill(text: "Train ${s(_modelMetrics["rows_train"])}"),
              _MiniPill(text: "Test ${s(_modelMetrics["rows_test"])}"),
            ],
          ),
        ),
        const SizedBox(height: 24),
      ],
    );
  }

  @override
  Widget build(BuildContext context) {
    final connectedName = _device?.platformName.isNotEmpty == true
        ? _device!.platformName
        : _device?.remoteId.str;
    final tabTitles = ["Connection", "Dashboard", "Raw debug", "About"];

    return Scaffold(
      appBar: AppBar(
        title: Text(tabTitles[_tabIndex]),
        actions: [
          _StatusPill(text: _status),
          const SizedBox(width: 10),
        ],
      ),
      floatingActionButton: _connected
          ? FloatingActionButton.extended(
              onPressed: _reconnecting ? null : _reconnect,
              icon: const Icon(Icons.refresh),
              label: Text(_reconnecting ? "Reconnecting" : "Reconnect"),
            )
          : null,
      body: IndexedStack(
        index: _tabIndex,
        children: [
          _buildConnectionTab(connectedName),
          _buildDashboardTab(),
          _buildRawTab(),
          _buildAboutTab(),
        ],
      ),
      bottomNavigationBar: NavigationBar(
        selectedIndex: _tabIndex,
        onDestinationSelected: (index) => setState(() => _tabIndex = index),
        destinations: const [
          NavigationDestination(icon: Icon(Icons.bluetooth_searching), label: "Connection"),
          NavigationDestination(icon: Icon(Icons.monitor_heart), label: "Dashboard"),
          NavigationDestination(icon: Icon(Icons.code), label: "Raw"),
          NavigationDestination(icon: Icon(Icons.info_outline), label: "About"),
        ],
      ),
    );
  }
}

class MetricGroup {
  final double? avg;
  final double? min;
  final double? max;
  final double? std;

  const MetricGroup({this.avg, this.min, this.max, this.std});

  static double? _toDouble(dynamic v) {
    if (v is num) return v.toDouble();
    if (v is String) return double.tryParse(v);
    return null;
  }

  factory MetricGroup.fromMap(Map<String, dynamic> m) {
    return MetricGroup(
      avg: _toDouble(m["avg"]),
      min: _toDouble(m["min"]),
      max: _toDouble(m["max"]),
      std: _toDouble(m["std"]),
    );
  }
}

class JsonChunkAssembler {
  final StringBuffer _buf = StringBuffer();
  static const int _maxRemainder = 5000;
  static const int _maxBuffer = 12000;
  static final RegExp _packetStart = RegExp(r'\{"(?:ts|TS)"\s*:');

  void reset() => _buf.clear();
  int get pendingBytes => _buf.length;

  List<Map<String, dynamic>> push(String chunk) {
    if (chunk.isEmpty) return const [];
    _buf.write(chunk);

    if (_buf.length > _maxBuffer) {
      final s = _buf.toString();
      final keep = s.substring(s.length - _maxBuffer);
      _buf
        ..clear()
        ..write(keep);
    }

    final text = _buf.toString();
    final objects = <Map<String, dynamic>>[];
    final starts = _packetStart.allMatches(text).map((m) => m.start).toList(growable: false);

    if (starts.length >= 2) {
      for (int i = 0; i < starts.length - 1; i++) {
        final segment = text.substring(starts[i], starts[i + 1]);
        final parsed = _parseSegment(segment);
        if (parsed != null) {
          objects.add(parsed);
        }
      }

      final rem = text.substring(starts.last);
      final safe = rem.length > _maxRemainder ? rem.substring(rem.length - _maxRemainder) : rem;
      _buf
        ..clear()
        ..write(safe);
      return objects;
    }

    if (starts.length == 1) {
      final segment = text.substring(starts.first);
      final parsed = _parseSegment(segment);
      if (parsed != null) {
        objects.add(parsed);
        final lastBrace = segment.lastIndexOf("}");
        final consumed = starts.first + lastBrace + 1;
        final rem = text.substring(consumed);
        final safe = rem.length > _maxRemainder ? rem.substring(rem.length - _maxRemainder) : rem;
        _buf
          ..clear()
          ..write(safe);
        return objects;
      }
    }

    if (_buf.length > _maxRemainder) {
      final idx = text.lastIndexOf("{");
      _buf.clear();
      if (idx >= 0) {
        _buf.write(text.substring(idx));
      } else {
        _buf.write(text.substring(text.length - _maxRemainder));
      }
    }

    return objects;
  }

  Map<String, dynamic>? _parseSegment(String segment) {
    int end = segment.lastIndexOf("}");
    while (end >= 0) {
      final candidate = segment.substring(0, end + 1);
      final parsed = _tryParse(candidate);
      if (parsed != null && _looksLikePayload(parsed)) {
        return parsed;
      }
      end = segment.lastIndexOf("}", end - 1);
    }
    return null;
  }

  bool _looksLikePayload(Map<String, dynamic> m) {
    return m.containsKey("ts") ||
        m.containsKey("TS") ||
        m.containsKey("BPM") ||
        m.containsKey("bpm") ||
        m.containsKey("GSR") ||
        m.containsKey("gsr");
  }

  Map<String, dynamic>? _tryParse(String s) {
    try {
      final v = json.decode(s);
      if (v is Map<String, dynamic>) return v;
      if (v is Map) return v.cast<String, dynamic>();
      return null;
    } catch (_) {
      return null;
    }
  }
}

class _TopActions extends StatelessWidget {
  final bool scanning;
  final bool connecting;
  final bool connected;
  final String? connectedName;
  final String parseStatus;
  final bool mlModelLoaded;
  final TextEditingController filterController;
  final ValueChanged<String> onFilterChanged;
  final VoidCallback onScan;
  final VoidCallback onStopScan;
  final VoidCallback onDisconnect;
  final VoidCallback onReconnect;

  const _TopActions({
    required this.scanning,
    required this.connecting,
    required this.connected,
    required this.connectedName,
    required this.parseStatus,
    required this.mlModelLoaded,
    required this.filterController,
    required this.onFilterChanged,
    required this.onScan,
    required this.onStopScan,
    required this.onDisconnect,
    required this.onReconnect,
  });

  @override
  Widget build(BuildContext context) {
    final cs = Theme.of(context).colorScheme;

    return Card(
      child: Padding(
        padding: const EdgeInsets.all(14),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Wrap(
              runSpacing: 10,
              spacing: 10,
              children: [
                FilledButton.icon(
                  onPressed: scanning ? null : onScan,
                  icon: const Icon(Icons.radar),
                  label: Text(scanning ? "Scanning" : "Scan"),
                ),
                OutlinedButton.icon(
                  onPressed: scanning ? onStopScan : null,
                  icon: const Icon(Icons.stop),
                  label: const Text("Stop"),
                ),
                if (connected)
                  FilledButton.tonalIcon(
                    onPressed: onDisconnect,
                    icon: const Icon(Icons.link_off),
                    label: const Text("Disconnect"),
                  ),
                if (connected)
                  FilledButton.tonalIcon(
                    onPressed: onReconnect,
                    icon: const Icon(Icons.refresh),
                    label: const Text("Reconnect"),
                  ),
              ],
            ),
            const SizedBox(height: 12),
            TextField(
              controller: filterController,
              decoration: const InputDecoration(
                labelText: "Device name filter",
                hintText: "ESP32_HealthMonitor",
                border: OutlineInputBorder(),
              ),
              onChanged: onFilterChanged,
            ),
            const SizedBox(height: 12),
            Container(
              padding: const EdgeInsets.all(12),
              decoration: BoxDecoration(
                borderRadius: BorderRadius.circular(12),
                color: cs.surfaceContainerHighest.withValues(alpha: 0.35),
                border: Border.all(color: Colors.white.withValues(alpha: 0.08)),
              ),
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Row(
                    children: [
                      Icon(connected ? Icons.bluetooth_connected : Icons.bluetooth, size: 18),
                      const SizedBox(width: 10),
                      Expanded(
                        child: Text(
                          connected ? "Connected to ${connectedName ?? "device"}" : (connecting ? "Connecting..." : "Not connected"),
                          maxLines: 1,
                          overflow: TextOverflow.ellipsis,
                        ),
                      ),
                    ],
                  ),
                  const SizedBox(height: 8),
                  Wrap(
                    spacing: 8,
                    runSpacing: 8,
                    children: [
                      _MiniPill(text: "Parse: $parseStatus"),
                      _MiniPill(text: "ML ${mlModelLoaded ? "ON" : "OFF"}"),
                    ],
                  ),
                ],
              ),
            ),
          ],
        ),
      ),
    );
  }
}

class _MetricsGrid extends StatelessWidget {
  final int? ts;
  final MetricGroup? bpm;
  final MetricGroup? gsr;
  final double? temp;
  final StressInferenceResult? stressResult;
  final String? stressInputIssue;
  final bool mlModelLoaded;
  final int calibrationWindows;
  final int calibrationTarget;
  final int windowSamples;
  final int windowTarget;
  final bool calibrationReady;
  final List<double> bpmHistory;
  final List<double> gsrHistory;
  final List<double> stressHistory;

  const _MetricsGrid({
    required this.ts,
    required this.bpm,
    required this.gsr,
    required this.temp,
    required this.stressResult,
    required this.stressInputIssue,
    required this.mlModelLoaded,
    required this.calibrationWindows,
    required this.calibrationTarget,
    required this.windowSamples,
    required this.windowTarget,
    required this.calibrationReady,
    required this.bpmHistory,
    required this.gsrHistory,
    required this.stressHistory,
  });

  @override
  Widget build(BuildContext context) {
    final stressText = stressResult?.levelText ?? "N/A";
    final stressProb = stressResult == null ? "N/A" : "${(stressResult!.stressProbability * 100).toStringAsFixed(0)}%";
    final proxyText = stressResult == null ? "N/A" : stressResult!.cortisolProxy.toStringAsFixed(1);

    return Card(
      child: Padding(
        padding: const EdgeInsets.all(14),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            const Text("Live metrics", style: TextStyle(fontSize: 16, fontWeight: FontWeight.w600)),
            const SizedBox(height: 10),
            Wrap(
              spacing: 10,
              runSpacing: 10,
              children: [
                _ExpandableMetricCard(
                  title: "BPM",
                  icon: Icons.favorite,
                  accent: const Color(0xFFE11D48),
                  primaryValue: _fmt(bpm?.avg),
                  primaryUnit: "bpm avg",
                  details: [
                    ("Min", _fmt(bpm?.min)),
                    ("Max", _fmt(bpm?.max)),
                    ("Std", _fmt(bpm?.std)),
                    ("Last ts", ts?.toString() ?? "N/A"),
                  ],
                ),
                _ExpandableMetricCard(
                  title: "GSR",
                  icon: Icons.waves,
                  accent: const Color(0xFF14B8A6),
                  primaryValue: _fmt(gsr?.avg),
                  primaryUnit: "avg",
                  details: [
                    ("Min", _fmt(gsr?.min)),
                    ("Max", _fmt(gsr?.max)),
                    ("Std", _fmt(gsr?.std)),
                    ("Samples", gsrHistory.length.toString()),
                  ],
                ),
                _ExpandableMetricCard(
                  title: "Temperature",
                  icon: Icons.thermostat,
                  accent: const Color(0xFFF59E0B),
                  primaryValue: _fmt(temp),
                  primaryUnit: "deg C",
                  details: [
                    ("Raw ts", ts?.toString() ?? "N/A"),
                    ("Calib", calibrationReady ? "ready" : "$calibrationWindows/$calibrationTarget"),
                    ("Window", "$windowSamples/$windowTarget"),
                  ],
                ),
                _ExpandableMetricCard(
                  title: "Stress",
                  icon: Icons.psychology_alt,
                  accent: const Color(0xFF6366F1),
                  primaryValue: stressText,
                  primaryUnit: "level",
                  details: [
                    ("Model", mlModelLoaded ? "trained logistic" : "fallback heuristic"),
                    ("Probability", stressProb),
                    ("Cortisol proxy", proxyText),
                    ("Input", stressInputIssue ?? "all valid"),
                    ("Calibration", calibrationReady ? "ready" : "$calibrationWindows/$calibrationTarget"),
                    ("Window", "$windowSamples/$windowTarget"),
                  ],
                ),
              ],
            ),
            const SizedBox(height: 14),
            _MiniSparkline(title: "BPM trend", data: bpmHistory),
            const SizedBox(height: 10),
            _MiniSparkline(title: "GSR trend", data: gsrHistory),
            const SizedBox(height: 10),
            _MiniSparkline(title: "Stress probability trend", data: stressHistory),
          ],
        ),
      ),
    );
  }

  String _fmt(double? v) => v == null ? "N/A" : v.toStringAsFixed(2);
}

class _ExpandableMetricCard extends StatelessWidget {
  final String title;
  final IconData icon;
  final Color accent;
  final String primaryValue;
  final String primaryUnit;
  final List<(String, String)> details;

  const _ExpandableMetricCard({
    required this.title,
    required this.icon,
    required this.accent,
    required this.primaryValue,
    required this.primaryUnit,
    required this.details,
  });

  @override
  Widget build(BuildContext context) {
    final cs = Theme.of(context).colorScheme;
    return ConstrainedBox(
      constraints: const BoxConstraints(minWidth: 280, maxWidth: 520),
      child: Container(
        decoration: BoxDecoration(
          borderRadius: BorderRadius.circular(16),
          gradient: LinearGradient(
            colors: [
              accent.withValues(alpha: 0.18),
              cs.surfaceContainerHighest.withValues(alpha: 0.26),
            ],
            begin: Alignment.topLeft,
            end: Alignment.bottomRight,
          ),
          border: Border.all(color: Colors.white.withValues(alpha: 0.09)),
        ),
        child: Theme(
          data: Theme.of(context).copyWith(dividerColor: Colors.transparent),
          child: ExpansionTile(
            tilePadding: const EdgeInsets.symmetric(horizontal: 14, vertical: 6),
            childrenPadding: const EdgeInsets.fromLTRB(14, 0, 14, 12),
            leading: Container(
              width: 34,
              height: 34,
              decoration: BoxDecoration(
                color: accent.withValues(alpha: 0.24),
                borderRadius: BorderRadius.circular(10),
              ),
              child: Icon(icon, size: 18),
            ),
            title: Text(title, style: const TextStyle(fontWeight: FontWeight.w700)),
            subtitle: Text(primaryUnit),
            trailing: Text(
              primaryValue,
              style: const TextStyle(fontWeight: FontWeight.w800, fontSize: 18),
            ),
            children: details
                .map((d) => _DetailRow(label: d.$1, value: d.$2))
                .toList(growable: false),
          ),
        ),
      ),
    );
  }
}

class _DetailRow extends StatelessWidget {
  final String label;
  final String value;

  const _DetailRow({required this.label, required this.value});

  @override
  Widget build(BuildContext context) {
    return Padding(
      padding: const EdgeInsets.symmetric(vertical: 4),
      child: Row(
        children: [
          Expanded(
            child: Text(
              label,
              style: TextStyle(color: Colors.white.withValues(alpha: 0.72)),
            ),
          ),
          Text(
            value,
            style: const TextStyle(fontWeight: FontWeight.w700),
          ),
        ],
      ),
    );
  }
}

class _MiniSparkline extends StatelessWidget {
  final String title;
  final List<double> data;

  const _MiniSparkline({required this.title, required this.data});

  @override
  Widget build(BuildContext context) {
    final cs = Theme.of(context).colorScheme;

    return Container(
      padding: const EdgeInsets.all(12),
      decoration: BoxDecoration(
        borderRadius: BorderRadius.circular(14),
        color: cs.surfaceContainerHighest.withValues(alpha: 0.22),
        border: Border.all(color: Colors.white.withValues(alpha: 0.08)),
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Text(title, style: const TextStyle(fontWeight: FontWeight.w600)),
          const SizedBox(height: 8),
          SizedBox(
            height: 42,
            child: CustomPaint(
              painter: _SparkPainter(data),
              child: const SizedBox.expand(),
            ),
          ),
        ],
      ),
    );
  }
}

class _SparkPainter extends CustomPainter {
  final List<double> data;
  _SparkPainter(this.data);

  @override
  void paint(Canvas canvas, Size size) {
    if (data.length < 2) return;

    final minV = data.reduce(min);
    final maxV = data.reduce(max);
    final span = (maxV - minV).abs() < 1e-9 ? 1.0 : (maxV - minV);

    final paintLine = Paint()
      ..strokeWidth = 2
      ..style = PaintingStyle.stroke;

    final path = Path();

    for (int i = 0; i < data.length; i++) {
      final x = size.width * (i / (data.length - 1));
      final norm = (data[i] - minV) / span;
      final y = size.height * (1.0 - norm);

      if (i == 0) {
        path.moveTo(x, y);
      } else {
        path.lineTo(x, y);
      }
    }

    canvas.drawPath(path, paintLine);
  }

  @override
  bool shouldRepaint(covariant _SparkPainter oldDelegate) => oldDelegate.data != data;
}

class _CardSection extends StatelessWidget {
  final String title;
  final String subtitle;
  final Widget child;

  const _CardSection({required this.title, required this.subtitle, required this.child});

  @override
  Widget build(BuildContext context) {
    final cs = Theme.of(context).colorScheme;
    return Card(
      child: Padding(
        padding: const EdgeInsets.all(14),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Text(title, style: const TextStyle(fontSize: 16, fontWeight: FontWeight.w600)),
            const SizedBox(height: 4),
            Text(subtitle, style: TextStyle(color: cs.onSurface.withValues(alpha: 0.7))),
            const SizedBox(height: 12),
            child,
          ],
        ),
      ),
    );
  }
}

class _DeviceTile extends StatelessWidget {
  final String name;
  final String id;
  final int rssi;
  final VoidCallback onTap;

  const _DeviceTile({required this.name, required this.id, required this.rssi, required this.onTap});

  @override
  Widget build(BuildContext context) {
    final cs = Theme.of(context).colorScheme;

    return InkWell(
      onTap: onTap,
      borderRadius: BorderRadius.circular(14),
      child: Container(
        margin: const EdgeInsets.only(bottom: 10),
        padding: const EdgeInsets.all(12),
        decoration: BoxDecoration(
          borderRadius: BorderRadius.circular(14),
          color: cs.surfaceContainerHighest.withValues(alpha: 0.22),
          border: Border.all(color: Colors.white.withValues(alpha: 0.08)),
        ),
        child: Row(
          children: [
            const Icon(Icons.devices),
            const SizedBox(width: 10),
            Expanded(
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Text(name, style: const TextStyle(fontWeight: FontWeight.w700)),
                  const SizedBox(height: 3),
                  Text(
                    id,
                    style: TextStyle(color: Colors.white.withValues(alpha: 0.6), fontSize: 12),
                    maxLines: 1,
                    overflow: TextOverflow.ellipsis,
                  ),
                ],
              ),
            ),
            const SizedBox(width: 10),
            _MiniPill(text: "RSSI $rssi"),
            const SizedBox(width: 8),
            const Icon(Icons.chevron_right),
          ],
        ),
      ),
    );
  }
}

class _EmptyState extends StatelessWidget {
  final String text;
  const _EmptyState({required this.text});

  @override
  Widget build(BuildContext context) {
    return Container(
      padding: const EdgeInsets.all(14),
      decoration: BoxDecoration(
        borderRadius: BorderRadius.circular(14),
        border: Border.all(color: Colors.white.withValues(alpha: 0.08)),
      ),
      child: Row(
        children: [
          const Icon(Icons.info_outline),
          const SizedBox(width: 10),
          Expanded(child: Text(text)),
        ],
      ),
    );
  }
}

class _StatusPill extends StatelessWidget {
  final String text;
  const _StatusPill({required this.text});

  @override
  Widget build(BuildContext context) {
    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 6),
      decoration: BoxDecoration(
        borderRadius: BorderRadius.circular(999),
        color: Colors.white.withValues(alpha: 0.08),
        border: Border.all(color: Colors.white.withValues(alpha: 0.10)),
      ),
      child: Text(
        text,
        style: const TextStyle(fontSize: 12),
        maxLines: 1,
        overflow: TextOverflow.ellipsis,
      ),
    );
  }
}

class _MiniPill extends StatelessWidget {
  final String text;
  const _MiniPill({required this.text});

  @override
  Widget build(BuildContext context) {
    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 6),
      decoration: BoxDecoration(
        borderRadius: BorderRadius.circular(999),
        color: Colors.white.withValues(alpha: 0.06),
        border: Border.all(color: Colors.white.withValues(alpha: 0.10)),
      ),
      child: Text(text, style: const TextStyle(fontSize: 12)),
    );
  }
}

class HistoryEntry {
  final DateTime when;
  final int? ts;
  final double? bpmAvg;
  final double? gsrAvg;
  final double? tempAvg;
  final double stressProb;
  final double cortisolProxy;
  final String stressLevel;
  final String label;

  const HistoryEntry({
    required this.when,
    required this.ts,
    required this.bpmAvg,
    required this.gsrAvg,
    required this.tempAvg,
    required this.stressProb,
    required this.cortisolProxy,
    required this.stressLevel,
    required this.label,
  });
}

class _HistoryTable extends StatelessWidget {
  final List<HistoryEntry> entries;

  const _HistoryTable({required this.entries});

  @override
  Widget build(BuildContext context) {
    if (entries.isEmpty) {
      return const _EmptyState(text: "No history yet. Start receiving live data.");
    }

    final rows = entries.reversed.take(40).toList(growable: false);
    String fmt(double? v) => v == null ? "N/A" : v.toStringAsFixed(2);

    return SingleChildScrollView(
      scrollDirection: Axis.horizontal,
      child: DataTable(
        columns: const [
          DataColumn(label: Text("Time")),
          DataColumn(label: Text("ts")),
          DataColumn(label: Text("BPM")),
          DataColumn(label: Text("GSR")),
          DataColumn(label: Text("Temp")),
          DataColumn(label: Text("Stress %")),
          DataColumn(label: Text("Proxy")),
          DataColumn(label: Text("Level")),
          DataColumn(label: Text("Label")),
        ],
        rows: rows
            .map(
              (e) => DataRow(cells: [
                DataCell(Text("${e.when.hour.toString().padLeft(2, '0')}:${e.when.minute.toString().padLeft(2, '0')}:${e.when.second.toString().padLeft(2, '0')}")),
                DataCell(Text(e.ts?.toString() ?? "N/A")),
                DataCell(Text(fmt(e.bpmAvg))),
                DataCell(Text(fmt(e.gsrAvg))),
                DataCell(Text(fmt(e.tempAvg))),
                DataCell(Text((e.stressProb * 100).toStringAsFixed(1))),
                DataCell(Text(e.cortisolProxy.toStringAsFixed(1))),
                DataCell(Text(e.stressLevel)),
                DataCell(Text(e.label)),
              ]),
            )
            .toList(growable: false),
      ),
    );
  }
}

class _HistoryPage extends StatelessWidget {
  final List<HistoryEntry> entries;
  final String? csvPath;
  final int loggedRows;
  final Future<void> Function() onCopyCsv;

  const _HistoryPage({
    required this.entries,
    required this.csvPath,
    required this.loggedRows,
    required this.onCopyCsv,
  });

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: AppBar(
        title: const Text("Session History"),
        actions: [
          IconButton(
            tooltip: "Copy CSV",
            onPressed: onCopyCsv,
            icon: const Icon(Icons.copy),
          ),
          const SizedBox(width: 8),
        ],
      ),
      body: ListView(
        padding: const EdgeInsets.all(16),
        children: [
          _CardSection(
            title: "Logger",
            subtitle: "Export and file information",
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                _MiniPill(text: "Logged rows $loggedRows"),
                const SizedBox(height: 8),
                Text("CSV path: ${csvPath ?? "N/A"}"),
                const SizedBox(height: 8),
                FilledButton.icon(
                  onPressed: onCopyCsv,
                  icon: const Icon(Icons.file_copy_outlined),
                  label: const Text("Copy CSV to clipboard"),
                ),
              ],
            ),
          ),
          const SizedBox(height: 12),
          _CardSection(
            title: "History table",
            subtitle: "Latest rows from this run",
            child: _HistoryTable(entries: entries),
          ),
        ],
      ),
    );
  }
}
