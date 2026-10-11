import 'dart:convert';
import 'dart:math';

import 'package:cloud_firestore/cloud_firestore.dart';
import 'package:firebase_auth/firebase_auth.dart';
import 'package:flutter/material.dart';
import 'package:shared_preferences/shared_preferences.dart';

import 'chat_screen.dart';

/// آخر الغرف التي دخلها المستخدم (محفوظة على الجهاز فقط).
class RecentRooms {
  static const _key = 'recentRooms';

  static Future<List<Map<String, String>>> load() async {
    final prefs = await SharedPreferences.getInstance();
    final raw = prefs.getString(_key);
    if (raw == null) return [];
    try {
      return (jsonDecode(raw) as List)
          .map((e) => Map<String, String>.from(e as Map))
          .toList();
    } catch (_) {
      return [];
    }
  }

  static Future<void> _save(List<Map<String, String>> list) async {
    final prefs = await SharedPreferences.getInstance();
    await prefs.setString(_key, jsonEncode(list));
  }

  static Future<void> add(String code, String name) async {
    final list = await load();
    list.removeWhere((e) => e['code'] == code);
    list.insert(0, {'code': code, 'name': name});
    await _save(list.take(20).toList());
  }

  static Future<void> remove(String code) async {
    final list = await load();
    list.removeWhere((e) => e['code'] == code);
    await _save(list);
  }
}

class HomeScreen extends StatefulWidget {
  const HomeScreen({super.key});

  @override
  State<HomeScreen> createState() => _HomeScreenState();
}

class _HomeScreenState extends State<HomeScreen> {
  final _codeController = TextEditingController();
  final _nameController = TextEditingController();
  bool _isLoading = false;
  List<Map<String, String>> _recent = [];

  @override
  void initState() {
    super.initState();
    _loadRecent();
  }

  @override
  void dispose() {
    _codeController.dispose();
    _nameController.dispose();
    super.dispose();
  }

  Future<void> _loadRecent() async {
    final list = await RecentRooms.load();
    if (mounted) setState(() => _recent = list);
  }

  void _snack(String msg) {
    if (!mounted) return;
    ScaffoldMessenger.of(context)
      ..hideCurrentSnackBar()
      ..showSnackBar(SnackBar(content: Text(msg)));
  }

  String _generateCode() {
    const chars = 'ABCDEFGHJKLMNPQRSTUVWXYZ23456789';
    final random = Random.secure();
    return List.generate(6, (_) => chars[random.nextInt(chars.length)]).join();
  }

  Future<void> _open(String code, String name) async {
    await RecentRooms.add(code, name);
    if (!mounted) return;
    await Navigator.push(
      context,
      MaterialPageRoute(builder: (_) => ChatScreen(roomCode: code)),
    );
    _loadRecent();
  }

  Future<void> _createRoom() async {
    setState(() => _isLoading = true);
    try {
      final uid = FirebaseAuth.instance.currentUser!.uid;
      final name = _nameController.text.trim();
      final db = FirebaseFirestore.instance;

      for (var i = 0; i < 5; i++) {
        final code = _generateCode();
        final ref = db.collection('rooms').doc(code);
        if ((await ref.get()).exists) continue;
        await ref.set({
          'name': name,
          'creatorId': uid,
          'createdAt': FieldValue.serverTimestamp(),
        });
        _nameController.clear();
        await _open(code, name);
        return;
      }
      _snack('تعذّر إنشاء كود فريد، حاول مرة أخرى');
    } catch (e) {
      _snack('خطأ: $e');
    } finally {
      if (mounted) setState(() => _isLoading = false);
    }
  }

  Future<void> _joinRoom([String? presetCode]) async {
    final code = (presetCode ?? _codeController.text).trim().toUpperCase();
    if (code.isEmpty) {
      _snack('اكتب كود الغرفة');
      return;
    }
    setState(() => _isLoading = true);
    try {
      final doc =
          await FirebaseFirestore.instance.collection('rooms').doc(code).get();
      if (!doc.exists) {
        _snack('الغرفة غير موجودة');
        await RecentRooms.remove(code);
        _loadRecent();
        return;
      }
      _codeController.clear();
      await _open(code, (doc.data()?['name'] as String?) ?? '');
    } catch (e) {
      _snack('خطأ: $e');
    } finally {
      if (mounted) setState(() => _isLoading = false);
    }
  }

  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    return Scaffold(
      appBar: AppBar(title: const Text('شات مجهول'), centerTitle: true),
      body: ListView(
        padding: const EdgeInsets.all(20),
        children: [
          Icon(Icons.forum_rounded, size: 64, color: scheme.primary),
          const SizedBox(height: 8),
          const Text(
            'دردشة مجهولة بين الأصدقاء.\nأنشئ غرفة وشارك الكود فقط.',
            textAlign: TextAlign.center,
            style: TextStyle(fontSize: 16),
          ),
          const SizedBox(height: 24),
          Card(
            child: Padding(
              padding: const EdgeInsets.all(16),
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.stretch,
                children: [
                  TextField(
                    controller: _nameController,
                    maxLength: 40,
                    decoration: const InputDecoration(
                      labelText: 'اسم الغرفة (اختياري)',
                      border: OutlineInputBorder(),
                    ),
                  ),
                  const SizedBox(height: 8),
                  FilledButton.icon(
                    onPressed: _isLoading ? null : _createRoom,
                    icon: const Icon(Icons.add),
                    label: const Text('إنشاء غرفة جديدة'),
                  ),
                ],
              ),
            ),
          ),
          Card(
            child: Padding(
              padding: const EdgeInsets.all(16),
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.stretch,
                children: [
                  TextField(
                    controller: _codeController,
                    textAlign: TextAlign.center,
                    maxLength: 6,
                    style: const TextStyle(fontSize: 22, letterSpacing: 4),
                    textCapitalization: TextCapitalization.characters,
                    decoration: const InputDecoration(
                      hintText: 'كود الغرفة',
                      counterText: '',
                      border: OutlineInputBorder(),
                    ),
                    onSubmitted: (_) => _joinRoom(),
                  ),
                  const SizedBox(height: 12),
                  FilledButton.tonalIcon(
                    onPressed: _isLoading ? null : () => _joinRoom(),
                    icon: const Icon(Icons.login),
                    label: const Text('انضمام للغرفة'),
                  ),
                ],
              ),
            ),
          ),
          if (_isLoading)
            const Padding(
              padding: EdgeInsets.all(8),
              child: Center(child: CircularProgressIndicator()),
            ),
          if (_recent.isNotEmpty) ...[
            const SizedBox(height: 16),
            const Text('غرفك الأخيرة',
                style: TextStyle(fontSize: 16, fontWeight: FontWeight.bold)),
            const SizedBox(height: 8),
            for (final r in _recent)
              Card(
                child: ListTile(
                  leading: const Icon(Icons.meeting_room_outlined),
                  title: Text(
                    (r['name'] ?? '').isEmpty ? 'غرفة بدون اسم' : r['name']!,
                  ),
                  subtitle: Text(r['code'] ?? '',
                      style: const TextStyle(letterSpacing: 2)),
                  onTap: _isLoading ? null : () => _joinRoom(r['code']),
                  trailing: IconButton(
                    icon: const Icon(Icons.close),
                    onPressed: () async {
                      await RecentRooms.remove(r['code']!);
                      _loadRecent();
                    },
                  ),
                ),
              ),
          ],
        ],
      ),
    );
  }
}
