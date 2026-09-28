import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_blue_plus/flutter_blue_plus.dart';
import 'package:geolocator/geolocator.dart';
import 'package:permission_handler/permission_handler.dart';
import 'package:shared_preferences/shared_preferences.dart';

const targetDeviceName = 'SOS_ESP32';
const serviceUuid = '8ab8a002-2f4c-4a6e-9f9e-6f1e2b3c4d5a';
const characteristicUuid = '8ab8a001-2f4c-4a6e-9f9e-6f1e2b3c4d5a';

void main() => runApp(const SosGuardianApp());

class SosGuardianApp extends StatelessWidget {
  const SosGuardianApp({super.key});
  @override
  Widget build(BuildContext context) => MaterialApp(
    debugShowCheckedModeBanner: false,
    title: 'SOS Guardian',
    theme: ThemeData(colorScheme: ColorScheme.fromSeed(seedColor: Colors.red), useMaterial3: true),
    home: const SosHomePage(),
  );
}

class SosHomePage extends StatefulWidget {
  const SosHomePage({super.key});
  @override State<SosHomePage> createState() => _SosHomePageState();
}

class _SosHomePageState extends State<SosHomePage> {
  final phone = TextEditingController();
  BluetoothDevice? device;
  BluetoothCharacteristic? characteristic;
  StreamSubscription<List<ScanResult>>? scanSub;
  StreamSubscription<BluetoothConnectionState>? connectionSub;
  StreamSubscription<List<int>>? notifySub;
  bool scanning = false, connected = false, emergencyRunning = false;
  String status = 'Ready';
  String location = 'Location not acquired yet';
  String lastAlarm = 'None';

  @override void initState() { super.initState(); _loadPhone(); }

  Future<void> _loadPhone() async {
    final p = await SharedPreferences.getInstance();
    phone.text = p.getString('caregiver_phone') ?? '';
  }

  Future<void> _savePhone() async {
    if (phone.text.trim().isEmpty) return _show('Enter a caregiver phone number.');
    final p = await SharedPreferences.getInstance();
    await p.setString('caregiver_phone', phone.text.trim());
    _show('Caregiver number saved.');
  }

  Future<bool> _permissions() async {
    final list = <Permission>[Permission.bluetoothScan, Permission.bluetoothConnect, Permission.location];
    if (Platform.isAndroid) list.addAll([Permission.sms, Permission.phone]);
    final r = await list.request();
    return (r[Permission.location]?.isGranted ?? false) &&
      (!Platform.isAndroid || ((r[Permission.bluetoothScan]?.isGranted ?? false) && (r[Permission.bluetoothConnect]?.isGranted ?? false)));
  }

  Future<void> _scan() async {
    if (!await _permissions()) return _show('Required permissions were not granted.');
    await scanSub?.cancel();
    setState(() { scanning = true; status = 'Scanning for $targetDeviceName...'; device = null; });
    scanSub = FlutterBluePlus.scanResults.listen((results) async {
      for (final r in results) {
        if (r.device.platformName.trim() == targetDeviceName) {
          await FlutterBluePlus.stopScan();
          await scanSub?.cancel();
          if (!mounted) return;
          setState(() { scanning = false; device = r.device; status = '$targetDeviceName found'; });
          _connect(r.device);
          return;
        }
      }
    });
    try {
      await FlutterBluePlus.startScan(timeout: const Duration(seconds: 15));
      await Future.delayed(const Duration(seconds: 15));
      if (mounted && scanning) setState(() { scanning = false; status = device == null ? '$targetDeviceName not found' : status; });
    } catch (e) {
      if (mounted) setState(() { scanning = false; status = 'Scan error: $e'; });
    }
  }

  Future<void> _connect(BluetoothDevice d) async {
    await connectionSub?.cancel();
    connectionSub = d.connectionState.listen((s) async {
      if (!mounted) return;
      if (s == BluetoothConnectionState.connected) {
        setState(() { connected = true; status = 'Connected to $targetDeviceName'; });
        await _discover(d);
      } else if (s == BluetoothConnectionState.disconnected) {
        setState(() { connected = false; characteristic = null; status = 'Disconnected'; });
      }
    });
    try {
      await d.connect(timeout: const Duration(seconds: 12));
    } catch (e) {
      if (mounted) setState(() { connected = false; status = 'Connection failed: $e'; });
    }
  }

  Future<void> _discover(BluetoothDevice d) async {
    try {
      final services = await d.discoverServices();
      for (final s in services) {
        if (s.uuid.str.toLowerCase() == serviceUuid.toLowerCase()) {
          for (final c in s.characteristics) {
            if (c.uuid.str.toLowerCase() == characteristicUuid.toLowerCase()) {
              characteristic = c;
              if (c.properties.notify) {
                await c.setNotifyValue(true);
                await notifySub?.cancel();
                notifySub = c.lastValueStream.listen(_bleData);
                if (mounted) setState(() => status = 'Monitoring $targetDeviceName');
              }
              return;
            }
          }
        }
      }
      if (mounted) setState(() => status = 'BLE service/characteristic not found');
    } catch (e) { if (mounted) setState(() => status = 'BLE setup error: $e'); }
  }

  void _bleData(List<int> data) {
    final text = utf8.decode(data, allowMalformed: true).trim();
    if (text.toUpperCase().contains('ALARM')) {
      if (mounted) setState(() { lastAlarm = DateTime.now().toLocal().toString(); status = 'ALARM received'; });
      _emergency('ESP32 ALARM');
    }
  }

  Future<void> _getLocation() async {
    if (!await _permissions()) return;
    if (!await Geolocator.isLocationServiceEnabled()) return _show('Please turn Location Services on.');
    try {
      final p = await Geolocator.getCurrentPosition(locationSettings: const LocationSettings(accuracy: LocationAccuracy.high));
      if (mounted) setState(() => location = '${p.latitude.toStringAsFixed(6)}, ${p.longitude.toStringAsFixed(6)}');
    } catch (e) { _show('Could not obtain GPS location: $e'); }
  }

  Future<void> _emergency(String source) async {
    if (emergencyRunning) return;
    final number = phone.text.trim();
    if (number.isEmpty) return _show('Emergency received, but no caregiver number is saved.');
    setState(() { emergencyRunning = true; status = 'Emergency: getting GPS location...'; });
    try {
      final p = await Geolocator.getCurrentPosition(locationSettings: const LocationSettings(accuracy: LocationAccuracy.high));
      final lat = p.latitude.toStringAsFixed(6), lon = p.longitude.toStringAsFixed(6);
      if (mounted) setState(() { location = '$lat, $lon'; status = 'Emergency: sending SMS...'; });
      final body = 'SOS EMERGENCY!\nSource: $source\n\nThe SOS button has been activated.\n\nLocation coordinates:\nLatitude: $lat\nLongitude: $lon\n\nCopy the coordinates and paste them into Google Maps.';
      bool smsOk = false; String msg = '';
      if (Platform.isAndroid) {
        final r = await _native.invokeMethod<dynamic>('sendSms', {'phone': number, 'body': body});
        if (r is Map) { smsOk = r['success'] == true; msg = '${r['message'] ?? ''}'; }
      } else { msg = 'Direct SMS is not available on iOS.'; }
      if (mounted) setState(() => status = smsOk ? 'SMS request accepted; starting emergency call...' : 'SMS not sent: $msg');
      await Future.delayed(const Duration(seconds: 2));
      if (Platform.isAndroid) {
        await _native.invokeMethod('makeCall', {'phone': number});
      } else if (mounted) {
        await showDialog<void>(context: context, builder: (_) => AlertDialog(
          title: const Text('iOS emergency call'),
          content: Text('iOS does not allow an ordinary app to silently place a cellular call.\n\nNumber: $number'),
          actions: [TextButton(onPressed: () => Navigator.pop(context), child: const Text('OK'))],
        ));
      }
    } catch (e) {
      if (mounted) setState(() => status = 'Emergency sequence error: $e');
    } finally { if (mounted) setState(() => emergencyRunning = false); }
  }

  Future<void> _disconnect() async {
    await notifySub?.cancel(); await connectionSub?.cancel();
    try { await device?.disconnect(); } catch (_) {}
    if (mounted) setState(() { connected = false; device = null; characteristic = null; status = 'Disconnected'; });
  }

  void _show(String s) { if (!mounted) return; ScaffoldMessenger.of(context).showSnackBar(SnackBar(content: Text(s))); }

  @override void dispose() { scanSub?.cancel(); connectionSub?.cancel(); notifySub?.cancel(); phone.dispose(); super.dispose(); }

  @override Widget build(BuildContext context) {
    return Scaffold(
      appBar: AppBar(title: const Text('SOS Guardian'), centerTitle: true),
      body: ListView(padding: const EdgeInsets.all(16), children: [
        Card(child: Padding(padding: const EdgeInsets.all(18), child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
          const Text('ESP32 SOS Device', style: TextStyle(fontSize: 20, fontWeight: FontWeight.bold)),
          const SizedBox(height: 12),
          Row(children: [Icon(Icons.bluetooth, color: connected ? Colors.green : Colors.red), const SizedBox(width: 8), Expanded(child: Text(status))]),
          const SizedBox(height: 14),
          Row(children: [
            Expanded(child: FilledButton.icon(onPressed: scanning ? null : _scan, icon: const Icon(Icons.search), label: Text(scanning ? 'Scanning...' : 'Scan'))),
            const SizedBox(width: 10),
            Expanded(child: OutlinedButton.icon(onPressed: connected ? _disconnect : null, icon: const Icon(Icons.link_off), label: const Text('Disconnect'))),
          ]),
          const SizedBox(height: 8), Text('Expected device: $targetDeviceName', style: Theme.of(context).textTheme.bodySmall),
        ]))),
        const SizedBox(height: 12),
        Card(child: Padding(padding: const EdgeInsets.all(18), child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
          const Text('Caregiver', style: TextStyle(fontSize: 20, fontWeight: FontWeight.bold)),
          const SizedBox(height: 12),
          TextField(controller: phone, keyboardType: TextInputType.phone, decoration: const InputDecoration(labelText: 'Caregiver phone number', hintText: '+20xxxxxxxxxx', border: OutlineInputBorder(), prefixIcon: Icon(Icons.phone))),
          const SizedBox(height: 10),
          SizedBox(width: double.infinity, child: OutlinedButton.icon(onPressed: _savePhone, icon: const Icon(Icons.save), label: const Text('Save Number'))),
        ]))),
        const SizedBox(height: 12),
        Card(child: Padding(padding: const EdgeInsets.all(18), child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
          const Text('Location', style: TextStyle(fontSize: 20, fontWeight: FontWeight.bold)),
          const SizedBox(height: 12), SelectableText(location),
          const SizedBox(height: 10),
          SizedBox(width: double.infinity, child: OutlinedButton.icon(onPressed: _getLocation, icon: const Icon(Icons.my_location), label: const Text('Get Current Location'))),
          const SizedBox(height: 8), Text('Only plain-text coordinates are sent by SMS. No Google Maps link is included.', style: Theme.of(context).textTheme.bodySmall),
        ]))),
        const SizedBox(height: 12),
        Card(child: Padding(padding: const EdgeInsets.all(18), child: Column(children: [
          const Icon(Icons.warning_amber_rounded, size: 52, color: Colors.red),
          const SizedBox(height: 6), const Text('Emergency Test', style: TextStyle(fontSize: 20, fontWeight: FontWeight.bold)),
          const SizedBox(height: 6), const Text('Runs the same GPS → SMS → call sequence as an ESP32 ALARM.', textAlign: TextAlign.center),
          const SizedBox(height: 14),
          SizedBox(width: double.infinity, child: FilledButton(
            style: FilledButton.styleFrom(backgroundColor: Colors.red, foregroundColor: Colors.white, padding: const EdgeInsets.symmetric(vertical: 16)),
            onPressed: emergencyRunning ? null : () => _emergency('TEST EMERGENCY ALERT'),
            child: Text(emergencyRunning ? 'EMERGENCY RUNNING...' : 'TEST EMERGENCY ALERT'),
          )),
        ]))),
        const SizedBox(height: 12),
        Card(child: ListTile(leading: const Icon(Icons.notifications_active), title: const Text('Last ALARM'), subtitle: Text(lastAlarm))),
      ]),
    );
  }
}

const MethodChannel _native = MethodChannel('sos_guardian/native');
