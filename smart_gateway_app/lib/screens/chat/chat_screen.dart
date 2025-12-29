// lib/screens/chat/chat_screen.dart
import 'dart:async';
import 'package:flutter/material.dart';
import 'package:intl/intl.dart';

import '../../Services/Api.dart' show Api;

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
  String id; // server id or local-temp id
  final int authorId;
  final String body;
  final DateTime createdAt;
  bool sending;
  bool failed;

  _ChatMessage({
    required this.id,
    required this.authorId,
    required this.body,
    required this.createdAt,
    this.sending = false,
    this.failed = false,
  });
}

class _ChatScreenState extends State<ChatScreen> {
  final _controller = TextEditingController();
  final _scroll = ScrollController();

  bool _loading = true;
  String? _error;
  List<_ChatMessage> _messages = [];
  Timer? _pollTimer;
  bool _sending = false;

  // Header info
  String _counterpartName = '';
  String _appBarTitle = '';
  int? _counterpartUserId;

  // Me info
  String? _myRole; // doctor/patient
  int? get _meId => Api.currentUserId;

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

  Future<void> _init() async {
    await _ensureMe();
    await _loadAppointmentInfo();
    await _loadMessages();
    _pollTimer =
        Timer.periodic(const Duration(seconds: 50), (_) => _loadMessages(silent: true));
  }

  @override
  void dispose() {
    _pollTimer?.cancel();
    _controller.dispose();
    _scroll.dispose();
    super.dispose();
  }

  // -------------------------
  // whoami -> sets Api.currentUserId and role
  // -------------------------
  Future<void> _ensureMe() async {
    if (Api.currentUserId != null) return;
    try {
      final r = await Api.get('/whoami');
      if (r is Map) {
        final m = Map<String, dynamic>.from(r);

        final idRaw = m['id'];
        if (idRaw != null) {
          Api.currentUserId =
              (idRaw is num) ? idRaw.toInt() : int.tryParse('$idRaw');
        }

        final roleRaw = m['role'];
        if (roleRaw != null) {
          _myRole = roleRaw.toString().toLowerCase();
        }
      }
    } catch (_) {
      // ignore
    }
  }

  // -------------------------
  // Appointment header info (patient sees doctor name, doctor sees patient name)
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

      final doctor =
          (appt['doctor'] is Map) ? Map<String, dynamic>.from(appt['doctor']) : null;
      final patient =
          (appt['patient'] is Map) ? Map<String, dynamic>.from(appt['patient']) : null;

      final doctorName = (doctor?['name'] ??
              doctor?['full_name'] ??
              appt['doctor_name'] ??
              appt['doctor_display_name'] ??
              appt['doctor_full_name'] ??
              '')
          .toString();

      final patientName = (patient?['name'] ??
              patient?['full_name'] ??
              appt['patient_name'] ??
              appt['patient_display_name'] ??
              appt['patient_full_name'] ??
              '')
          .toString();

      int? doctorUserId;
      final dUidRaw =
          appt['doctor_user_id'] ?? doctor?['user_id'] ?? doctor?['id'];
      if (dUidRaw != null) {
        doctorUserId =
            (dUidRaw is num) ? dUidRaw.toInt() : int.tryParse('$dUidRaw');
      }

      int? patientUserId;
      final pUidRaw =
          appt['patient_user_id'] ?? patient?['user_id'] ?? patient?['id'];
      if (pUidRaw != null) {
        patientUserId =
            (pUidRaw is num) ? pUidRaw.toInt() : int.tryParse('$pUidRaw');
      }

      final me = _meId;
      bool iAmDoctor = false;
      if (_myRole != null) {
        iAmDoctor = _myRole!.contains('doctor');
      } else if (me != null && doctorUserId != null) {
        iAmDoctor = me == doctorUserId;
      }

      String name = iAmDoctor ? patientName : doctorName;
      int? counterpartId = iAmDoctor ? patientUserId : doctorUserId;

      if (name.trim().isEmpty) {
        if (doctorName.trim().isNotEmpty) {
          name = doctorName;
        } else if (patientName.trim().isNotEmpty) {
          name = patientName;
        } else {
          name = 'User';
        }
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

    try {
      final dynamic page =
          await Api.getMessages(widget.apptId, page: 1, pageSize: 200);

      List<dynamic> dataList = [];
      if (page == null) {
        dataList = [];
      } else if (page is List) {
        dataList = page;
      } else if (page is Map) {
        if (page['data'] is List) {
          dataList = List<dynamic>.from(page['data'] as List);
        } else if (page['messages'] is List) {
          dataList = List<dynamic>.from(page['messages'] as List);
        } else if (page['results'] is List) {
          dataList = List<dynamic>.from(page['results'] as List);
        } else if (page['items'] is List) {
          dataList = List<dynamic>.from(page['items'] as List);
        } else {
          if (page.containsKey('id') ||
              page.containsKey('body') ||
              page.containsKey('message') ||
              page.containsKey('text')) {
            dataList = [page];
          }
        }
      }

      final parsed = <_ChatMessage>[];
      for (final item in dataList) {
        if (item == null || item is! Map) continue;

        try {
          final m = Map<String, dynamic>.from(item);

          final id = (m['id'] ?? m['message_id'] ?? m['msg_id'] ?? '').toString();
          final body = (m['body'] ?? m['message'] ?? m['text'] ?? '').toString();

          // ✅ IMPORTANT FIX: backend uses sender_user_id
          final authorRaw =
              m['sender_user_id'] ?? // <--- from your FastAPI response
              m['author_id'] ??
              m['user_id'] ??
              m['sender_id'] ??
              m['from_id'] ??
              m['author'] ??
              0;

          final authorId = (authorRaw is num)
              ? authorRaw.toInt()
              : (int.tryParse(authorRaw?.toString() ?? '') ?? 0);

          DateTime created;
          final createdRaw =
              m['created_at'] ?? m['timestamp'] ?? m['ts'] ?? m['time'];

          if (createdRaw is String && createdRaw.isNotEmpty) {
            created = DateTime.tryParse(createdRaw) ?? DateTime.now();
          } else if (createdRaw is int) {
            created = createdRaw > 9999999999
                ? DateTime.fromMillisecondsSinceEpoch(createdRaw)
                : DateTime.fromMillisecondsSinceEpoch(createdRaw * 1000);
          } else if (createdRaw is num) {
            final v = createdRaw.toInt();
            created = v > 9999999999
                ? DateTime.fromMillisecondsSinceEpoch(v)
                : DateTime.fromMillisecondsSinceEpoch(v * 1000);
          } else {
            created = DateTime.now();
          }

          parsed.add(_ChatMessage(
            id: id.isEmpty ? UniqueKey().toString() : id,
            authorId: authorId,
            body: body,
            createdAt: created,
            sending: false,
            failed: false,
          ));
        } catch (_) {
          // skip malformed
        }
      }

      // keep optimistic "sending" messages so they don't disappear during polling
      final localSending = _messages.where((m) => m.sending).toList();

      setState(() {
        parsed.sort((a, b) => a.createdAt.compareTo(b.createdAt));
        _messages = [...parsed, ...localSending];
        _loading = false;
        _error = null;
      });

      _scrollToBottom();
    } catch (e) {
      final msg = 'Failed to load messages: $e';
      if (!silent) {
        setState(() {
          _loading = false;
          _error = msg;
        });
      } else {
        setState(() {
          _error = msg;
        });
      }
    }
  }

  // -------------------------
  // Send message
  // -------------------------
  Future<void> _sendMessage(String text) async {
    if (text.trim().isEmpty) return;
    if (_sending) return;

    await _ensureMe();

    final me = _meId ?? 0;
    final tempId = 'tmp-${DateTime.now().millisecondsSinceEpoch}';
    final now = DateTime.now();

    final optimistic = _ChatMessage(
      id: tempId,
      authorId: me,
      body: text,
      createdAt: now,
      sending: true,
      failed: false,
    );

    setState(() {
      _messages.add(optimistic);
      _sending = true;
      _controller.clear();
    });

    _scrollToBottom();

    try {
      final Map<String, dynamic> created =
          await Api.postMessage(widget.apptId, text, kind: 'text');

      // Backend returns: { ok: true, message_id: X, created_at: ... }
      final serverId = (created['id'] ?? created['message_id'] ?? '').toString();

      DateTime createdAt = now;
      final createdAtRaw = created['created_at'] ?? created['timestamp'] ?? created['ts'];
      if (createdAtRaw is String && createdAtRaw.isNotEmpty) {
        createdAt = DateTime.tryParse(createdAtRaw) ?? now;
      } else if (createdAtRaw is int) {
        createdAt = createdAtRaw > 9999999999
            ? DateTime.fromMillisecondsSinceEpoch(createdAtRaw)
            : DateTime.fromMillisecondsSinceEpoch(createdAtRaw * 1000);
      } else if (createdAtRaw is num) {
        final v = createdAtRaw.toInt();
        createdAt = v > 9999999999
            ? DateTime.fromMillisecondsSinceEpoch(v)
            : DateTime.fromMillisecondsSinceEpoch(v * 1000);
      }

      setState(() {
        for (int i = 0; i < _messages.length; i++) {
          if (_messages[i].id == tempId) {
            _messages[i] = _ChatMessage(
              id: serverId.isEmpty ? tempId : serverId,
              authorId: me,
              body: text,
              createdAt: createdAt,
              sending: false,
              failed: false,
            );
            break;
          }
        }
        _sending = false;
      });

      _loadMessages(silent: true);
    } catch (e) {
      setState(() {
        for (int i = 0; i < _messages.length; i++) {
          if (_messages[i].id == tempId) {
            _messages[i].sending = false;
            _messages[i].failed = true;
            break;
          }
        }
        _sending = false;
        _error = 'Send failed: $e';
      });
    }
  }

  void _retryMessage(_ChatMessage m) {
    if (!m.failed) return;
    setState(() {
      _messages.removeWhere((it) => it.id == m.id);
    });
    _sendMessage(m.body);
  }

  void _scrollToBottom() {
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (_scroll.hasClients) {
        try {
          _scroll.animateTo(
            _scroll.position.maxScrollExtent + 50,
            duration: const Duration(milliseconds: 250),
            curve: Curves.easeOut,
          );
        } catch (_) {}
      }
    });
  }

  bool _isMeMessage(_ChatMessage m) {
    final me = _meId;
    if (me != null) return m.authorId == me;

    // fallback (if whoami fails): if we know counterpart user id, everything else is mine
    if (_counterpartUserId != null) return m.authorId != _counterpartUserId;
    return false;
  }

  Widget _buildMessageTile(_ChatMessage m) {
    final isMe = _isMeMessage(m);
    final align = isMe ? CrossAxisAlignment.end : CrossAxisAlignment.start;
    final bubbleColor = isMe ? Colors.teal.shade100 : Colors.grey.shade200;
    final time = DateFormat.Hm().format(m.createdAt);

    return Padding(
      padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 6),
      child: Row(
        mainAxisAlignment: isMe ? MainAxisAlignment.end : MainAxisAlignment.start,
        children: [
          if (!isMe) const SizedBox(width: 6),
          ConstrainedBox(
            constraints: const BoxConstraints(maxWidth: 760),
            child: Container(
              decoration: BoxDecoration(
                color: bubbleColor,
                borderRadius: BorderRadius.circular(10),
              ),
              padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 10),
              child: Column(
                crossAxisAlignment: align,
                children: [
                  Text(m.body, style: const TextStyle(fontSize: 15)),
                  const SizedBox(height: 6),
                  Row(
                    mainAxisSize: MainAxisSize.min,
                    children: [
                      Text(
                        time,
                        style: const TextStyle(fontSize: 11, color: Colors.black54),
                      ),
                      if (m.sending) ...[
                        const SizedBox(width: 8),
                        const SizedBox(
                          width: 12,
                          height: 12,
                          child: CircularProgressIndicator(strokeWidth: 1.5),
                        ),
                      ],
                      if (m.failed) ...[
                        const SizedBox(width: 8),
                        InkWell(
                          onTap: () => _retryMessage(m),
                          child: const Row(
                            children: [
                              Icon(Icons.error_outline, color: Colors.red, size: 14),
                              SizedBox(width: 4),
                              Text(
                                'Retry',
                                style: TextStyle(color: Colors.red, fontSize: 12),
                              ),
                            ],
                          ),
                        ),
                      ],
                    ],
                  ),
                ],
              ),
            ),
          ),
          if (isMe) const SizedBox(width: 6),
        ],
      ),
    );
  }

  Future<void> _onRefresh() async {
    await _loadMessages();
  }

  @override
  Widget build(BuildContext context) {
    final title = (_appBarTitle.isNotEmpty) ? _appBarTitle : widget.title;

    return Scaffold(
      appBar: AppBar(
        title: Text(title),
        actions: [
          IconButton(
            onPressed: _loadMessages,
            icon: const Icon(Icons.refresh),
            tooltip: 'Refresh',
          ),
        ],
      ),
      body: Column(
        children: [
          Expanded(
            child: _loading
                ? const Center(child: CircularProgressIndicator())
                : _error != null
                    ? Center(
                        child: Padding(
                          padding: const EdgeInsets.all(16),
                          child: Column(
                            mainAxisSize: MainAxisSize.min,
                            children: [
                              Text(_error!, style: const TextStyle(color: Colors.red)),
                              const SizedBox(height: 12),
                              ElevatedButton.icon(
                                onPressed: _loadMessages,
                                icon: const Icon(Icons.refresh),
                                label: const Text('Retry'),
                              ),
                            ],
                          ),
                        ),
                      )
                    : RefreshIndicator(
                        onRefresh: _onRefresh,
                        child: ListView.builder(
                          controller: _scroll,
                          padding: const EdgeInsets.only(top: 8, bottom: 8),
                          itemCount: _messages.length,
                          itemBuilder: (_, i) => _buildMessageTile(_messages[i]),
                        ),
                      ),
          ),

          // Composer
          SafeArea(
            top: false,
            child: Container(
              padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 6),
              color: Theme.of(context).scaffoldBackgroundColor,
              child: Row(
                children: [
                  Expanded(
                    child: TextField(
                      controller: _controller,
                      minLines: 1,
                      maxLines: 4,
                      decoration: const InputDecoration(
                        hintText: 'Type a message...',
                        border: OutlineInputBorder(),
                        isDense: true,
                        contentPadding:
                            EdgeInsets.symmetric(horizontal: 12, vertical: 10),
                      ),
                      onSubmitted: (_) {
                        final txt = _controller.text.trim();
                        if (txt.isNotEmpty) _sendMessage(txt);
                      },
                    ),
                  ),
                  const SizedBox(width: 8),
                  FilledButton.icon(
                    onPressed: () {
                      final txt = _controller.text.trim();
                      if (txt.isEmpty) return;
                      _sendMessage(txt);
                    },
                    icon: const Icon(Icons.send),
                    label: const Text('Send'),
                  ),
                ],
              ),
            ),
          ),
        ],
      ),
    );
  }
}
