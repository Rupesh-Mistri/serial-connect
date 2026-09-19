import 'dart:async';
import 'dart:io' show Platform;
import 'dart:typed_data';
import '../models/serial_transport_type.dart';
import 'ble_serial_transport.dart';
import 'mock_serial_transport.dart';
import 'serial_transport.dart';
import 'tcp_serial_transport.dart';
import 'usb_serial_transport.dart';

class SerialManager {
  static final SerialManager _instance = SerialManager._internal();
  factory SerialManager() => _instance;

  late final UsbSerialTransport _usbTransport;
  late final BleSerialTransport _bleTransport;
  late final TcpSerialTransport _tcpTransport;
  late final MockSerialTransport _mockTransport;

  late SerialTransport _activeTransport;
  SerialTransportType _selectedType = SerialTransportType.usbOtg;

  final StreamController<String> _dataController =
      StreamController<String>.broadcast();
  final StreamController<Uint8List> _rawDataController =
      StreamController<Uint8List>.broadcast();
  final StreamController<bool> _connectionController =
      StreamController<bool>.broadcast();
  final StreamController<String> _errorController =
      StreamController<String>.broadcast();
  final StreamController<String> _logController =
      StreamController<String>.broadcast();

  final List<StreamSubscription> _transportSubs = [];

  SerialManager._internal() {
    _usbTransport = UsbSerialTransport();
    _bleTransport = BleSerialTransport();
    _tcpTransport = TcpSerialTransport();
    _mockTransport = MockSerialTransport();

    // Default to USB OTG on Android, BLE on iOS/Desktop
    if (Platform.isAndroid) {
      _selectedType = SerialTransportType.usbOtg;
      _activeTransport = _usbTransport;
    } else {
      _selectedType = SerialTransportType.ble;
      _activeTransport = _bleTransport;
    }

    _bindTransportEvents(_activeTransport);
  }

  void _bindTransportEvents(SerialTransport transport) {
    for (final s in _transportSubs) {
      s.cancel();
    }
    _transportSubs.clear();

    _transportSubs.add(transport.onData.listen((data) => _dataController.add(data)));
    _transportSubs.add(transport.onRawData.listen((bytes) => _rawDataController.add(bytes)));
    _transportSubs.add(transport.onConnectionChanged.listen((conn) => _connectionController.add(conn)));
    _transportSubs.add(transport.onError.listen((err) => _errorController.add(err)));
    _transportSubs.add(transport.onLog.listen((log) => _logController.add(log)));
  }

  SerialTransport get activeTransport => _activeTransport;
  SerialTransportType get selectedType => _selectedType;

  UsbSerialTransport get usbTransport => _usbTransport;
  BleSerialTransport get bleTransport => _bleTransport;
  TcpSerialTransport get tcpTransport => _tcpTransport;
  MockSerialTransport get mockTransport => _mockTransport;

  bool get isConnected => _activeTransport.isConnected;
  int get currentBaudRate => _activeTransport.currentBaudRate;
  String get driverName => _activeTransport.driverName;

  Stream<String> get onData => _dataController.stream;
  Stream<Uint8List> get onRawData => _rawDataController.stream;
  Stream<bool> get onConnectionChanged => _connectionController.stream;
  Stream<String> get onError => _errorController.stream;
  Stream<String> get onLog => _logController.stream;

  Future<void> switchTransport(SerialTransportType type) async {
    if (_selectedType == type) return;

    if (_activeTransport.isConnected) {
      await _activeTransport.disconnect();
    }

    _selectedType = type;
    switch (type) {
      case SerialTransportType.usbOtg:
        _activeTransport = _usbTransport;
        break;
      case SerialTransportType.ble:
        _activeTransport = _bleTransport;
        break;
      case SerialTransportType.tcp:
        _activeTransport = _tcpTransport;
        break;
      case SerialTransportType.simulator:
        _activeTransport = _mockTransport;
        break;
    }

    _bindTransportEvents(_activeTransport);
    _logController.add('SYS: Switched transport to ${_selectedType.label}');
    _connectionController.add(_activeTransport.isConnected);
  }

  Future<bool> connect({int baudRate = 115200, Map<String, dynamic>? config}) async {
    return _activeTransport.connect(baudRate: baudRate, config: config);
  }

  Future<bool> disconnect() async {
    return _activeTransport.disconnect();
  }

  Future<bool> send(String data) async {
    return _activeTransport.send(data);
  }

  Future<bool> sendRaw(Uint8List bytes) async {
    return _activeTransport.sendRaw(bytes);
  }

  Future<bool> setBaudRate(int baudRate) async {
    return _activeTransport.setBaudRate(baudRate);
  }

  Future<bool> setDtr(bool high) async {
    return _activeTransport.setDtr(high);
  }

  Future<bool> setRts(bool high) async {
    return _activeTransport.setRts(high);
  }

  void appendExternalLog(String message) {
    _logController.add(message);
  }

  void dispose() {
    for (final s in _transportSubs) {
      s.cancel();
    }
    _usbTransport.dispose();
    _bleTransport.dispose();
    _tcpTransport.dispose();
    _mockTransport.dispose();
    _dataController.close();
    _rawDataController.close();
    _connectionController.close();
    _errorController.close();
    _logController.close();
  }
}
