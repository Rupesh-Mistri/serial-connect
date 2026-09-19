import 'dart:async';
import 'dart:convert';
import 'dart:typed_data';
import 'package:file_picker/file_picker.dart';
import 'package:flutter/material.dart';
import '../flasher/avr_flasher.dart';
import '../flasher/esp32_flasher.dart';
import '../flasher/firmware_generator.dart';
import '../models/serial_transport_type.dart';
import '../services/serial_manager.dart';
import '../widgets/transport_dialog.dart';

class FlasherScreen extends StatefulWidget {
  const FlasherScreen({super.key});

  @override
  State<FlasherScreen> createState() => _FlasherScreenState();
}

class _FlasherScreenState extends State<FlasherScreen>
    implements Esp32FlasherCallback, AvrFlasherCallback {
  final SerialManager _serialManager = SerialManager();

  final List<String> _targetBoards = [
    'ESP32 / ESP8266 (SLIP)',
    'Arduino Nano (Old Bootloader - 57600)',
    'Arduino Nano / Uno (Optiboot - 115200)',
  ];

  final List<String> _flashBaudRates = [
    '921600',
    '460800',
    '230400',
    '115200',
    '57600',
    '9600',
  ];

  final List<String> _monitorBaudRates = [
    '115200',
    '9600',
    '921600',
    '460800',
    '230400',
    '57600',
    '38400',
    '19200',
    '4800',
  ];

  int _selectedBoardIndex = 0;
  String _selectedFlashBaud = '921600';
  String _selectedMonitorBaud = '115200';

  final TextEditingController _addressController =
      TextEditingController(text: '0x10000');
  final TextEditingController _txController = TextEditingController();
  final ScrollController _logScrollController = ScrollController();

  Uint8List? _selectedFirmwareBytes;
  String _selectedFileName = 'No file selected';

  bool _isFlashing = false;
  int _flashProgress = 0;
  String _progressDetails = 'Ready to flash';

  final List<String> _terminalLogs = [];

  Esp32Flasher? _esp32Flasher;
  AvrFlasher? _avrFlasher;

  late final StreamSubscription _connSub;
  late final StreamSubscription _logSub;

  @override
  void initState() {
    super.initState();

    _connSub = _serialManager.onConnectionChanged.listen((_) {
      if (mounted) setState(() {});
    });

    _logSub = _serialManager.onLog.listen((log) {
      _appendLog(log);
    });

    _loadDefaultAssetFirmware();
  }

  void _loadDefaultAssetFirmware() async {
    try {
      final bytes = await FirmwareGenerator.loadAssetFirmware();
      if (mounted) {
        setState(() {
          _selectedFirmwareBytes = bytes;
          _selectedFileName = '[Preset] esp32_readout_v1.0.bin (${bytes.length ~/ 1024} KB)';
        });
        _appendLog('SYS: Loaded built-in preset firmware: esp32_readout_v1.0.bin');
      }
    } catch (_) {
      _appendLog('SYS: Ready. Select a file (.bin/.hex) or source file.');
    }
  }

  @override
  void dispose() {
    _connSub.cancel();
    _logSub.cancel();
    _addressController.dispose();
    _txController.dispose();
    _logScrollController.dispose();
    super.dispose();
  }

  void _appendLog(String line) {
    if (!mounted) return;
    setState(() {
      _terminalLogs.add(line);
      if (_terminalLogs.length > 500) {
        _terminalLogs.removeRange(0, 100);
      }
    });

    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (_logScrollController.hasClients) {
        _logScrollController.jumpTo(_logScrollController.position.maxScrollExtent);
      }
    });
  }

  void _onBoardChanged(int index) {
    setState(() {
      _selectedBoardIndex = index;
      if (index == 0) {
        _addressController.text = '0x10000';
        _selectedFlashBaud = '921600';
      } else if (index == 1) {
        _addressController.text = '0x0000';
        _selectedFlashBaud = '57600';
      } else {
        _addressController.text = '0x0000';
        _selectedFlashBaud = '115200';
      }
    });
    _appendLog('SYS: Target Board changed to: ${_targetBoards[index]}');
  }

  Future<void> _pickFirmwareFile() async {
    try {
      final files = await FilePicker.pickFiles(type: FileType.any);

      if (files.isNotEmpty) {
        final file = files.first;
        final bytes = await file.readAsBytes();
        setState(() {
          _selectedFirmwareBytes = bytes;
          _selectedFileName = '${file.name} (${bytes.length ~/ 1024} KB)';
        });
        _appendLog('SYS: Firmware loaded: ${file.name} (${bytes.length} bytes)');
        if (mounted) {
          ScaffoldMessenger.of(context).showSnackBar(
            SnackBar(content: Text('Loaded ${file.name} (${bytes.length ~/ 1024} KB)')),
          );
        }
      }
    } catch (e) {
      _appendLog('ERR: File pick failed: $e');
    }
  }

  Future<void> _convertSourceFile() async {
    try {
      final files = await FilePicker.pickFiles(type: FileType.any);

      if (files.isNotEmpty) {
        final file = files.first;
        final bytes = await file.readAsBytes();
        final srcCode = utf8.decode(bytes, allowMalformed: true);
        final binBytes = await FirmwareGenerator.convertSourceToFirmware(file.name, srcCode);
        final saved = await FirmwareGenerator.saveGeneratedBinFile(file.name, binBytes);

        setState(() {
          _selectedFirmwareBytes = binBytes;
          _selectedFileName = '⚡ Converted: ${file.name} -> firmware.bin (${binBytes.length ~/ 1024} KB)';
        });
        _appendLog('SYS: Converted source file "${file.name}" to binary on-device (${binBytes.length} bytes)');
        if (saved != null) {
          _appendLog('SYS: Saved unique binary to: ${saved.path}');
        }
        if (mounted) {
          ScaffoldMessenger.of(context).showSnackBar(
            const SnackBar(content: Text('Source file converted to binary on-device!')),
          );
        }
      }
    } catch (e) {
      _appendLog('ERR: Source conversion failed: $e');
    }
  }

  void _startFlashing() {
    if (_isFlashing) {
      _esp32Flasher?.cancel();
      _avrFlasher?.cancel();
      return;
    }

    if (!_serialManager.isConnected) {
      ScaffoldMessenger.of(context).showSnackBar(
        const SnackBar(content: Text('Please connect Serial device first')),
      );
      return;
    }

    if (_selectedFirmwareBytes == null || _selectedFirmwareBytes!.isEmpty) {
      ScaffoldMessenger.of(context).showSnackBar(
        const SnackBar(content: Text('Please select a valid firmware file (.bin / .hex)')),
      );
      return;
    }

    int flashAddress = 0x10000;
    final addrStr = _addressController.text.trim();
    try {
      if (addrStr.toLowerCase().startsWith('0x')) {
        flashAddress = int.parse(addrStr.substring(2), radix: 16);
      } else {
        flashAddress = int.parse(addrStr, radix: 16);
      }
    } catch (_) {
      ScaffoldMessenger.of(context).showSnackBar(
        const SnackBar(content: Text('Invalid flash address offset (e.g. 0x10000)')),
      );
      return;
    }

    final flashBaud = int.tryParse(_selectedFlashBaud) ?? 115200;

    setState(() {
      _isFlashing = true;
      _flashProgress = 0;
      _progressDetails = 'Initializing flash...';
    });

    _appendLog('FLASHER: Target Board: ${_targetBoards[_selectedBoardIndex]}');
    _appendLog('FLASHER: File: $_selectedFileName');
    _appendLog('FLASHER: Flash Offset: 0x${flashAddress.toRadixString(16)} | Baud Rate: $flashBaud');

    if (_selectedBoardIndex == 0) {
      // ESP32 SLIP
      _esp32Flasher = Esp32Flasher(serialManager: _serialManager, callback: this);
      _esp32Flasher!.startFlashing(_selectedFirmwareBytes!, flashAddress, flashBaud);
    } else {
      // Arduino AVR STK500
      _avrFlasher = AvrFlasher(serialManager: _serialManager, callback: this);
      _avrFlasher!.startFlashing(_selectedFirmwareBytes!, flashBaud);
    }
  }

  // Flasher Callbacks
  @override
  void onStatus(String message) {
    if (mounted) {
      setState(() {
        _progressDetails = message;
      });
      _appendLog('FLASHER: $message');
    }
  }

  @override
  void onProgress(int percentage, String details) {
    if (mounted) {
      setState(() {
        _flashProgress = percentage;
        _progressDetails = details;
      });
    }
  }

  @override
  void onSuccess(String message) {
    if (mounted) {
      setState(() {
        _isFlashing = false;
        _flashProgress = 100;
        _progressDetails = 'Complete! Chip rebooted.';
      });
      _appendLog('FLASHER SUCCESS: $message');
      ScaffoldMessenger.of(context).showSnackBar(
        const SnackBar(backgroundColor: Colors.green, content: Text('Flashing Successful!')),
      );
    }
  }

  @override
  void onError(String error) {
    if (mounted) {
      setState(() {
        _isFlashing = false;
        _progressDetails = 'Error: $error';
      });
      _appendLog('FLASHER ERROR: $error');
      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(backgroundColor: Colors.red, content: Text('Flashing Failed: $error')),
      );
    }
  }

  void _sendSerialCommand() {
    final cmd = _txController.text.trim();
    if (cmd.isNotEmpty && _serialManager.isConnected) {
      _serialManager.send('$cmd\r\n');
      _txController.clear();
    }
  }

  @override
  Widget build(BuildContext context) {
    final isConnected = _serialManager.isConnected;

    return Scaffold(
      backgroundColor: const Color(0xFF1F1F1F),
      appBar: AppBar(
        backgroundColor: const Color(0xFF1F1F1F),
        elevation: 0,
        leading: IconButton(
          icon: const Icon(Icons.arrow_back, color: Colors.white),
          onPressed: () => Navigator.pop(context),
        ),
        title: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            const Text(
              'Microcontroller Flasher & Monitor',
              style: TextStyle(color: Colors.white, fontSize: 15, fontWeight: FontWeight.bold),
            ),
            Text(
              isConnected ? 'Connected (${_serialManager.driverName})' : 'Status: Disconnected',
              style: TextStyle(
                color: isConnected ? const Color(0xFF00E676) : const Color(0xFF9E9E9E),
                fontSize: 11,
              ),
            ),
          ],
        ),
        actions: [
          IconButton(
            icon: Icon(
              _serialManager.selectedType == SerialTransportType.usbOtg
                  ? Icons.usb
                  : (_serialManager.selectedType == SerialTransportType.ble
                      ? Icons.bluetooth
                      : (_serialManager.selectedType == SerialTransportType.tcp
                          ? Icons.wifi
                          : Icons.devices)),
              color: const Color(0xFF64B5F6),
            ),
            tooltip: 'Change Transport',
            onPressed: () => TransportDialog.show(context),
          ),
          Padding(
            padding: const EdgeInsets.only(right: 8.0),
            child: Center(
              child: SizedBox(
                height: 34,
                child: ElevatedButton(
                  style: ElevatedButton.styleFrom(
                    backgroundColor: isConnected ? const Color(0xFFD32F2F) : const Color(0xFF1565C0),
                    foregroundColor: Colors.white,
                    padding: const EdgeInsets.symmetric(horizontal: 10),
                  ),
                  onPressed: () {
                    if (isConnected) {
                      _serialManager.disconnect();
                    } else {
                      _serialManager.connect(baudRate: int.tryParse(_selectedMonitorBaud) ?? 115200);
                    }
                  },
                  child: Text(isConnected ? 'Disconnect' : 'Connect', style: const TextStyle(fontSize: 11)),
                ),
              ),
            ),
          ),
        ],
      ),
      body: SingleChildScrollView(
        padding: const EdgeInsets.all(12),
        child: Column(
          children: [
            // Card 1: Firmware Flashing Section
            Container(
              decoration: BoxDecoration(
                color: const Color(0xFF1E1E1E),
                borderRadius: BorderRadius.circular(8),
                border: Border.all(color: const Color(0xFF333333)),
              ),
              padding: const EdgeInsets.all(14),
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Row(
                    mainAxisAlignment: MainAxisAlignment.spaceBetween,
                    children: [
                      const Text(
                        'Firmware Flasher (USB / BLE / TCP)',
                        style: TextStyle(color: Color(0xFF90CAF9), fontSize: 14, fontWeight: FontWeight.bold),
                      ),
                      Container(
                        padding: const EdgeInsets.symmetric(horizontal: 6, vertical: 2),
                        decoration: BoxDecoration(
                          color: const Color(0xFF263238),
                          borderRadius: BorderRadius.circular(4),
                        ),
                        child: Text(
                          _serialManager.selectedType.label,
                          style: const TextStyle(color: Color(0xFF64B5F6), fontSize: 10, fontWeight: FontWeight.bold),
                        ),
                      ),
                    ],
                  ),
                  const SizedBox(height: 10),

                  // Target Board Dropdown
                  const Text('Target Microcontroller Board', style: TextStyle(color: Color(0xFF9E9E9E), fontSize: 10)),
                  const SizedBox(height: 4),
                  Container(
                    padding: const EdgeInsets.symmetric(horizontal: 10),
                    decoration: BoxDecoration(
                      color: const Color(0xFF2C2C2C),
                      borderRadius: BorderRadius.circular(6),
                    ),
                    child: DropdownButtonHideUnderline(
                      child: DropdownButton<int>(
                        isExpanded: true,
                        value: _selectedBoardIndex,
                        dropdownColor: const Color(0xFF2C2C2C),
                        items: List.generate(
                          _targetBoards.length,
                          (i) => DropdownMenuItem(
                            value: i,
                            child: Text(_targetBoards[i], style: const TextStyle(color: Colors.white, fontSize: 12)),
                          ),
                        ),
                        onChanged: (val) {
                          if (val != null) _onBoardChanged(val);
                        },
                      ),
                    ),
                  ),
                  const SizedBox(height: 10),

                  // File Selection Buttons Row
                  Row(
                    children: [
                      Expanded(
                        child: ElevatedButton.icon(
                          onPressed: _pickFirmwareFile,
                          icon: const Icon(Icons.folder_open, size: 14),
                          label: const Text('📁 Select .bin/.hex', style: TextStyle(fontSize: 11)),
                          style: ElevatedButton.styleFrom(
                            backgroundColor: const Color(0xFF37474F),
                            foregroundColor: Colors.white,
                            padding: const EdgeInsets.symmetric(vertical: 10),
                          ),
                        ),
                      ),
                      const SizedBox(width: 8),
                      Expanded(
                        flex: 1,
                        child: ElevatedButton.icon(
                          onPressed: _convertSourceFile,
                          icon: const Icon(Icons.flash_on, size: 14),
                          label: const Text('⚡ Convert .cpp/.ino', style: TextStyle(fontSize: 11)),
                          style: ElevatedButton.styleFrom(
                            backgroundColor: const Color(0xFF0277BD),
                            foregroundColor: Colors.white,
                            padding: const EdgeInsets.symmetric(vertical: 10),
                          ),
                        ),
                      ),
                    ],
                  ),
                  const SizedBox(height: 8),

                  // Selected File Display
                  Text(
                    _selectedFileName,
                    style: const TextStyle(color: Color(0xFFB0BEC5), fontSize: 11),
                    maxLines: 2,
                    overflow: TextOverflow.ellipsis,
                  ),
                  const SizedBox(height: 12),

                  // Config Row: Flash Address & Flash Baud
                  Row(
                    children: [
                      Expanded(
                        child: Column(
                          crossAxisAlignment: CrossAxisAlignment.start,
                          children: [
                            const Text('Flash Address Offset', style: TextStyle(color: Color(0xFF9E9E9E), fontSize: 10)),
                            const SizedBox(height: 4),
                            SizedBox(
                              height: 38,
                              child: TextField(
                                controller: _addressController,
                                style: const TextStyle(color: Colors.white, fontSize: 12),
                                decoration: const InputDecoration(
                                  filled: true,
                                  fillColor: Color(0xFF2C2C2C),
                                  border: OutlineInputBorder(borderSide: BorderSide.none),
                                  contentPadding: EdgeInsets.symmetric(horizontal: 10),
                                ),
                              ),
                            ),
                          ],
                        ),
                      ),
                      const SizedBox(width: 10),
                      Expanded(
                        child: Column(
                          crossAxisAlignment: CrossAxisAlignment.start,
                          children: [
                            const Text('Flash Baud Rate', style: TextStyle(color: Color(0xFF9E9E9E), fontSize: 10)),
                            const SizedBox(height: 4),
                            Container(
                              height: 38,
                              padding: const EdgeInsets.symmetric(horizontal: 10),
                              decoration: BoxDecoration(
                                color: const Color(0xFF2C2C2C),
                                borderRadius: BorderRadius.circular(4),
                              ),
                              child: DropdownButtonHideUnderline(
                                child: DropdownButton<String>(
                                  isExpanded: true,
                                  value: _selectedFlashBaud,
                                  dropdownColor: const Color(0xFF2C2C2C),
                                  items: _flashBaudRates
                                      .map((b) => DropdownMenuItem(
                                            value: b,
                                            child: Text(b, style: const TextStyle(color: Colors.white, fontSize: 12)),
                                          ))
                                      .toList(),
                                  onChanged: (val) {
                                    if (val != null) setState(() => _selectedFlashBaud = val);
                                  },
                                ),
                              ),
                            ),
                          ],
                        ),
                      ),
                    ],
                  ),
                  const SizedBox(height: 12),

                  // Progress Bar & Action Button
                  ClipRRect(
                    borderRadius: BorderRadius.circular(4),
                    child: LinearProgressIndicator(
                      value: _flashProgress / 100.0,
                      backgroundColor: const Color(0xFF2C2C2C),
                      valueColor: const AlwaysStoppedAnimation<Color>(Color(0xFF64B5F6)),
                      minHeight: 8,
                    ),
                  ),
                  const SizedBox(height: 8),

                  Row(
                    children: [
                      Expanded(
                        child: Text(
                          _progressDetails,
                          style: const TextStyle(color: Color(0xFFB0BEC5), fontSize: 11),
                        ),
                      ),
                      ElevatedButton(
                        style: ElevatedButton.styleFrom(
                          backgroundColor: _isFlashing ? const Color(0xFFD32F2F) : const Color(0xFF2E7D32),
                          foregroundColor: Colors.white,
                          padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 10),
                        ),
                        onPressed: _startFlashing,
                        child: Text(
                          _isFlashing ? 'Cancel' : 'Upload / Flash',
                          style: const TextStyle(fontSize: 12, fontWeight: FontWeight.bold),
                        ),
                      ),
                    ],
                  ),
                ],
              ),
            ),
            const SizedBox(height: 14),

            // Card 2: USB Serial Terminal & Monitor
            Container(
              height: 320,
              decoration: BoxDecoration(
                color: const Color(0xFF1E1E1E),
                borderRadius: BorderRadius.circular(8),
                border: Border.all(color: const Color(0xFF333333)),
              ),
              padding: const EdgeInsets.all(12),
              child: Column(
                children: [
                  Row(
                    children: [
                      const Text(
                        'Serial Terminal Monitor',
                        style: TextStyle(color: Color(0xFFA5D6A7), fontSize: 13, fontWeight: FontWeight.bold),
                      ),
                      const Spacer(),
                      // Monitor Baud Dropdown
                      Container(
                        height: 28,
                        padding: const EdgeInsets.symmetric(horizontal: 6),
                        decoration: BoxDecoration(
                          color: const Color(0xFF2C2C2C),
                          borderRadius: BorderRadius.circular(4),
                        ),
                        child: DropdownButtonHideUnderline(
                          child: DropdownButton<String>(
                            value: _selectedMonitorBaud,
                            dropdownColor: const Color(0xFF2C2C2C),
                            items: _monitorBaudRates
                                .map((b) => DropdownMenuItem(
                                      value: b,
                                      child: Text(b, style: const TextStyle(color: Colors.white, fontSize: 11)),
                                    ))
                                .toList(),
                            onChanged: (val) {
                              if (val != null) {
                                setState(() => _selectedMonitorBaud = val);
                                final baud = int.tryParse(val) ?? 115200;
                                _serialManager.setBaudRate(baud);
                              }
                            },
                          ),
                        ),
                      ),
                      const SizedBox(width: 8),
                      TextButton(
                        onPressed: () {
                          setState(() {
                            _terminalLogs.clear();
                          });
                        },
                        child: const Text('Clear', style: TextStyle(color: Color(0xFF64B5F6), fontSize: 11, fontWeight: FontWeight.bold)),
                      ),
                    ],
                  ),
                  const SizedBox(height: 6),

                  // Monospace Log Screen
                  Expanded(
                    child: Container(
                      width: double.infinity,
                      padding: const EdgeInsets.all(8),
                      decoration: BoxDecoration(
                        color: const Color(0xFF0A0A0A),
                        borderRadius: BorderRadius.circular(4),
                      ),
                      child: ListView.builder(
                        controller: _logScrollController,
                        itemCount: _terminalLogs.length,
                        itemBuilder: (ctx, i) {
                          final log = _terminalLogs[i];
                          Color color = const Color(0xFF00FF66);
                          if (log.startsWith('TX:')) color = const Color(0xFF00E5FF);
                          if (log.startsWith('SYS:') || log.startsWith('FLASHER:')) color = const Color(0xFFFFD600);
                          if (log.startsWith('ERR:')) color = const Color(0xFFFF5252);
                          return Text(
                            log,
                            style: TextStyle(fontFamily: 'monospace', fontSize: 11, color: color),
                          );
                        },
                      ),
                    ),
                  ),
                  const SizedBox(height: 6),

                  // Serial Command TX Row
                  Row(
                    children: [
                      Expanded(
                        child: SizedBox(
                          height: 36,
                          child: TextField(
                            controller: _txController,
                            style: const TextStyle(fontFamily: 'monospace', color: Colors.white, fontSize: 12),
                            decoration: const InputDecoration(
                              hintText: 'Type serial command...',
                              hintStyle: TextStyle(color: Color(0xFF757575), fontSize: 12),
                              filled: true,
                              fillColor: Color(0xFF2C2C2C),
                              border: OutlineInputBorder(borderSide: BorderSide.none),
                              contentPadding: EdgeInsets.symmetric(horizontal: 10),
                            ),
                            onSubmitted: (_) => _sendSerialCommand(),
                          ),
                        ),
                      ),
                      const SizedBox(width: 6),
                      SizedBox(
                        height: 36,
                        child: ElevatedButton(
                          style: ElevatedButton.styleFrom(
                            backgroundColor: const Color(0xFF0288D1),
                            foregroundColor: Colors.white,
                            padding: const EdgeInsets.symmetric(horizontal: 14),
                          ),
                          onPressed: _sendSerialCommand,
                          child: const Text('Send', style: TextStyle(fontSize: 11)),
                        ),
                      ),
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
