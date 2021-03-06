// Copyright 2017, Paul DeMarco.
// All rights reserved. Use of this source code is governed by a
// BSD-style license that can be found in the LICENSE file.

part of flutter_blue;

class FlutterBlue {
  final MethodChannel _channel = const MethodChannel('$NAMESPACE/methods');
  final EventChannel _stateChannel = const EventChannel('$NAMESPACE/state');
  final StreamController<MethodCall> _methodStreamController =
  new StreamController.broadcast(); // ignore: close_sinks
  Stream<MethodCall> get _methodStream =>
      _methodStreamController
          .stream; // Used internally to dispatch methods from platform.

  /// Singleton boilerplate
  FlutterBlue._() {
    _channel.setMethodCallHandler((MethodCall call) {
      _methodStreamController.add(call);
      return;
    });

    _setLogLevelIfAvailable();
  }

  static FlutterBlue _instance = new FlutterBlue._();

  static FlutterBlue get instance => _instance;

  /// Log level of the instance, default is all messages (debug).
  LogLevel _logLevel = LogLevel.debug;

  LogLevel get logLevel => _logLevel;

  /// Checks whether the device supports Bluetooth
  Future<bool> get isAvailable =>
      _channel.invokeMethod('isAvailable').then<bool>((d) => d);

  /// Checks if Bluetooth functionality is turned on
  Future<bool> get isOn => _channel.invokeMethod('isOn').then<bool>((d) => d);

  BehaviorSubject<bool> _isScanning = BehaviorSubject.seeded(false);

  Stream<bool> get isScanning => _isScanning.stream;

  BehaviorSubject<List<ScanResult>> scanResultsSubject = BehaviorSubject.seeded([]);

  /// Returns a stream that is a list of [ScanResult] results while a scan is in progress.
  ///
  /// The list emitted is all the scanned results as of the last initiated scan. When a scan is
  /// first started, an empty list is emitted. The returned stream is never closed.
  ///
  /// One use for [scanResults] is as the stream in a StreamBuilder to display the
  /// results of a scan in real time while the scan is in progress.
  // Stream<List<ScanResult>> get scanResultsSteam => scanResultsSubject.stream.throttleTime(scanThrottleTime).transform(StreamTransformer.fromHandlers(handleData: _filterResult));
  Stream<List<ScanResult>> get scanResultsSteam => scanResultsSubject.stream;

  void _filterResult(List<ScanResult> result, EventSink sink) {
    List<ScanResult> s = result.where(scanFilter).toList();

    s.sort((a, b) => a.rssi > b.rssi ? 1 : 0);
    // if (isAutoReconnect && currentDevice != null) {
    //   var matched = s.where((element) => element == currentDevice);
    //   if (matched.length > 0) {
    //     stopScan();
    //     connectDevice(currentDevice);
    //   }
    // }
    // dlog.i('sink.add:${s}, ${s.length}');
    sink.add(s);
  }

  Duration scanThrottleTime = Duration(milliseconds: 2000);
  bool Function(ScanResult) scanFilter = (result) {
    return true;
  };

  PublishSubject _stopScanPill = new PublishSubject();

  /// Gets the current state of the Bluetooth module
  Stream<BluetoothState> get state async* {
    yield await _channel
        .invokeMethod('state')
        .then((buffer) => new protos.BluetoothState.fromBuffer(buffer))
        .then((s) => BluetoothState.values[s.state.value]);

    yield* _stateChannel
        .receiveBroadcastStream()
        .map((buffer) => new protos.BluetoothState.fromBuffer(buffer))
        .map((s) => BluetoothState.values[s.state.value]);
  }

  /// Retrieve a list of connected devices
  Future<List<BluetoothDevice>> get connectedDevices {
    return _channel
        .invokeMethod('getConnectedDevices')
        .then((buffer) => protos.ConnectedDevicesResponse.fromBuffer(buffer))
        .then((p) => p.devices)
        .then((p) => p.map((d) => BluetoothDevice.fromProto(d)).toList());
  }

  _setLogLevelIfAvailable() async {
    if (await isAvailable) {
      // Send the log level to the underlying platforms.
      setLogLevel(logLevel);
    }
  }

  /// Starts a scan for Bluetooth Low Energy devices and returns a stream
  /// of the [ScanResult] results as they are received.
  ///
  /// timeout calls stopStream after a specified [Duration].
  /// You can also get a list of ongoing results in the [scanResults] stream.
  /// If scanning is already in progress, this will throw an [Exception].
  Stream<ScanResult> scan({
    ScanMode scanMode = ScanMode.lowLatency,
    List<Guid> withServices = const [],
    List<Guid> withDevices = const [],
    Duration timeout,
    bool allowDuplicates = false,
    Duration throttleTime,
  }) async* {
    var settings = protos.ScanSettings.create()
      ..androidScanMode = scanMode.value
      ..allowDuplicates = allowDuplicates
      ..serviceUuids.addAll(withServices.map((g) => g.toString()).toList());

    if (_isScanning.value == true) {
      throw Exception('Another scan is already in progress.');
    }

    // Update ThrottleTime
    if (throttleTime != null) {
      scanThrottleTime = throttleTime;
    }
    
    // Emit to isScanning
    _isScanning.add(true);



    final killStreams = <Stream>[];
    killStreams.add(_stopScanPill);
    // if (timeout != null) {
    //   killStreams.add(Rx.timer(null, timeout));
    // }

    // Clear scan results list
    scanResultsSubject.add(<ScanResult>[]);

    try {
      await _channel.invokeMethod('startScan', settings.writeToBuffer());
    } catch (e) {
      print('Error starting scan.');
      _stopScanPill.add(null);
      _isScanning.add(false);
      throw e;
    }

    _scanTimeoutTimer?.cancel();
    if (timeout != null) {
      _scanTimeoutTimer = Timer(timeout, () {
        stopScan();
      });
    }

    _cachedDevices.clear();
    _updateScanResultTimer?.cancel();
    // print('scanThrottleTime: $scanThrottleTime');
    _updateScanResultTimer = Timer.periodic(scanThrottleTime, (t) {
      // print('check scan result cache');
      int _nowSec = DateTime.now().millisecondsSinceEpoch;
      int _diffTime = scanThrottleTime.inMilliseconds;
      _cachedDevices.removeWhere((key, value) {
        // print('diff: ${_nowSec - value.date.millisecondsSinceEpoch}');
        if (_nowSec - value.date.millisecondsSinceEpoch > _diffTime) {
          // print('!!!!!!! has remove!!!!!');
          return true;
        }
        return false;
      });

      final list = _cachedDevices.values.map((e) => e.result).toList();

      scanResultsSubject.add(list);
    });

    yield* FlutterBlue.instance._methodStream
        .where((m) => m.method == "ScanResult")
        .map((m) => m.arguments)
        .takeUntil(Rx.merge(killStreams))
        .doOnDone(stopScan)
        .map((buffer) => new protos.ScanResult.fromBuffer(buffer))
        .map((p) {
      final result = new ScanResult.fromProto(p);

      _cachedDevices[result.device.id.toString()] = GLScanResultCache(result);

      // int _nowSec = DateTime.now().millisecondsSinceEpoch;
      // _cachedDevices.removeWhere((key, value) {
      //   if (value.date.millisecondsSinceEpoch - _nowSec > 3000) {
      //     return true;
      //   }
      //   return false;
      // });

      // final list = scanResultsSubject.value;
      // int index = list.indexOf(result);
      // if (index != -1) {
      //   list[index] = result;
      // } else {
      //   list.add(result);
      // }

      final list = _cachedDevices.values.map((e) => e.result).toList();

      scanResultsSubject.add(list);

      return result;
    });
  }
  Timer _updateScanResultTimer;
  Map<String, GLScanResultCache> _cachedDevices = {};
  Timer _scanTimeoutTimer;
  /// Starts a scan and returns a future that will complete once the scan has finished.
  /// 
  /// Once a scan is started, call [stopScan] to stop the scan and complete the returned future.
  ///
  /// timeout automatically stops the scan after a specified [Duration].
  ///
  /// To observe the results while the scan is in progress, listen to the [scanResults] stream, 
  /// or call [scan] instead.
  Future startScan({
    ScanMode scanMode = ScanMode.lowLatency,
    List<Guid> withServices = const [],
    List<Guid> withDevices = const [],
    Duration timeout,
    bool allowDuplicates = false,
    Duration throttleTime,
  }) async {
    await scan(
        scanMode: scanMode,
        withServices: withServices,
        withDevices: withDevices,
        timeout: timeout,
        allowDuplicates: allowDuplicates,
        throttleTime: throttleTime)
        .drain();
    return scanResultsSubject.value;
  }

  /// Stops a scan for Bluetooth Low Energy devices
  Future stopScan() async {
    _scanTimeoutTimer?.cancel();
    _updateScanResultTimer?.cancel();
    await _channel.invokeMethod('stopScan');
    _stopScanPill.add(null);
    _isScanning.add(false);
  }

  /// The list of connected peripherals can include those that are connected
  /// by other apps and that will need to be connected locally using the
  /// device.connect() method before they can be used.
//  Stream<List<BluetoothDevice>> connectedDevices({
//    List<Guid> withServices = const [],
//  }) =>
//      throw UnimplementedError();

  /// Sets the log level of the FlutterBlue instance
  /// Messages equal or below the log level specified are stored/forwarded,
  /// messages above are dropped.
  void setLogLevel(LogLevel level) async {
    await _channel.invokeMethod('setLogLevel', level.index);
    _logLevel = level;
  }

  void _log(LogLevel level, String message) {
    if (level.index <= _logLevel.index) {
      print(message);
    }
  }
}

/// Log levels for FlutterBlue
enum LogLevel {
  emergency,
  alert,
  critical,
  error,
  warning,
  notice,
  info,
  debug,
}

/// State of the bluetooth adapter.
enum BluetoothState {
  unknown,
  unavailable,
  unauthorized,
  turningOn,
  on,
  turningOff,
  off
}

class ScanMode {
  const ScanMode(this.value);

  static const lowPower = const ScanMode(0);
  static const balanced = const ScanMode(1);
  static const lowLatency = const ScanMode(2);
  static const opportunistic = const ScanMode(-1);
  final int value;
}

class DeviceIdentifier {
  final String id;

  const DeviceIdentifier(this.id);

  @override
  String toString() => id;

  @override
  int get hashCode => id.hashCode;

  @override
  bool operator ==(other) =>
      other is DeviceIdentifier && compareAsciiLowerCase(id, other.id) == 0;
}

class ScanResult {
  const ScanResult({this.device, this.advertisementData, this.rssi});

  ScanResult.fromProto(protos.ScanResult p)
      : device = new BluetoothDevice.fromProto(p.device),
        advertisementData =
        new AdvertisementData.fromProto(p.advertisementData),
        rssi = p.rssi;

  final BluetoothDevice device;
  final AdvertisementData advertisementData;
  final int rssi;

  @override
  bool operator ==(Object other) =>
      identical(this, other) ||
          other is ScanResult &&
              runtimeType == other.runtimeType &&
              device == other.device;

  @override
  int get hashCode => device.hashCode;

  @override
  String toString() {
    return 'ScanResult{device: $device, advertisementData: $advertisementData, rssi: $rssi}';
  }
}

class AdvertisementData {
  final String localName;
  final int txPowerLevel;
  final bool connectable;
  final Map<int, List<int>> manufacturerData;
  final Map<String, List<int>> serviceData;
  final List<String> serviceUuids;

  AdvertisementData({this.localName,
    this.txPowerLevel,
    this.connectable,
    this.manufacturerData,
    this.serviceData,
    this.serviceUuids});

  AdvertisementData.fromProto(protos.AdvertisementData p)
      : localName = p.localName,
        txPowerLevel =
        (p.txPowerLevel.hasValue()) ? p.txPowerLevel.value : null,
        connectable = p.connectable,
        manufacturerData = p.manufacturerData,
        serviceData = p.serviceData,
        serviceUuids = p.serviceUuids;

  @override
  String toString() {
    return 'AdvertisementData{localName: $localName, txPowerLevel: $txPowerLevel, connectable: $connectable, manufacturerData: $manufacturerData, serviceData: $serviceData, serviceUuids: $serviceUuids}';
  }
}

class GLScanResultCache {
  ScanResult result;
  DateTime date;
  GLScanResultCache(this.result, {this.date}) {
    if (date == null) {
      date = DateTime.now();
    }
  }
}