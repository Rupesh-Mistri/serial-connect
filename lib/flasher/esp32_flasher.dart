import 'dart:async';
import 'dart:typed_data';
import '../services/serial_manager.dart';

abstract class Esp32FlasherCallback {
  void onStatus(String message);
  void onProgress(int percentage, String details);
  void onSuccess(String message);
  void onError(String error);
}

class Esp32Flasher {
  static const int slipEnd = 0xC0;
  static const int slipEsc = 0xDB;
  static const int slipEscEnd = 0xDC;
  static const int slipEscEsc = 0xDD;

  // ESP Bootloader Opcodes
  static const int espFlashBegin     = 0x02;
  static const int espFlashData      = 0x03;
  static const int espFlashEnd       = 0x04;
  static const int espSync           = 0x08;
  static const int espSpiAttach      = 0x0D;
  static const int espChangeBaudrate = 0x0F;

  static const int packetSize = 1024;

  final SerialManager serialManager;
  final Esp32FlasherCallback callback;

  final List<int> _rxBuffer = [];
  Completer<void>? _rxCompleter;
  StreamSubscription? _rawSub;
  bool _isCancelled = false;

  Esp32Flasher({required this.serialManager, required this.callback});

  void cancel() {
    _isCancelled = true;
  }

  void startFlashing(Uint8List firmwareBytes, int flashAddress, int flashBaudRate) {
    _isCancelled = false;
    scheduleMicrotask(() async {
      try {
        callback.onStatus('Connecting & initializing Serial connection...');
        if (!serialManager.isConnected) {
          callback.onError('Serial port is not connected');
          return;
        }

        // 1. Initial sync baud rate (115200)
        await serialManager.setBaudRate(115200);
        await Future.delayed(const Duration(milliseconds: 100));

        // Attach raw byte listener
        _rxBuffer.clear();
        _rawSub?.cancel();
        _rawSub = serialManager.onRawData.listen((data) {
          _rxBuffer.addAll(data);
          if (_rxCompleter != null && !_rxCompleter!.isCompleted) {
            _rxCompleter!.complete();
          }
        });

        // 2. Hardware Auto-Reset into Bootloader Mode
        callback.onStatus('Resetting target into Bootloader mode (RTS/DTR)...');
        await _resetIntoBootloader();

        // 3. Sync with ESP32 Bootloader
        callback.onStatus('Synchronizing with ESP32 bootloader...');
        await _syncBootloader();

        // 4. Attach SPI Flash
        callback.onStatus('Attaching SPI flash...');
        try {
          await _spiAttach();
        } catch (_) {}

        // 5. Change Baud Rate if selected (e.g. 921600)
        if (flashBaudRate > 115200) {
          callback.onStatus('Setting flash baud rate to $flashBaudRate...');
          try {
            await _changeBaudRate(flashBaudRate);
          } catch (e) {
            callback.onStatus('Baud rate warning: $e, continuing at 115200 baud.');
            await serialManager.setBaudRate(115200);
            await Future.delayed(const Duration(milliseconds: 100));
          }
        }

        // 6. Flash Begin (Erase)
        final totalSize = firmwareBytes.length;
        final numBlocks = (totalSize + packetSize - 1) ~/ packetSize;

        callback.onStatus('Beginning flash erase ($totalSize bytes @ 0x${flashAddress.toRadixString(16)})...');
        await _flashBegin(totalSize, numBlocks, packetSize, flashAddress);

        // 7. Write flash blocks sequentially
        callback.onStatus('Flashing firmware blocks...');
        final startTime = DateTime.now().millisecondsSinceEpoch;

        for (int i = 0; i < numBlocks; i++) {
          if (_isCancelled) {
            callback.onError('Flashing cancelled by user');
            return;
          }

          final blockOffset = i * packetSize;
          final length = (packetSize < totalSize - blockOffset) ? packetSize : (totalSize - blockOffset);
          final block = Uint8List(packetSize);
          block.fillRange(0, packetSize, 0xFF); // Pad with 0xFF
          block.setRange(0, length, firmwareBytes.sublist(blockOffset, blockOffset + length));

          await _flashData(block, i);

          final progress = (((i + 1) / numBlocks) * 100).toInt();
          final elapsed = (DateTime.now().millisecondsSinceEpoch - startTime).clamp(1, 999999999);
          final bytesSent = (i + 1) * packetSize;
          final kbps = (bytesSent / 1024.0) / (elapsed / 1000.0);
          final details = '$progress% (${bytesSent ~/ 1024} / ${totalSize ~/ 1024} KB - ${kbps.toStringAsFixed(1)} KB/s)';
          callback.onProgress(progress, details);
        }

        // 8. Finish flashing & Reboot
        callback.onStatus('Finalizing flash & resetting chip...');
        await _flashEnd(true);

        await _resetIntoAppMode();
        callback.onSuccess('Firmware flashed successfully ($totalSize bytes written)!');
      } catch (e) {
        callback.onError('Flashing failed: $e');
      } finally {
        _rawSub?.cancel();
        _rawSub = null;
      }
    });
  }

  Future<void> _resetIntoBootloader() async {
    await serialManager.setRts(true);
    await serialManager.setDtr(false);
    await Future.delayed(const Duration(milliseconds: 100));

    await serialManager.setDtr(true);
    await serialManager.setRts(false);
    await Future.delayed(const Duration(milliseconds: 150));

    await serialManager.setDtr(false);
    await Future.delayed(const Duration(milliseconds: 100));
  }

  Future<void> _resetIntoAppMode() async {
    await serialManager.setDtr(false);
    await serialManager.setRts(true);
    await Future.delayed(const Duration(milliseconds: 100));
    await serialManager.setRts(false);
    await Future.delayed(const Duration(milliseconds: 100));
  }

  Future<void> _syncBootloader() async {
    final syncData = Uint8List(36);
    syncData[0] = 0x07;
    syncData[1] = 0x07;
    syncData[2] = 0x12;
    syncData[3] = 0x20;
    for (int i = 4; i < 36; i++) {
      syncData[i] = 0x55;
    }

    bool synced = false;
    for (int attempt = 0; attempt < 12; attempt++) {
      if (_isCancelled) throw Exception('Operation cancelled');
      try {
        await _sendCommand(espSync, syncData, 0, 400);
        synced = true;
        break;
      } catch (_) {
        await Future.delayed(const Duration(milliseconds: 100));
      }
    }

    if (!synced) {
      throw Exception('Failed to sync with ESP32 bootloader. Check connection or hold BOOT button.');
    }

    await _drainRxBuffer(200);
  }

  Future<void> _spiAttach() async {
    final data = Uint8List(8);
    await _sendCommand(espSpiAttach, data, 0, 3000);
  }

  Future<void> _changeBaudRate(int newBaud) async {
    final data = Uint8List(8);
    _writeInt32(data, 0, newBaud);
    _writeInt32(data, 4, 0);

    await _sendCommand(espChangeBaudrate, data, 0, 2000);
    await serialManager.setBaudRate(newBaud);
    await Future.delayed(const Duration(milliseconds: 100));
    await _drainRxBuffer(100);
  }

  Future<void> _flashBegin(int totalSize, int numBlocks, int blockSize, int offset) async {
    final data = Uint8List(16);
    _writeInt32(data, 0, totalSize);
    _writeInt32(data, 4, numBlocks);
    _writeInt32(data, 8, blockSize);
    _writeInt32(data, 12, offset);

    await _sendCommand(espFlashBegin, data, 0, 60000);
  }

  Future<void> _flashData(Uint8List blockData, int sequenceNumber) async {
    final data = Uint8List(16 + blockData.length);
    _writeInt32(data, 0, blockData.length);
    _writeInt32(data, 4, sequenceNumber);
    _writeInt32(data, 8, 0);
    _writeInt32(data, 12, 0);
    data.setRange(16, 16 + blockData.length, blockData);

    final checksum = _calculateChecksum(blockData);
    await _sendCommand(espFlashData, data, checksum, 10000);
  }

  Future<void> _flashEnd(bool reboot) async {
    final data = Uint8List(4);
    _writeInt32(data, 0, reboot ? 0 : 1);
    await _sendCommand(espFlashEnd, data, 0, 3000);
  }

  Future<void> _drainRxBuffer(int waitMs) async {
    final deadline = DateTime.now().millisecondsSinceEpoch + waitMs;
    while (DateTime.now().millisecondsSinceEpoch < deadline) {
      if (_rxBuffer.isNotEmpty) {
        _rxBuffer.clear();
      }
      await Future.delayed(const Duration(milliseconds: 40));
    }
  }

  Future<void> _sendCommand(int cmd, Uint8List data, int checksum, int timeoutMs) async {
    final frame = _buildSlipCommand(cmd, data, checksum);
    await serialManager.sendRaw(frame);
    final response = await _readResponseForCommand(cmd, timeoutMs);

    final error = response[response.length - 1];
    if (error != 0) {
      throw Exception('ESP Bootloader returned error code: 0x${error.toRadixString(16)}');
    }
  }

  Future<Uint8List> _readResponseForCommand(int expectedCmd, int timeoutMs) async {
    final deadline = DateTime.now().millisecondsSinceEpoch + timeoutMs;
    while (DateTime.now().millisecondsSinceEpoch < deadline) {
      final remaining = deadline - DateTime.now().millisecondsSinceEpoch;
      if (remaining <= 0) break;

      final response = await _readSingleSlipFrame(remaining);
      if (response.length >= 8 && response[0] == 0x01) {
        if (response[1] == expectedCmd) {
          return response;
        }
      }
    }
    throw Exception('Response timeout ($timeoutMs ms) for command 0x${expectedCmd.toRadixString(16)}');
  }

  Future<Uint8List> _readSingleSlipFrame(int timeoutMs) async {
    final deadline = DateTime.now().millisecondsSinceEpoch + timeoutMs;

    while (DateTime.now().millisecondsSinceEpoch < deadline) {
      if (_rxBuffer.isEmpty) {
        _rxCompleter = Completer<void>();
        final waitTime = deadline - DateTime.now().millisecondsSinceEpoch;
        if (waitTime > 0) {
          await _rxCompleter!.future.timeout(
            Duration(milliseconds: waitTime),
            onTimeout: () {},
          );
        }
      }

      if (_rxBuffer.isEmpty) continue;

      int frameStart = -1;
      bool escapeNext = false;
      final packet = <int>[];

      for (int i = 0; i < _rxBuffer.length; i++) {
        final b = _rxBuffer[i];
        if (b == slipEnd) {
          if (frameStart != -1 && packet.isNotEmpty) {
            final frameEnd = i;
            _rxBuffer.removeRange(0, frameEnd + 1);
            return Uint8List.fromList(packet);
          } else {
            frameStart = i;
            packet.clear();
          }
        } else if (frameStart != -1) {
          if (escapeNext) {
            if (b == slipEscEnd) {
              packet.add(slipEnd);
            } else if (b == slipEscEsc) {
              packet.add(slipEsc);
            } else {
              packet.add(b);
            }
            escapeNext = false;
          } else if (b == slipEsc) {
            escapeNext = true;
          } else {
            packet.add(b);
          }
        }
      }

      final waitTime = deadline - DateTime.now().millisecondsSinceEpoch;
      if (waitTime > 0) {
        await Future.delayed(const Duration(milliseconds: 30));
      }
    }
    throw Exception('SLIP frame timeout ($timeoutMs ms)');
  }

  Uint8List _buildSlipCommand(int cmd, Uint8List data, int checksum) {
    final body = <int>[];
    final dataLen = data.length;

    body.add(0x00); // Direction: Request
    body.add(cmd);
    body.add(dataLen & 0xFF);
    body.add((dataLen >> 8) & 0xFF);

    body.add(checksum & 0xFF);
    body.add((checksum >> 8) & 0xFF);
    body.add((checksum >> 16) & 0xFF);
    body.add((checksum >> 24) & 0xFF);

    if (dataLen > 0) {
      body.addAll(data);
    }

    // Wrap body into SLIP packet
    final slip = <int>[];
    slip.add(slipEnd);
    for (final b in body) {
      if (b == slipEnd) {
        slip.add(slipEsc);
        slip.add(slipEscEnd);
      } else if (b == slipEsc) {
        slip.add(slipEsc);
        slip.add(slipEscEsc);
      } else {
        slip.add(b);
      }
    }
    slip.add(slipEnd);
    return Uint8List.fromList(slip);
  }

  int _calculateChecksum(Uint8List data) {
    int checksum = 0xEF;
    for (final b in data) {
      checksum ^= b;
    }
    return checksum;
  }

  void _writeInt32(Uint8List buffer, int offset, int value) {
    buffer[offset]     = value & 0xFF;
    buffer[offset + 1] = (value >> 8) & 0xFF;
    buffer[offset + 2] = (value >> 16) & 0xFF;
    buffer[offset + 3] = (value >> 24) & 0xFF;
  }
}
