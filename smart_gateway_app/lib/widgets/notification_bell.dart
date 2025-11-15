// lib/widgets/notification_bell.dart
import 'dart:async';
import 'package:flutter/material.dart';
import '../services/notification_center.dart';

class NotificationBell extends StatefulWidget {
  const NotificationBell({super.key, this.onOpenAppointment});
  final void Function(int apptId)? onOpenAppointment;

  @override
  State<NotificationBell> createState() => _NotificationBellState();
}

class _NotificationBellState extends State<NotificationBell> {
  int _unread = 0;
  late final NotificationCenter _nc;
  StreamSubscription<int>? _sub;

  @override
  void initState() {
    super.initState();
    _nc = NotificationCenter();
    _init();
  }

  @override
  void dispose() {
    _sub?.cancel();
    super.dispose();
  }

  Future<void> _init() async {
    _unread = await _nc.unreadCount();
    if (mounted) setState(() {});
    _sub = _nc.unreadCountStream.listen((n) async {
      _unread = n;
      if (mounted) setState(() {});
    });
  }

  @override
  Widget build(BuildContext context) {
    return Stack(
      clipBehavior: Clip.none,
      children: [
        IconButton(
          icon: const Icon(Icons.notifications_none),
          tooltip: 'Notifications',
          onPressed: () async {
            await showModalBottomSheet(
              context: context,
              isScrollControlled: true,
              useSafeArea: true,
              showDragHandle: true,
              builder: (ctx) => _NotificationPanel(
                onOpenAppointment: widget.onOpenAppointment,
              ),
            );
            _unread = await _nc.unreadCount();
            if (mounted) setState(() {});
          },
        ),
        if (_unread > 0)
          Positioned(
            right: 7,
            top: 7,
            child: Container(
              width: 10,
              height: 10,
              decoration: BoxDecoration(
                color: Theme.of(context).colorScheme.error,
                shape: BoxShape.circle,
              ),
            ),
          ),
      ],
    );
  }
}

class _NotificationPanel extends StatefulWidget {
  const _NotificationPanel({this.onOpenAppointment});
  final void Function(int apptId)? onOpenAppointment;

  @override
  State<_NotificationPanel> createState() => _NotificationPanelState();
}

class _NotificationPanelState extends State<_NotificationPanel> {
  final _nc = NotificationCenter();
  List<LocalNotice> _items = [];
  final Set<int> _selected = {};
  bool _selectMode = false;
  StreamSubscription<int>? _sub;

  @override
  void initState() {
    super.initState();
    _load();
    // Auto-refresh the panel if new notices arrive while open
    _sub = _nc.unreadCountStream.listen((_) => _load());
  }

  @override
  void dispose() {
    _sub?.cancel();
    super.dispose();
  }

  Future<void> _load() async {
    _items = await _nc.list();
    if (mounted) setState(() {});
  }

  String _humanTime(DateTime dt) {
    final now = DateTime.now();
    final diff = now.difference(dt);
    if (diff.inSeconds < 60) return 'just now';
    if (diff.inMinutes < 60) return '${diff.inMinutes}m ago';
    if (diff.inHours < 24) return '${diff.inHours}h ago';
    if (diff.inDays == 1) return 'yesterday';
    if (diff.inDays < 7) return '${diff.inDays}d ago';
    final two = (int x) => x.toString().padLeft(2, '0');
    return '${dt.year}-${two(dt.month)}-${two(dt.day)} • ${two(dt.hour)}:${two(dt.minute)}';
  }

  void _toggleSelect(int id) {
    if (_selected.contains(id)) {
      _selected.remove(id);
    } else {
      _selected.add(id);
    }
    setState(() {});
  }

  Future<void> _deleteSelected() async {
    if (_selected.isEmpty) return;
    await _nc.deleteMany(_selected);
    _selected.clear();
    _selectMode = false;
    await _load();
  }

  Future<void> _deleteAll() async {
    if (_items.isEmpty) return;
    final ok = await showDialog<bool>(
      context: context,
      builder: (_) => AlertDialog(
        title: const Text('Delete all notifications?'),
        content: const Text('This action cannot be undone.'),
        actions: [
          TextButton(onPressed: () => Navigator.pop(context, false), child: const Text('Cancel')),
          FilledButton(onPressed: () => Navigator.pop(context, true), child: const Text('Delete all')),
        ],
      ),
    );
    if (ok == true) {
      await _nc.clear();
      if (mounted) setState(() {
        _items = [];
        _selected.clear();
        _selectMode = false;
      });
    }
  }

  void _selectAllOrNone() {
    if (_selected.length == _items.length) {
      _selected.clear();
    } else {
      _selected
        ..clear()
        ..addAll(_items.map((e) => e.id));
    }
    setState(() {});
  }

  @override
  Widget build(BuildContext context) {
    final isWide = MediaQuery.of(context).size.width >= 600;

    return Padding(
      padding: const EdgeInsets.fromLTRB(12, 8, 12, 12),
      child: Column(
        mainAxisSize: MainAxisSize.min,
        children: [
          // Header actions
          Row(
            children: [
              const Expanded(
                child: Text(
                  'Notifications',
                  style: TextStyle(fontSize: 18, fontWeight: FontWeight.w600),
                ),
              ),
              if (_items.isNotEmpty)
                IconButton(
                  tooltip: 'Delete all',
                  onPressed: _deleteAll,
                  icon: const Icon(Icons.delete_sweep),
                ),
              if (_items.any((n) => !n.read))
                TextButton(
                  onPressed: () async {
                    await _nc.markAllRead();
                    await _load();
                  },
                  child: const Text('Mark all read'),
                ),
              if (!_selectMode && _items.isNotEmpty)
                TextButton.icon(
                  onPressed: () => setState(() => _selectMode = true),
                  icon: const Icon(Icons.select_all),
                  label: const Text('Select'),
                ),
              if (_selectMode)
                Row(
                  children: [
                    TextButton(
                      onPressed: _selectAllOrNone,
                      child: Text(
                        _selected.length == _items.length ? 'Deselect all' : 'Select all',
                      ),
                    ),
                    const SizedBox(width: 4),
                    TextButton.icon(
                      onPressed: _selected.isEmpty ? null : _deleteSelected,
                      icon: const Icon(Icons.delete),
                      label: const Text('Delete'),
                    ),
                  ],
                ),
            ],
          ),
          const SizedBox(height: 6),

          if (_items.isEmpty)
            const Padding(
              padding: EdgeInsets.all(24),
              child: Text('No notifications yet.'),
            )
          else
            Flexible(
              child: ListView.separated(
                shrinkWrap: true,
                itemCount: _items.length,
                separatorBuilder: (_, __) => const Divider(height: 1),
                itemBuilder: (ctx, i) {
                  final n = _items[i];
                  final apptId = n.appointmentId;
                  final selected = _selected.contains(n.id);

                  IconData icon;
                  switch (n.type) {
                    case 'approved':
                      icon = Icons.check_circle;
                      break;
                    case 'rejected':
                      icon = Icons.cancel;
                      break;
                    case 'completed':
                      icon = Icons.task_alt;
                      break;
                    default:
                      icon = Icons.alarm;
                  }

                  final meta = [
                    if (apptId != null) '#$apptId',
                    _humanTime(n.at),
                  ].join(' • ');

                  return Dismissible(
                    key: ValueKey(n.id),
                    background: Container(
                      color: Theme.of(context).colorScheme.errorContainer,
                      padding: const EdgeInsets.only(left: 16),
                      alignment: Alignment.centerLeft,
                      child: const Icon(Icons.delete),
                    ),
                    secondaryBackground: Container(
                      color: Theme.of(context).colorScheme.errorContainer,
                      padding: const EdgeInsets.only(right: 16),
                      alignment: Alignment.centerRight,
                      child: const Icon(Icons.delete),
                    ),
                    onDismissed: (_) async {
                      await _nc.delete(n.id);
                      if (mounted) setState(() => _items.removeAt(i));
                    },
                    child: InkWell(
                      onTap: () async {
                        if (_selectMode) {
                          _toggleSelect(n.id);
                          return;
                        }
                        await _nc.markRead(n.id);
                        if (apptId != null && widget.onOpenAppointment != null) {
                          if (mounted) Navigator.of(context).pop(); // close panel
                          widget.onOpenAppointment!(apptId);
                        } else {
                          if (mounted) setState(() {});
                        }
                      },
                      onLongPress: () {
                        if (!_selectMode) setState(() => _selectMode = true);
                        _toggleSelect(n.id);
                      },
                      child: ListTile(
                        leading: Icon(icon),
                        title: Text(
                          n.title,
                          maxLines: 1,
                          overflow: TextOverflow.ellipsis,
                          style: TextStyle(
                            fontWeight: n.read ? FontWeight.w500 : FontWeight.w600,
                          ),
                        ),
                        subtitle: Column(
                          crossAxisAlignment: CrossAxisAlignment.start,
                          children: [
                            Text(
                              n.body,
                              maxLines: 2,
                              overflow: TextOverflow.ellipsis,
                            ),
                            const SizedBox(height: 2),
                            Text(
                              meta, // "#123 • 5m ago"
                              style: Theme.of(context).textTheme.bodySmall,
                            ),
                          ],
                        ),
                        trailing: Row(
                          mainAxisSize: MainAxisSize.min,
                          children: [
                            if (!n.read) const Icon(Icons.fiber_new, size: 18),
                            if (_selectMode)
                              Checkbox(
                                value: selected,
                                onChanged: (_) => _toggleSelect(n.id),
                              ),
                            IconButton(
                              tooltip: 'Delete',
                              icon: const Icon(Icons.close),
                              onPressed: () async {
                                await _nc.delete(n.id);
                                if (mounted) {
                                  _items.removeAt(i);
                                  setState(() {});
                                }
                              },
                            ),
                          ],
                        ),
                      ),
                    ),
                  );
                },
              ),
            ),
        ],
      ),
    );
  }
}
