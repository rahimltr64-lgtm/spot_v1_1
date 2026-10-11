import 'package:cloud_firestore/cloud_firestore.dart';
import 'package:firebase_auth/firebase_auth.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';

import 'home_screen.dart';

const _animals = [
  'ثعلب', 'صقر', 'نمر', 'ذئب', 'دلفين', 'باندا',
  'أسد', 'فهد', 'غزال', 'بومة', 'قطة', 'دب',
];

int _hash(String s) {
  var h = 0;
  for (final c in s.codeUnits) {
    h = (h * 31 + c) & 0x7fffffff;
  }
  return h;
}

/// اسم مستعار ثابت لكل مستخدم داخل كل غرفة (مثل: «صقر 42»).
String aliasFor(String uid, String room) {
  final h = _hash('$uid$room');
  return '${_animals[h % _animals.length]} ${(h ~/ 13) % 90 + 10}';
}

Color aliasColor(String uid, String room) {
  final h = _hash('$room$uid');
  return HSLColor.fromAHSL(1, (h % 360).toDouble(), 0.6, 0.72).toColor();
}

String _time(DateTime t) =>
    '${t.hour.toString().padLeft(2, '0')}:${t.minute.toString().padLeft(2, '0')}';

class ChatScreen extends StatefulWidget {
  final String roomCode;
  const ChatScreen({super.key, required this.roomCode});

  @override
  State<ChatScreen> createState() => _ChatScreenState();
}

class _ChatScreenState extends State<ChatScreen> {
  final _controller = TextEditingController();
  final _uid = FirebaseAuth.instance.currentUser!.uid;
  DateTime? _lastSent;

  late final DocumentReference<Map<String, dynamic>> _roomRef =
      FirebaseFirestore.instance.collection('rooms').doc(widget.roomCode);

  late final Stream<DocumentSnapshot<Map<String, dynamic>>> _roomStream =
      _roomRef.snapshots();

  late final Stream<QuerySnapshot<Map<String, dynamic>>> _messagesStream =
      _roomRef
          .collection('messages')
          .orderBy('createdAt', descending: true)
          .limit(150)
          .snapshots();

  @override
  void dispose() {
    _controller.dispose();
    super.dispose();
  }

  void _snack(String msg) {
    if (!mounted) return;
    ScaffoldMessenger.of(context)
      ..hideCurrentSnackBar()
      ..showSnackBar(SnackBar(content: Text(msg)));
  }

  Future<void> _send() async {
    final text = _controller.text.trim();
    if (text.isEmpty) return;

    final now = DateTime.now();
    if (_lastSent != null &&
        now.difference(_lastSent!) < const Duration(milliseconds: 800)) {
      return; // حماية بسيطة من الإرسال المتكرر
    }
    _lastSent = now;
    _controller.clear();

    try {
      await _roomRef.collection('messages').add({
        'text': text,
        'senderId': _uid,
        'createdAt': FieldValue.serverTimestamp(),
      });
    } catch (_) {
      _controller.text = text;
      _snack('تعذّر إرسال الرسالة');
    }
  }

  Future<void> _deleteMessage(DocumentReference ref) async {
    try {
      await ref.delete();
    } catch (_) {
      _snack('تعذّر حذف الرسالة');
    }
  }

  void _showMessageMenu(
      QueryDocumentSnapshot<Map<String, dynamic>> doc, bool canDelete) {
    final text = (doc.data()['text'] as String?) ?? '';
    showModalBottomSheet(
      context: context,
      builder: (ctx) => SafeArea(
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            ListTile(
              leading: const Icon(Icons.copy),
              title: const Text('نسخ'),
              onTap: () {
                Clipboard.setData(ClipboardData(text: text));
                Navigator.pop(ctx);
                _snack('تم النسخ');
              },
            ),
            if (canDelete)
              ListTile(
                leading: const Icon(Icons.delete_outline, color: Colors.redAccent),
                title: const Text('حذف'),
                onTap: () {
                  Navigator.pop(ctx);
                  _deleteMessage(doc.reference);
                },
              ),
          ],
        ),
      ),
    );
  }

  Future<void> _deleteRoom() async {
    final ok = await showDialog<bool>(
      context: context,
      builder: (ctx) => AlertDialog(
        title: const Text('حذف الغرفة'),
        content: const Text('سيتم حذف الغرفة وكل رسائلها نهائيًا لجميع الأعضاء.'),
        actions: [
          TextButton(
              onPressed: () => Navigator.pop(ctx, false),
              child: const Text('إلغاء')),
          FilledButton(
              onPressed: () => Navigator.pop(ctx, true),
              child: const Text('حذف')),
        ],
      ),
    );
    if (ok != true) return;

    try {
      // نحذف الرسائل أولًا (والغرفة ما زالت موجودة) ثم الغرفة.
      while (true) {
        final snap = await _roomRef.collection('messages').limit(400).get();
        if (snap.docs.isEmpty) break;
        final batch = FirebaseFirestore.instance.batch();
        for (final d in snap.docs) {
          batch.delete(d.reference);
        }
        await batch.commit();
      }
      await _roomRef.delete();
      await RecentRooms.remove(widget.roomCode);
      if (mounted) Navigator.pop(context);
    } catch (_) {
      _snack('تعذّر حذف الغرفة');
    }
  }

  Future<void> _leave() async {
    await RecentRooms.remove(widget.roomCode);
    if (mounted) Navigator.pop(context);
  }

  @override
  Widget build(BuildContext context) {
    return StreamBuilder<DocumentSnapshot<Map<String, dynamic>>>(
      stream: _roomStream,
      builder: (context, roomSnap) {
        if (roomSnap.hasError) {
          return Scaffold(
            appBar: AppBar(),
            body: const Center(child: Text('حدث خطأ في تحميل الغرفة')),
          );
        }
        if (!roomSnap.hasData) {
          return Scaffold(
            appBar: AppBar(),
            body: const Center(child: CircularProgressIndicator()),
          );
        }
        final room = roomSnap.data!;
        if (!room.exists) {
          RecentRooms.remove(widget.roomCode);
          return Scaffold(
            appBar: AppBar(),
            body: const Center(child: Text('هذه الغرفة لم تعد موجودة')),
          );
        }

        final data = room.data() ?? {};
        final name = (data['name'] as String?) ?? '';
        final isCreator = data['creatorId'] == _uid;

        return Scaffold(
          appBar: AppBar(
            title: Column(
              mainAxisSize: MainAxisSize.min,
              children: [
                Text(name.isEmpty ? 'غرفة' : name),
                Text(
                  widget.roomCode,
                  style: const TextStyle(fontSize: 12, letterSpacing: 2),
                ),
              ],
            ),
            centerTitle: true,
            actions: [
              IconButton(
                tooltip: 'نسخ الكود',
                icon: const Icon(Icons.copy),
                onPressed: () {
                  Clipboard.setData(ClipboardData(text: widget.roomCode));
                  _snack('تم نسخ الكود: ${widget.roomCode}');
                },
              ),
              PopupMenuButton<String>(
                onSelected: (v) {
                  if (v == 'leave') _leave();
                  if (v == 'delete') _deleteRoom();
                },
                itemBuilder: (_) => [
                  const PopupMenuItem(value: 'leave', child: Text('مغادرة الغرفة')),
                  if (isCreator)
                    const PopupMenuItem(value: 'delete', child: Text('حذف الغرفة')),
                ],
              ),
            ],
          ),
          body: Column(
            children: [
              Expanded(child: _buildMessages(isCreator)),
              _buildComposer(),
            ],
          ),
        );
      },
    );
  }

  Widget _buildMessages(bool isCreator) {
    return StreamBuilder<QuerySnapshot<Map<String, dynamic>>>(
      stream: _messagesStream,
      builder: (context, snap) {
        if (snap.hasError) return const Center(child: Text('حدث خطأ'));
        if (!snap.hasData) {
          return const Center(child: CircularProgressIndicator());
        }
        final docs = snap.data!.docs;
        if (docs.isEmpty) {
          return const Center(child: Text('لا توجد رسائل بعد، ابدأ المحادثة 👋'));
        }
        return ListView.builder(
          reverse: true, // الأحدث في الأسفل بدون حاجة لتمرير يدوي
          padding: const EdgeInsets.all(12),
          itemCount: docs.length,
          itemBuilder: (context, i) {
            final doc = docs[i];
            final d = doc.data();
            final sender = (d['senderId'] as String?) ?? '';
            final mine = sender == _uid;
            final ts = (d['createdAt'] as Timestamp?)?.toDate() ?? DateTime.now();
            return _Bubble(
              text: (d['text'] as String?) ?? '',
              alias: aliasFor(sender, widget.roomCode),
              aliasColor: aliasColor(sender, widget.roomCode),
              time: _time(ts),
              mine: mine,
              onLongPress: () => _showMessageMenu(doc, mine || isCreator),
            );
          },
        );
      },
    );
  }

  Widget _buildComposer() {
    return SafeArea(
      child: Container(
        padding: const EdgeInsets.fromLTRB(12, 8, 12, 8),
        color: Theme.of(context).colorScheme.surfaceContainer,
        child: Row(
          crossAxisAlignment: CrossAxisAlignment.end,
          children: [
            Expanded(
              child: TextField(
                controller: _controller,
                minLines: 1,
                maxLines: 4,
                keyboardType: TextInputType.multiline,
                textInputAction: TextInputAction.newline,
                inputFormatters: [LengthLimitingTextInputFormatter(500)],
                decoration: InputDecoration(
                  hintText: 'اكتب رسالة مجهولة...',
                  border: OutlineInputBorder(
                    borderRadius: BorderRadius.circular(24),
                  ),
                  contentPadding:
                      const EdgeInsets.symmetric(horizontal: 16, vertical: 10),
                ),
              ),
            ),
            const SizedBox(width: 8),
            IconButton.filled(
              onPressed: _send,
              icon: const Icon(Icons.send),
            ),
          ],
        ),
      ),
    );
  }
}

class _Bubble extends StatelessWidget {
  final String text;
  final String alias;
  final Color aliasColor;
  final String time;
  final bool mine;
  final VoidCallback onLongPress;

  const _Bubble({
    required this.text,
    required this.alias,
    required this.aliasColor,
    required this.time,
    required this.mine,
    required this.onLongPress,
  });

  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    return Align(
      alignment: mine
          ? AlignmentDirectional.centerStart
          : AlignmentDirectional.centerEnd,
      child: GestureDetector(
        onLongPress: onLongPress,
        child: Container(
          constraints: BoxConstraints(
            maxWidth: MediaQuery.of(context).size.width * 0.78,
          ),
          margin: const EdgeInsets.symmetric(vertical: 4),
          padding: const EdgeInsets.symmetric(horizontal: 14, vertical: 8),
          decoration: BoxDecoration(
            color: mine ? scheme.primaryContainer : scheme.surfaceContainerHighest,
            borderRadius: BorderRadius.circular(16),
          ),
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Text(
                mine ? 'أنت' : alias,
                style: TextStyle(
                  fontSize: 12,
                  fontWeight: FontWeight.bold,
                  color: mine ? scheme.onPrimaryContainer : aliasColor,
                ),
              ),
              const SizedBox(height: 2),
              Text(text, style: const TextStyle(fontSize: 16)),
              const SizedBox(height: 2),
              Text(
                time,
                style: TextStyle(
                  fontSize: 10,
                  color: scheme.onSurface.withOpacity(0.55),
                ),
              ),
            ],
          ),
        ),
      ),
    );
  }
}
