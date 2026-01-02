// lib/screens/chat/chat_screen.dart
import 'dart:async';
import 'dart:typed_data';

import 'package:flutter/foundation.dart' show kIsWeb;
import 'package:flutter/material.dart';
import 'package:image_picker/image_picker.dart';
import 'package:intl/intl.dart';
import 'package:firebase_messaging/firebase_messaging.dart';

import '../../Services/Api.dart' show Api;

enum _MsgKind { text, image }
enum _MsgStatus { sending, failed, sent, delivered, read }

class ChatScreen extends StatefulWidget {
  final int apptId;
  final String title;

  const ChatScreen({
    Key? key,
    int? apptId,
    int? appointmentId,
    this.title = 'Chat',
  })  : apptId = (apptId ?? appointmentId) ?? -1,
        super(key: key);

  @override
  State<ChatScreen> createState() => _ChatScreenState();
}

class _ChatMessage {
  String id;
  final int authorId;
  final _MsgKind kind;
  final String? body;
  final String? imageUrl;
  final Uint8List? localImageBytes;
  final DateTime createdAt;
  _MsgStatus status;

  _ChatMessage({
    required this.id,
    required this.authorId,
    required this.kind,
    required this.createdAt,
    this.body,
    this.imageUrl,
    this.localImageBytes,
    this.status = _MsgStatus.sent,
  });
}

class _ChatScreenState extends State<ChatScreen> {
  final _controller = TextEditingController();
  final _scroll = ScrollController();
  final _picker = ImagePicker();

  bool _loading = true;
  String? _error;
  List<_ChatMessage> _messages = [];
  bool _sending = false;
  Timer? _pollTimer;

  // Header info
  String _counterpartName = '';
  String _appBarTitle = '';
  int? _counterpartUserId;

  // whoami
  String? _myRole;
  int? get _meId => Api.currentUserId;

  // firebase
  StreamSubscription<RemoteMessage>? _fcmSub;
  bool _initialLoaded = false;

  @override
  void initState() {
    super.initState();
    if (widget.apptId <= 0) {
      Future.microtask(() {
        setState(() {
          _loading = false;
          _error = 'Invalid appointment id';
        });
      });
      return;
    }
    _init();
  }

  @override
  void dispose() {
    _pollTimer?.cancel();
    _fcmSub?.cancel();
    _controller.dispose();
    _scroll.dispose();
    super.dispose();
  }

  Future<void> _init() async {
    await Api.init();
    await _ensureMe();
    await _registerDeviceToken();
    await _loadAppointmentInfo();
    await _loadMessages();

    // Listen for foreground FCM messages and refresh chat when a relevant push arrives.
    try {
      _fcmSub = FirebaseMessaging.onMessage.listen((RemoteMessage message) {
        final data = message.data;
        if (data != null) {
          // If payload contains appointment id for this chat, refresh
          final apptId = data['appointment_id'] ?? data['appt_id'] ?? data['apptId'] ?? data['appointmentId'];
          try {
            if (apptId != null && apptId.toString() == widget.apptId.toString()) {
              _loadMessages(silent: true);
            }
          } catch (_) {
            _loadMessages(silent: true);
          }
        }
      });
    } catch (_) {}

    // Polling fallback if needed (every 5s)
    _pollTimer = Timer.periodic(const Duration(seconds: 5), (_) => _loadMessages(silent: true));
  }

  // -------------------------
  // whoami
  // -------------------------
  Future<void> _ensureMe() async {
    if (Api.currentUserId != null) return;
    try {
      final r = await Api.get('/whoami');
      if (r is Map) {
        final m = Map<String, dynamic>.from(r);
        dynamic idRaw = m['id'];
        if (idRaw == null && m['user'] is Map) idRaw = (m['user'] as Map)['id'];
        if (idRaw != null) Api.currentUserId = (idRaw is num) ? idRaw.toInt() : int.tryParse('$idRaw');

        dynamic roleRaw = m['role'] ?? m['type'];
        if (roleRaw == null && m['user'] is Map) roleRaw = (m['user'] as Map)['role'];
        if (roleRaw != null) _myRole = roleRaw.toString().toLowerCase();
      }
    } catch (_) {}
  }

  // -------------------------
  // register FCM token on server
  // -------------------------
  Future<void> _registerDeviceToken() async {
    try {
      final fm = FirebaseMessaging.instance;

      // Request permission on iOS / web
      if (!kIsWeb) {
        NotificationSettings settings = await fm.requestPermission();
        // We proceed regardless of permission result — token can still be available
        debugPrint('FCM permission: ${settings.authorizationStatus}');
      }

      final token = await fm.getToken();
      if (token != null && token.isNotEmpty) {
        final platform = kIsWeb ? 'web' : (Theme.of(context).platform == TargetPlatform.iOS ? 'ios' : 'android');
        try {
          await Api.post('/me/device_token', data: {'token': token, 'platform': platform});
          debugPrint('[Chat] registered device token to server');
        } catch (e) {
          debugPrint('[Chat] failed to register device token: $e');
        }
      }

      // refresh handling
      fm.onTokenRefresh.listen((newToken) async {
        if (newToken != null && newToken.isNotEmpty) {
          final platform = kIsWeb ? 'web' : (Theme.of(context).platform == TargetPlatform.iOS ? 'ios' : 'android');
          try {
            await Api.post('/me/device_token', data: {'token': newToken, 'platform': platform});
            debugPrint('[Chat] refreshed device token posted to server');
          } catch (e) {
            debugPrint('[Chat] token refresh post failed: $e');
          }
        }
      });
    } catch (e) {
      debugPrint('registerDeviceToken error: $e');
    }
  }

  // -------------------------
  // Appointment header
  // -------------------------
  Future<void> _loadAppointmentInfo() async {
    try {
      final r = await Api.get('/appointments/${widget.apptId}');
      if (r is! Map) {
        setState(() {
          _counterpartName = 'User';
          _appBarTitle = 'User • #${widget.apptId}';
        });
        return;
      }

      final appt = Map<String, dynamic>.from(r);

      final doctor = (appt['doctor'] is Map) ? Map<String, dynamic>.from(appt['doctor']) : null;
      final patient = (appt['patient'] is Map) ? Map<String, dynamic>.from(appt['patient']) : null;

      final doctorName = (doctor?['name'] ?? doctor?['full_name'] ?? appt['doctor_name'] ?? '').toString();
      final patientName = (patient?['name'] ?? patient?['full_name'] ?? appt['patient_name'] ?? '').toString();

      int? doctorUserId;
      final dUidRaw = appt['doctor_user_id'] ?? doctor?['user_id'] ?? doctor?['id'];
      if (dUidRaw != null) doctorUserId = (dUidRaw is num) ? dUidRaw.toInt() : int.tryParse('$dUidRaw');

      int? patientUserId;
      final pUidRaw = appt['patient_user_id'] ?? patient?['user_id'] ?? patient?['id'];
      if (pUidRaw != null) patientUserId = (pUidRaw is num) ? pUidRaw.toInt() : int.tryParse('$pUidRaw');

      final me = _meId;
      bool iAmDoctor = false;
      if (_myRole != null) iAmDoctor = _myRole!.contains('doctor');
      else if (me != null && doctorUserId != null) iAmDoctor = me == doctorUserId;

      String name = iAmDoctor ? patientName : doctorName;
      int? counterpartId = iAmDoctor ? patientUserId : doctorUserId;

      if (name.trim().isEmpty) {
        name = doctorName.trim().isNotEmpty ? doctorName : (patientName.trim().isNotEmpty ? patientName : 'User');
      }

      setState(() {
        _counterpartName = name;
        _appBarTitle = '$_counterpartName • #${widget.apptId}';
        _counterpartUserId = counterpartId;
      });
    } catch (_) {
      setState(() {
        _counterpartName = 'User';
        _appBarTitle = 'User • #${widget.apptId}';
      });
    }
  }

  // -------------------------
  // Load messages
  // -------------------------
  Future<void> _loadMessages({bool silent = false}) async {
    if (!silent) {
      setState(() {
        _loading = true;
        _error = null;
      });
    }

    // measure whether user is near bottom so we only scroll down automatically in that case
    final wasNearBottom = _scroll.hasClients ? (_scroll.position.maxScrollExtent - _scroll.position.pixels) < 150 : true;

    try {
      dynamic page;
      // prefer the chat listing endpoint
      try {
        page = await Api.get('/appointments/${widget.apptId}/chat', query: {'page': 1, 'page_size': 200});
      } catch (_) {
        page = await Api.getMessages(widget.apptId, page: 1, pageSize: 200);
      }

      List<dynamic> dataList = [];

      if (page == null) {
        dataList = [];
      } else if (page is List) {
        dataList = List<dynamic>.from(page);
      } else if (page is Map) {
        if (page['items'] is List) dataList = List<dynamic>.from(page['items'] as List);
        else if (page['data'] is List) dataList = List<dynamic>.from(page['data'] as List);
        else if (page['messages'] is List) dataList = List<dynamic>.from(page['messages'] as List);
        else if (page['results'] is List) dataList = List<dynamic>.from(page['results'] as List);
        else if (page.containsKey('message') && page['message'] is Map) dataList = [page['message']];
        else if (page.containsKey('id') || page.containsKey('body') || page.containsKey('text') || page.containsKey('file_path')) dataList = [page];
        else dataList = [];
      } else {
        dataList = [];
      }

      final parsed = <_ChatMessage>[];
      for (final item in dataList) {
        if (item == null || item is! Map) continue;
        try {
          final m = Map<String, dynamic>.from(item);
          final id = (m['id'] ?? m['message_id'] ?? m['msg_id'] ?? '').toString();
          final kindRaw = (m['kind'] ?? (m['file_path'] != null ? 'image' : 'text')).toString().toLowerCase();
          final kind = kindRaw == 'image' ? _MsgKind.image : _MsgKind.text;
          final body = (m['body'] ?? m['message'] ?? m['text'] ?? '').toString();

          final authorRaw = m['sender_user_id'] ?? m['author_id'] ?? m['user_id'] ?? m['sender_id'] ?? 0;
          final authorId = (authorRaw is num) ? authorRaw.toInt() : (int.tryParse(authorRaw?.toString() ?? '') ?? 0);

          DateTime created;
          final createdRaw = m['created_at'] ?? m['timestamp'] ?? m['ts'] ?? m['time'];
          if (createdRaw is String && createdRaw.isNotEmpty) {
            created = DateTime.tryParse(createdRaw) ?? DateTime.now();
          } else if (createdRaw is int) {
            created = createdRaw > 9999999999 ? DateTime.fromMillisecondsSinceEpoch(createdRaw) : DateTime.fromMillisecondsSinceEpoch(createdRaw * 1000);
          } else if (createdRaw is num) {
            final v = createdRaw.toInt();
            created = v > 9999999999 ? DateTime.fromMillisecondsSinceEpoch(v) : DateTime.fromMillisecondsSinceEpoch(v * 1000);
          } else {
            created = DateTime.now();
          }

          _MsgStatus status = _MsgStatus.sent;
          final statusRaw = (m['status'] ?? m['read'] ?? m['read_at'])?.toString().toLowerCase();
          if (statusRaw == 'delivered') status = _MsgStatus.delivered;
          if (statusRaw == 'read' || m['read'] == true) status = _MsgStatus.read;
          if (m['read_at'] != null) status = _MsgStatus.read;
          if (m['delivered_at'] != null && status != _MsgStatus.read) status = _MsgStatus.delivered;

          if (kind == _MsgKind.image) {
            final filePath = (m['file_path'] ?? m['file'] ?? m['image_path'] ?? m['image_url'] ?? '').toString();
            final url = filePath.isNotEmpty ? Api.filePathToUrl(filePath) : null;
            parsed.add(_ChatMessage(
              id: id.isEmpty ? UniqueKey().toString() : id,
              authorId: authorId,
              kind: _MsgKind.image,
              imageUrl: url,
              localImageBytes: null,
              createdAt: created,
              status: status,
            ));
          } else {
            parsed.add(_ChatMessage(
              id: id.isEmpty ? UniqueKey().toString() : id,
              authorId: authorId,
              kind: _MsgKind.text,
              body: body,
              createdAt: created,
              status: status,
            ));
          }
        } catch (_) {
          // skip
        }
      }

      final localSending = _messages.where((m) => m.status == _MsgStatus.sending).toList();

      setState(() {
        parsed.sort((a, b) => a.createdAt.compareTo(b.createdAt));
        _messages = [...parsed, ...localSending];
        _loading = false;
        _error = null;
      });

      // Only auto-scroll if user was near bottom (or first load)
      if (!_initialLoaded || wasNearBottom) {
        _scrollToBottom();
      }
      _initialLoaded = true;
    } catch (e) {
      final msg = 'Failed to load messages: $e';
      if (!silent) {
        setState(() {
          _loading = false;
          _error = msg;
        });
      } else {
        setState(() => _error = msg);
      }
    }
  }

  // -------------------------
  // Send text
  // -------------------------
  Future<void> _sendText() async {
    final text = _controller.text.trim();
    if (text.isEmpty) return;
    if (_sending) return;

    await _ensureMe();
    final me = _meId ?? 0;
    final tempId = 'tmp-${DateTime.now().millisecondsSinceEpoch}';
    final now = DateTime.now();

    setState(() {
      _messages.add(_ChatMessage(id: tempId, authorId: me, kind: _MsgKind.text, body: text, createdAt: now, status: _MsgStatus.sending));
      _sending = true;
      _controller.clear();
    });

    _scrollToBottom();

    try {
      final created = await Api.postMessage(widget.apptId, text, kind: 'text'); // server returns message map
      final serverId = (created['id'] ?? created['message_id'] ?? tempId).toString();

      DateTime createdAt = now;
      final createdAtRaw = created['created_at'] ?? created['timestamp'] ?? created['ts'];
      if (createdAtRaw is String && createdAtRaw.isNotEmpty) createdAt = DateTime.tryParse(createdAtRaw) ?? now;
      else if (createdAtRaw is int) createdAt = createdAtRaw > 9999999999 ? DateTime.fromMillisecondsSinceEpoch(createdAtRaw) : DateTime.fromMillisecondsSinceEpoch(createdAtRaw * 1000);
      else if (createdAtRaw is num) { final v = createdAtRaw.toInt(); createdAt = v > 9999999999 ? DateTime.fromMillisecondsSinceEpoch(v) : DateTime.fromMillisecondsSinceEpoch(v * 1000); }

      setState(() {
        final idx = _messages.indexWhere((m) => m.id == tempId);
        if (idx != -1) {
          _messages[idx] = _ChatMessage(id: serverId.isEmpty ? tempId : serverId, authorId: me, kind: _MsgKind.text, body: text, createdAt: createdAt, status: _MsgStatus.sent);
        }
        _sending = false;
      });

      // refresh to pick statuses/delivered/etc.
      _loadMessages(silent: true);
    } catch (e) {
      setState(() {
        final idx = _messages.indexWhere((m) => m.id == tempId);
        if (idx != -1) _messages[idx].status = _MsgStatus.failed;
        _sending = false;
        _error = 'Send failed: $e';
      });
    }
  }

  // -------------------------
  // Send image
  // -------------------------
  Future<void> _pickAndSendImage() async {
    if (_sending) return;
    final picked = await _picker.pickImage(source: ImageSource.gallery, imageQuality: 85);
    if (picked == null) return;
    final bytes = await picked.readAsBytes();
    await _sendImageBytes(bytes, picked.name);
  }

  Future<void> _sendImageBytes(Uint8List bytes, String filename) async {
    if (_sending) return;
    await _ensureMe();
    final me = _meId ?? 0;
    final tempId = 'tmp-img-${DateTime.now().millisecondsSinceEpoch}';
    final now = DateTime.now();

    setState(() {
      _messages.add(_ChatMessage(id: tempId, authorId: me, kind: _MsgKind.image, localImageBytes: bytes, createdAt: now, status: _MsgStatus.sending));
      _sending = true;
    });

    _scrollToBottom();

    try {
      final created = await Api.postImageMessage(widget.apptId, bytes, filename: filename); // your Api handles multipart
      final serverId = (created['id'] ?? created['message_id'] ?? tempId).toString();
      final filePath = (created['file_path'] ?? created['file'] ?? created['image_url'] ?? '').toString();
      final url = filePath.isNotEmpty ? Api.filePathToUrl(filePath) : (created['image_url'] ?? created['url'] ?? '').toString();

      DateTime createdAt = now;
      final createdAtRaw = created['created_at'] ?? created['timestamp'] ?? created['ts'];
      if (createdAtRaw is String && createdAtRaw.isNotEmpty) createdAt = DateTime.tryParse(createdAtRaw) ?? now;
      else if (createdAtRaw is int) createdAt = createdAtRaw > 9999999999 ? DateTime.fromMillisecondsSinceEpoch(createdAtRaw) : DateTime.fromMillisecondsSinceEpoch(createdAtRaw * 1000);
      else if (createdAtRaw is num) { final v = createdAtRaw.toInt(); createdAt = v > 9999999999 ? DateTime.fromMillisecondsSinceEpoch(v) : DateTime.fromMillisecondsSinceEpoch(v * 1000); }

      setState(() {
        final idx = _messages.indexWhere((m) => m.id == tempId);
        if (idx != -1) {
          _messages[idx] = _ChatMessage(id: serverId, authorId: me, kind: _MsgKind.image, imageUrl: url.isEmpty ? null : url, localImageBytes: url.isEmpty ? bytes : null, createdAt: createdAt, status: _MsgStatus.sent);
        }
        _sending = false;
      });

      // refresh
      _loadMessages(silent: true);
    } catch (e) {
      setState(() {
        final idx = _messages.indexWhere((m) => m.id == tempId);
        if (idx != -1) _messages[idx].status = _MsgStatus.failed;
        _sending = false;
        _error = 'Image send failed: $e';
      });
    }
  }

  void _retry(_ChatMessage m) {
    if (m.status != _MsgStatus.failed) return;
    if (m.kind == _MsgKind.text) {
      final t = m.body ?? '';
      setState(() => _messages.removeWhere((x) => x.id == m.id));
      _controller.text = t;
      _sendText();
      return;
    }
    if (m.kind == _MsgKind.image && m.localImageBytes != null) {
      final bytes = m.localImageBytes!;
      setState(() => _messages.removeWhere((x) => x.id == m.id));
      _sendImageBytes(bytes, 'image.jpg');
    }
  }

  // -------------------------
  // UI helpers
  // -------------------------
  bool _isMe(_ChatMessage m) {
    final me = _meId;
    if (me != null) return m.authorId == me;
    if (_counterpartUserId != null) return m.authorId != _counterpartUserId;
    return false;
  }

  String _statusLabel(_ChatMessage m, bool isMe) {
    if (!isMe) return '';
    switch (m.status) {
      case _MsgStatus.sending:
        return 'Sending…';
      case _MsgStatus.failed:
        return 'Failed';
      case _MsgStatus.sent:
        return 'Sent';
      case _MsgStatus.delivered:
        return 'Delivered';
      case _MsgStatus.read:
        return 'Read';
    }
  }

  void _scrollToBottom() {
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (_scroll.hasClients) {
        try {
          _scroll.animateTo(_scroll.position.maxScrollExtent + 120, duration: const Duration(milliseconds: 250), curve: Curves.easeOut);
        } catch (_) {}
      }
    });
  }

  Widget _bubbleContent(_ChatMessage m) {
    if (m.kind == _MsgKind.image) {
      if (m.imageUrl != null && m.imageUrl!.isNotEmpty) {
        return ClipRRect(
          borderRadius: BorderRadius.circular(10),
          child: Image.network(m.imageUrl!, width: 220, height: 220, fit: BoxFit.cover, errorBuilder: (_, __, ___) => const Text('Image failed')),
        );
      }
      if (m.localImageBytes != null) {
        return ClipRRect(borderRadius: BorderRadius.circular(10), child: Image.memory(m.localImageBytes!, width: 220, height: 220, fit: BoxFit.cover));
      }
      return const Text('Image');
    }
    return Text(m.body ?? '', style: const TextStyle(fontSize: 15));
  }

  Widget _buildMessageTile(_ChatMessage m) {
    final isMe = _isMe(m);
    final align = isMe ? CrossAxisAlignment.end : CrossAxisAlignment.start;
    final bubbleColor = isMe ? Colors.teal.shade100 : Colors.grey.shade200;
    final time = DateFormat.Hm().format(m.createdAt);
    final status = _statusLabel(m, isMe);

    return Padding(
      padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 6),
      child: Row(mainAxisAlignment: isMe ? MainAxisAlignment.end : MainAxisAlignment.start, children: [
        if (!isMe) const SizedBox(width: 6),
        ConstrainedBox(
          constraints: const BoxConstraints(maxWidth: 760),
          child: Container(
            decoration: BoxDecoration(color: bubbleColor, borderRadius: BorderRadius.circular(10)),
            padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 10),
            child: Column(crossAxisAlignment: align, children: [
              _bubbleContent(m),
              const SizedBox(height: 6),
              Row(mainAxisSize: MainAxisSize.min, children: [
                Text(time, style: const TextStyle(fontSize: 11, color: Colors.black54)),
                if (status.isNotEmpty) ...[
                  const SizedBox(width: 8),
                  Text(status, style: const TextStyle(fontSize: 11, color: Colors.black54)),
                ],
                if (m.status == _MsgStatus.failed) ...[
                  const SizedBox(width: 8),
                  InkWell(onTap: () => _retry(m), child: const Row(children: [Icon(Icons.error_outline, color: Colors.red, size: 14), SizedBox(width: 4), Text('Retry', style: TextStyle(color: Colors.red, fontSize: 12))])),
                ],
                if (m.status == _MsgStatus.sending) ...[
                  const SizedBox(width: 8),
                  const SizedBox(width: 12, height: 12, child: CircularProgressIndicator(strokeWidth: 1.5)),
                ],
              ]),
            ]),
          ),
        ),
        if (isMe) const SizedBox(width: 6),
      ]),
    );
  }

  Future<void> _onRefresh() async => _loadMessages();

  @override
  Widget build(BuildContext context) {
    final title = (_appBarTitle.isNotEmpty) ? _appBarTitle : widget.title;

    return Scaffold(
      appBar: AppBar(title: Text(title), actions: [IconButton(onPressed: _loadMessages, icon: const Icon(Icons.refresh), tooltip: 'Refresh')]),
      body: Column(children: [
        Expanded(
          child: _loading
              ? const Center(child: CircularProgressIndicator())
              : _error != null
                  ? Center(
                      child: Padding(
                        padding: const EdgeInsets.all(16),
                        child: Column(mainAxisSize: MainAxisSize.min, children: [
                          Text(_error!, style: const TextStyle(color: Colors.red)),
                          const SizedBox(height: 12),
                          ElevatedButton.icon(onPressed: _loadMessages, icon: const Icon(Icons.refresh), label: const Text('Retry'))
                        ]),
                      ),
                    )
                  : RefreshIndicator(
                      onRefresh: _onRefresh,
                      child: ListView.builder(controller: _scroll, padding: const EdgeInsets.only(top: 8, bottom: 8), itemCount: _messages.length, itemBuilder: (_, i) => _buildMessageTile(_messages[i])),
                    ),
        ),
        SafeArea(
          top: false,
          child: Container(
            padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 6),
            color: Theme.of(context).scaffoldBackgroundColor,
            child: Row(children: [
              IconButton(onPressed: _pickAndSendImage, icon: const Icon(Icons.attach_file), tooltip: 'Send image'),
              Expanded(child: TextField(controller: _controller, minLines: 1, maxLines: 4, decoration: const InputDecoration(hintText: 'Type a message...', border: OutlineInputBorder(), isDense: true, contentPadding: EdgeInsets.symmetric(horizontal: 12, vertical: 10)), onSubmitted: (_) => _sendText())),
              const SizedBox(width: 8),
              FilledButton.icon(onPressed: _sendText, icon: const Icon(Icons.send), label: const Text('Send')),
            ]),
          ),
        ),
      ]),
    );
  }
}
