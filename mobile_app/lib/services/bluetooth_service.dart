import 'dart:convert';
import 'dart:typed_data';
import 'package:flutter_bluetooth_serial/flutter_bluetooth_serial.dart';

class BluetoothService {
  BluetoothConnection? _connection;
  bool _isConnected = false;

  bool get isConnected => _isConnected;

  Future<bool> connectToDevice(String targetDeviceName) async {
    try {
      // Get a list of paired devices
      List<BluetoothDevice> devices = await FlutterBluetoothSerial.instance.getBondedDevices();
      
      BluetoothDevice? targetDevice;
      for (BluetoothDevice device in devices) {
        if (device.name == targetDeviceName) {
          targetDevice = device;
          break;
        }
      }

      if (targetDevice == null) {
        print("Device $targetDeviceName not found among paired devices.");
        return false;
      }

      _connection = await BluetoothConnection.toAddress(targetDevice.address);
      _isConnected = true;
      print('Connected to $targetDeviceName');
      
      _connection!.input!.listen((Uint8List data) {
        print('Data incoming: ${ascii.decode(data)}');
      }).onDone(() {
        print('Disconnected by remote request');
        _isConnected = false;
      });

      return true;
    } catch (e) {
      print('Cannot connect, exception occured: $e');
      _isConnected = false;
      return false;
    }
  }

  void sendSignal(String signal) {
    if (_isConnected && _connection != null) {
      try {
        _connection!.output.add(ascii.encode(signal));
        _connection!.output.allSent;
        print("Sent signal: $signal");
      } catch (e) {
        print("Error sending signal: $e");
      }
    } else {
      print("Not connected, cannot send signal.");
    }
  }

  void dispose() {
    if (_isConnected) {
      _connection?.dispose();
      _connection = null;
      _isConnected = false;
    }
  }
}
