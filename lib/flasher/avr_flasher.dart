import 'dart:async';
import 'dart:typed_data';
import '../services/serial_manager.dart';
import 'intel_hex_parser.dart';

abstract class AvrFlasherCallback {
  void onStatus(String message);
  void onProgress(int percentage, String details);
  void onSuccess(String message);
  void onError(String error);
}

class AvrFlasher {
  // STK500 Constants
  static const int stkOk              = 0x10;
  static const int stkInSync          = 0x14;
  static const int stkGetSync        = 0x30;
  static const int stkEnterProgmode  = 0x50;
  static const int stkLeaveProgmode  = 0x51;
  static const int stkLoadAddress    = 0x55;
  static const int stkProgPage       = 0x64;
  static const int syncCrcEop        = 0x20;

  static const int pageSize = 128; // ATmega328P Flash Page Size

  final SerialManager serialManager;
  final AvrFlasherCallback callback;

  final List<int> _rxBuffer = [];
  Completer<void>? _rxCompleter;
  StreamSubscription? _rawSub;
  bool _isCancelled = false;

  AvrFlasher({required this.serialManager, required this.callback});

  void cancel() {
    _isCancelled = true;
  }

  void startFlashing(Uint8List rawFirmwareBytes, int targetBaudRate) {
    _isCancelled = false;
    scheduleMicrotask(() async {
      try {
        callback.onStatus('Parsing Intel HEX / binary data...');
        final firmwareBytes = IntelHexParser.parseHexOrRaw(rawFirmwareBytes);

        if (firmwareBytes.isEmpty) {
          callback.onError('Firmware binary is empty');
          return;
        }

        callback.onStatus('Connecting & initializing Serial connection @ $targetBaudRate baud...');
        if (!serialManager.isConnected) {
          callback.onError('Serial port is not connected');
          return;
        }

        await serialManager.setBaudRate(targetBaudRate);
        await Future.delayed(const Duration(milliseconds: 100));

        // Attach listener for incoming STK500 responses
        _rxBuffer.clear();
        _rawSub?.cancel();
        _rawSub = serialManager.onRawData.listen((data) {
          _rxBuffer.addAll(data);
          if (_rxCompleter != null && !_rxCompleter!.isCompleted) {
            _rxCompleter!.complete();
          }
        });

        // 1. Hardware Reset into Arduino Bootloader (DTR/RTS)
        callback.onStatus('Resetting Arduino Nano/Uno via DTR/RTS pulse...');
        await _resetArduinoBootloader();

        // 2. Synchronize STK500 Bootloader
        callback.onStatus('Synchronizing with STK500 / Optiboot bootloader...');
        await _syncStk500();

        // 3. Enter Programming Mode
        callback.onStatus('Entering programming mode...');
        await _enterProgMode();

        // 4. Flash Pages Sequential Upload
        final totalBytes = firmwareBytes.length;
        final numPages = (totalBytes + pageSize - 1) ~/ pageSize;

        callback.onStatus('Flashing $totalBytes bytes ($numPages pages) to Arduino...');
        final startTime = DateTime.now().millisecondsSinceEpoch;

        for (int p = 0; p < numPages; p++) {
          if (_isCancelled) {
            callback.onError('Flashing cancelled by user');
            return;
          }

          final pageAddress = p * pageSize;
          final wordAddress = pageAddress ~/ 2; // STK500 uses 16-bit word addresses

          // Set target word address
          await _loadAddress(wordAddress);

          // Extract page payload (pad with 0xFF if last page is incomplete)
          final pageData = Uint8List(pageSize);
          final bytesLeft = totalBytes - pageAddress;
          final lengthToCopy = (pageSize < bytesLeft) ? pageSize : bytesLeft;
          pageData.setRange(0, lengthToCopy, firmwareBytes.sublist(pageAddress, pageAddress + lengthToCopy));
          for (int i = lengthToCopy; i < pageSize; i++) {
            pageData[i] = 0xFF;
          }

          // Program Page
          await _progPage(pageData);

          final progress = (((p + 1) / numPages) * 100).toInt();
          final elapsed = ((DateTime.now().millisecondsSinceEpoch - startTime) / 1000).toStringAsFixed(1);
          callback.onProgress(progress, 'Flashing page ${p + 1}/$numPages ($progress%) - ${elapsed}s');
        }

        // 5. Leave Programming Mode
        callback.onStatus('Leaving programming mode & rebooting Arduino...');
        await _leaveProgMode();

        await _resetArduinoBootloader();

        final totalTime = ((DateTime.now().millisecondsSinceEpoch - startTime) / 1000).toStringAsFixed(1);
        callback.onSuccess('Arduino flashing completed successfully in ${totalTime}s!');
      } catch (e) {
        callback.onError('AVR Flashing failed: $e');
      } finally {
        _rawSub?.cancel();
        _rawSub = null;
      }
    });
  }

  Future<void> _resetArduinoBootloader() async {
    // Pulse DTR/RTS to trigger ATmega328P auto-reset circuit
    await serialManager.setDtr(false);
    await serialManager.setRts(false);
    await Future.delayed(const Duration(milliseconds: 100));
    await serialManager.setDtr(true);
    await serialManager.setRts(true);
    await Future.delayed(const Duration(milliseconds: 50));
    await serialManager.setDtr(false);
    await serialManager.setRts(false);
    await Future.delayed(const Duration(milliseconds: 250));
  }

  Future<void> _syncStk500() async {
    final cmd = Uint8List.fromList([stkGetSync, syncCrcEop]);
    bool synced = false;

    for (int attempt = 0; attempt < 25; attempt++) {
      if (_isCancelled) throw Exception('Cancelled');
      await _sendCmdRaw(cmd);
      final resp = await _readStkResponse(2, 200);
      if (resp.length >= 2 && resp[0] == stkInSync && resp[1] == stkOk) {
        synced = true;
        break;
      }
      await Future.delayed(const Duration(milliseconds: 50));
    }

    if (!synced) {
      throw Exception('Failed to sync with STK500 bootloader. Check board type & baud rate (57600 vs 115200).');
    }
  }

  Future<void> _enterProgMode() async {
    final cmd = Uint8List.fromList([stkEnterProgmode, syncCrcEop]);
    await _sendCmdRaw(cmd);
    final resp = await _readStkResponse(2, 500);
    _checkResponseOk(resp, 'enterProgMode');
  }

  Future<void> _leaveProgMode() async {
    final cmd = Uint8List.fromList([stkLeaveProgmode, syncCrcEop]);
    await _sendCmdRaw(cmd);
    final resp = await _readStkResponse(2, 500);
    _checkResponseOk(resp, 'leaveProgMode');
  }

  Future<void> _loadAddress(int wordAddress) async {
    final addrLow = wordAddress & 0xFF;
    final addrHigh = (wordAddress >> 8) & 0xFF;
    final cmd = Uint8List.fromList([stkLoadAddress, addrLow, addrHigh, syncCrcEop]);
    await _sendCmdRaw(cmd);
    final resp = await _readStkResponse(2, 300);
    _checkResponseOk(resp, 'loadAddress');
  }

  Future<void> _progPage(Uint8List pageData) async {
    final cmd = <int>[];
    cmd.add(stkProgPage);
    cmd.add((pageSize >> 8) & 0xFF); // Size High
    cmd.add(pageSize & 0xFF);        // Size Low
    cmd.add(0x46);                    // Flash memory space ('F' = 0x46)
    cmd.addAll(pageData);
    cmd.add(syncCrcEop);

    await _sendCmdRaw(Uint8List.fromList(cmd));
    final resp = await _readStkResponse(2, 500);
    _checkResponseOk(resp, 'progPage');
  }

  Future<void> _sendCmdRaw(Uint8List cmd) async {
    _rxBuffer.clear();
    await serialManager.sendRaw(cmd);
  }

  Future<Uint8List> _readStkResponse(int expectedLength, int timeoutMs) async {
    final deadline = DateTime.now().millisecondsSinceEpoch + timeoutMs;
    while (_rxBuffer.length < expectedLength && DateTime.now().millisecondsSinceEpoch < deadline) {
      _rxCompleter = Completer<void>();
      final waitTime = deadline - DateTime.now().millisecondsSinceEpoch;
      if (waitTime > 0) {
        await _rxCompleter!.future.timeout(
          Duration(milliseconds: waitTime),
          onTimeout: () {},
        );
      }
    }
    final resp = Uint8List.fromList(_rxBuffer);
    _rxBuffer.clear();
    return resp;
  }

  void _checkResponseOk(Uint8List resp, String stepName) {
    if (resp.length < 2 || resp[0] != stkInSync || resp[1] != stkOk) {
      throw Exception('STK500 error during $stepName (Response: ${resp.length} bytes)');
    }
  }
}
