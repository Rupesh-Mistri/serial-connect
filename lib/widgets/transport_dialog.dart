import 'dart:io' show Platform;
import 'package:flutter/material.dart';
import 'package:flutter_blue_plus/flutter_blue_plus.dart';
import '../models/serial_transport_type.dart';
import '../services/ble_serial_transport.dart';
import '../services/serial_manager.dart';

class TransportDialog extends StatefulWidget {
  const TransportDialog({super.key});

  static Future<void> show(BuildContext context) {
    return showDialog(
      context: context,
      builder: (ctx) => const TransportDialog(),
    );
  }

  @override
  State<TransportDialog> createState() => _TransportDialogState();
}

class _TransportDialogState extends State<TransportDialog> {
  final SerialManager _serialManager = SerialManager();
  late SerialTransportType _selected;

  final TextEditingController _ipController =
      TextEditingController(text: '192.168.4.1');
  final TextEditingController _portController =
      TextEditingController(text: '8080');

  bool _isScanningBle = false;
  List<ScanResult> _bleResults = [];

  @override
  void initState() {
    super.initState();
    _selected = _serialManager.selectedType;
  }

  @override
  void dispose() {
    _ipController.dispose();
    _portController.dispose();
    super.dispose();
  }

  void _startBleScan() async {
    setState(() {
      _isScanningBle = true;
      _bleResults.clear();
    });

    try {
      await BleSerialTransport.stopScan();
      BleSerialTransport.scanForDevices(timeout: const Duration(seconds: 4))
          .listen((results) {
        if (mounted) {
          setState(() {
            _bleResults = results;
          });
        }
      }, onDone: () {
        if (mounted) {
          setState(() {
            _isScanningBle = false;
          });
        }
      });
    } catch (e) {
      if (mounted) {
        setState(() {
          _isScanningBle = false;
        });
        ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(content: Text('Bluetooth scan error: $e')),
        );
      }
    }
  }

  @override
  Widget build(BuildContext context) {
    return AlertDialog(
      backgroundColor: const Color(0xFF1E1E1E),
      title: Row(
        children: [
          const Icon(Icons.settings_input_composite, color: Color(0xFF90CAF9), size: 22),
          const SizedBox(width: 8),
          const Text(
            'Select Serial Transport',
            style: TextStyle(color: Colors.white, fontSize: 16, fontWeight: FontWeight.bold),
          ),
        ],
      ),
      content: SizedBox(
        width: double.maxFinite,
        child: SingleChildScrollView(
          child: Column(
            mainAxisSize: MainAxisSize.min,
            children: [
              // USB OTG Option
              _buildTransportOption(
                type: SerialTransportType.usbOtg,
                title: 'USB OTG (Host)',
                subtitle: Platform.isAndroid
                    ? 'Direct USB-UART chips (CP210x, FTDI, CH340, PL2303, CDC)'
                    : 'Supported primarily on Android OTG',
                icon: Icons.usb,
                enabled: Platform.isAndroid,
              ),
              const Divider(color: Color(0xFF333333)),

              // BLE Option
              _buildTransportOption(
                type: SerialTransportType.ble,
                title: 'Bluetooth LE Serial (BLE)',
                subtitle: 'iOS & Android (Nordic UART Service, ESP32 BLE, HM-10)',
                icon: Icons.bluetooth,
                enabled: true,
              ),
              if (_selected == SerialTransportType.ble) ...[
                const SizedBox(height: 8),
                Row(
                  children: [
                    ElevatedButton.icon(
                      onPressed: _isScanningBle ? null : _startBleScan,
                      icon: _isScanningBle
                          ? const SizedBox(
                              width: 14,
                              height: 14,
                              child: CircularProgressIndicator(strokeWidth: 2, color: Colors.white),
                            )
                          : const Icon(Icons.search, size: 16),
                      label: Text(_isScanningBle ? 'Scanning...' : 'Scan BLE Devices', style: const TextStyle(fontSize: 12)),
                      style: ElevatedButton.styleFrom(
                        backgroundColor: const Color(0xFF1565C0),
                        foregroundColor: Colors.white,
                        padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 8),
                      ),
                    ),
                  ],
                ),
                if (_bleResults.isNotEmpty) ...[
                  const SizedBox(height: 8),
                  Container(
                    height: 120,
                    decoration: BoxDecoration(
                      color: const Color(0xFF121212),
                      borderRadius: BorderRadius.circular(6),
                      border: Border.all(color: const Color(0xFF333333)),
                    ),
                    child: ListView.builder(
                      shrinkWrap: true,
                      itemCount: _bleResults.length,
                      itemBuilder: (ctx, idx) {
                        final r = _bleResults[idx];
                        final name = r.device.platformName.isNotEmpty
                            ? r.device.platformName
                            : (r.advertisementData.advName.isNotEmpty
                                ? r.advertisementData.advName
                                : 'Unknown BLE Device');
                        return ListTile(
                          dense: true,
                          title: Text(name, style: const TextStyle(color: Colors.white, fontSize: 12)),
                          subtitle: Text(r.device.remoteId.str, style: const TextStyle(color: Colors.grey, fontSize: 10)),
                          trailing: ElevatedButton(
                            style: ElevatedButton.styleFrom(
                              backgroundColor: const Color(0xFF2E7D32),
                              padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 4),
                            ),
                            onPressed: () async {
                              await _serialManager.switchTransport(SerialTransportType.ble);
                              await _serialManager.connect(config: {'device': r.device});
                              if (context.mounted) Navigator.pop(context);
                            },
                            child: const Text('Connect', style: TextStyle(fontSize: 11, color: Colors.white)),
                          ),
                        );
                      },
                    ),
                  ),
                ],
              ],
              const Divider(color: Color(0xFF333333)),

              // TCP Option
              _buildTransportOption(
                type: SerialTransportType.tcp,
                title: 'WiFi / TCP Serial Bridge',
                subtitle: 'iOS & Android (ESP32 WiFi Telnet/UART server)',
                icon: Icons.wifi,
                enabled: true,
              ),
              if (_selected == SerialTransportType.tcp) ...[
                const SizedBox(height: 8),
                Row(
                  children: [
                    Expanded(
                      flex: 2,
                      child: TextField(
                        controller: _ipController,
                        style: const TextStyle(color: Colors.white, fontSize: 12),
                        decoration: const InputDecoration(
                          labelText: 'IP Address',
                          labelStyle: TextStyle(color: Colors.grey, fontSize: 11),
                          isDense: true,
                          filled: true,
                          fillColor: Color(0xFF2C2C2C),
                          border: OutlineInputBorder(),
                        ),
                      ),
                    ),
                    const SizedBox(width: 8),
                    Expanded(
                      flex: 1,
                      child: TextField(
                        controller: _portController,
                        keyboardType: TextInputType.number,
                        style: const TextStyle(color: Colors.white, fontSize: 12),
                        decoration: const InputDecoration(
                          labelText: 'Port',
                          labelStyle: TextStyle(color: Colors.grey, fontSize: 11),
                          isDense: true,
                          filled: true,
                          fillColor: Color(0xFF2C2C2C),
                          border: OutlineInputBorder(),
                        ),
                      ),
                    ),
                  ],
                ),
              ],
              const Divider(color: Color(0xFF333333)),

              // Simulator Option
              _buildTransportOption(
                type: SerialTransportType.simulator,
                title: 'MCU Simulator / Loopback',
                subtitle: 'Simulates ESP32-S3 AT commands & GPS/Sensor telemetry',
                icon: Icons.devices,
                enabled: true,
              ),
            ],
          ),
        ),
      ),
      actions: [
        TextButton(
          onPressed: () => Navigator.pop(context),
          child: const Text('Cancel', style: TextStyle(color: Colors.grey)),
        ),
        ElevatedButton(
          style: ElevatedButton.styleFrom(
            backgroundColor: const Color(0xFF1565C0),
            foregroundColor: Colors.white,
          ),
          onPressed: () async {
            await _serialManager.switchTransport(_selected);
            if (_selected == SerialTransportType.tcp) {
              final host = _ipController.text.trim();
              final port = int.tryParse(_portController.text.trim()) ?? 8080;
              await _serialManager.connect(config: {'host': host, 'port': port});
            }
            if (context.mounted) Navigator.pop(context);
          },
          child: const Text('Apply'),
        ),
      ],
    );
  }

  Widget _buildTransportOption({
    required SerialTransportType type,
    required String title,
    required String subtitle,
    required IconData icon,
    required bool enabled,
  }) {
    final isCurrent = _selected == type;
    return InkWell(
      onTap: enabled
          ? () {
              setState(() {
                _selected = type;
              });
            }
          : null,
      borderRadius: BorderRadius.circular(6),
      child: Container(
        padding: const EdgeInsets.symmetric(vertical: 8, horizontal: 6),
        decoration: BoxDecoration(
          color: isCurrent ? const Color(0xFF263238) : Colors.transparent,
          borderRadius: BorderRadius.circular(6),
          border: Border.all(
            color: isCurrent ? const Color(0xFF1976D2) : Colors.transparent,
          ),
        ),
        child: Row(
          children: [
            Icon(icon, color: enabled ? (isCurrent ? const Color(0xFF64B5F6) : Colors.white70) : Colors.grey, size: 22),
            const SizedBox(width: 10),
            Expanded(
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Text(
                    title,
                    style: TextStyle(
                      color: enabled ? Colors.white : Colors.grey,
                      fontWeight: FontWeight.bold,
                      fontSize: 13,
                    ),
                  ),
                  const SizedBox(height: 2),
                  Text(
                    subtitle,
                    style: TextStyle(
                      color: enabled ? const Color(0xFF9E9E9E) : Colors.grey.shade700,
                      fontSize: 10,
                    ),
                  ),
                ],
              ),
            ),
            Container(
              width: 20,
              height: 20,
              decoration: BoxDecoration(
                shape: BoxShape.circle,
                border: Border.all(
                  color: isCurrent ? const Color(0xFF64B5F6) : (enabled ? Colors.grey : Colors.grey.shade800),
                  width: 2,
                ),
              ),
              child: isCurrent
                  ? Center(
                      child: Container(
                        width: 10,
                        height: 10,
                        decoration: const BoxDecoration(
                          shape: BoxShape.circle,
                          color: Color(0xFF64B5F6),
                        ),
                      ),
                    )
                  : null,
            ),
          ],
        ),
      ),
    );
  }
}
