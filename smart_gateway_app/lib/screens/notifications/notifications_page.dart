import 'package:flutter/material.dart';
import 'package:intl/intl.dart';
import '../../services/notification_center.dart';

class NotificationsPage extends StatefulWidget {
  const NotificationsPage({super.key, this.onOpenAppointment});
  final void Function(int apptId)? onOpenAppointment;

  @override
  State<NotificationsPage> createState() => _NotificationsPageState();
}

class _NotificationsPageState extends State<NotificationsPage> {
  final _nc = NotificationCenter();
  List<LocalNotice> _items = [];
  final Set<int> _selected = {};
  bool _selectMode = false;

  @override
  void initState() {
    super.initState();
    _load();
  }

  Future<void> _load() async {
    _items = await _nc.list();
    if (mounted) setState(() {});
  }

  String _humanTime(DateTime dt) {
    final now = DateTime.now();
    final d = now.difference(dt);
    if (d.inSeconds < 60) return 'just now';
    if (d.inMinutes < 60) return '${d.inMinutes}m ago';
    if (d.inHours < 24) return '${d.inHours}h ago';
    if (d.inDays == 1) return 'yesterday';
    if (d.inDays < 7) return '${d.inDays}d ago';
    return DateFormat('MMM d, yyyy • h:mm a').format(dt);
    // Localize if needed
  }

  void _toggleSelect(int id) {
    if (_selected.contains(id)) {
      _selected.remove(id);
    } else {
      _selected.add(id);
    }
    setState(() {});
  }

  @override
  Widget build(BuildContext context) {
    final isWide = MediaQuery.of(context).size.width >= 600;

    return Scaffold(
      appBar: AppBar(
        title: const Text('Notifications'),
        actions: [
          if (isWide && !_selectMode && _items.isNotEmpty)
            TextButton.icon(
              onPressed: () => setState(() => _selectMode = true),
              icon: const Icon(Icons.select_all),
              label: const Text('Select'),
            ),
          if (_selectMode)
            TextButton.icon(
              onPressed: _selected.isEmpty
                  ? null
                  : () async {
                      await _nc.deleteMany(_selected);
                      _selected.clear();
                      _selectMode = false;
                      await _load();
                    },
              icon: const Icon(Icons.delete),
              label: const Text('Delete'),
            ),
          if (_items.isNotEmpty)
            IconButton(
              tooltip: 'Delete all',
              onPressed: () async {
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
                  if (mounted) setState(() { _items = []; _selected.clear(); _selectMode = false; });
                }
              },
              icon: const Icon(Icons.delete_sweep),
            ),
        ],
      ),
      body: SafeArea(
        child: _items.isEmpty
            ? const Center(child: Text('No notifications'))
            : ListView.separated(
                itemCount: _items.length,
                separatorBuilder: (_, __) => const Divider(height: 1),
                itemBuilder: (ctx, i) {
                  final n = _items[i];
                  final apptId = n.appointmentId;
                  final selected = _selected.contains(n.id);

                  IconData icon;
                  switch (n.type) {
                    case 'approved': icon = Icons.check_circle; break;
                    case 'rejected': icon = Icons.cancel; break;
                    case 'completed': icon = Icons.task_alt; break;
                    default: icon = Icons.alarm;
                  }

                  final subtitle = [
                    if (apptId != null) '#$apptId',
                    _humanTime(n.at),
                  ].join(' • ');

                  return InkWell(
                    onTap: () async {
                      if (_selectMode) {
                        _toggleSelect(n.id);
                        return;
                      }
                      await _nc.markRead(n.id);
                      if (apptId != null && widget.onOpenAppointment != null) {
                        widget.onOpenAppointment!(apptId);
                      }
                      if (mounted) setState(() {});
                    },
                    onLongPress: () {
                      if (!_selectMode) {
                        setState(() => _selectMode = true);
                      }
                      _toggleSelect(n.id);
                    },
                    child: ListTile(
                      leading: Icon(icon),
                      title: Text(n.title, maxLines: 1, overflow: TextOverflow.ellipsis),
                      subtitle: Text(
                        '${n.body}${apptId != null ? ' ' : ''}',
                        maxLines: 2,
                        overflow: TextOverflow.ellipsis,
                      ),
                      trailing: Row(
                        mainAxisSize: MainAxisSize.min,
                        children: [
                          Text(subtitle, style: Theme.of(context).textTheme.bodySmall),
                          const SizedBox(width: 10),
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
                  );
                },
              ),
      ),
    );
  }
}
