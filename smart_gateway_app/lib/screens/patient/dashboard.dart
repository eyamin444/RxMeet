// lib/screens/patient/dashboard.dart
//
// Patient app: Doctors -> Book (compact calendar + capacity), My Appointments,
// Gallery (reports/prescriptions), Profile, Payment History.
// - Visit mode filter (online/offline) determines which schedules are shown
// - Patient books a schedule BLOCK (window), not a minute slot
// - Patient sees only THEIR OWN serial number
// - My Appointments: tabs (Pending default, History), search, sort, ASC/DESC,
//   pagination 10/page, row Delete (History only, soft-delete semantics)
// - Appointment Detail: cancel/change (only when progress == 'not_yet'),
//   rate after completion, scoped files (upload & patient-owned delete),
//   online video/chat, contact number copy/call (doctor & hospital),
//   show doctor name + avatar and copyable appointment ID, "View profile"
// - Logout navigates to LoginPage (no reload)
// - Payment History tab with receipt download
//
// NOTE: Some backend behaviors (reminders & email) are triggered server-side.
//
// ignore_for_file: use_build_context_synchronously

import 'dart:typed_data';

import 'dart:ui' as ui;
import 'dart:io' show File;
import 'dart:async'; 
import 'package:dio/dio.dart';
import 'package:file_picker/file_picker.dart';
import 'package:flutter/foundation.dart';
import 'package:flutter/material.dart';
import 'package:intl/intl.dart';
import 'package:url_launcher/url_launcher.dart';
import 'package:flutter/services.dart' show Clipboard, ClipboardData;
import 'package:flutter/foundation.dart' show kIsWeb, defaultTargetPlatform, TargetPlatform;
import 'package:file_saver/file_saver.dart';
import 'package:path_provider/path_provider.dart';  
import 'package:share_plus/share_plus.dart';
import '../../main.dart' show LoginPage; // for logout navigation
import '../../models.dart';
import '../../services/api.dart';
import '../../services/auth.dart';
import '../../widgets/snack.dart';
import '../../screens/video/video_screen.dart';
import '../../screens/chat/chat_screen.dart';
import '../../widgets/notification_bell.dart';
import '../../services/notification_sync.dart';
import '../payment/payment_screen.dart';
import 'package:smart_gateway_app/utils/download.dart';
import 'package:smart_gateway_app/utils/print_helper.dart';
//import 'package:smart_gateway_app/debug/test_notifications.dart';


// open URLs in the running tab (web) / same app (mobile)
Future<void> _openInSameTab(String url) async {
  try {
    await launchUrl(Uri.parse(url), webOnlyWindowName: '_self');
  } catch (_) {
    await launchUrl(Uri.parse(url), mode: LaunchMode.externalApplication);
  }
}

bool _isImageUrl(String url) {
  final u = url.toLowerCase();
  return u.endsWith('.png') ||
      u.endsWith('.jpg') ||
      u.endsWith('.jpeg') ||
      u.endsWith('.gif') ||
      u.endsWith('.webp');
}

// Opens an image in a centered lightbox; non-images open in the same tab/app
Future<void> showDocLightbox(
  BuildContext context, {
  required String title,
  required String url,
}) async {
  if (!_isImageUrl(url)) {
    await _openInSameTab(url);
    return;
  }
  await showDialog(
    context: context,
    barrierDismissible: true,
    barrierColor: Colors.black.withOpacity(0.75),
    builder: (_) => Dialog(
      insetPadding: const EdgeInsets.all(16),
      child: ConstrainedBox(
        constraints: const BoxConstraints(maxWidth: 980, maxHeight: 720),
        child: Column(
          children: [
// ==== NOTIFICATION TEST PANEL START ====
//const TestNotificationsPanel(),
// ==== NOTIFICATION TEST PANEL END ====

            // Header
            Container(
              padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 12),
              decoration: BoxDecoration(
                border: Border(bottom: BorderSide(color: Theme.of(context).dividerColor)),
              ),
              child: Row(
                children: [
                  Expanded(
                    child: Text(
                      title,
                      style: Theme.of(context).textTheme.titleMedium,
                      overflow: TextOverflow.ellipsis,
                    ),
                  ),
                  IconButton(
                    tooltip: 'Close',
                    onPressed: () => Navigator.pop(context),
                    icon: const Icon(Icons.close),
                  ),
                ],
              ),
            ),
            // Body
            Expanded(
              child: Padding(
                padding: const EdgeInsets.all(12),
                child: InteractiveViewer(
                  maxScale: 4,
                  child: Center(
                    child: Image.network(url, fit: BoxFit.contain),
                  ),
                ),
              ),
            ),
          ],
        ),
      ),
    ),
  );
}

class PatientDashboard extends StatefulWidget {
  const PatientDashboard({super.key, required this.me});
  final User me;

  @override
  State<PatientDashboard> createState() => _PatientDashboardState();
}

class _PatientDashboardState extends State<PatientDashboard> {
  int idx = 0;
final GlobalKey<_MyAppointmentsTabState> _apptsKey = GlobalKey<_MyAppointmentsTabState>();

  @override
  Widget build(BuildContext context) {
    final tabs = [
      const BrowseDoctorsTab(), 
      const _AppointmentsHomeTab(), 
      const _GalleryTab(),
      const _PaymentsTab(),
      const _ProfileTab(),
    ];
    return Scaffold(
      appBar: AppBar(
        title: const Text('Patient'),
          actions: [
            NotificationBell(
  onOpenAppointment: (id) {
    Navigator.of(context)
        .push(MaterialPageRoute(builder: (_) => _AppointmentDetailPage(apptId: id)))
        // ⬇️ refresh the Appointments tab state after returning
        .then((_) => _apptsKey.currentState?._load());
  },
),
          IconButton(
            tooltip: 'Logout',
            onPressed: () async {
              try {
                await AuthService.logout();
              } catch (_) {}
              if (!mounted) return;
              Navigator.of(context).pushAndRemoveUntil(
                MaterialPageRoute(builder: (_) => const LoginPage()),
                (r) => false,
              );
            },
            icon: const Icon(Icons.logout),
          ),
        ],
      ),
      body: tabs[idx],
      bottomNavigationBar: NavigationBar(
        selectedIndex: idx,
        onDestinationSelected: (v) => setState(() => idx = v),
        destinations: const [
          NavigationDestination(icon: Icon(Icons.local_hospital), label: 'Doctors'),
          NavigationDestination(icon: Icon(Icons.event), label: 'My Appts'),
          NavigationDestination(icon: Icon(Icons.photo_library), label: 'Reports'),
          NavigationDestination(icon: Icon(Icons.receipt_long), label: 'Payments'),
          NavigationDestination(icon: Icon(Icons.person), label: 'Profile'),
        ],
      ),
    );
  }
}

// ─────────────────────────────────────────────────────────────────────────────
//  FULL DOCTORS TAB (responsive / overflow-safe) 
// ─────────────────────────────────────────────────────────────────────────────

class BrowseDoctorsTab extends StatefulWidget {
  const BrowseDoctorsTab({super.key});
  @override
  State<BrowseDoctorsTab> createState() => _BrowseDoctorsTabState();
}

class _BrowseDoctorsTabState extends State<BrowseDoctorsTab> {
  // ───────────────────────────────── Data & state ─────────────────────────────────
  final _q = TextEditingController();
  final _scroll = ScrollController();

  // All doctors (from server), filtered, and paged-for-display
  final List<Doctor> _all = [];
  List<Doctor> _filtered = [];
  List<Doctor> _paged = [];

  // Paging (lazy list): load more on scroll
  static const int _pageSize = 24;
  int _page = 0;

  // Loading flags
  bool _initialLoading = true;
  bool _filtering = false;

  // Specialty
  List<String> _specialties = const ['All'];
  String _selectedSpecialty = 'All';

  // Filters
  bool _availableOnly = false;
  // any | today | tomorrow | 7d | custom
  String _availabilityPreset = 'any';
  bool _customIsRange = false;
  DateTime? _customFrom;
  DateTime? _customTo;

  // Mode: any | online | offline (enabled only when availableOnly is ON)
  String _mode = 'any';

  // Caches
  // "$doctorId|yyyy-MM-dd|mode" -> hasAvailability?
  final Map<String, bool> _availDayCache = {};
  // "$doctorId|mode" -> next available date (or null if none found within probe window)
  final Map<String, DateTime?> _nextCache = {};

  @override
  void initState() {
    super.initState();
    _bootstrap();
    _scroll.addListener(_onScroll);
  }

  @override
  void dispose() {
    _q.dispose();
    _scroll.dispose();
    super.dispose();
  }

  // ───────────────────────────────── Bootstrap ─────────────────────────────────
  Future<void> _bootstrap() async {
    setState(() {
      _initialLoading = true;
      _filtering = true;
    });
    try {
      await _loadDoctors();
      _buildSpecialtyListFrom(_all);
      await _applyFilters();
    } finally {
      if (!mounted) return;
      setState(() {
        _initialLoading = false;
        _filtering = false;
      });
    }
  }

  Future<void> _loadDoctors() async {
    final res = await Api.get('/doctors');
    final list = (res as List)
        .map((m) => Doctor.fromJson(Map<String, dynamic>.from(m as Map)))
        .toList();

    _all
      ..clear()
      ..addAll(list);
  }

  void _buildSpecialtyListFrom(List<Doctor> list) {
    final set = <String>{};
    for (final d in list) {
      final s = (d.specialty).trim();
      if (s.isNotEmpty) set.add(s);
    }
    final sorted = set.toList()
      ..sort((a, b) => a.toLowerCase().compareTo(b.toLowerCase()));
    _specialties = ['All', ...sorted];
  }

  // ──────────────────────────────── Utilities ─────────────────────────────────
  String _iso(DateTime d) =>
      '${d.year.toString().padLeft(4, '0')}-${d.month.toString().padLeft(2, '0')}-${d.day.toString().padLeft(2, '0')}';

  String _ddMMyyyy(DateTime d) =>
      '${d.day.toString().padLeft(2, '0')}-${d.month.toString().padLeft(2, '0')}-${d.year}';

  String _niceShort(DateTime d) {
    const w = ['Mon', 'Tue', 'Wed', 'Thu', 'Fri', 'Sat', 'Sun'];
    const m = ['Jan','Feb','Mar','Apr','May','Jun','Jul','Aug','Sep','Oct','Nov','Dec'];
    final wd = w[(d.weekday - 1).clamp(0, 6)];
    final mm = m[(d.month - 1).clamp(0, 11)];
    return '$wd, $mm ${d.day}';
  }

  String? _photoUrl(String? path) {
    if (path == null || path.isEmpty) return null;
    var p = path;
    if (p.startsWith('./')) p = p.substring(2);
    if (p.startsWith('/')) p = p.substring(1);
    if (p.startsWith('http://') || p.startsWith('https://')) return p;
    final base = Api.baseUrl.endsWith('/')
        ? Api.baseUrl.substring(0, Api.baseUrl.length - 1)
        : Api.baseUrl;
    return '$base/$p';
  }

  DateTimeRange? _activeWindow() {
    final now = DateTime.now();
    final today = DateTime(now.year, now.month, now.day);

    switch (_availabilityPreset) {
      case 'today':
        return DateTimeRange(start: today, end: today);
      case 'tomorrow':
        final d = today.add(const Duration(days: 1));
        return DateTimeRange(start: d, end: d);
      case '7d':
        return DateTimeRange(start: today, end: today.add(const Duration(days: 7)));
      case 'custom':
        if (_customFrom == null) return null;
        final s = DateTime(_customFrom!.year, _customFrom!.month, _customFrom!.day);
        final e = DateTime((_customTo ?? _customFrom!).year, (_customTo ?? _customFrom!).month, (_customTo ?? _customFrom!).day);
        final start = s.isBefore(e) ? s : e;
        final end = e.isAfter(s) ? e : s;
        return DateTimeRange(start: start, end: end);
      default:
        return null; // 'any'
    }
  }

  String _windowHeader() {
    if (!_availableOnly) return '';
    final rng = _activeWindow();
    if (_availabilityPreset == 'any' || rng == null) return 'Any time';
    final same = rng.start.year == rng.end.year &&
        rng.start.month == rng.end.month &&
        rng.start.day == rng.end.day;
    if (same) return _ddMMyyyy(rng.start);
    return '${_ddMMyyyy(rng.start)} to ${_ddMMyyyy(rng.end)}';
  }

  bool get _clearVisible =>
      _q.text.trim().isNotEmpty ||
      _selectedSpecialty != 'All' ||
      _availableOnly ||
      _availabilityPreset != 'any' ||
      _mode != 'any';

  void _clearAll() {
    setState(() {
      _q.clear();
      _selectedSpecialty = 'All';
      _availableOnly = false;
      _availabilityPreset = 'any';
      _customIsRange = false;
      _customFrom = null;
      _customTo = null;
      _mode = 'any';
    });
    _applyFilters();
  }

  // ─────────────────────────── Availability helpers ───────────────────────────
  Future<bool> _hasBlocksOn(int doctorId, DateTime day, String mode) async {
    final m = (mode == 'online' || mode == 'offline') ? mode : 'any';
    final key = '$doctorId|${_iso(day)}|$m';
    final cached = _availDayCache[key];
    if (cached != null) return cached;

    try {
      final q = (m == 'any') ? {'day': _iso(day)} : {'day': _iso(day), 'visit_mode': m};
      final res = await Api.get('/doctors/$doctorId/blocks', query: q);
      final ok = (res is List) && res.isNotEmpty;
      _availDayCache[key] = ok;
      return ok;
    } catch (_) {
      _availDayCache[key] = false;
      return false;
    }
  }

  Future<Map<String, dynamic>?> _findEarliestInWindow(
      int doctorId, DateTime start, DateTime end, String mode) async {
    DateTime cur = DateTime(start.year, start.month, start.day);
    final last = DateTime(end.year, end.month, end.day);

    while (!cur.isAfter(last)) {
      if (mode == 'any') {
        final on = await _hasBlocksOn(doctorId, cur, 'online');
        final off = await _hasBlocksOn(doctorId, cur, 'offline');
        if (on || off) {
          return {
            'date': cur,
            'mode': (on && off) ? 'online' : (on ? 'online' : 'offline'),
          };
        }
      } else {
        if (await _hasBlocksOn(doctorId, cur, mode)) {
          return {'date': cur, 'mode': mode};
        }
      }
      cur = cur.add(const Duration(days: 1));
    }
    return null;
  }

  Future<Map<String, dynamic>?> _nextAvailableAnyMode(int doctorId) async {
    Future<DateTime?> _probe(String m) async {
      final k = '$doctorId|$m';
      if (_nextCache.containsKey(k)) return _nextCache[k];
      final now = DateTime.now();
      final end = now.add(const Duration(days: 30));
      final r = await _findEarliestInWindow(doctorId, now, end, m);
      final dt = r == null ? null : r['date'] as DateTime;
      _nextCache[k] = dt;
      return dt;
    }

    final on = await _probe('online');
    final off = await _probe('offline');
    if (on == null && off == null) return null;
    if (on == null) return {'date': off, 'mode': 'offline'};
    if (off == null) return {'date': on, 'mode': 'online'};
    return on.isBefore(off) ? {'date': on, 'mode': 'online'} : {'date': off, 'mode': 'offline'};
  }

  // ───────────────────────────────── Filtering ─────────────────────────────────
  Future<void> _applyFilters() async {
    setState(() {
      _filtering = true;
      _filtered = const [];
      _paged = const [];
      _page = 0;
    });

    final nameQ = _q.text.trim().toLowerCase();

    final base = _all.where((d) {
      if (_selectedSpecialty != 'All' &&
          d.specialty.toLowerCase() != _selectedSpecialty.toLowerCase()) {
        return false;
      }
      if (nameQ.isNotEmpty && !d.name.toLowerCase().contains(nameQ)) {
        return false;
      }
      return true;
    }).toList();

    if (!_availableOnly) {
      setState(() {
        _filtered = base;
      });
      _resetPaging();
      for (final d in _firstN(base, _pageSize * 2)) {
        _nextAvailableAnyMode(d.id);
      }
      setState(() => _filtering = false);
      return;
    }

    final rng = _activeWindow();
    final today = DateTime.now();
    final start = (rng?.start) ?? DateTime(today.year, today.month, today.day);
    final DateTime end = (rng == null && _availabilityPreset == 'any')
        ? start.add(const Duration(days: 14))
        : rng!.end;

    const concurrency = 6;
    final out = <Doctor>[];

    for (int i = 0; i < base.length; i += concurrency) {
      final chunk = base.sublist(i, (i + concurrency).clamp(0, base.length));
      final results = await Future.wait(chunk.map((d) async {
        final hit = await _findEarliestInWindow(d.id, start, end, _mode);
        if (hit != null) {
          final m = hit['mode'] as String;
          final dt = hit['date'] as DateTime;
          final kc = '${d.id}|$m';
          final prev = _nextCache[kc];
          if (prev == null || dt.isBefore(prev)) _nextCache[kc] = dt;
          return d;
        }
        return null;
      }));

      out.addAll(results.whereType<Doctor>());

      if (mounted) {
        setState(() {
          _filtered = List<Doctor>.from(out);
        });
        _resetPaging();
      }
    }

    if (mounted) setState(() => _filtering = false);
  }

  Iterable<T> _firstN<T>(List<T> list, int n) => list.take(n.clamp(0, list.length));

  void _resetPaging() {
    _page = 0;
    _paged = [];
    _loadMore();
  }

  void _loadMore() {
    if (_page * _pageSize >= _filtered.length) return;
    final start = _page * _pageSize;
    final end = (start + _pageSize).clamp(0, _filtered.length);
    _paged.addAll(_filtered.sublist(start, end));
    _page++;
    if (mounted) setState(() {});
  }

  void _onScroll() {
    if (_scroll.position.pixels > _scroll.position.maxScrollExtent - 600) {
      _loadMore();
    }
  }

  // ─────────────────────────────── Date pickers ───────────────────────────────
  Future<void> _pickCustom() async {
    if (_customIsRange) {
      final now = DateTime.now();
      final first = DateTime(now.year, now.month, now.day);
      final last = first.add(const Duration(days: 365));
      final initial = DateTimeRange(
        start: _customFrom ?? first,
        end: _customTo ?? (_customFrom ?? first),
      );
      final range = await showDateRangePicker(
        context: context,
        firstDate: first,
        lastDate: last,
        initialDateRange: initial,
        saveText: 'Apply',
      );
      if (range != null) {
        setState(() {
          _availabilityPreset = 'custom';
          _customFrom = range.start;
          _customTo = range.end;
        });
        await _applyFilters();
      }
    } else {
      final now = DateTime.now();
      final first = DateTime(now.year, now.month, now.day);
      final last = first.add(const Duration(days: 365));
      final picked = await showDatePicker(
        context: context,
        firstDate: first,
        lastDate: last,
        initialDate: _customFrom ?? first,
      );
      if (picked != null) {
        setState(() {
          _availabilityPreset = 'custom';
          _customFrom = picked;
          _customTo = picked;
        });
        await _applyFilters();
      }
    }
  }

  // ─────────────────────────────────── UI ────────────────────────────────────
  @override
  Widget build(BuildContext context) {
    final mq = MediaQuery.of(context);
    final width = mq.size.width;
    final isLandscape = mq.orientation == Orientation.landscape;
    final compact = width < 720 || (width < 900 && isLandscape);

    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        Padding(
          padding: const EdgeInsets.fromLTRB(12, 12, 12, 6),
          child: compact ? _topCompact() : _topInline(),
        ),

        if (_availableOnly)
          Padding(
            padding: const EdgeInsets.fromLTRB(16, 0, 16, 6),
            child: Wrap(
              spacing: 8,
              runSpacing: 8,
              children: [
                _chipLabel(_windowHeader()),
                if (_mode != 'any') _chipLabel('Mode: ${_mode[0].toUpperCase()}${_mode.substring(1)}'),
              ],
            ),
          ),

        Expanded(
          child: _initialLoading
              ? const Center(child: CircularProgressIndicator())
              : _paged.isEmpty
                  ? Center(child: Text(_filtering ? 'Filtering…' : 'No doctors match the filters.'))
                  : RefreshIndicator(
                      onRefresh: _bootstrap,
                      child: ListView.builder(
                        controller: _scroll,
                        padding: const EdgeInsets.only(bottom: 96),
                        itemCount: _paged.length + 1,
                        itemBuilder: (ctx, i) {
                          if (i == _paged.length) {
                            final more = _page * _pageSize < _filtered.length;
                            return more
                                ? const Padding(
                                    padding: EdgeInsets.all(16),
                                    child: Center(
                                      child: SizedBox(
                                        width: 20,
                                        height: 20,
                                        child: CircularProgressIndicator(strokeWidth: 2),
                                      ),
                                    ),
                                  )
                                : const SizedBox.shrink();
                          }
                          final d = _paged[i];
                          final bool showHeader = (i == 0) ||
                              (_paged[i - 1].specialty.toLowerCase() != d.specialty.toLowerCase());
                          return Column(
                            crossAxisAlignment: CrossAxisAlignment.stretch,
                            children: [
                              if (showHeader)
                                Padding(
                                  padding: const EdgeInsets.fromLTRB(16, 12, 16, 6),
                                  child: Row(
                                    children: [
                                      Icon(Icons.local_hospital, color: Theme.of(context).colorScheme.primary),
                                      const SizedBox(width: 8),
                                      Text(
                                        d.specialty.isEmpty ? 'General' : d.specialty,
                                        style: Theme.of(context).textTheme.titleMedium?.copyWith(fontWeight: FontWeight.w800),
                                      ),
                                    ],
                                  ),
                                ),
                              _doctorCard(d),
                            ],
                          );
                        },
                      ),
                    ),
        ),
      ],
    );
  }

  // ───────────────────────── Top bars (responsive, overflow-safe) ─────────────────────────
  Widget _topCompact() {
    return Row(
      children: [
        Expanded(child: _searchPill()),
        const SizedBox(width: 8),
        if (_clearVisible)
          TextButton.icon(
            onPressed: _clearAll,
            icon: const Icon(Icons.clear),
            label: const Text('Clear'),
          ),
        const SizedBox(width: 4),
        FilledButton.icon(
          onPressed: _openFilterSheet,
          icon: const Icon(Icons.tune),
          label: const Text('Filter'),
        ),
      ],
    );
  }

  Widget _topInline() {
    return LayoutBuilder(
      builder: (ctx, c) {
        return Wrap(
          spacing: 12,
          runSpacing: 10,
          crossAxisAlignment: WrapCrossAlignment.end,
          children: [
            SizedBox(width: c.maxWidth.clamp(0, 560), child: _searchPill()),
            _labeledBox('Specialty', _specialtyDropdown(), width: 240),
            _switchBox(),
            _labeledBox('Availability', _availabilityDropdown(), width: 220),
            _labeledBox('Mode', _modeDropdown(), width: 160),
            if (_clearVisible)
              TextButton.icon(
                onPressed: _clearAll,
                icon: const Icon(Icons.clear),
                label: const Text('Clear'),
              ),
          ],
        );
      },
    );
  }

  Widget _switchBox() {
    return Container(
      padding: const EdgeInsets.only(bottom: 6),
      child: Row(
        mainAxisSize: MainAxisSize.min,
        children: [
          Switch(
            value: _availableOnly,
            onChanged: (v) async {
              setState(() => _availableOnly = v);
              await _applyFilters();
            },
          ),
          const SizedBox(width: 6),
          const Text('Available only'),
        ],
      ),
    );
  }

  Widget _labeledBox(String label, Widget child, {double? width}) {
    return SizedBox(
      width: width,
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Text(label, style: Theme.of(context).textTheme.bodySmall),
          const SizedBox(height: 6),
          child,
        ],
      ),
    );
  }

  Widget _searchPill() {
    return Container(
      height: 46,
      decoration: BoxDecoration(
        color: Theme.of(context).colorScheme.surface,
        borderRadius: BorderRadius.circular(999),
        border: Border.all(color: Theme.of(context).dividerColor),
        boxShadow: [
          BoxShadow(
            blurRadius: 8,
            offset: const Offset(0, 2),
            color: const Color(0xFF000000).withOpacity(0.04),
          ),
        ],
      ),
      child: Row(
        children: [
          const SizedBox(width: 12),
          const Icon(Icons.search, size: 20),
          const SizedBox(width: 8),
          Expanded(
            child: TextField(
              controller: _q,
              textInputAction: TextInputAction.search,
              decoration: const InputDecoration(
                hintText: 'Search doctors…',
                border: InputBorder.none,
              ),
              onChanged: (_) => _applyFilters(),
              onSubmitted: (_) => _applyFilters(),
            ),
          ),
          if (_q.text.isNotEmpty)
            IconButton(
              icon: const Icon(Icons.close),
              tooltip: 'Clear search',
              onPressed: () {
                _q.clear();
                _applyFilters();
              },
            ),
          const SizedBox(width: 4),
        ],
      ),
    );
  }

  Widget _chipLabel(String text) {
    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 6),
      decoration: BoxDecoration(
        border: Border.all(color: Theme.of(context).dividerColor),
        borderRadius: BorderRadius.circular(999),
      ),
      child: Text(text, style: Theme.of(context).textTheme.bodySmall),
    );
  }

  // ───────────────────────────── Filter widgets ─────────────────────────────
  Widget _specialtyDropdown() {
    final safeValue = _specialties.contains(_selectedSpecialty)
        ? _selectedSpecialty
        : 'All';
    return DropdownButtonHideUnderline(
      child: DropdownButton<String>(
        isExpanded: true,
        value: safeValue,
        items: _specialties
            .map((s) => DropdownMenuItem(value: s, child: Text(s)))
            .toList(),
        onChanged: (v) async {
          setState(() => _selectedSpecialty = v ?? 'All');
          await _applyFilters();
        },
      ),
    );
  }

  Widget _availabilityDropdown() {
    final items = const [
      DropdownMenuItem(value: 'any', child: Text('Any time')),
      DropdownMenuItem(value: 'today', child: Text('Today')),
      DropdownMenuItem(value: 'tomorrow', child: Text('Tomorrow')),
      DropdownMenuItem(value: '7d', child: Text('Next 7 days')),
      DropdownMenuItem(value: 'custom', child: Text('Custom…')),
    ];
    final safeValue =
        items.any((e) => e.value == _availabilityPreset) ? _availabilityPreset : 'any';

    return DropdownButtonHideUnderline(
      child: DropdownButton<String>(
        isExpanded: true,
        value: safeValue,
        items: items,
        onChanged: _availableOnly
            ? (v) async {
                if (v == null) return;
                if (v == 'custom') {
                  await _pickCustom();
                } else {
                  setState(() {
                    _availabilityPreset = v;
                    _customFrom = null;
                    _customTo = null;
                    _customIsRange = false;
                  });
                  await _applyFilters();
                }
              }
            : null,
      ),
    );
  }

  Widget _modeDropdown() {
    final items = const [
      DropdownMenuItem(value: 'any', child: Text('Any')),
      DropdownMenuItem(value: 'online', child: Text('Online')),
      DropdownMenuItem(value: 'offline', child: Text('Offline')),
    ];
    final safeValue = (['any', 'online', 'offline'].contains(_mode)) ? _mode : 'any';

    return DropdownButtonHideUnderline(
      child: DropdownButton<String>(
        isExpanded: true,
        value: safeValue,
        items: items,
        onChanged: _availableOnly
            ? (v) async {
                setState(() => _mode = v ?? 'any');
                await _applyFilters();
              }
            : null,
      ),
    );
  }

  Future<void> _openFilterSheet() async {
    await showModalBottomSheet<void>(
      context: context,
      useSafeArea: true,
      isScrollControlled: true,
      builder: (ctx) {
        return DraggableScrollableSheet(
          expand: false,
          initialChildSize: 0.85,
          minChildSize: 0.55,
          maxChildSize: 0.95,
          builder: (_, controller) {
            return ListView(
              controller: controller,
              padding: const EdgeInsets.fromLTRB(16, 12, 16, 16),
              children: [
                Center(
                  child: Container(
                    width: 36,
                    height: 4,
                    margin: const EdgeInsets.only(bottom: 12),
                    decoration: BoxDecoration(
                      color: Theme.of(context).dividerColor,
                      borderRadius: BorderRadius.circular(2),
                    ),
                  ),
                ),
                Row(
                  children: [
                    const Icon(Icons.tune),
                    const SizedBox(width: 8),
                    Text('Filters', style: Theme.of(context).textTheme.titleMedium),
                    const Spacer(),
                    if (_clearVisible)
                      TextButton.icon(
                        onPressed: () {
                          Navigator.pop(ctx);
                          _clearAll();
                        },
                        icon: const Icon(Icons.clear),
                        label: const Text('Clear'),
                      ),
                  ],
                ),
                const SizedBox(height: 12),
                _labeledBox('Specialty', _specialtyDropdown()),
                const SizedBox(height: 12),
                Row(
                  children: [
                    Switch(
                      value: _availableOnly,
                      onChanged: (v) => setState(() => _availableOnly = v),
                    ),
                    const SizedBox(width: 6),
                    const Text('Available only'),
                  ],
                ),
                const SizedBox(height: 12),
                _labeledBox('Availability', _availabilityDropdown()),
                const SizedBox(height: 12),
                _labeledBox('Mode', _modeDropdown()),
                const SizedBox(height: 16),
                Row(
                  mainAxisAlignment: MainAxisAlignment.end,
                  children: [
                    TextButton(
                      child: const Text('Cancel'),
                      onPressed: () => Navigator.pop(ctx),
                    ),
                    const SizedBox(width: 8),
                    FilledButton.icon(
                      icon: const Icon(Icons.check),
                      label: const Text('Apply'),
                      onPressed: () async {
                        Navigator.pop(ctx);
                        await _applyFilters();
                      },
                    ),
                  ],
                ),
                const SizedBox(height: 8),
                if (_availabilityPreset == 'custom') ...[
                  Row(
                    mainAxisAlignment: MainAxisAlignment.center,
                    children: [
                      ChoiceChip(
                        selected: !_customIsRange,
                        label: const Text('Single day'),
                        onSelected: (_) => setState(() => _customIsRange = false),
                      ),
                      const SizedBox(width: 8),
                      ChoiceChip(
                        selected: _customIsRange,
                        label: const Text('Date range'),
                        onSelected: (_) => setState(() => _customIsRange = true),
                      ),
                    ],
                  ),
                  const SizedBox(height: 8),
                  OutlinedButton.icon(
                    onPressed: _pickCustom,
                    icon: const Icon(Icons.calendar_today),
                    label: const Text('Choose date'),
                  ),
                ],
              ],
            );
          },
        );
      },
    );
  }

  // ─────────────────────────────── Doctor card ───────────────────────────────
  Widget _doctorCard(Doctor d) {
    final theme = Theme.of(context);
    final url = _photoUrl(d.photoPath);

    return Padding(
      padding: const EdgeInsets.fromLTRB(12, 6, 12, 6),
      child: InkWell(
        borderRadius: BorderRadius.circular(16),
        onTap: () => _openDoctor(d),
        child: Card(
          elevation: 0,
          color: theme.colorScheme.surfaceVariant.withOpacity(0.25),
          shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(16)),
          child: Padding(
            padding: const EdgeInsets.all(12),
            child: Row(
              children: [
                _safeAvatar(url, d.name),
                const SizedBox(width: 12),
                Expanded(
                  child: FutureBuilder<Map<String, dynamic>?>(
                    future: _availableOnly
                        ? _resolveEarliestForActiveWindow(d.id)
                        : _nextAvailableAnyMode(d.id),
                    builder: (ctx, snap) {
                      DateTime? next;
                      String? mode;
                      if (snap.hasData && snap.data != null) {
                        next = snap.data!['date'] as DateTime?;
                        mode = snap.data!['mode'] as String?;
                      }
                      return Column(
                        crossAxisAlignment: CrossAxisAlignment.start,
                        children: [
                          Row(
                            children: [
                              Expanded(
                                child: Text(
                                  d.name,
                                  maxLines: 1,
                                  overflow: TextOverflow.ellipsis,
                                  style: const TextStyle(fontWeight: FontWeight.w700, fontSize: 16),
                                ),
                              ),
                              Row(
                                children: List.generate(
                                  5,
                                  (i) => Icon(
                                    i < d.rating.clamp(0, 5) ? Icons.star : Icons.star_border,
                                    size: 16,
                                    color: const Color(0xFFFFC107),
                                  ),
                                ),
                              ),
                            ],
                          ),
                          const SizedBox(height: 4),
                          Text(d.category.isEmpty ? '—' : d.category,
                              style: Theme.of(context).textTheme.bodySmall),
                          const SizedBox(height: 6),
                          Row(
                            children: [
                              Icon(
                                next == null
                                    ? Icons.event_busy
                                    : (mode == 'online' ? Icons.wifi : Icons.apartment),
                                size: 16,
                                color: next == null
                                    ? const Color(0xFFD32F2F)
                                    : theme.colorScheme.primary,
                              ),
                              const SizedBox(width: 6),
                              Text(
                                next == null ? 'Not available' : 'Next: ${_niceShort(next)}',
                                style: theme.textTheme.bodySmall,
                              ),
                            ],
                          ),
                        ],
                      );
                    },
                  ),
                ),
              ],
            ),
          ),
        ),
      ),
    );
  }

  // CircleAvatar that never triggers the onBackgroundImageError assertion
  Widget _safeAvatar(String? url, String name) {
    final fallback = name.isNotEmpty ? name[0].toUpperCase() : '?';
    const double r = 26;

    if (url == null) {
      return CircleAvatar(radius: r, child: Text(fallback));
    }

    return CircleAvatar(
      radius: r,
      backgroundColor: Theme.of(context).colorScheme.surfaceVariant,
      child: ClipOval(
        child: Image.network(
          url,
          width: r * 2,
          height: r * 2,
          fit: BoxFit.cover,
          // If the image fails, show the initial instead of throwing/asserting
          errorBuilder: (_, __, ___) => Center(child: Text(fallback)),
        ),
      ),
    );
  }

  Future<Map<String, dynamic>?> _resolveEarliestForActiveWindow(int doctorId) async {
    final rng = _activeWindow();
    final now = DateTime.now();
    final start = rng?.start ?? DateTime(now.year, now.month, now.day);
    final end = rng?.end ?? start.add(const Duration(days: 14));
    return _findEarliestInWindow(doctorId, start, end, _mode);
  }

  void _openDoctor(Doctor d) {
    Navigator.of(context).push(
      MaterialPageRoute(builder: (_) => _DoctorProfile(doctorId: d.id)),
    );
  }
}


// ─────────────────────────────────────────────────────────────────────────────
// Doctor profile (bio, degrees, ratings) — Eclips-style UI (no extra imports)
// ─────────────────────────────────────────────────────────────────────────────

class _DoctorProfile extends StatefulWidget {
  const _DoctorProfile({required this.doctorId});
  final int doctorId;

  @override
  State<_DoctorProfile> createState() => _DoctorProfileState();
}
class _DoctorProfileState extends State<_DoctorProfile> {
    Doctor? doc;
    List<Map<String, String>> edu = [];   // normalized: degree/institute/year
    List<dynamic> ratings = [];
    bool loading = true;
      String docAddress = '';
  String docPhone = '';
  num? docVisitingFee;

    String? _absUrl(String? path) {
      if (path == null || path.isEmpty) return null;
      var p = path;
      if (p.startsWith('./')) p = p.substring(2);
      if (!p.startsWith('http')) {
        if (!p.startsWith('/')) p = '/$p';
        p = '${Api.baseUrl}$p';
      }
      return p;
    }

    @override
    void initState() {
      super.initState();
      _load();
    }

    Future<void> _load() async {
      setState(() => loading = true);
      try {
        final dJson = await Api.get('/doctors/${widget.doctorId}');
        final d = Doctor.fromJson((dJson as Map).cast<String, dynamic>());
                // Normalize contact/address/fee from flexible backends
        String _s(String k) => ((dJson as Map)[k]?.toString() ?? '').trim();

        final String address =
            _s('address').isNotEmpty ? _s('address')
          : _s('clinic_address').isNotEmpty ? _s('clinic_address')
          : _s('hospital_address').isNotEmpty ? _s('hospital_address')
          : _s('location');

        final String phone =
            _s('phone').isNotEmpty ? _s('phone')
          : _s('mobile').isNotEmpty ? _s('mobile')
          : _s('contact_phone').isNotEmpty ? _s('contact_phone')
          : _s('contact_number');

        num? visitingFee;
        for (final k in ['visiting_fee','visit_fee','fee','fees','amount','price']) {
          final v = (dJson as Map)[k];
          if (v == null) continue;
          if (v is num) { visitingFee = v; break; }
          final n = num.tryParse(v.toString().replaceAll(RegExp(r'[^0-9.\-]'), ''));
          if (n != null) { visitingFee = n; break; }
        }


        // Education
        final normalized = <Map<String, String>>[];
        try {
          final e = await Api.get('/doctors/${widget.doctorId}/education');
          if (e is List) {
            for (final row in e) {
              final m = (row as Map).cast<String, dynamic>();
              normalized.add({
                'degree': (m['degree'] ?? '').toString(),
                'institute': (m['institute'] ?? '').toString(),
                'year': (m['year'] ?? '').toString(),
              });
            }
          }
        } catch (_) {}

        // Fallback: background text (e.g., “MBBS, MD”)
        if (normalized.isEmpty) {
          final bg = (d.background).trim();
          if (bg.isNotEmpty) {
            final lines = bg.contains('\n') ? bg.split('\n') : bg.split(RegExp(r'[;,]'));
            for (var raw in lines) {
              final s = raw.trim();
              if (s.isEmpty) continue;
              final yearMatch = RegExp(r'\b(19|20)\d{2}\b').firstMatch(s);
              final year = yearMatch?.group(0) ?? '';
              normalized.add({
                'degree': s.replaceAll(RegExp(r'\(?(19|20)\d{2}\)?'), '').trim(),
                'institute': '',
                'year': year,
              });
            }
          }
        }

        // Ratings (read-only)
        List<dynamic> ratingsList = [];
        try {
          final r = await Api.get('/doctors/${widget.doctorId}/ratings');
          if (r is List) ratingsList = r;
        } catch (_) {}

        if (!mounted) return;
        if (!mounted) return;
        setState(() {
          doc = d;
          edu = normalized;
          ratings = ratingsList;
          // NEW
          docAddress = address;
          docPhone = phone;
          docVisitingFee = visitingFee;
          loading = false;
        });

      } catch (e) {
        if (!mounted) return;
        setState(() => loading = false);
        ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(content: Text('Failed to load doctor: $e')),
        );
      }
    }

    Widget _stars(num value, {double size = 18}) {
      final v = value.toDouble();
      final full = v.floor();
      final hasHalf = (v - full) >= 0.5;
      return Row(
        mainAxisSize: MainAxisSize.min,
        children: List.generate(5, (i) {
          if (i < full) return Icon(Icons.star, size: size);
          if (i == full && hasHalf) return Icon(Icons.star_half, size: size);
          return Icon(Icons.star_border, size: size);
        }),
      );
    }

    String _niceDate(String raw) {
      try {
        final dt = DateTime.parse(raw).toLocal();
        return '${dt.year}-${dt.month.toString().padLeft(2, '0')}-${dt.day.toString().padLeft(2, '0')}';
      } catch (_) {
        return raw;
      }
    }

    @override
    Widget build(BuildContext context) {
      if (loading || doc == null) {
        return const Scaffold(body: Center(child: CircularProgressIndicator()));
      }
      final d = doc!;
      final photoUrl = _absUrl(d.photoPath);
      final theme = Theme.of(context);
      final color = theme.colorScheme;

      return Scaffold(
        appBar: AppBar(
          leading: IconButton(
            icon: const Icon(Icons.arrow_back),
            onPressed: () => Navigator.of(context).maybePop(),
          ),
          title: const Text("Doctor's Profile Details"),
          centerTitle: false,
          elevation: 0,
        ),

        // Fixed CTA button
        bottomNavigationBar: SafeArea(
          minimum: const EdgeInsets.fromLTRB(16, 8, 16, 16),
          child: SizedBox(
            height: 52,
            child: FilledButton(
              onPressed: () {
                Navigator.of(context).push(
                  MaterialPageRoute(builder: (_) => _DoctorDetail(doctor: d)),
                );
              },
              child: const Text('Book Appointment Now'),
            ),
          ),
        ),

        body: RefreshIndicator(
          onRefresh: _load,
          child: ListView(
            padding: EdgeInsets.zero,
            children: [
              // Decorative header with BIG profile picture
              Container(
                height: 220,
                decoration: BoxDecoration(
                  gradient: LinearGradient(
                    colors: [color.primary.withOpacity(0.08), color.secondary.withOpacity(0.06)],
                    begin: Alignment.topLeft,
                    end: Alignment.bottomRight,
                  ),
                ),
                child: Align(
                  alignment: Alignment.bottomCenter,
                  child: Padding(
                    padding: const EdgeInsets.fromLTRB(16, 0, 16, 0),
                    child: Card(
                      elevation: 0,
                      shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(16)),
                      child: Padding(
                        padding: const EdgeInsets.all(16),
                        child: Row(
                          crossAxisAlignment: CrossAxisAlignment.center,
                          children: [
                            // BIG avatar (requested)
                            ClipRRect(
                              borderRadius: BorderRadius.circular(16),
                              child: photoUrl == null
                                  ? Container(
                                      width: 112,
                                      height: 112,
                                      color: color.surfaceVariant,
                                      child: const Icon(Icons.person, size: 60),
                                    )
                                  : Image.network(
                                      photoUrl,
                                      width: 112,
                                      height: 112,
                                      fit: BoxFit.cover,
                                      // Prevent web image errors from rendering as a big red text block
                                      errorBuilder: (context, error, stack) => Container(
                                        width: 112,
                                        height: 112,
                                        color: color.surfaceVariant,
                                        child: const Icon(Icons.person, size: 60),
                                      ),
                                    ),
                            ),
                            const SizedBox(width: 16),
                            // Minimal info: name, degrees (first line), specialty, rating
                            Expanded(
                              child: Column(
                                crossAxisAlignment: CrossAxisAlignment.start,
                                mainAxisSize: MainAxisSize.min,
                                children: [
                                  Text(
                                    d.name,
                                    style: theme.textTheme.titleLarge?.copyWith(fontWeight: FontWeight.w600),
                                  ),
                                  const SizedBox(height: 4),
                                  Text(
                                    // use first 1–2 degrees if available, else background
                                    edu.isNotEmpty
                                        ? edu.map((e) => (e['degree'] ?? '').trim())
                                            .where((s) => s.isNotEmpty)
                                            .take(2)
                                            .join(', ')
                                        : (d.background.isEmpty ? '—' : d.background),
                                    style: theme.textTheme.bodyMedium?.copyWith(color: color.primary),
                                  ),
                                  const SizedBox(height: 4),
                                  Text(d.specialty.isEmpty ? 'Specialist' : d.specialty),
                                  const SizedBox(height: 8),
                                  Row(
                                    children: [
                                      _stars(d.rating, size: 18),
                                      const SizedBox(width: 8),
                                      Text('${d.rating}.0', style: theme.textTheme.bodySmall),
                                    ],
                                  ),
                                ],
                              ),
                            ),
                          ],
                        ),
                      ),
                    ),
                  ),
                ),
              ),

              // Sections (only what you need)
              const SizedBox(height: 16),
              _SectionHeader(icon: Icons.school, title: 'Degrees / Education'),
              Padding(
                padding: const EdgeInsets.fromLTRB(16, 8, 16, 0),
                child: edu.isEmpty
                    ? const Text('—')
                    : Column(
                        children: edu.map((e) {
                          final degree = (e['degree'] ?? '').trim();
                          final institute = (e['institute'] ?? '').trim();
                          final year = (e['year'] ?? '').trim();
                          final subtitle = [institute, year].where((x) => x.isNotEmpty).join(' • ');
                          return ListTile(
                            dense: true,
                            contentPadding: EdgeInsets.zero,
                            leading: const Icon(Icons.verified_outlined),
                            title: Text(degree.isEmpty ? 'Degree' : degree),
                            subtitle: subtitle.isEmpty ? null : Text(subtitle),
                          );
                        }).toList(),
                      ),
              ),
              // Clinic & Contact Info
              if (docAddress.isNotEmpty || docVisitingFee != null || docPhone.isNotEmpty) ...[
                Padding(
                  padding: const EdgeInsets.fromLTRB(16, 0, 16, 0),
                  child: Card(
                    shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(14)),
                    child: Padding(
                      padding: const EdgeInsets.fromLTRB(12, 10, 12, 12),
                      child: Column(
                        crossAxisAlignment: CrossAxisAlignment.start,
                        children: [
                          Row(children: [
                            Icon(Icons.local_hospital, color: theme.colorScheme.primary),
                            const SizedBox(width: 8),
                            Text('Clinic & Contact Info', style: theme.textTheme.titleMedium),
                          ]),
                          const SizedBox(height: 8),

                          if (docAddress.isNotEmpty)
                            ListTile(
                              dense: true,
                              contentPadding: EdgeInsets.zero,
                              leading: const Icon(Icons.location_on_outlined),
                              title: Text(docAddress),
                            ),

                          if (docVisitingFee != null) ...[
                            const SizedBox(height: 2),
                            ListTile(
                              dense: true,
                              contentPadding: EdgeInsets.zero,
                              leading: const Icon(Icons.payments_outlined),
                              title: Text('Visiting fee: ${NumberFormat.currency(symbol: '').format(docVisitingFee)}'),
                            ),
                          ],

                          if (docPhone.isNotEmpty) ...[
                            const SizedBox(height: 2),
                            ListTile(
                              dense: true,
                              contentPadding: EdgeInsets.zero,
                              leading: const Icon(Icons.phone_outlined),
                              title: Text(docPhone),
                              trailing: IconButton(
                                tooltip: 'Call',
                                onPressed: () async {
                                  final uri = Uri.parse('tel:$docPhone');
                                  if (await canLaunchUrl(uri)) {
                                    await launchUrl(uri);
                                  }
                                },
                                icon: const Icon(Icons.phone),
                              ),
                            ),
                          ],
                        ],
                      ),
                    ),
                  ),
                ),
                const SizedBox(height: 16),
              ],

              const SizedBox(height: 20),
              _SectionHeader(icon: Icons.rate_review, title: 'Patient Ratings & Comments'),
              Padding(
                padding: const EdgeInsets.fromLTRB(16, 8, 16, 100), // extra bottom space above CTA
                child: ratings.isEmpty
                    ? const Text('No ratings yet.')
                    : Column(
                        children: ratings.map((r) {
                          final stars = (r['stars'] ?? 0) as num;
                          final comment = (r['comment'] ?? '').toString();
                          final when = (r['created_at'] ?? '').toString();
                          return Card(
                            margin: const EdgeInsets.symmetric(vertical: 6),
                            child: ListTile(
                              title: Row(
                                children: [
                                  _stars(stars, size: 16),
                                  const SizedBox(width: 8),
                                  Text(_niceDate(when), style: theme.textTheme.bodySmall),
                                ],
                              ),
                              subtitle: Padding(
                                padding: const EdgeInsets.only(top: 6),
                                child: Text(comment.isEmpty ? '—' : comment),
                              ),
                            ),
                          );
                        }).toList(),
                      ),
              ),
            ],
          ),
        ),
      );
    }
}

// Small section header widget
class _SectionHeader extends StatelessWidget {
  final IconData icon;
  final String title;
  const _SectionHeader({required this.icon, required this.title});
  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    return Padding(
      padding: const EdgeInsets.fromLTRB(16, 0, 16, 0),
      child: Row(
        children: [
          Icon(icon, color: theme.colorScheme.primary),
          const SizedBox(width: 8),
          Text(title, style: theme.textTheme.titleMedium),
        ],
      ),
    );
  }
}

// ─────────────────────────────────────────────────────────────────────────────
// Book flow: compact month calendar + schedule blocks + Confirm
// ─────────────────────────────────────────────────────────────────────────────
class _DoctorDetail extends StatefulWidget {
  const _DoctorDetail({required this.doctor});
  final Doctor doctor;

  @override
  State<_DoctorDetail> createState() => _DoctorDetailState();
}

// Reused by several places in this file (top-level helpers).
String _toHm(String raw) {
  if (raw.isEmpty) return '';
  final s = raw.trim();
  final colon = RegExp(r'^\d{1,2}:\d{2}$');
  if (colon.hasMatch(s)) {
    final parts = s.split(':');
    return '${parts[0].padLeft(2, '0')}:${parts[1]}';
  }
  final iso = DateTime.tryParse(s.replaceFirst(' ', 'T'));
  if (iso != null) return DateFormat('HH:mm').format(iso);
  final p = RegExp(r'(\d{1,2})[.: -](\d{2})').firstMatch(s);
  if (p != null) {
    final h = p.group(1)!; final m = p.group(2)!;
    return '${h.padLeft(2, '0')}:$m';
  }
  return '';
}
String _extractHm(Map<String, dynamic> m, List<String> keys) {
  for (final k in keys) {
    final v = m[k];
    if (v == null) continue;
    final hm = _toHm(v.toString());
    if (hm.isNotEmpty) return hm;
  }
  return '';
}

class _DoctorDetailState extends State<_DoctorDetail> {
  // UI state
  String visitMode = 'offline';
  final TextEditingController problem = TextEditingController();

  // Calendar state
  final DateFormat _dfIso = DateFormat('yyyy-MM-dd');
  DateTime monthAnchor = DateTime(DateTime.now().year, DateTime.now().month, 1);
  bool loading = true;
  final Map<String, List<Map<String, dynamic>>> blocksByDay = {};
  String? selectedDayKey;
  Map<String, dynamic>? selectedBlock;

  String _hDot(String hhmm) {
    final parts = hhmm.split(':');
    if (parts.length >= 2) {
      final h = int.tryParse(parts[0]) ?? 0;
      final m = int.tryParse(parts[1]) ?? 0;
      return '$h.${m.toString().padLeft(2, '0')}';
    }
    return hhmm;
  }

  @override
  void initState() {
    super.initState();
    _prefetchMonth();
  }

  int _daysInMonth(DateTime d) => DateTime(d.year, d.month + 1, 0).day;

Future<void> _prefetchMonth({String? mode, DateTime? anchor}) async {
  setState(() => loading = true);

  // CAPTURE the intent at call time
  final String useMode = (mode ?? visitMode);
  final DateTime useAnchor = (anchor ?? monthAnchor);

  // Build into a temp map to avoid race-condition overwrites
  final Map<String, List<Map<String, dynamic>>> tmp = {};
  String? tmpSelected;

  final days = _daysInMonth(useAnchor);
  final today = DateTime(DateTime.now().year, DateTime.now().month, DateTime.now().day);

  for (int day = 1; day <= days; day++) {
    final d = DateTime(useAnchor.year, useAnchor.month, day);
    if (d.isBefore(today)) continue;
    final key = _dfIso.format(d);

    List<Map<String, dynamic>> blocks = [];
    dynamic res;
    try {
    // Most backends expose /blocks — try this first to avoid noisy 404s.
    res = await Api.get('/doctors/${widget.doctor.id}/blocks',
        query: {'day': key, 'visit_mode': useMode});
    } catch (_) {
    try {
        res = await Api.get('/doctors/${widget.doctor.id}/schedules',
            query: {'day': key, 'visit_mode': useMode});
    } catch (_) {
        try {
        res = await Api.get('/doctors/${widget.doctor.id}/windows',
            query: {'day': key, 'visit_mode': useMode});
        } catch (_) {
        res = null;
        }
    }
    }

    Map<String, dynamic> mk({
      required String start,
      required String end,
      required int remaining,
      dynamic id,
    }) => {
      'start': start,
      'end': end,
      'remaining': remaining,
      'id': id ?? '${key}_${start}_$end',
    };

    if (res is Map) {
      final m = (res as Map).cast<String, dynamic>();

      if (m['date_rules'] is List) {
        for (final r0 in (m['date_rules'] as List)) {
          final r = (r0 as Map).cast<String, dynamic>();
          if ((r['date'] ?? '') != key) continue;
          final modeStr = (r['mode'] ?? r['visit_mode'] ?? '').toString().toLowerCase();
          if (modeStr.isNotEmpty && modeStr != useMode) continue;

          final max = r['max_patients'];
          final cap = max is num ? max.toInt() : int.tryParse('$max') ?? 0;

          final sStart = _extractHm(r, ['start','time_from','start_time','from','schedule_time_from']);
          final sEnd   = _extractHm(r, ['end','time_to','end_time','to','schedule_time_to']);
          if (sStart.isNotEmpty && sEnd.isNotEmpty) {
            blocks.add(mk(start: sStart, end: sEnd, remaining: cap <= 0 ? 0 : cap, id: r['id']));
          }
        }
      }

      if (blocks.isEmpty && m['blocks'] is List) {
        for (final b0 in (m['blocks'] as List)) {
          final b = (b0 as Map).cast<String, dynamic>();
          final modeStr = (b['mode'] ?? b['visit_mode'] ?? '').toString().toLowerCase();
          if (modeStr.isNotEmpty && modeStr != useMode) continue;
          final rem = b['remaining'] ?? b['available'] ?? b['available_seats'] ?? b['max_patients'] ?? 1;
          final r = rem is num ? rem.toInt() : int.tryParse('$rem') ?? 1;

          final sStart = _extractHm(b, ['start','time_from','start_time','from','schedule_time_from','slot_start']);
          final sEnd   = _extractHm(b, ['end','time_to','end_time','to','schedule_time_to','slot_end']);
          if (sStart.isNotEmpty && sEnd.isNotEmpty) {
            blocks.add(mk(start: sStart, end: sEnd, remaining: r <= 0 ? 0 : r, id: b['id']));
          }
        }
      }

      if (blocks.isEmpty && m['windows'] is List) {
        for (final w0 in (m['windows'] as List)) {
          final w = (w0 as Map).cast<String, dynamic>();
          final modeStr = (w['mode'] ?? w['visit_mode'] ?? '').toString().toLowerCase();
          if (modeStr.isNotEmpty && modeStr != useMode) continue;

          final rem = w['available'] ?? w['available_seats'] ?? 1;
          final r = rem is num ? rem.toInt() : int.tryParse('$rem') ?? 1;

          final sStart = _extractHm(w, ['start','time_from','start_time','from','schedule_time_from']);
          final sEnd   = _extractHm(w, ['end','time_to','end_time','to','schedule_time_to']);
          if (sStart.isNotEmpty && sEnd.isNotEmpty) {
            blocks.add(mk(start: sStart, end: sEnd, remaining: r <= 0 ? 0 : r, id: w['id']));
          }
        }
      }
    } else if (res is List) {
      for (final b0 in res) {
        final b = (b0 as Map).cast<String, dynamic>();
        final modeStr = (b['mode'] ?? b['visit_mode'] ?? '').toString().toLowerCase();
        if (modeStr.isNotEmpty && modeStr != useMode) continue;
        final rem = b['remaining'] ?? b['available'] ?? b['available_seats'] ?? b['max_patients'] ?? 1;
        final r = rem is num ? rem.toInt() : int.tryParse('$rem') ?? 1;

        final sStart = _extractHm(b, ['start','time_from','start_time','from','schedule_time_from']);
        final sEnd   = _extractHm(b, ['end','time_to','end_time','to','schedule_time_to']);
        if (sStart.isNotEmpty && sEnd.isNotEmpty) {
          blocks.add(mk(start: sStart, end: sEnd, remaining: r <= 0 ? 0 : r, id: b['id']));
        }
      }
    }

    if (blocks.isNotEmpty) {
      tmp[key] = blocks;
      tmpSelected ??= key;
    }
  }

  // choose the earliest key (stable)
  final keys = tmp.keys.toList()..sort();
  if (keys.isNotEmpty) tmpSelected = keys.first;

  if (!mounted) return;
  // Only commit if the inputs still match; otherwise drop stale results
  if (useMode != visitMode || useAnchor != monthAnchor) return;

  setState(() {
    blocksByDay
      ..clear()
      ..addAll(tmp);
    selectedDayKey = tmpSelected;
    loading = false;
  });
}

  // Try multiple payloads/endpoints to avoid 422/404 with heterogeneous backends
  Future<void> _confirm() async {
    if (selectedDayKey == null || selectedBlock == null) {
      showSnack(context, 'Pick a day and a time window first.');
      return;
    }

    final String day = selectedDayKey!;
    final String startHm = (selectedBlock!['start'] ?? '').toString();
    final String endHm   = (selectedBlock!['end'] ?? '').toString();
    final dynamic schedId = selectedBlock!['id'];
    final int doctorId = widget.doctor.id;

    String _iso(String hm) => '${day}T${hm.padLeft(5, '0')}:00';

    final List<String> endpoints = <String>[
      // canonical
      '/appointments',
      '/appointments/create',
      '/appointments/request',
      '/appointments/new',
      '/appointments/book',
      '/appointments/confirm',
      // patient-scoped
      '/patient/appointments',
      '/patient/appointments/create',
      '/patient/appointment',
      '/patient/appointment/create',
      // singular/legacy
      '/appointment',
      '/appointment/create',
      '/appointments/store',
      '/appointments/submit',
      // api-prefixed
      '/api/appointments',
      '/api/appointments/create',
      '/api/appointment',
      '/api/appointment/create',
    ];

    final List<Map<String, dynamic>> payloads = <Map<String, dynamic>>[
      // 1) schedule/window id
      {'doctor_id': doctorId, 'schedule_id': schedId, 'visit_mode': visitMode, 'patient_problem': problem.text},
      // 2) alt id key
      {'doctor_id': doctorId, 'window_id': schedId, 'visit_mode': visitMode, 'reason': problem.text},
      // 3) slot id naming
      {'doctor_id': doctorId, 'slot_id': schedId, 'visit_mode': visitMode, 'note': problem.text},
      // 4) date + HH:mm range
      {'doctor_id': doctorId, 'date': day, 'start': startHm, 'end': endHm, 'visit_mode': visitMode, 'patient_problem': problem.text},
      // 5) date + HH:mm alt keys
      {'doctor_id': doctorId, 'appointment_date': day, 'time_from': startHm, 'time_to': endHm, 'visit_mode': visitMode, 'note': problem.text},
      // 6) schedule_* keys
      {'doctor_id': doctorId, 'schedule_date': day, 'schedule_time_from': startHm, 'schedule_time_to': endHm, 'visit_mode': visitMode},
      // 7) ISO timestamps
      {'doctor_id': doctorId, 'start_time': _iso(startHm), 'end_time': _iso(endHm), 'visit_mode': visitMode, 'patient_problem': problem.text},
      // 8) ISO with from/to + mode
      {'doctor_id': doctorId, 'from': _iso(startHm), 'to': _iso(endHm), 'mode': visitMode, 'note': problem.text},
      // 9) minimalist
      {'doctor': doctorId, 'schedule': schedId, 'mode': visitMode, 'problem': problem.text},
    ];

    dynamic lastErr;
    for (final ep in endpoints) {
      for (final body in payloads) {
        try {
          final res = await Api.post(ep, data: body);
          if (res is Map && (res['id'] != null || res['appointment_id'] != null)) {
            final apptId = res['id'] ?? res['appointment_id'];
            showSnack(context, 'Appointment requested (#$apptId)');
            if (mounted) Navigator.pop(context);
            return;
          }
          showSnack(context, 'Appointment requested.');
          if (mounted) Navigator.pop(context);
          return;
        } on DioException catch (e) {
          final code = e.response?.statusCode;
          final data = e.response?.data;
          final body = data is String ? data : (data != null ? data.toString() : '');
          lastErr = 'HTTP $code ${e.requestOptions.method} ${e.requestOptions.uri} $body';
        } catch (e) {
          lastErr = e.toString();
        }
      }
    }

    showSnack(
      context,
      'Failed to create appointment. Tried: ${endpoints.join(', ')}.\nLast error: $lastErr',
    );
  }

    // Single day cell in the mini calendar (filled background for available days)
    Widget _dayCell(DateTime d, String key) {
    final colors = Theme.of(context).colorScheme;
    final bool inMonth = d.month == monthAnchor.month;
    final bool isPast = d.isBefore(DateTime(
        DateTime.now().year, DateTime.now().month, DateTime.now().day));

    // NEW: consider a day selectable if it has *any* blocks
    final bool hasAvail =
        (blocksByDay[key] ?? const <Map<String, dynamic>>[]).isNotEmpty;

    final bool isSelected = selectedDayKey == key;
    final bool disabled = !inMonth || isPast || !hasAvail;

    final Color? bg = isSelected
        ? colors.primary
        : hasAvail
            ? colors.primaryContainer
            : null;

    final Color? fg = isSelected
        ? colors.onPrimary
        : hasAvail
            ? colors.onPrimaryContainer
            : (inMonth ? null : Colors.black26);

    return InkWell(
        onTap: disabled
            ? null
            : () => setState(() {
                selectedDayKey = key;
                selectedBlock = null;
                }),
        child: Container(
        decoration: BoxDecoration(
            color: bg,
            borderRadius: BorderRadius.circular(10),
            border: Border.all(
            color: isSelected
                ? colors.primary
                : hasAvail
                    ? colors.primaryContainer
                    : Theme.of(context).dividerColor,
            width: 1.2,
            ),
        ),
        alignment: Alignment.center,
        child: Text(
            '${d.day}',
            style: TextStyle(
            color: fg,
            fontWeight: FontWeight.w600,
            ),
        ),
        ),
    );
    }

  List<String> _next7AvailableKeys() {
    final nowKey = _dfIso.format(DateTime.now());
    final keys = blocksByDay.keys.toList()..sort();
    final onlyFuture = keys.where((k) => k.compareTo(nowKey) >= 0);
    final avail = onlyFuture.where((k) => (blocksByDay[k] ?? const []).isNotEmpty).toList();
    return avail.take(7).toList();

  }

  // Renders the compact month calendar used on the doctor booking screen.
  Widget _compactMonthCalendar() {
    final first = DateTime(monthAnchor.year, monthAnchor.month, 1);
    final gridStart = first.subtract(Duration(days: (first.weekday + 6) % 7));
    final days = List<DateTime>.generate(
      42,
      (i) => DateTime(gridStart.year, gridStart.month, gridStart.day + i),
    );

    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Row(children: [
          IconButton(
            tooltip: 'Prev month',
            onPressed: () async {
            final newAnchor = DateTime(monthAnchor.year, monthAnchor.month - 1, 1);
            setState(() => monthAnchor = newAnchor);
            await _prefetchMonth(mode: visitMode, anchor: newAnchor);
            },

            icon: const Icon(Icons.chevron_left),
          ),
          Expanded(
            child: Center(
              child: Text(
                DateFormat('MMMM yyyy').format(monthAnchor),
                style: Theme.of(context).textTheme.titleMedium,
              ),
            ),
          ),
          IconButton(
            tooltip: 'Next month',
            onPressed: () async {
            final newAnchor = DateTime(monthAnchor.year, monthAnchor.month + 1, 1);
            setState(() => monthAnchor = newAnchor);
            await _prefetchMonth(mode: visitMode, anchor: newAnchor);
            },

            icon: const Icon(Icons.chevron_right),
          ),
        ]),
        const SizedBox(height: 4),
        Row(
          children: const ['Mon', 'Tue', 'Wed', 'Thu', 'Fri', 'Sat', 'Sun']
              .map((d) => Expanded(
                    child: Padding(
                      padding: EdgeInsets.symmetric(vertical: 4),
                      child: Center(
                        child: Text(d, style: TextStyle(fontSize: 12, color: Colors.black54)),
                      ),
                    ),
                  ))
              .toList(),
        ),
        GridView.builder(
          shrinkWrap: true,
          physics: const NeverScrollableScrollPhysics(),
          itemCount: days.length,
          gridDelegate: const SliverGridDelegateWithFixedCrossAxisCount(
            crossAxisCount: 7,
            mainAxisExtent: 44,
            crossAxisSpacing: 4,
            mainAxisSpacing: 4,
          ),
          itemBuilder: (_, i) {
            final d = days[i];
            final key = _dfIso.format(d);
            return _dayCell(d, key);
          },
        ),
      ],
    );
  }

  @override
  Widget build(BuildContext context) {
    final d = widget.doctor;
    return Scaffold(
      appBar: AppBar(
        title: Text(d.name),
        actions: [
          TextButton(
            onPressed: () => Navigator.of(context).push(
              MaterialPageRoute(builder: (_) => _DoctorProfile(doctorId: d.id)),
            ),
            child: const Text('View Profile'),
          )
        ],
      ),
      body: loading
          ? const Center(child: CircularProgressIndicator())
          : ListView(
              padding: const EdgeInsets.all(12),
              children: [
                Row(children: [
                  const Text('Visit:'), const SizedBox(width: 8),
                  DropdownButton<String>(
                    value: visitMode,
                    items: const [
                      DropdownMenuItem(value: 'offline', child: Text('Offline')),
                      DropdownMenuItem(value: 'online', child: Text('Online')),
                    ],
                    onChanged: (v) async {
                    setState(() {
                        visitMode = v ?? 'offline';
                        selectedBlock = null;
                        selectedDayKey = null;
                    });
                    await _prefetchMonth(mode: visitMode, anchor: monthAnchor);
                    },

                  ),
                ]),
                const SizedBox(height: 8),
                TextField(
                  controller: problem,
                  decoration: const InputDecoration(
                    labelText: 'Describe your problem',
                    border: OutlineInputBorder(),
                  ),
                ),
                const SizedBox(height: 12),
                _compactMonthCalendar(),
                const SizedBox(height: 12),
                Builder(builder: (_) {
                  final next7 = _next7AvailableKeys();
                  if (next7.isEmpty) return const SizedBox.shrink();
                  return Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      Text('Next 7 available days', style: Theme.of(context).textTheme.titleSmall),
                      const SizedBox(height: 6),
                      SizedBox(
                        height: 40,
                        child: ListView(
                          scrollDirection: Axis.horizontal,
                          children: next7.map((k) {
                            final dayDate = DateTime.parse('${k}T00:00:00');
                            final label = DateFormat('EEE d').format(dayDate);
                            final sel = selectedDayKey == k;
                            return Padding(
                              padding: const EdgeInsets.only(right: 8),
                              child: ChoiceChip(
                                selected: sel,
                                label: Text(label),
                                onSelected: (_) => setState(() {
                                  selectedDayKey = k;
                                  selectedBlock = null;
                                }),
                              ),
                            );
                          }).toList(),
                        ),
                      ),
                    ],
                  );
                }),
                const SizedBox(height: 8),
                Builder(builder: (_) {
                  final key = selectedDayKey;
                  if (key == null) {
                    return const Padding(
                      padding: EdgeInsets.symmetric(vertical: 24),
                      child: Center(child: Text('Pick an available date from the calendar.')),
                    );
                  }
                  final blocks = (blocksByDay[key] ?? [])
                      .where((b) => (b['remaining'] ?? 0) > 0)
                      .toList();
                  if (blocks.isEmpty) {
                    return Padding(
                      padding: const EdgeInsets.symmetric(vertical: 24),
                      child: Center(child: Text('No available blocks on $key')),
                    );
                  }
                  return Wrap(
                    spacing: 8,
                    runSpacing: 8,
                    children: blocks.map((b) {
                      final start = (b['start'] ?? '').toString();
                      final end = (b['end'] ?? '').toString();
                      final isSel = identical(selectedBlock, b);
                      return ChoiceChip(
                        selected: isSel,
                        label: Text('${_hDot(start)}-${_hDot(end)}'),
                        onSelected: (_) => setState(() => selectedBlock = b),
                      );
                    }).toList(),
                  );
                }),
                const SizedBox(height: 16),
                Align(
                  alignment: Alignment.centerLeft,
                  child: FilledButton.icon(
                    onPressed: selectedBlock == null ? null : _confirm,
                    icon: const Icon(Icons.check),
                    label: const Text('Confirm Appointment'),
                  ),
                ),
                const SizedBox(height: 24),
              ],
            ),
    );
  }

  @override
  void dispose() {
    problem.dispose();
    super.dispose();
  }
}

// ─────────────────────────────────────────────────────────────────────────────
// My Appointments HOME -> tabs: Pending (default) & History
// ─────────────────────────────────────────────────────────────────────────────
class _AppointmentsHomeTab extends StatefulWidget {
  const _AppointmentsHomeTab();

  @override
  State<_AppointmentsHomeTab> createState() => _AppointmentsHomeTabState();
}

class _AppointmentsHomeTabState extends State<_AppointmentsHomeTab> with TickerProviderStateMixin {
  late final TabController _tabs = TabController(length: 2, vsync: this); // Pending, History

  @override
  void initState() {
    super.initState();
    _tabs.index = 0; // default to Pending
  }

  @override
  Widget build(BuildContext context) {
    return Column(children: [
      TabBar(
        controller: _tabs,
        tabs: const [
          Tab(text: 'Pending'),
          Tab(text: 'History'),
        ],
      ),
      Expanded(
        child: TabBarView(
          controller: _tabs,
          children: const [
            _MyAppointmentsTab(initialTab: 'pending'),
            _MyAppointmentsTab(initialTab: 'history'),
          ],
        ),
      ),
    ]);
  }
}
// ─────────────────────────────────────────────────────────────────────────────
// My Appointments —List
// manual search (Search button / keyboard submit), DESC by default.
// ─────────────────────────────────────────────────────────────────────────────
class _MyAppointmentsTab extends StatefulWidget {
  const _MyAppointmentsTab({this.initialTab = 'pending'});
  final String initialTab; // 'pending' | 'history'

  @override
  State<_MyAppointmentsTab> createState() => _MyAppointmentsTabState();
}

class _MyAppointmentsTabState extends State<_MyAppointmentsTab> {
  // Data
  List<Appointment> _items = [];
  bool _loading = true;
  // Caches
  final Map<int, Doctor> _doctorCache = {};
  final Map<int, DateTime> _createdAtCache = {}; // for sort(created_at)

  // Search / sort / paging
  final _searchCtrl = TextEditingController();   // accepts #id / id / doctor name
  String _sortBy = 'appointment_date';           // 'appointment_date' | 'created_at'
  String _order  = 'desc';                       // default DESC
  int _page = 1;
  static const _pageSize = 10;
  int _totalPages = 1;

  @override
  void initState() {
    super.initState();
    _load();
  }

  @override
  void dispose() {
    _searchCtrl.dispose();
    super.dispose();
  }

  // ───────────────────────────── helpers ─────────────────────────────
  Future<Doctor?> _ensureDoctor(int id) async {
    if (_doctorCache.containsKey(id)) return _doctorCache[id];
    try {
      final d = Doctor.fromJson(await Api.get('/doctors/$id'));
      _doctorCache[id] = d;
      if (mounted) setState(() {}); // update visible tiles
      return d;
    } catch (_) {
      return null;
    }
  }

  String? _photoUrl(String? path) {
    if (path == null || path.isEmpty) return null;
    var p = path.startsWith('./') ? path.substring(2) : path;
    if (p.startsWith('/')) p = p.substring(1);
    return '${Api.baseUrl}/$p';
  }

  /// Only `not_yet` can become `expired` (when end < now); otherwise keep progress/status.
  String _derivedProgress(Appointment a) {
    if (a.status == 'cancelled' || a.status == 'rejected') return a.status; // terminal server status
    if (a.progress == 'completed' || a.progress == 'in_progress' || a.progress == 'hold' || a.progress == 'requested') {
      return a.progress;
    }
    if (a.end.isBefore(DateTime.now())) return 'expired'; // not_yet ⇒ expired
    return a.progress; // likely 'not_yet'
  }

  bool _isRunning(Appointment a) {
    final p = _derivedProgress(a);
    final terminal =
        a.status == 'cancelled' ||
        a.status == 'rejected'  ||
        p == 'completed'        ||
        p == 'expired';
    return !terminal;
  }

  Widget _statusChip(String rawStatus, String progress) {
    final label = (progress == 'expired')
        ? 'expired'
        : (rawStatus == 'cancelled' ? 'cancelled'
            : (rawStatus == 'rejected' ? 'rejected' : progress));

    final s = label.toLowerCase();
    Color bg, fg;
    if (s.contains('completed')) { bg = Colors.green.withOpacity(.15); fg = Colors.green.shade800; }
    else if (s.contains('cancel') || s.contains('reject')) { bg = Colors.red.withOpacity(.15); fg = Colors.red.shade800; }
    else if (s.contains('expired')) { bg = Colors.orange.withOpacity(.18); fg = Colors.orange.shade800; }
    else if (s.contains('in_progress')) { bg = Colors.blue.withOpacity(.12); fg = Colors.blue.shade800; }
    else { bg = Theme.of(context).colorScheme.primary.withOpacity(.12); fg = Theme.of(context).colorScheme.primary; }

    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 5),
      decoration: BoxDecoration(color: bg, borderRadius: BorderRadius.circular(999)),
      child: Text(label, style: TextStyle(color: fg, fontSize: 12, fontWeight: FontWeight.w600)),
    );
  }

  // ───────────────────────────── loader ─────────────────────────────
  Future<void> _load() async {
    setState(() => _loading = true);

    final search = _searchCtrl.text.trim();

    final query = {
      'tab': widget.initialTab,
      'sort': _sortBy,
      'order': _order,
      'page': _page,
      'page_size': _pageSize,
      // keep server-side doctor-name search for names, not IDs
      if (search.isNotEmpty && !_looksLikeId(search)) 'doctor_name': search,
      if (search.isNotEmpty && !_looksLikeId(search)) 'q': search,
      if (search.isNotEmpty && !_looksLikeId(search)) 'search': search,
    }..removeWhere((k, v) => v == null);

    try {
      final res = await Api.get('/me/appointments', query: query);

      _createdAtCache.clear();

      List<Appointment> all;
      if (res is Map && res['items'] is List) {
        final list = (res['items'] as List);
        for (final e in list) {
          try {
            final m = Map<String, dynamic>.from(e as Map);
            final id = (m['id'] is num) ? (m['id'] as num).toInt() : int.tryParse('${m['id']}');
            final created = (m['created_at'] ?? m['createdAt'])?.toString();
            final dt = (created != null && created.isNotEmpty) ? DateTime.tryParse(created) : null;
            if (id != null && dt != null) _createdAtCache[id] = dt.toUtc();
          } catch (_) {}
        }
        all = list.map((e) => Appointment.fromJson(e)).toList();
      } else if (res is List) {
        for (final e in res) {
          try {
            final m = Map<String, dynamic>.from(e as Map);
            final id = (m['id'] is num) ? (m['id'] as num).toInt() : int.tryParse('${m['id']}');
            final created = (m['created_at'] ?? m['createdAt'])?.toString();
            final dt = (created != null && created.isNotEmpty) ? DateTime.tryParse(created) : null;
            if (id != null && dt != null) _createdAtCache[id] = dt.toUtc();
          } catch (_) {}
        }
        all = res.map((e) => Appointment.fromJson(e)).toList();
      } else {
        all = const <Appointment>[];
      }
      // ==== Notification sync on appointments fetch ====
      // Use the full result set so approvals/rejections/completions are captured across tabs.
      await NotificationSync().onAppointmentsFetched(
        all,
        patientName: 'Patient', // Optional: replace with a real name if available
      );

      // Tab filter using derived "expired"
      List<Appointment> filtered = (widget.initialTab == 'pending')
          ? all.where(_isRunning).toList()
          : all.where((a) => !_isRunning(a)).toList();

      // Local search by appointment ID (supports "#123" or "123")
      if (search.isNotEmpty && _looksLikeId(search)) {
        final id = _parseId(search);
        if (id != null) {
          filtered = filtered.where((a) => a.id == id).toList();
        }
      }

      // Sort (supports created_at via cache)
      int cmp(Appointment a, Appointment b) {
        DateTime A, B;
        if (_sortBy == 'created_at') {
          A = _createdAtCache[a.id] ?? a.start;
          B = _createdAtCache[b.id] ?? b.start;
        } else {
          A = a.start;
          B = b.start;
        }
        final base = A.compareTo(B);
        return _order == 'desc' ? -base : base;
      }
      filtered.sort(cmp);

      // Repaginate AFTER filtering
      final total = filtered.length;
      _totalPages = (total / _pageSize).ceil().clamp(1, 9999);
      if (_totalPages == 0) _totalPages = 1;
      if (_page > _totalPages) _page = _totalPages;
      final start = (_page - 1) * _pageSize;
      _items = filtered.skip(start).take(_pageSize).toList();
    } catch (e) {
      showSnack(context, 'Load failed: $e');
      _items = [];
      _totalPages = 1;
    } finally {
      if (mounted) setState(() => _loading = false);
    }
  }

  bool _looksLikeId(String s) => s.startsWith('#') || int.tryParse(s) != null;
  int? _parseId(String s) => s.startsWith('#') ? int.tryParse(s.substring(1)) : int.tryParse(s);

  // ───────────────────────────── UI ─────────────────────────────
  Widget _toolbar(BuildContext context) {
    final isPhone = MediaQuery.of(context).size.width < 600;

    final searchField = TextField(
      controller: _searchCtrl,
      decoration: const InputDecoration(
        hintText: 'Search by doctor or #id / id',
        border: InputBorder.none,
        prefixIcon: Icon(Icons.search),
        contentPadding: EdgeInsets.symmetric(horizontal: 12, vertical: 14),
      ),
      onSubmitted: (_) { _page = 1; _load(); }, // manual search
    );

    final searchPill = Container(
      decoration: BoxDecoration(
        color: Theme.of(context).colorScheme.surface,
        border: Border.all(color: Theme.of(context).dividerColor),
        borderRadius: BorderRadius.circular(999),
      ),
      child: Row(
        children: [
          Expanded(child: searchField),
          Padding(
            padding: const EdgeInsets.only(right: 4),
            child: FilledButton.tonalIcon(
              style: FilledButton.styleFrom(
                shape: const StadiumBorder(),
                padding: const EdgeInsets.symmetric(horizontal: 14, vertical: 10),
              ),
              onPressed: () { _page = 1; _load(); },
              icon: const Icon(Icons.search),
              label: const Text('Search'),
            ),
          ),
        ],
      ),
    );

    // controls: sort + order (desktop-only refresh is omitted per earlier request for phones)
    final List<Widget> sortWidgets = [
      DropdownButtonHideUnderline(
        child: DropdownButton<String>(
          value: _sortBy,
          items: const [
            DropdownMenuItem(value: 'appointment_date', child: Text('Appointment Date')),
            DropdownMenuItem(value: 'created_at',       child: Text('Creation Date')),
          ],
          onChanged: (v) { _sortBy = v ?? 'appointment_date'; _page = 1; _load(); },
        ),
      ),
      const SizedBox(width: 6),
      IconButton(
        tooltip: _order == 'desc' ? 'DESC' : 'ASC',
        onPressed: () { setState(() { _order = _order == 'desc' ? 'asc' : 'desc'; _page = 1; }); _load(); },
        icon: Icon(_order == 'desc' ? Icons.south : Icons.north),
      ),
    ];

    final isDesktop = MediaQuery.of(context).size.width >= 600;
    if (isDesktop) {
      sortWidgets.add(
        IconButton(
          tooltip: 'Refresh',
          onPressed: _load,
          icon: const Icon(Icons.refresh),
        ),
      );
    }

    return Padding(
      padding: const EdgeInsets.fromLTRB(12, 8, 12, 6),
      child: isPhone
          ? Column(
              children: [
                SizedBox(height: 48, child: searchPill),
                const SizedBox(height: 8),
                Align(alignment: Alignment.centerRight, child: Row(mainAxisSize: MainAxisSize.min, children: sortWidgets)),
              ],
            )
          : Row(
              children: [
                Expanded(child: SizedBox(height: 48, child: searchPill)),
                const SizedBox(width: 12),
                Row(mainAxisSize: MainAxisSize.min, children: sortWidgets),
              ],
            ),
    );
  }

  @override
  Widget build(BuildContext context) {
    if (_loading) return const Center(child: CircularProgressIndicator());

    final df = DateFormat('MMM d, yyyy • HH:mm');

    return Column(
      children: [
        _toolbar(context),

        Expanded(
          child: RefreshIndicator(
            onRefresh: _load, // pull-to-refresh on phone
            child: _items.isEmpty
                ? const Center(child: Text('No appointments'))
                : ListView.builder(
                    padding: const EdgeInsets.only(bottom: 8),
                    itemCount: _items.length,
                    itemBuilder: (_, i) {
                      final a = _items[i];
                      final d = _doctorCache[a.doctorId];
                      if (d == null) _ensureDoctor(a.doctorId);

                      final url = _photoUrl(d?.photoPath);
                      final avatar = CircleAvatar(
                        backgroundImage: url != null ? NetworkImage(url) : null,
                        child: url == null ? const Icon(Icons.person) : null,
                      );

                      final derived = _derivedProgress(a);
                      final title = d != null ? d.name : 'Doctor #${a.doctorId}';
                      final dateLine = '${df.format(a.start.toLocal())} — ${DateFormat('HH:mm').format(a.end.toLocal())}';

                      return Card(
                        margin: const EdgeInsets.symmetric(horizontal: 12, vertical: 6),
                        elevation: 0,
                        shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(14)),
                        child: ListTile(
                          leading: avatar,
                          title: Text(
                            title,
                            maxLines: 1,
                            overflow: TextOverflow.ellipsis,
                            style: const TextStyle(fontWeight: FontWeight.w600),
                          ),
                          // ADD: appointment id rendered up front for quick scanning
                          subtitle: Text(
                            '#${a.id} • $dateLine • mode: ${a.visitMode}',
                            maxLines: 1,
                            overflow: TextOverflow.ellipsis,
                          ),
                          trailing: _statusChip(a.status, derived),
                          onTap: () {
                            Navigator.of(context)
                                .push(MaterialPageRoute(builder: (_) => _AppointmentDetailPage(apptId: a.id)))
                                .then((_) => _load());
                          },
                        ),
                      );
                    },
                  ),
          ),
        ),

        if (_totalPages > 1)
          Padding(
            padding: const EdgeInsets.symmetric(vertical: 8),
            child: Wrap(
              spacing: 6,
              children: List.generate(_totalPages, (i) => i + 1).map((p) {
                return ChoiceChip(
                  selected: p == _page,
                  label: Text('$p'),
                  onSelected: (_) { setState(() => _page = p); _load(); },
                );
              }).toList(),
            ),
          ),
      ],
    );
  }
}

// ─────────────────────────────────────────────────────────────────────────────
// Appointment detail (patient) — mobile-first compact UI
// Rules preserved:
// ─────────────────────────────────────────────────────────────────────────────

class _AppointmentDetailPage extends StatefulWidget {
  const _AppointmentDetailPage({required this.apptId});
  final int apptId;

  @override
  State<_AppointmentDetailPage> createState() => _AppointmentDetailPageState();
}

class _AppointmentDetailPageState extends State<_AppointmentDetailPage> {
  Map<String, dynamic>? appt;
  List<Map<String, dynamic>> reports = [];
  List<Map<String, dynamic>> prescriptions = [];
  bool loading = true;

  // reschedule state
  String visitMode = 'offline';
  final DateFormat _dDay = DateFormat('EEE, MMM d');      // e.g. Wed, Oct 29
  final DateFormat _dTime = DateFormat('h:mm a');         // e.g. 9:00 AM
  final DateFormat _dIso = DateFormat('yyyy-MM-dd');      // for API day key
  DateTime monthAnchor = DateTime(DateTime.now().year, DateTime.now().month, 1);
  final Map<String, List<Map<String, dynamic>>> schedulesByDay = {};
  String? selectedDayKey;
  Map<String, dynamic>? targetBlock;
  

  // rating (kept as before; hidden unless progress == completed)
  final _comment = TextEditingController();
  int _stars = 5;
  Map<String, dynamic>? _existingRating;

  // ---------------- helpers ----------------
  int _daysInMonth(DateTime d) => DateTime(d.year, d.month + 1, 0).day;

  DateTime? _parseAnyDate(dynamic v) {
    if (v == null) return null;
    if (v is DateTime) return v;
    if (v is int) {
      final isMs = v > 20000000000;
      return DateTime.fromMillisecondsSinceEpoch(isMs ? v : v * 1000);
    }
    final s = v.toString().trim();
    if (s.isEmpty) return null;
    return DateTime.tryParse(s.replaceFirst(' ', 'T'));
  }

  DateTime? _findCreatedAt(Map a) {
    const keys = [
      'created_at','createdAt','created','created_date','createdOn',
      'inserted_at','meta.created_at','meta.createdAt'
    ];
    for (final k in keys) {
      dynamic cur = a;
      for (final part in k.split('.')) {
        if (cur is Map && cur[part] != null) {
          cur = cur[part];
        } else {
          cur = null;
          break;
        }
      }
      final dt = _parseAnyDate(cur);
      if (dt != null) return dt;
    }
    return null;
  }

  String? _getStringPath(Map m, String path) {
    dynamic cur = m;
    for (final part in path.split('.')) {
      if (cur is Map && cur[part] != null) {
        cur = cur[part];
      } else {
        return null;
      }
    }
    final s = cur?.toString().trim();
    return (s == null || s.isEmpty) ? null : s;
  }

  String _hospitalPhoneOf(Map a) {
    const keys = [
      'contact_phone','hospital_phone','hospital.contact_phone',
      'hospital.phone','hospital.phone_number','hospital_mobile',
      'contact_number','hospital_contact'
    ];
    for (final k in keys) {
      final v = _getStringPath(a, k);
      if (v != null) return v;
    }
    return '';
  }

  String _doctorPhoneOf(Map a) {
    const keys = [
      'doctor_phone','doctor.contact_phone','doctor.phone',
      'doctor.mobile','doctor_cell','doctor_phone_number'
    ];
    for (final k in keys) {
      final v = _getStringPath(a, k);
      if (v != null) return v;
    }
    return '';
  }

  num? _paymentAmountOf(Map a) {
    const keys = ['amount','payment_amount','fee','fees','total','price','payable'];
    for (final k in keys) {
      final v = a[k];
      if (v == null) continue;
      if (v is num) return v;
      final n = num.tryParse(v.toString());
      if (n != null) return n;
    }
    final pay = a['payment'] as Map?;
    if (pay != null) {
      for (final k in keys) {
        final v = pay[k];
        if (v == null) continue;
        if (v is num) return v;
        final n = num.tryParse(v.toString());
        if (n != null) return n;
      }
    }
    return null;
  }

  String? _photoUrl(String? path) {
    if (path == null || path.isEmpty) return null;
    var p = path.startsWith('./') ? path.substring(2) : path;
    if (p.startsWith('/')) p = p.substring(1);
    return '${Api.baseUrl}/$p';
  }

  // robust URL extraction for a record
  String? _anyUrl(Map<String, dynamic> m) {
    const keys = ['file_url', 'url', 'file_path', 'path', 'pdf_url'];
    for (final k in keys) {
      final v = m[k]?.toString();
      if (v != null && v.isNotEmpty) {
        if (v.startsWith('http')) return v;
        return '${Api.baseUrl}${v.startsWith('/') ? v : '/$v'}';
      }
    }
    final data = (m['data'] is Map) ? (m['data'] as Map).cast<String, dynamic>() : null;
    if (data != null) {
      for (final k in keys) {
        final v = data[k]?.toString();
        if (v != null && v.isNotEmpty) {
          if (v.startsWith('http')) return v;
          return '${Api.baseUrl}${v.startsWith('/') ? v : '/$v'}';
        }
      }
    }
    return null;
  }

  // ---------------- lifecycle ----------------
  @override
  void initState() {
    super.initState();
    _loadAll();
  }

  Future<void> _loadAll() async {
    setState(() => loading = true);

    final r = await Api.get('/appointments/${widget.apptId}');
    appt = (r as Map).cast<String, dynamic>();
    visitMode = (appt!['visit_mode'] ?? 'offline').toString().toLowerCase();

    // enrich doctor (optional)
try {
  final id = (appt!['doctor_id'] as num?)?.toInt();
  if (id != null) {
    final dj = await Api.get('/doctors/$id') as Map;
    final d  = Doctor.fromJson(dj.cast<String, dynamic>());

    appt!['doctor_name']         ??= d.name;
    appt!['doctor_photo_path']    = d.photoPath;

    // NEW: try multiple keys for phone/address/fee to be robust
    appt!['doctor_phone']         ??= (dj['phone'] ?? dj['contact_phone'] ?? dj['mobile'] ?? dj['contact_number'])?.toString();
    appt!['doctor_address']       ??= (dj['address'] ?? dj['location'] ?? dj['clinic_address'] ?? dj['hospital_address'])?.toString();

    // Visiting fee normalizer
    num? _fx(dynamic v) {
      if (v == null) return null;
      if (v is num) return v;
      return num.tryParse(v.toString().replaceAll(RegExp(r'[^0-9.\-]'), ''));
    }
    appt!['doctor_visiting_fee'] ??=
        _fx(dj['visiting_fee']) ??
        _fx(dj['visit_fee']) ??
        _fx(dj['fee']) ??
        _fx(dj['fees']) ??
        _fx(dj['amount']) ??
        _fx(dj['price']);
  }
} catch (_) {}

    // reports (scoped)
    try {
      final rr = await Api.get('/appointments/${widget.apptId}/reports');
      reports = (rr as List).map((e) => (e as Map).cast<String, dynamic>()).toList();
    } catch (_) {
      reports = [];
    }

    // prescriptions (scoped; read-only)
    try {
      dynamic rx;
      final urls = <String>[
        '/appointments/${widget.apptId}/prescriptions',
        '/appointments/${widget.apptId}/prescription',
        '/appointment/${widget.apptId}/prescriptions',
        '/appointment/${widget.apptId}/prescription',
        '/prescriptions?appointment_id=${widget.apptId}',
        '/api/prescriptions?appointment_id=${widget.apptId}',
      ];
      for (final u in urls) {
        try { rx = await Api.get(u); if (rx != null) break; } catch (_) {}
      }
      if (rx == null) {
        final fromAppt = appt?['prescriptions'] ?? appt?['prescription'];
        if (fromAppt != null) rx = fromAppt;
      }
      if (rx is List) {
        prescriptions = rx.map<Map<String, dynamic>>((e) => Map<String, dynamic>.from(e as Map)).toList();
      } else if (rx is Map) {
        if (rx['items'] is List) {
          prescriptions = (rx['items'] as List).map<Map<String, dynamic>>((e) => Map<String, dynamic>.from(e as Map)).toList();
        } else if (rx['data'] is List) {
          prescriptions = (rx['data'] as List).map<Map<String, dynamic>>((e) => Map<String, dynamic>.from(e as Map)).toList();
        } else if (rx.isNotEmpty) {
          prescriptions = [Map<String, dynamic>.from(rx)];
        } else {
          prescriptions = [];
        }
      } else {
        prescriptions = [];
      }
    } catch (_) {
      prescriptions = [];
    }

    // existing rating (optional)
    try {
      final rr = await Api.get('/appointments/${widget.apptId}/rating') as Map?;
      if (rr != null && rr.isNotEmpty) {
        _existingRating = rr.cast<String, dynamic>();
        _stars = ((_existingRating?['stars'] as num?)?.toInt() ?? _stars).clamp(1, 5);
        _comment.text = (_existingRating?['comment'] ?? '').toString();
      } else {
        _existingRating = null;
      }
    } catch (_) {
      _existingRating = null;
    }

    await _prefetchMonth();
    setState(() => loading = false);
  }

  // ---------------- derived flags ----------------
  String get _progress => (appt?['progress'] ?? 'not_yet').toString();
  String get _status => (appt?['status'] ?? '').toString();
  String get _visit => (appt?['visit_mode'] ?? 'offline').toString().toLowerCase();
  bool get _isOnline => _visit == 'online';

  bool get _canUploadReports => (_progress == 'in_progress' || _progress == 'hold');
  bool get _canReschedule => _progress == 'not_yet' && !{'cancelled','rejected'}.contains(_status);
  bool get _canCancel => _progress == 'not_yet' && !{'cancelled','rejected','completed'}.contains(_status);
  bool get _canRate => _progress == 'completed';

  bool get _paid => (appt?['payment_status'] ?? '').toString() == 'paid';
  bool get _canPay {
    if (_status == 'cancelled' || _status == 'rejected') return false;
    return !_paid;
  }

  bool get _canDeleteAppt {
    final norm = _status.trim().toLowerCase().replaceAll(' ', '_').replaceAll('-', '_');
    const deletable = {'cancelled','rejected','no_show','not_show','not_showed','noshow'};
    return deletable.contains(norm);
  }

  bool _videoWindowNow() {
    try {
      final s = DateTime.parse(appt!['start_time'].toString());
      final e = DateTime.parse(appt!['end_time'].toString());
      final now = DateTime.now();
      return now.isAfter(s.subtract(const Duration(minutes: 10))) &&
             now.isBefore(e.add(const Duration(minutes: 30)));
    } catch (_) {
      return false;
    }
  }

  //bool get _canVideo => _isOnline && (_progress == 'in_progress' || _progress == 'hold') && _videoWindowNow();
  //bool get _canChat  => _isOnline && (_progress == 'in_progress' || _progress == 'hold') && _paid && _status == 'approved';
  bool get _canVideo => _isOnline && (_progress == 'in_progress' || _progress == 'hold');
  bool get _canChat  => _isOnline && (_progress == 'in_progress' || _progress == 'hold');

  // ---------------- actions ----------------
  Future<bool> _confirm({
    required String title,
    required String message,
    String confirmText = 'Confirm',
    bool danger = false,
  }) async {
    final res = await showDialog<bool>(
      context: context,
      builder: (ctx) => AlertDialog(
        shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(16)),
        title: Text(title),
        content: Text(message),
        actions: [
          TextButton(onPressed: () => Navigator.pop(ctx, false), child: const Text('Cancel')),
          FilledButton.tonal(
            style: danger
                ? FilledButton.styleFrom(
                    backgroundColor: Theme.of(ctx).colorScheme.errorContainer,
                    foregroundColor: Theme.of(ctx).colorScheme.onErrorContainer)
                : null,
            onPressed: () => Navigator.pop(ctx, true),
            child: Text(confirmText),
          ),
        ],
      ),
    );
    return res == true;
  }

  Future<void> _cancel() async {
    final ok = await _confirm(
      title: 'Cancel appointment?',
      message: 'You can cancel only while the appointment is not yet started.',
      confirmText: 'Yes, cancel',
      danger: true,
    );
    if (!ok) return;
    try {
      try {
        await Api.patch('/appointments/${widget.apptId}/cancel');
      } catch (_) {
        await Api.post('/appointments/${widget.apptId}:cancel');
      }
      showSnack(context, 'Appointment cancelled');
      await _loadAll();
    } catch (e) {
      showSnack(context, 'Cancel failed: $e');
    }
  }

  Future<void> _deleteAppointment() async {
    final ok = await _confirm(
      title: 'Delete this appointment?',
      message: 'This will remove it from your list. This action cannot be undone.',
      confirmText: 'Delete',
      danger: true,
    );
    if (!ok) return;

    final id = widget.apptId;
    final tries = <Future<dynamic> Function()>[
      () => Api.delete('/appointments/$id'),
      () => Api.delete('/appointment/$id'),
      () => Api.post  ('/appointments/$id/delete'),
      () => Api.post  ('/appointment/$id/delete'),
      () => Api.patch ('/appointments/$id', data: {'deleted': true}),
      () => Api.delete('/me/appointments/$id'),
      () => Api.post  ('/me/appointments/$id/delete'),
    ];

    dynamic lastErr;
    for (final t in tries) {
      try {
        await t();
        showSnack(context, 'Appointment deleted');
        if (mounted) Navigator.pop(context);
        return;
      } catch (e) {
        lastErr = e;
      }
    }
    showSnack(context, 'Delete failed: $lastErr');
  }

  Future<void> _rateSubmit() async {
    try {
      await Api.post('/appointments/${widget.apptId}/rate', data: {'stars': _stars, 'comment': _comment.text});
      _existingRating = {'stars': _stars, 'comment': _comment.text};
      showSnack(context, 'Thanks for your feedback!');
      setState(() {});
    } catch (e) {
      showSnack(context, 'Rating failed: $e');
    }
  }

  Future<void> _requestReschedule() async {
    if (selectedDayKey == null || targetBlock == null) {
      showSnack(context, 'Pick a new day & time first.');
      return;
    }
    String hhmm(String hm) => hm.padLeft(5, '0');
    final body = {
      'new_start_time': '${selectedDayKey!}T${hhmm((targetBlock!['start'] ?? '').toString())}:00',
      'new_end_time':   '${selectedDayKey!}T${hhmm((targetBlock!['end'] ?? '').toString())}:00',
    };
    try {
      await Api.patch('/appointments/${widget.apptId}/reschedule', data: body);
      showSnack(context, 'Reschedule request sent');
      await _loadAll();
    } catch (e) {
      showSnack(context, 'Request failed: $e');
    }
  }



Future<void> _downloadFile(String url, String suggested) async {
  try {
    String? _fromContentDisposition(String? cd) {
      if (cd == null) return null;
      final mStar = RegExp(r'''filename\*\s*=\s*[^']*''([^;]+)''''', caseSensitive: false).firstMatch(cd);
      if (mStar != null) {
        return Uri.decodeFull(mStar.group(1)!.trim());
      }
      final mQuoted = RegExp(r'''filename\s*=\s*"([^"]+)"''', caseSensitive: false).firstMatch(cd);
      if (mQuoted != null) {
        return mQuoted.group(1)!.trim();
      }
      final mBare = RegExp(r'''filename\s*=\s*([^;]+)''', caseSensitive: false).firstMatch(cd);
      if (mBare != null) {
        return mBare.group(1)!.trim();
      }
      return null;
    }

    String _extFromMime(String? mime) {
      switch ((mime ?? '').toLowerCase()) {
        case 'application/pdf': return '.pdf';
        case 'image/png': return '.png';
        case 'image/jpeg':
        case 'image/jpg': return '.jpg';
        case 'image/webp': return '.webp';
        case 'text/plain': return '.txt';
        default: return '';
      }
    }

    String _ensureExt(String name, {String? urlPath, String? mime}) {
      final hasExt = name.contains('.') && !name.endsWith('.');
      if (hasExt) return name;
      final segs = (urlPath ?? '').split('/').where((s) => s.isNotEmpty).toList();
      final last = segs.isNotEmpty ? segs.last : '';
      if (last.contains('.')) {
        final ext = last.substring(last.lastIndexOf('.'));
        return name.isEmpty ? last : name + ext;
      }
      final guess = _extFromMime(mime);
      if (guess.isNotEmpty) return name.isEmpty ? 'document' + guess : name + guess;
      return name.isEmpty ? 'document.pdf' : name + '.pdf';
    }

    final isAbsolute = url.startsWith('http://') || url.startsWith('https://');
    final requestUri = isAbsolute ? Uri.parse(url) : Uri.parse('${Api.baseUrl}$url');
    final dio = Dio();
    final res = await dio.getUri<List<int>>(
      requestUri,
      options: Options(responseType: ResponseType.bytes, followRedirects: true, validateStatus: (_) => true),
    );

    if (res.statusCode != null && res.statusCode! >= 200 && res.statusCode! < 300 && res.data != null) {
      final cd = res.headers.value('content-disposition');
      final ctype = res.headers.value('content-type');
      final fromCd = _fromContentDisposition(cd);
      String name = (fromCd ?? suggested).trim();
      name = _ensureExt(name, urlPath: requestUri.path, mime: ctype);
      final bytes = Uint8List.fromList(res.data!);
      await downloadBytes(bytes, name);
    } else {
      await openUrlExternal(url);
    }
  } catch (e) {
    showSnack(context, 'Download failed: $e');
  }
}

  Future<void> _uploadReport() async {
    if (!_canUploadReports) return;
    final pick = await FilePicker.platform.pickFiles(withData: true);
    if (pick == null || pick.files.isEmpty) return;
    final f = pick.files.first;
    final form = FormData.fromMap({'file': MultipartFile.fromBytes(f.bytes as Uint8List, filename: f.name)});
    try {
      await Api.post('/appointments/${widget.apptId}/reports', data: form, multipart: true);
      showSnack(context, 'Uploaded ${f.name}');
      await _loadAll();
    } catch (e) {
      // singular fallback
      try {
        final form2 = FormData.fromMap({'file': MultipartFile.fromBytes(f.bytes as Uint8List, filename: f.name)});
        await Api.post('/appointments/${widget.apptId}/report', data: form2, multipart: true);
        showSnack(context, 'Uploaded ${f.name}');
        await _loadAll();
      } catch (e2) {
        showSnack(context, 'Upload failed: $e2');
      }
    }
  }

  Future<void> _deleteReport(int id) async {
    final ok = await _confirm(
      title: 'Delete report?',
      message: 'This cannot be undone.',
      confirmText: 'Delete',
      danger: true,
    );
    if (!ok) return;

    final apptId = widget.apptId;
    final tries = <Future<dynamic> Function()>[
      () => Api.delete('/appointments/$apptId/reports/$id'),
      () => Api.delete('/appointments/$apptId/report/$id'),
      () => Api.post  ('/appointments/$apptId/reports/$id/delete'),
      () => Api.post  ('/appointments/$apptId/report/$id/delete'),
      () => Api.patch ('/appointments/$apptId/report/$id', data: {'deleted': true}),
      // global fallbacks
      () => Api.delete('/reports/$id'),
      () => Api.delete('/report/$id'),
      () => Api.post  ('/reports/$id/delete'),
      () => Api.post  ('/report/$id/delete'),
      () => Api.patch ('/report/$id', data: {'deleted': true}),
    ];

    dynamic lastErr;
    for (final call in tries) {
      try {
        await call();
        showSnack(context, 'Deleted');
        await _loadAll();
        return;
      } catch (e) {
        lastErr = e;
      }
    }
    showSnack(context, 'Delete failed: $lastErr');
  }

  // ---------------- schedules fetch ----------------
  Future<void> _prefetchMonth({String? mode, DateTime? anchor}) async {
    final String useMode = (mode ?? visitMode);
    final DateTime useAnchor = (anchor ?? monthAnchor);

    final Map<String, List<Map<String, dynamic>>> tmp = {};
    String? tmpSelected;

    final days = _daysInMonth(useAnchor);
    final todayMidnight = DateTime(DateTime.now().year, DateTime.now().month, DateTime.now().day);
    final int doctorId = (appt?['doctor_id'] as num?)?.toInt() ?? 0;
    if (doctorId == 0) return;

    String _extractHm(Map b, List<String> keys) {
      for (final k in keys) {
        final v = b[k];
        if (v == null) continue;
        final s = v.toString();
        final m = RegExp(r'(\d{1,2}):(\d{2})').firstMatch(s);
        if (m != null) return '${m.group(1)!.padLeft(2, '0')}:${m.group(2)}';
      }
      return '';
    }

    Map<String, dynamic> mk({
      required dynamic id,
      required String start,
      required String end,
      required int remaining,
    }) => {'id': id ?? '${start}_$end', 'start': start, 'end': end, 'remaining': remaining};

    for (int day = 1; day <= days; day++) {
      final d = DateTime(useAnchor.year, useAnchor.month, day);
      if (d.isBefore(todayMidnight)) continue;

      final key = _dIso.format(d);
      List<Map<String, dynamic>> blocks = [];
      dynamic res;

      try {
        res = await Api.get('/doctors/$doctorId/blocks', query: {'day': key, 'visit_mode': useMode});
      } catch (_) {
        try {
          res = await Api.get('/doctors/$doctorId/windows', query: {'day': key, 'visit_mode': useMode});
        } catch (_) {
          res = null;
        }
      }

      if (res is Map) {
        final m = res.cast<String, dynamic>();
        if (m['date_rules'] is List) {
          for (final r0 in (m['date_rules'] as List)) {
            final r = (r0 as Map).cast<String, dynamic>();
            if ((r['date'] ?? '').toString() != key) continue;
            final modeStr = (r['mode'] ?? r['visit_mode'] ?? '').toString().toLowerCase();
            if (useMode.isNotEmpty && modeStr.isNotEmpty && modeStr != useMode) continue;
            final sStart = _extractHm(r, ['start','time_from','start_time','from','schedule_time_from']);
            final sEnd   = _extractHm(r, ['end','time_to','end_time','to','schedule_time_to']);
            if (sStart.isEmpty || sEnd.isEmpty) continue;
            final mp = r['max_patients'];
            final cap = mp is num ? mp.toInt() : int.tryParse('$mp') ?? 1;
            blocks.add(mk(id: r['id'], start: sStart, end: sEnd, remaining: cap <= 0 ? 1 : cap));
          }
        }
        if (blocks.isEmpty && m['blocks'] is List) {
          for (final b0 in (m['blocks'] as List)) {
            final b = (b0 as Map).cast<String, dynamic>();
            final modeStr = (b['mode'] ?? b['visit_mode'] ?? '').toString().toLowerCase();
            if (modeStr.isNotEmpty && modeStr != useMode) continue;
            final rem = (b['remaining'] ?? b['available'] ?? b['available_seats'] ?? b['max_patients'] ?? 1);
            final remaining = rem is num ? rem.toInt() : int.tryParse(rem.toString()) ?? 1;
            final sStart = _extractHm(b, ['start','time_from','start_time','from','schedule_time_from','slot_start']);
            final sEnd   = _extractHm(b, ['end','time_to','end_time','to','schedule_time_to','slot_end']);
            if (sStart.isNotEmpty && sEnd.isNotEmpty) {
              blocks.add(mk(id: b['id'], start: sStart, end: sEnd, remaining: remaining <= 0 ? 0 : remaining));
            }
          }
        } else if (blocks.isEmpty && m['windows'] is List) {
          for (final w0 in (m['windows'] as List)) {
            final w = (w0 as Map).cast<String, dynamic>();
            final modeStr = (w['mode'] ?? w['visit_mode'] ?? '').toString().toLowerCase();
            if (modeStr.isNotEmpty && modeStr != useMode) continue;
            final rem = w['available'] ?? w['available_seats'] ?? 1;
            final remaining = rem is num ? rem.toInt() : int.tryParse('$rem') ?? 1;
            final sStart = _extractHm(w, ['start','time_from','start_time','from','schedule_time_from','slot_start']);
            final sEnd   = _extractHm(w, ['end','time_to','end_time','to','schedule_time_to','slot_end']);
            if (sStart.isNotEmpty && sEnd.isNotEmpty) {
              blocks.add(mk(id: w['id'], start: sStart, end: sEnd, remaining: remaining <= 0 ? 0 : remaining));
            }
          }
        } else if (blocks.isEmpty && m['slots'] is List) {
          final list = (m['slots'] as List).map((e) => DateTime.parse(e.toString())).toList()..sort();
          if (list.isNotEmpty) {
            blocks.add(mk(
              id: '${key}_group',
              start: DateFormat('HH:mm').format(list.first),
              end: DateFormat('HH:mm').format(list.last.add(const Duration(minutes: 30))),
              remaining: 9999,
            ));
          }
        }
      } else if (res is List) {
        for (final b0 in res) {
          final b = (b0 as Map).cast<String, dynamic>();
          final modeStr = (b['mode'] ?? b['visit_mode'] ?? '').toString().toLowerCase();
          if (modeStr.isNotEmpty && modeStr != useMode) continue;
          final rem = b['remaining'] ?? b['available'] ?? b['available_seats'] ?? b['max_patients'] ?? 1;
          final remaining = rem is num ? rem.toInt() : int.tryParse('$rem') ?? 1;
          final sStart = _extractHm(b, ['start','time_from','start_time','from','schedule_time_from','slot_start']);
          final sEnd   = _extractHm(b, ['end','time_to','end_time','to','schedule_time_to','slot_end']);
          if (sStart.isNotEmpty && sEnd.isNotEmpty) {
            blocks.add(mk(id: b['id'], start: sStart, end: sEnd, remaining: remaining <= 0 ? 0 : remaining));
          }
        }
      }

      if (blocks.isNotEmpty) {
        final filtered = blocks.where((b) => (b['remaining'] ?? 0) > 0).toList();
        if (filtered.isNotEmpty) {
          tmp[key] = filtered;
          tmpSelected ??= key;
        }
      }
    }

    if (!mounted) return;
    setState(() {
      schedulesByDay
        ..clear()
        ..addAll(tmp);
      selectedDayKey = tmpSelected;
    });
  }

  // ---------------- UI ----------------
  @override
  Widget build(BuildContext context) {
    if (loading || appt == null) {
      return const Scaffold(body: Center(child: CircularProgressIndicator()));
    }

    final start = DateTime.parse(appt!['start_time'].toString());
    final end   = DateTime.parse(appt!['end_time'].toString());
    final idStr = (appt!['id'] ?? widget.apptId).toString();
    final serial = (appt!['serial'] ?? '').toString();
    final createdAt = _findCreatedAt(appt!);
    final amount = _paymentAmountOf(appt ?? const {});
    final visit = _visit;

    final doctorName = (appt!['doctor_name'] ?? 'Doctor').toString();
    final doctorId = (appt!['doctor_id'] as num?)?.toInt();
    final doctorPhotoUrl = _photoUrl((appt!['doctor_photo_path'] ?? '').toString());

    final videoUrl = (appt!['video_room'] ?? '').toString();

String phoneHospital = _hospitalPhoneOf(appt!);
String phoneDoctor   = _doctorPhoneOf(appt!);

// fallback from embedded doctor map
try {
  final d = appt!['doctor'] as Map?;
  if ((phoneDoctor.isEmpty || phoneDoctor.trim().isEmpty) && d != null) {
    phoneDoctor = _getStringPath(d.cast<String, dynamic>(), 'phone') ??
                  _getStringPath(d.cast<String, dynamic>(), 'mobile') ??
                  '';
  }
} catch (_) {}

// fallback from enriched fields
if (phoneDoctor.isEmpty || phoneDoctor.trim().isEmpty) {
  phoneDoctor = (appt!['doctor_phone'] ?? '').toString();
}

    final VoidCallback? goToDoc = (doctorId == null)
        ? null
        : () => Navigator.of(context).push(
              MaterialPageRoute(builder: (_) => _DoctorProfile(doctorId: doctorId)),
            );

    return Scaffold(
      appBar: AppBar(
        title: const Text('Appointment Detail'),
        leading: BackButton(onPressed: () => Navigator.pop(context)),
        actions: [
          if (_canDeleteAppt)
            IconButton(
              tooltip: 'Delete appointment',
              onPressed: _deleteAppointment,
              icon: const Icon(Icons.delete_forever, color: Colors.red),
            ),
        ],
      ),
      body: LayoutBuilder(
        builder: (ctx, c) {
          final isPhone = c.maxWidth < 520;
          return ListView(
            padding: const EdgeInsets.all(12),
            children: [
              _compactHeaderCard(
                isPhone: isPhone,
                start: start,
                end: end,
                visit: visit,
                apptIdStr: idStr,
                serial: serial,
                createdAt: createdAt,
                amount: amount,
                doctorName: doctorName,
                doctorPhotoUrl: doctorPhotoUrl,
                onTapDoctor: goToDoc,
              ),

               const SizedBox(height: 8),

              // Clinic & Contact Info + online actions (no duplicated phone below)
              Builder(
                builder: (context) {
                  // Derive robust doctor info from the enriched appt map
                  final String doctorAddress =
                      (appt!['doctor_address'] ?? '').toString().trim();

                  final num? visitingFee = (() {
                    final v = appt!['doctor_visiting_fee'];
                    if (v == null) return null;
                    if (v is num) return v;
                    return num.tryParse(
                      v.toString().replaceAll(RegExp(r'[^0-9.\-]'), ''),
                    );
                  })();

                  final bool showClinic =
                      doctorAddress.isNotEmpty || visitingFee != null || phoneDoctor.isNotEmpty;

                  return Column(
                    crossAxisAlignment: CrossAxisAlignment.stretch,
                    children: [
                      if (showClinic) ...[
                        const SizedBox(height: 8),
                        Card(
                          shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(14)),
                          child: Padding(
                            padding: const EdgeInsets.fromLTRB(12, 10, 12, 12),
                            child: Column(
                              crossAxisAlignment: CrossAxisAlignment.start,
                              children: [
                                Row(children: [
                                  Icon(Icons.local_hospital, color: Theme.of(context).colorScheme.primary),
                                  const SizedBox(width: 8),
                                  Text('Clinic & Contact Info', style: Theme.of(context).textTheme.titleMedium),
                                ]),
                                const SizedBox(height: 8),

                                if (doctorAddress.isNotEmpty)
                                  ListTile(
                                    dense: true,
                                    contentPadding: EdgeInsets.zero,
                                    leading: const Icon(Icons.location_on_outlined),
                                    title: Text(doctorAddress),
                                  ),

                                if (visitingFee != null) ...[
                                  const SizedBox(height: 2),
                                  ListTile(
                                    dense: true,
                                    contentPadding: EdgeInsets.zero,
                                    leading: const Icon(Icons.payments_outlined),
                                    title: Text('Visiting fee: ${NumberFormat.currency(symbol: '').format(visitingFee)}'),
                                  ),
                                ],

                                if (phoneDoctor.isNotEmpty) ...[
                                  const SizedBox(height: 2),
                                  ListTile(
                                    dense: true,
                                    contentPadding: EdgeInsets.zero,
                                    leading: const Icon(Icons.phone_outlined),
                                    title: Text(phoneDoctor),
                                    trailing: IconButton(
                                      tooltip: 'Call',
                                      onPressed: () async {
                                        final uri = Uri.parse('tel:$phoneDoctor');
                                        if (await canLaunchUrl(uri)) {
                                          await launchUrl(uri);
                                        }
                                      },
                                      icon: const Icon(Icons.phone),
                                    ),
                                  ),
                                ],
                              ],
                            ),
                          ),
                        ),
                      ],
                // Online-only live actions
                _isOnline
                    ? Wrap(
                        spacing: 8,
                        runSpacing: 8,
                        children: [
                          FilledButton.icon(
                            onPressed: _canVideo
                                ? () => Navigator.of(context).push(
                                      MaterialPageRoute(
                                        builder: (_) =>
                                            VideoScreen(
                                          appointmentId: widget.apptId,
                                          isDoctor: false,
                                        )
                                      ),
                                    )
                                : null,
                            icon: const Icon(Icons.videocam),
                            label: const Text('Video'),
                          ),
                          FilledButton.tonalIcon(
                            onPressed: _canChat
                                ? () => Navigator.of(context).push(
                                      MaterialPageRoute(
                                        builder: (_) => ChatScreen(apptId: widget.apptId),
                                      ),
                                    )
                                : null,
                            icon: const Icon(Icons.chat_bubble_outline),
                            label: const Text('Chat'),
                          ),
                        ],
                      )
                    : const SizedBox.shrink(),

                    ],
                  );
                },
              ),


              // Core actions row
              Wrap(
                spacing: 8,
                runSpacing: 8,
                children: [
                  OutlinedButton.icon(
                    onPressed: _canCancel ? _cancel : null,
                    icon: const Icon(Icons.cancel),
                    label: const Text('Cancel'),
                  ),
                  OutlinedButton.icon(
                    onPressed: _canReschedule
                        ? () async {
                            await showModalBottomSheet(
                              isScrollControlled: true,
                              context: context,
                              builder: (_) => _ApptRescheduleSheet(
                                visitMode: visitMode,
                                monthAnchor: monthAnchor,
                                schedulesByDay: schedulesByDay,
                                onPick: (dayKey, block) {
                                  selectedDayKey = dayKey;
                                  targetBlock = block;
                                },
                                fetchFor: ({required String visitMode, required DateTime monthAnchor}) async {
                                  setState(() {
                                    this.visitMode = visitMode;
                                    this.monthAnchor = monthAnchor;
                                  });
                                  await _prefetchMonth();
                                  return Map<String, List<Map<String, dynamic>>>.from(schedulesByDay);
                                },
                              ),
                            );
                            if (targetBlock != null) await _requestReschedule();
                          }
                        : null,
                    icon: const Icon(Icons.schedule),
                    label: const Text('Change schedule'),
                  ),
                  FilledButton.icon(
                    onPressed: _canPay
                        ? () => Navigator.of(context).push(
                              MaterialPageRoute(builder: (_) => PaymentScreen(appointmentId: widget.apptId)),
                            )
                        : null,
                    icon: const Icon(Icons.payment),
                    label: const Text('Payment'),
                  ),
                ],
              ),

              const SizedBox(height: 8),
              if (phoneHospital.isNotEmpty || phoneDoctor.isNotEmpty)
                _contactsCard(phoneHospital, ''),


              const Divider(height: 24),

              // Prescriptions (read-only)
              _filesSection(
                title: 'Prescriptions (this appointment)',
                emptyText: 'No prescriptions yet.',
                items: prescriptions,
                // NO upload button for prescriptions; hide trailing controls; hide download if no url
                buildHeaderTrailing: () => const SizedBox.shrink(),
                icon: Icons.description_outlined,
                titleOf: (m) => (m['title'] ?? 'Prescription').toString(),
                urlOf: _anyUrl,
                idOf: (_) => null, // no delete
                trailingBuilder: (url, id, title) => url == null
                    ? null
                    : IconButton(
                        tooltip: 'Download',
                        onPressed: () => _downloadFile(url, title),
                        icon: const Icon(Icons.download),
                      ),
              ),

              const Divider(height: 24),

              // Reports (upload/delete allowed by rule)
              _filesSection(
                title: 'Reports (this appointment)',
                emptyText: 'No reports yet.',
                items: reports,
                buildHeaderTrailing: () => OutlinedButton.icon(
                  onPressed: _canUploadReports ? _uploadReport : null,
                  icon: const Icon(Icons.upload_file),
                  label: const Text('Upload'),
                ),
                icon: Icons.insert_drive_file_outlined,
                titleOf: (m) => (m['original_name'] ?? m['title'] ?? 'Report').toString(),
                urlOf: _anyUrl,
                idOf: (m) {
                  for (final v in [m['id'], m['report_id'], m['file_id'], m['doc_id'], m['rid']]) {
                    if (v == null) continue;
                    if (v is num) return v.toInt();
                    final n = int.tryParse(v.toString());
                    if (n != null) return n;
                  }
                  return null;
                },
                trailingBuilder: (url, id, title) => Wrap(spacing: 4, children: [
                  IconButton(
                    tooltip: 'Download',
                    onPressed: url == null ? null : () => _downloadFile(url, title),
                    icon: const Icon(Icons.download),
                  ),
                  IconButton(
                    tooltip: 'Delete',
                    onPressed: (_canUploadReports && id != null) ? () => _deleteReport(id!) : null,
                    icon: const Icon(Icons.delete, color: Colors.red),
                  ),
                ]),
              ),

              const Divider(height: 24),

              if (_canRate) _ratingCard(context),
            ],
          );
        },
      ),
    );
  }

  // ======= UI pieces =======

Widget _compactHeaderCard({
  required bool isPhone,
  required DateTime start,
  required DateTime end,
  required String visit,
  required String apptIdStr,
  required String serial,
  required DateTime? createdAt,
  required num? amount,
  required String doctorName,
  required String? doctorPhotoUrl,
  required VoidCallback? onTapDoctor,
}) {
    final cs = Theme.of(context).colorScheme;

    String lineDate() => '${_dDay.format(start)} • ${_dTime.format(start)} – ${_dTime.format(end)}';

    Widget keyVal(IconData ic, String v) => Row(
      children: [
        Icon(ic, size: 16, color: cs.primary),
        const SizedBox(width: 6),
        Expanded(child: Text(v, maxLines: 1, overflow: TextOverflow.ellipsis)),
      ],
    );

    return Card(
      elevation: 2,
      shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(16)),
      child: Padding(
        padding: const EdgeInsets.fromLTRB(12, 12, 12, 10),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            // date/time emphasized
            Row(
              children: [
                Icon(Icons.event, color: cs.primary),
                const SizedBox(width: 8),
                Expanded(
                  child: Text(
                    lineDate(),
                    style: Theme.of(context).textTheme.titleMedium?.copyWith(fontWeight: FontWeight.w800),
                  ),
                ),
                Container(
                  padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 4),
                  decoration: BoxDecoration(
                    color: cs.primaryContainer, borderRadius: BorderRadius.circular(20)),
                  child: Text(visit.toUpperCase(), style: TextStyle(color: cs.onPrimaryContainer, fontSize: 11)),
                ),
              ],
            ),
            const SizedBox(height: 8),
            // doctor + id copy
            Row(
              children: [
                InkWell(
                  onTap: onTapDoctor,
                  child: CircleAvatar(
                    radius: 18,
                    backgroundImage: doctorPhotoUrl != null ? NetworkImage(doctorPhotoUrl) : null,
                    child: doctorPhotoUrl == null ? const Icon(Icons.person, size: 20) : null,
                  ),
                ),
                const SizedBox(width: 8),
                Expanded(
                  child: InkWell(
                    onTap: onTapDoctor,
                    child: Text(
                      doctorName,
                      maxLines: 1,
                      overflow: TextOverflow.ellipsis,
                      style: Theme.of(context).textTheme.titleMedium?.copyWith(
                            fontWeight: FontWeight.w900,
                            color: cs.primary,
                          ),
                    ),
                  ),
                ),
                IconButton(
                  tooltip: 'Copy ID',
                  onPressed: () async {
                    await Clipboard.setData(ClipboardData(text: apptIdStr));
                    showSnack(context, 'Appointment ID copied');
                  },
                  icon: const Icon(Icons.copy),
                ),
              ],
            ),
            const SizedBox(height: 6),
            // compact key/vals (two columns on web, single on phone)
            LayoutBuilder(builder: (_, b) {
              final twoCol = b.maxWidth >= 560;
              final chips = <Widget>[
                keyVal(Icons.confirmation_number_outlined, 'Serial: ${serial.isEmpty ? '-' : serial}'),
                keyVal(Icons.flag_outlined, 'Status: ${_status.isEmpty ? '-' : _status}'),
                keyVal(Icons.timelapse, 'Progress: ${_progress.isEmpty ? '-' : _progress}'),
                if (amount != null) keyVal(Icons.payments_outlined, 'Amount: ${NumberFormat.currency(symbol: '').format(amount)}'),
                if (mounted && (context.findRenderObject() != null)) const SizedBox.shrink(),
                if (createdAt != null) keyVal(Icons.calendar_today_outlined, 'Created: ${DateFormat.yMMMd().add_jm().format(createdAt!)}'),
              ];

              if (!twoCol) {
                return Column(
                  children: [
                    for (int i = 0; i < chips.length; i++) ...[
                      chips[i],
                      if (i != chips.length - 1) const SizedBox(height: 4),
                    ],
                  ],
                );
              }
              // two columns (web / wide)
              final left = <Widget>[], right = <Widget>[];
              for (int i = 0; i < chips.length; i++) {
                (i.isEven ? left : right).add(Padding(
                  padding: const EdgeInsets.symmetric(vertical: 2),
                  child: chips[i],
                ));
              }
              return Row(
                children: [
                  Expanded(child: Column(children: left)),
                  const SizedBox(width: 12),
                  Expanded(child: Column(children: right)),
                ],
              );
            }),
          ],
        ),
      ),
    );
  }

  Widget _contactsCard(String phoneHospital, String phoneDoctor) {
    return Card(
      shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(14)),
      child: Padding(
        padding: const EdgeInsets.fromLTRB(12, 10, 12, 12),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Text('Contacts', style: Theme.of(context).textTheme.titleSmall),
            const SizedBox(height: 6),
            if (phoneHospital.isNotEmpty)
              Row(children: [
                const Icon(Icons.local_hospital, size: 18),
                const SizedBox(width: 6),
                Expanded(child: Text(phoneHospital)),
                IconButton(
                  tooltip: 'Copy',
                  onPressed: () async { await Clipboard.setData(ClipboardData(text: phoneHospital)); showSnack(context, 'Copied'); },
                  icon: const Icon(Icons.copy),
                ),
                IconButton(
                  tooltip: 'Call',
                  onPressed: () => launchUrl(Uri.parse('tel:$phoneHospital')),
                  icon: const Icon(Icons.phone),
                ),
              ]),
            if (phoneDoctor.isNotEmpty)
              Row(children: [
                const Icon(Icons.person, size: 18),
                const SizedBox(width: 6),
                Expanded(child: Text(phoneDoctor)),
                IconButton(
                  tooltip: 'Copy',
                  onPressed: () async { await Clipboard.setData(ClipboardData(text: phoneDoctor)); showSnack(context, 'Copied'); },
                  icon: const Icon(Icons.copy),
                ),
                IconButton(
                  tooltip: 'Call',
                  onPressed: () => launchUrl(Uri.parse('tel:$phoneDoctor')),
                  icon: const Icon(Icons.phone),
                ),
              ]),
          ],
        ),
      ),
    );
  }

  Widget _filesSection({
    required String title,
    required String emptyText,
    required List<Map<String, dynamic>> items,
    required Widget Function() buildHeaderTrailing,
    required IconData icon,
    required String Function(Map<String, dynamic>) titleOf,
    required String? Function(Map<String, dynamic>) urlOf,
    required int? Function(Map<String, dynamic>) idOf,
    required Widget? Function(String? url, int? id, String title) trailingBuilder,
  }) {
    return Column(
      children: [
        Row(
          children: [
            Text(title, style: Theme.of(context).textTheme.titleMedium),
            const Spacer(),
            buildHeaderTrailing(),
          ],
        ),
        const SizedBox(height: 8),
        if (items.isEmpty)
          Text(emptyText)
        else
          ...items.map((m) {
            final id = idOf(m);
            final t = titleOf(m);
            final url = urlOf(m);
            final created = (m['created_at'] ?? m['createdAt'] ?? '').toString();

            return Card(
              shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(12)),
              child: ListTile(
                leading: Icon(icon),
                title: Text(t, maxLines: 1, overflow: TextOverflow.ellipsis),
                subtitle: created.isEmpty ? null : Text(created),
                onTap: url == null ? null : () => showDocLightbox(context, title: t, url: url),
                trailing: trailingBuilder(url, id, t),
              ),
            );
          }),
      ],
    );
  }

  Widget _ratingCard(BuildContext context) {
    final existingStars = (_existingRating?['stars'] as num?)?.toInt();
    final existingComment = (_existingRating?['comment'] ?? '').toString().trim();

    return Card(
      elevation: 2,
      shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(14)),
      child: Padding(
        padding: const EdgeInsets.fromLTRB(16, 14, 16, 16),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Row(children: [
              const Icon(Icons.star, color: Colors.amber),
              const SizedBox(width: 8),
              Text('Rate your visit', style: Theme.of(context).textTheme.titleMedium),
              const Spacer(),
              if (_existingRating != null)
                const Text('You can update', style: TextStyle(fontSize: 12)),
            ]),
            const SizedBox(height: 8),
            if (_existingRating != null) ...[
              Row(
                children: List.generate(5, (i) {
                  final idx = i + 1;
                  final active = idx <= (existingStars ?? 0);
                  return Padding(
                    padding: const EdgeInsets.symmetric(horizontal: 1),
                    child: Icon(active ? Icons.star_rounded : Icons.star_outline_rounded, size: 20, color: Colors.amber),
                  );
                }),
              ),
              if (existingComment.isNotEmpty)
                Padding(
                  padding: const EdgeInsets.only(top: 6, bottom: 8),
                  child: Text(existingComment, style: const TextStyle(fontStyle: FontStyle.italic)),
                ),
              const Divider(height: 18),
              Text('Update your rating', style: Theme.of(context).textTheme.bodySmall),
              const SizedBox(height: 6),
            ],
            Row(
              children: List.generate(5, (i) {
                final idx = i + 1;
                final active = idx <= _stars;
                return InkResponse(
                  onTap: () => setState(() => _stars = idx),
                  child: Padding(
                    padding: const EdgeInsets.symmetric(horizontal: 2),
                    child: Icon(active ? Icons.star_rounded : Icons.star_outline_rounded, size: 34, color: Colors.amber),
                  ),
                );
              }),
            ),
            const SizedBox(height: 10),
            TextField(
              controller: _comment,
              maxLines: 3,
              decoration: InputDecoration(
                labelText: 'Share a short comment (optional)',
                border: OutlineInputBorder(borderRadius: BorderRadius.circular(12)),
              ),
            ),
            const SizedBox(height: 10),
            Align(
              alignment: Alignment.centerRight,
              child: FilledButton.icon(
                onPressed: _rateSubmit,
                icon: const Icon(Icons.send),
                label: Text(_existingRating == null ? 'Submit rating' : 'Update rating'),
              ),
            ),
          ],
        ),
      ),
    );
  }
}

// ─────────────────────────────────────────────────────────────────────────────
// Reschedule bottom sheet (unique class name)
// ─────────────────────────────────────────────────────────────────────────────
class _ApptRescheduleSheet extends StatefulWidget {
  const _ApptRescheduleSheet({
    required this.visitMode,
    required this.monthAnchor,
    required this.schedulesByDay,
    required this.onPick,
    required this.fetchFor,
  });

  final String visitMode;
  final DateTime monthAnchor;
  final Map<String, List<Map<String, dynamic>>> schedulesByDay;
  final void Function(String dayKey, Map<String, dynamic> block) onPick;
  final Future<Map<String, List<Map<String, dynamic>>>> Function({
    required String visitMode,
    required DateTime monthAnchor,
  }) fetchFor;

  @override
  State<_ApptRescheduleSheet> createState() => _ApptRescheduleSheetState();
}

class _ApptRescheduleSheetState extends State<_ApptRescheduleSheet> {
  late DateTime monthAnchor;
  late String visitMode;

  late Map<String, List<Map<String, dynamic>>> schedulesByDay;
  String? selectedDayKey;
  Map<String, dynamic>? selectedBlock;

  bool _loading = false;

  String _fmt(DateTime d) => DateFormat('yyyy-MM-dd').format(d);

  String _hDot(String hhmm) {
    final parts = hhmm.split(':');
    if (parts.length >= 2) {
      final h = int.tryParse(parts[0]) ?? 0;
      final m = int.tryParse(parts[1]) ?? 0;
      return '$h.${m.toString().padLeft(2, '0')}';
    }
    return hhmm;
  }

  String? _firstAvailKey(Map<String, List<Map<String, dynamic>>> m) {
    final keys = m.keys.toList()..sort();
    for (final k in keys) {
      final list = m[k] ?? const <Map<String, dynamic>>[];
      if (list.any((b) => (b['remaining'] ?? 0) > 0)) return k;
    }
    return null;
  }

  @override
  void initState() {
    super.initState();
    visitMode = widget.visitMode;
    monthAnchor = widget.monthAnchor;
    schedulesByDay = Map<String, List<Map<String, dynamic>>>.from(widget.schedulesByDay);
    selectedDayKey = _firstAvailKey(schedulesByDay);
  }

  Future<void> _reload({String? mode, DateTime? anchor}) async {
    setState(() => _loading = true);
    if (mode != null) visitMode = mode;
    if (anchor != null) monthAnchor = anchor;

    final fresh = await widget.fetchFor(visitMode: visitMode, monthAnchor: monthAnchor);

    setState(() {
      schedulesByDay = fresh;
      selectedBlock = null;
      selectedDayKey = _firstAvailKey(schedulesByDay);
      _loading = false;
    });
  }

  @override
  Widget build(BuildContext context) {
    final first = DateTime(monthAnchor.year, monthAnchor.month, 1);
    final start = first.subtract(Duration(days: (first.weekday + 6) % 7));
    final days = List<DateTime>.generate(42, (i) => DateTime(start.year, start.month, start.day + i));

    return SafeArea(
      child: Padding(
        padding: const EdgeInsets.all(12),
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            Row(children: [
              const Text('Visit:'), const SizedBox(width: 8),
              DropdownButton<String>(
                value: visitMode,
                items: const [
                  DropdownMenuItem(value: 'offline', child: Text('Offline')),
                  DropdownMenuItem(value: 'online', child: Text('Online')),
                ],
                onChanged: (v) => v == null ? null : _reload(mode: v),
              ),
              const Spacer(),
              IconButton(
                onPressed: () => _reload(anchor: DateTime(monthAnchor.year, monthAnchor.month - 1, 1)),
                icon: const Icon(Icons.chevron_left),
              ),
              Text(DateFormat('MMMM yyyy').format(monthAnchor)),
              IconButton(
                onPressed: () => _reload(anchor: DateTime(monthAnchor.year, monthAnchor.month + 1, 1)),
                icon: const Icon(Icons.chevron_right),
              ),
            ]),

            if (_loading)
              const Padding(padding: EdgeInsets.symmetric(vertical: 12), child: CircularProgressIndicator()),

            if (!_loading)
              GridView.builder(
                shrinkWrap: true,
                physics: const NeverScrollableScrollPhysics(),
                itemCount: days.length,
                gridDelegate: const SliverGridDelegateWithFixedCrossAxisCount(
                  crossAxisCount: 7, mainAxisExtent: 44, crossAxisSpacing: 4, mainAxisSpacing: 4),
                itemBuilder: (_, i) {
                  final d = days[i];
                  final k = _fmt(d);
                  final inMonth = d.month == monthAnchor.month;
                  final hasAvail = (schedulesByDay[k] ?? const []).isNotEmpty;
                  final isSelected = selectedDayKey == k;

                  final colors = Theme.of(context).colorScheme;
                  final Color? bg = isSelected
                      ? colors.primary
                      : hasAvail
                          ? colors.primaryContainer
                          : null;
                  final Color? fg = isSelected
                      ? colors.onPrimary
                      : hasAvail
                          ? colors.onPrimaryContainer
                          : (inMonth ? null : Colors.black26);

                  return InkWell(
                    onTap: (inMonth && hasAvail) ? () => setState(() => selectedDayKey = k) : null,
                    child: Container(
                      decoration: BoxDecoration(
                        color: bg,
                        borderRadius: BorderRadius.circular(10),
                        border: Border.all(
                          color: isSelected
                              ? colors.primary
                              : hasAvail
                                  ? colors.primaryContainer
                                  : Theme.of(context).dividerColor,
                        ),
                      ),
                      alignment: Alignment.center,
                      child: Text('${d.day}', style: TextStyle(color: fg, fontWeight: FontWeight.w600)),
                    ),
                  );
                },
              ),

            const SizedBox(height: 8),
            if (!_loading && selectedDayKey != null)
              Wrap(
                spacing: 8,
                runSpacing: 8,
                children: (schedulesByDay[selectedDayKey] ?? const []).map((b) {
                  final rem = (b['remaining'] ?? 0) as int;
                  final start = (b['start'] ?? '').toString();
                  final end = (b['end'] ?? '').toString();
                  final sel = identical(selectedBlock, b);
                  return ChoiceChip(
                    selected: sel,
                    label: Text('${_hDot(start)}-${_hDot(end)} ${rem == 0 ? '(full)' : ''}'),
                    onSelected: rem == 0 ? null : (_) => setState(() => selectedBlock = b),
                  );
                }).toList(),
              ),
            const SizedBox(height: 8),
            Align(
              alignment: Alignment.centerRight,
              child: FilledButton.icon(
                onPressed: (selectedDayKey != null && selectedBlock != null)
                    ? () { widget.onPick(selectedDayKey!, selectedBlock!); Navigator.pop(context); }
                    : null,
                icon: const Icon(Icons.check),
                label: const Text('Select'),
              ),
            ),
          ],
        ),
      ),
    );
  }
}

// ─────────────────────────────────────────────────────────────────────────────
// BEGIN_GALLERY_TAB
// Gallery Tab - Reports / Prescriptions (fast load + reliable download)
// ─────────────────────────────────────────────────────────────────────────────

class _GalleryTab extends StatefulWidget {
  const _GalleryTab();

  @override
  State<_GalleryTab> createState() => _GalleryTabState();
}

class _GalleryTabState extends State<_GalleryTab> {
  // Data
  List<Map<String, dynamic>> reports = [];
  List<Map<String, dynamic>> prescriptions = [];
  bool loading = true;

  int? _myUserId;
  final Map<int, Map<String, dynamic>> _apptCache = {};   // fetched lazily

  // ----------------------------- utils -----------------------------
  bool get _isMobile {
    final p = defaultTargetPlatform;
    return p == TargetPlatform.android || p == TargetPlatform.iOS;
  }

  int? _coerceInt(dynamic v) {
    if (v == null) return null;
    if (v is num) return v.toInt();
    return int.tryParse(v.toString());
  }

  DateTime? _parseDt(dynamic v) {
    if (v == null) return null;
    if (v is DateTime) return v.toUtc();
    try {
      return DateTime.parse(v.toString()).toUtc();
    } catch (_) {
      return null;
    }
  }

  String _whenStr(DateTime? dt) =>
      dt == null ? '-' : DateFormat.yMMMd().add_jm().format(dt.toLocal());

  bool _isImage(String path) {
    final lower = path.toLowerCase();
    return lower.endsWith('.png') ||
        lower.endsWith('.jpg') ||
        lower.endsWith('.jpeg') ||
        lower.endsWith('.gif') ||
        lower.endsWith('.webp');
  }

  String _fileUrlFromPath(String pathOrUrl) {
    var p = pathOrUrl;
    if (p.startsWith('./')) p = p.substring(2);
    if (!p.startsWith('/')) p = '/$p';
    return '${Api.baseUrl}$p';
  }

  String _doctorForAppt(int? apptId) {
    if (apptId == null) return '';
    final m = _apptCache[apptId];
    final d = (m?['doctor'] as Map?) ?? const {};
    return (d['name'] as String?) ?? '';
  }

  // ----------------------------- confirmation -----------------------------
  Future<bool> _confirm({
    required String title,
    required String message,
    String confirmText = 'Delete',
  }) async {
    final res = await showDialog<bool>(
      context: context,
      builder: (ctx) => AlertDialog(
        title: Text(title),
        content: Text(message),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(ctx, false),
            child: const Text('Cancel'),
          ),
          FilledButton.tonal(
            style: FilledButton.styleFrom(
              backgroundColor: Theme.of(ctx).colorScheme.errorContainer,
              foregroundColor: Theme.of(ctx).colorScheme.onErrorContainer,
            ),
            onPressed: () => Navigator.pop(ctx, true),
            child: Text(confirmText),
          ),
        ],
      ),
    );
    return res == true;
  }

// BEGIN_DOWNLOAD_HELPER
Future<void> _downloadUrl(String url, {String? suggestedName}) async {
  // ── helpers ────────────────────────────────────────────────────────────────
  String _sanitizeBase(String name) {
    final cleaned = name.replaceAll(RegExp(r'[^A-Za-z0-9 _\.-]+'), '');
    final collapsed = cleaned.replaceAll(RegExp(r'\s+'), ' ').trim();
    final underscored = collapsed.replaceAll(' ', '_');
    final safe = underscored.replaceFirst(RegExp(r'^[\.\-]+'), '');
    return safe.isEmpty ? 'file' : (safe.length > 120 ? safe.substring(0, 120) : safe);
  }

  String _stripOneExt(String name) {
    final idx = name.lastIndexOf('.');
    if (idx <= 0 || idx == name.length - 1) return name;
    final maybeExt = name.substring(idx + 1);
    if (maybeExt.length > 5) return name; // likely not a true extension
    return name.substring(0, idx);
  }

  String? _extFromFilename(String name) {
    final idx = name.lastIndexOf('.');
    if (idx <= 0 || idx == name.length - 1) return null;
    final ext = name.substring(idx + 1).toLowerCase();
    if (ext.length > 5) return null;
    return ext;
  }

  String? _extFromContentType(String ct) {
    ct = ct.toLowerCase();
    if (ct.startsWith('image/jpeg') || ct.startsWith('image/pjpeg') || ct.startsWith('image/jpg')) return 'jpg';
    if (ct.startsWith('image/png')) return 'png';
    if (ct.startsWith('image/gif')) return 'gif';
    if (ct.startsWith('image/webp')) return 'webp';
    if (ct.startsWith('image/bmp')) return 'bmp';
    if (ct.startsWith('image/heic')) return 'heic';
    if (ct.startsWith('image/heif')) return 'heif';
    if (ct.startsWith('image/tiff')) return 'tiff';
    if (ct.startsWith('application/pdf')) return 'pdf';
    if (ct.startsWith('text/plain')) return 'txt';
    if (ct.startsWith('application/json')) return 'json';
    if (ct.startsWith('application/zip')) return 'zip';
    if (ct.contains('wordprocessingml')) return 'docx';
    if (ct.contains('msword')) return 'doc';
    return null;
  }

  String _mimeFromExt(String ext) {
    switch (ext.toLowerCase()) {
      case 'jpg':
      case 'jpeg':
        return 'image/jpeg';
      case 'png':
        return 'image/png';
      case 'gif':
        return 'image/gif';
      case 'webp':
        return 'image/webp';
      case 'bmp':
        return 'image/bmp';
      case 'heic':
        return 'image/heic';
      case 'heif':
        return 'image/heif';
      case 'tiff':
        return 'image/tiff';
      case 'pdf':
        return 'application/pdf';
      case 'txt':
        return 'text/plain';
      case 'json':
        return 'application/json';
      case 'zip':
        return 'application/zip';
      case 'doc':
        return 'application/msword';
      case 'docx':
        return 'application/vnd.openxmlformats-officedocument.wordprocessingml.document';
      default:
        return 'application/octet-stream';
    }
  }

  // ── derive a clean filename (base + single extension) ─────────────────────
  final parsed = Uri.tryParse(url);
  final lastSeg = (parsed?.pathSegments.isNotEmpty ?? false) ? parsed!.pathSegments.last : '';
  final candidate = (suggestedName?.trim().isNotEmpty == true ? suggestedName!.trim() : lastSeg)
      .replaceAll('%20', ' ');

  try {
    // fetch bytes
    final resp = await Dio().get<List<int>>(
      url,
      options: Options(responseType: ResponseType.bytes, followRedirects: true),
    );
    final data = resp.data ?? const <int>[];
    if (data.isEmpty) throw 'Empty response';

    final ct = resp.headers.value('content-type') ?? '';
    String ext = _extFromContentType(ct) ?? _extFromFilename(candidate) ?? 'bin';

    String base = _stripOneExt(candidate);
    if (ext.isNotEmpty) {
      final extDot = '.${ext.toLowerCase()}';
      // remove repeated trailing extension(s), e.g., "file.jpg.jpg"
      while (base.toLowerCase().endsWith(extDot)) {
        base = base.substring(0, base.length - extDot.length);
      }
    }
    base = _sanitizeBase(base);
    if (base.isEmpty) base = 'file';

    final fullName = '$base.$ext';
    final bytes = Uint8List.fromList(data);
    final mime = _mimeFromExt(ext);

    // ── Mobile (Android/iOS): force Share Sheet to let user choose destination ──
    if (!_kIsWeb() && (defaultTargetPlatform == TargetPlatform.android || defaultTargetPlatform == TargetPlatform.iOS)) {
      await Share.shareXFiles(
        [XFile.fromData(bytes, name: fullName, mimeType: mime)],
        text: fullName,
      );
      showSnack(context, 'Choose a location to save $fullName');
      return;
    }

    // ── Web / Desktop: direct save ──
    try {
      await FileSaver.instance.saveFile(
        name: fullName, // include extension
        bytes: bytes,
      );
      showSnack(context, 'Saved $fullName');
      return;
    } catch (_) {
      // fallback: open externally
      final uri = Uri.parse(url);
      await launchUrl(
        uri,
        mode: kIsWeb ? LaunchMode.platformDefault : LaunchMode.externalApplication,
        webOnlyWindowName: '_blank',
      );
      showSnack(context, 'Opened externally.');
      return;
    }
  } catch (_) {
    try {
      final uri = Uri.parse(url);
      await launchUrl(
        uri,
        mode: kIsWeb ? LaunchMode.platformDefault : LaunchMode.externalApplication,
        webOnlyWindowName: '_blank',
      );
    } catch (_) {}
    showSnack(context, 'Could not download; opened instead.');
  }
}

bool _kIsWeb() => kIsWeb;
// END_DOWNLOAD_HELPER

 // ----------------------------- deletes -----------------------------
  Future<void> _deleteReport(int reportId, {int? appointmentId}) async {
    dynamic lastErr;
    final tryList = <Future<dynamic> Function()>[
      if (appointmentId != null)
        () => Api.delete('/appointments/$appointmentId/reports/$reportId'),
      () => Api.delete('/patients/reports/$reportId'),
      () => Api.post  ('/patients/reports/$reportId/delete'),
      () => Api.delete('/reports/$reportId'),
      () => Api.post  ('/reports/$reportId/delete'),
      () => Api.patch ('/reports/$reportId', data: {'deleted': true}),
    ];

    for (final fn in tryList) {
      try {
        await fn();
        showSnack(context, 'Deleted');
        await _load();
        return;
      } catch (e) {
        lastErr = e;
      }
    }
    showSnack(context, 'Delete failed: $lastErr');
  }

  Future<void> _deletePrescription(int apptId) async {
    dynamic lastErr;
    final tryList = <Future<dynamic> Function()>[
      () => Api.delete('/appointments/$apptId/prescription'),
      () => Api.post  ('/appointments/$apptId/prescription/delete'),
    ];
    for (final fn in tryList) {
      try {
        await fn();
        showSnack(context, 'Deleted prescription for #$apptId');
        await _load();
        return;
      } catch (e) {
        lastErr = e;
      }
    }
    showSnack(context, 'Delete failed: $lastErr');
  }

  // ----------------------------- upload -----------------------------
  Future<void> _uploadReport() async {
    final pick = await FilePicker.platform.pickFiles(withData: true);
    if (pick == null || pick.files.isEmpty) return;
    final f = pick.files.first;
    final form = FormData.fromMap({
      'file': MultipartFile.fromBytes(f.bytes as Uint8List, filename: f.name),
    });
    try {
      await Api.post('/patients/reports', data: form, multipart: true);
      showSnack(context, 'Uploaded ${f.name}');
      await _load();
    } catch (e) {
      showSnack(context, 'Upload failed: $e');
    }
  }

  // ----------------------------- loader (fast) -----------------------------
  // Key speedups:
  // 1) Parallel fetch of profile + reports.
  // 2) No per-appointment requests during initial load.
  //    Appointment details are fetched lazily only when needed.
  Future<void> _load() async {
    setState(() => loading = true);
    try {
      final futures = await Future.wait([
        Api.get('/patients/reports'),
        Api.get('/patient/profile'),
      ]);

      final rep = futures[0] as List;
      final prof = futures[1] as Map<String, dynamic>;
      _myUserId = _coerceInt(prof['id'] ?? prof['user_id'] ?? prof['patient_id']);

      final pres = (prof['prescriptions'] as List? ?? [])
          .map<Map<String, dynamic>>((p) => Map<String, dynamic>.from(p))
          .toList();

      // Process reports (keep appointment_id if backend provides it)
      reports = rep.map<Map<String, dynamic>>((r) {
        final m = Map<String, dynamic>.from(r as Map);
        m['uploaded_at_dt'] = _parseDt(m['uploaded_at']);
        // If appointment_id is absent, we leave it null (filled lazily when needed).
        return m;
      }).toList()
        ..sort((a, b) {
          final ad = (a['uploaded_at_dt'] as DateTime?);
          final bd = (b['uploaded_at_dt'] as DateTime?);
          if (ad == null && bd == null) return 0;
          if (ad == null) return 1;
          if (bd == null) return -1;
          return bd.compareTo(ad);
        });

      // Process prescriptions
      prescriptions = pres
        ..sort((a, b) {
          final ad = _parseDt(a['created_at']);
          final bd = _parseDt(b['created_at']);
          if (ad == null && bd == null) return 0;
          if (ad == null) return 1;
          if (bd == null) return -1;
          return bd.compareTo(ad);
        });
    } catch (e) {
      showSnack(context, 'Load failed: $e');
      reports = [];
      prescriptions = [];
    } finally {
      if (mounted) setState(() => loading = false);
    }
  }

  @override
  void initState() {
    super.initState();
    _load();
  }

  // ----------------------------- mobile actions -----------------------------
  Future<void> _openActionsMobile({
    required String title,
    String? createdAt,
    int? appointmentId,
    String? doctorName,
    VoidCallback? onOpen,
    VoidCallback? onDownload,
    Future<void> Function()? onDeleteConfirmed,
  }) async {
    // Lazy fetch appointment details on first open (optional)
    if ((doctorName == null || doctorName.isEmpty) && appointmentId != null && !_apptCache.containsKey(appointmentId)) {
      try {
        final detail = await Api.get('/appointments/$appointmentId') as Map<String, dynamic>;
        _apptCache[appointmentId] = detail;
        doctorName = _doctorForAppt(appointmentId);
      } catch (_) {}
    }

    await showModalBottomSheet<void>(
      context: context,
      showDragHandle: true,
      builder: (ctx) => SafeArea(
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            ListTile(
              title: Text(title, style: const TextStyle(fontWeight: FontWeight.w600)),
              subtitle: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  if (createdAt != null) Text('Created: $createdAt'),
                  if (appointmentId != null) Text('Appointment: #$appointmentId'),
                  if ((doctorName ?? '').isNotEmpty) Text('Doctor: $doctorName'),
                ],
              ),
            ),
            const Divider(height: 0),
            if (onOpen != null)
              ListTile(
                leading: const Icon(Icons.open_in_new),
                title: const Text('Open'),
                onTap: () { Navigator.pop(ctx); onOpen(); },
              ),
            if (onDownload != null)
              ListTile(
                leading: const Icon(Icons.download),
                title: const Text('Download'),
                onTap: () { Navigator.pop(ctx); onDownload(); },
              ),
            if (onDeleteConfirmed != null)
              ListTile(
                leading: const Icon(Icons.delete, color: Colors.red),
                title: const Text('Delete', style: TextStyle(color: Colors.red)),
                onTap: () async {
                  Navigator.pop(ctx);
                  final ok = await _confirm(
                    title: 'Delete?',
                    message: 'This action cannot be undone.',
                  );
                  if (ok) await onDeleteConfirmed();
                },
              ),
            const SizedBox(height: 8),
          ],
        ),
      ),
    );
  }

  // ----------------------------- build -----------------------------
  @override
  Widget build(BuildContext context) {
    if (loading) return const Center(child: CircularProgressIndicator());

    return DefaultTabController(
      length: 2,
      child: Column(
        children: [
          Padding(
            padding: const EdgeInsets.fromLTRB(8, 8, 8, 0),
            child: Row(
              children: [
                FilledButton.icon(
                  onPressed: _uploadReport,
                  icon: const Icon(Icons.upload),
                  label: const Text('Upload Report'),
                ),
                const Spacer(),
              ],
            ),
          ),
          const TabBar(
            tabs: [
              Tab(text: 'Reports'),
              Tab(text: 'Prescriptions'),
            ],
          ),
          Expanded(
            child: TabBarView(
              children: [
                _reportsGrid(),
                _prescriptionsGrid(),
              ],
            ),
          ),
        ],
      ),
    );
  }

  // ----------------------------- grids (builder = faster) -----------------------------
  Widget _reportsGrid() {
    if (reports.isEmpty) {
      return const Center(child: Text('No reports yet.'));
    }

    return GridView.builder(
      padding: const EdgeInsets.all(12),
      gridDelegate: SliverGridDelegateWithMaxCrossAxisExtent(
        maxCrossAxisExtent: _isMobile ? 240 : 280,
        mainAxisSpacing: 12,
        crossAxisSpacing: 12,
        childAspectRatio: 0.78,
      ),
      itemCount: reports.length,
      itemBuilder: (ctx, i) {
        final r = reports[i];
        final name = (r['original_name'] ?? 'Report').toString();
        final filePath = (r['file_path'] ?? '').toString();
        final url = _fileUrlFromPath(filePath);
        final isImg = _isImage(filePath);
        final preview = isImg
            ? Image.network(url, fit: BoxFit.cover, gaplessPlayback: true)
            : const Icon(Icons.insert_drive_file, size: 48);

        final rid = _coerceInt(r['id'])!;
        final apptId = _coerceInt(r['appointment_id']); // may be null (ok)
        final createdText = _whenStr(_parseDt(r['uploaded_at']));

        final cardBody = Card(
          clipBehavior: Clip.antiAlias,
          shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(16)),
          elevation: 1,
          child: InkWell(
            onTap: () => showDocLightbox(context, title: name, url: url),
            onLongPress: _isMobile
                ? () => _openActionsMobile(
                      title: name,
                      createdAt: createdText,
                      appointmentId: apptId,
                      doctorName: _doctorForAppt(apptId),
                      onOpen: () => showDocLightbox(context, title: name, url: url),
                      onDownload: () => _downloadUrl(url),
                      onDeleteConfirmed: () async {
                        final ok = await _confirm(
                          title: 'Delete report?',
                          message: 'This will permanently remove the report.',
                        );
                        if (ok) await _deleteReport(rid, appointmentId: apptId);
                      },
                    )
                : null,
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.stretch,
              children: [
                AspectRatio(aspectRatio: 4 / 3, child: Center(child: preview)),
                Padding(
                  padding: const EdgeInsets.fromLTRB(12, 10, 12, 8),
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      Text(name,
                          maxLines: 1,
                          overflow: TextOverflow.ellipsis,
                          style: const TextStyle(fontWeight: FontWeight.w600)),
                      const SizedBox(height: 4),
                      Row(
                        children: [
                          const Icon(Icons.schedule, size: 14),
                          const SizedBox(width: 4),
                          Expanded(
                            child: Text(
                              createdText,
                              style: Theme.of(context).textTheme.bodySmall,
                              overflow: TextOverflow.ellipsis,
                            ),
                          ),
                        ],
                      ),
                    ],
                  ),
                ),
                if (!_isMobile)
                  Padding(
                    padding: const EdgeInsets.fromLTRB(6, 0, 6, 6),
                    child: Row(
                      mainAxisAlignment: MainAxisAlignment.spaceBetween,
                      children: [
                        IconButton(
                          tooltip: 'Download',
                          onPressed: () => _downloadUrl(url),
                          icon: const Icon(Icons.download),
                        ),
                        IconButton(
                          tooltip: apptId == null ? 'Delete' : 'Delete (appointment-linked)',
                          onPressed: () async {
                            final ok = await _confirm(
                              title: 'Delete report?',
                              message: 'This will permanently remove the report.',
                            );
                            if (ok) await _deleteReport(rid, appointmentId: apptId);
                          },
                          icon: const Icon(Icons.delete, color: Colors.red),
                        ),
                      ],
                    ),
                  ),
              ],
            ),
          ),
        );

        // Tooltips only on non-mobile (doctor/appointment fetched lazily when opening sheet)
        return _isMobile ? cardBody : Tooltip(message: 'Created: $createdText', child: cardBody);
      },
    );
  }

  Widget _prescriptionsGrid() {
    if (prescriptions.isEmpty) {
      return const Center(child: Text('No prescriptions yet.'));
    }

    return GridView.builder(
      padding: const EdgeInsets.all(12),
      gridDelegate: SliverGridDelegateWithMaxCrossAxisExtent(
        maxCrossAxisExtent: _isMobile ? 240 : 280,
        mainAxisSpacing: 12,
        crossAxisSpacing: 12,
        childAspectRatio: 0.78,
      ),
      itemCount: prescriptions.length,
      itemBuilder: (ctx, i) {
        final p = prescriptions[i];
        final apptId = _coerceInt(p['appointment_id']) ?? 0;
        final createdText = _whenStr(_parseDt(p['created_at']));
        final fileUrl = (p['file_url'] ?? p['file_path'] ?? '') as String;
        final content = (p['content'] ?? '') as String;
        final hasFile = fileUrl.toString().isNotEmpty;
        final url = hasFile ? _fileUrlFromPath(fileUrl) : '';
        final isImg = hasFile && _isImage(fileUrl);
        final title = hasFile ? fileUrl.split('/').last : 'Prescription';
        final preview = hasFile
            ? (isImg
                ? Image.network(url, fit: BoxFit.cover, gaplessPlayback: true)
                : const Icon(Icons.description, size: 48))
            : const Icon(Icons.description, size: 48);

        final cardBody = Card(
          clipBehavior: Clip.antiAlias,
          shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(16)),
          elevation: 1,
          child: InkWell(
            onTap: hasFile ? () => showDocLightbox(context, title: title, url: url) : null,
            onLongPress: _isMobile
                ? () => _openActionsMobile(
                      title: title,
                      createdAt: createdText,
                      appointmentId: apptId,
                      doctorName: _doctorForAppt(apptId),
                      onOpen: hasFile ? () => showDocLightbox(context, title: title, url: url) : null,
                      onDownload: hasFile ? () => _downloadUrl(url) : null,
                      onDeleteConfirmed: () async {
                        final ok = await _confirm(
                          title: 'Delete prescription?',
                          message: 'This will remove the prescription for this appointment.',
                        );
                        if (ok) await _deletePrescription(apptId);
                      },
                    )
                : null,
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.stretch,
              children: [
                AspectRatio(aspectRatio: 4 / 3, child: Center(child: preview)),
                Padding(
                  padding: const EdgeInsets.fromLTRB(12, 10, 12, 8),
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      Text(title,
                          maxLines: 1,
                          overflow: TextOverflow.ellipsis,
                          style: const TextStyle(fontWeight: FontWeight.w600)),
                      if (content.isNotEmpty)
                        Padding(
                          padding: const EdgeInsets.only(top: 4),
                          child: Text(content, maxLines: 2, overflow: TextOverflow.ellipsis),
                        ),
                      const SizedBox(height: 4),
                      Row(
                        children: [
                          const Icon(Icons.schedule, size: 14),
                          const SizedBox(width: 4),
                          Expanded(
                            child: Text(
                              createdText,
                              style: Theme.of(context).textTheme.bodySmall,
                              overflow: TextOverflow.ellipsis,
                            ),
                          ),
                        ],
                      ),
                    ],
                  ),
                ),
                if (!_isMobile)
                  Padding(
                    padding: const EdgeInsets.fromLTRB(6, 0, 6, 6),
                    child: Row(
                      mainAxisAlignment: MainAxisAlignment.spaceBetween,
                      children: [
                        IconButton(
                          tooltip: 'Download',
                          onPressed: hasFile ? () => _downloadUrl(url) : null,
                          icon: const Icon(Icons.download),
                        ),
                        IconButton(
                          tooltip: 'Delete',
                          onPressed: () async {
                            final ok = await _confirm(
                              title: 'Delete prescription?',
                              message: 'This will remove the prescription for this appointment.',
                            );
                            if (ok) await _deletePrescription(apptId);
                          },
                          icon: const Icon(Icons.delete, color: Colors.red),
                        ),
                      ],
                    ),
                  ),
              ],
            ),
          ),
        );

        return _isMobile ? cardBody : Tooltip(message: 'Created: $createdText', child: cardBody);
      },
    );
  }
}


// ─────────────────────────────────────────────────────────────────────────────
// Payments Tab — Modern UI (cards + tall details) with an improved Search UI
// ─────────────────────────────────────────────────────────────────────────────
class _PaymentsTab extends StatefulWidget {
  const _PaymentsTab();

  @override
  State<_PaymentsTab> createState() => _PaymentsTabState();
}

class _PaymentsTabState extends State<_PaymentsTab> {
  bool loading = true;

  // Data
  List<Map<String, dynamic>> items = [];
  int page = 1;
  int totalPages = 1;
  static const pageSize = 10;

  // Filters
  final apptController = TextEditingController();    // Appointment #
  final txnController  = TextEditingController();    // Transaction ID
  final searchController = TextEditingController();  // Smart search (phone)

  // Sort settings (default: latest paid first)
  String sortKey = 'paid_at'; // 'paid_at' | 'appointment_id'
  bool sortDesc = true;

  @override
  void initState() {
    super.initState();
    _load();
  }

  @override
  void dispose() {
    apptController.dispose();
    txnController.dispose();
    searchController.dispose();
    super.dispose();
  }

  // ───────────────────────────────── helpers ─────────────────────────────────
  Map<String, dynamic> _normalize(Map raw) {
    final m = Map<String, dynamic>.from(raw);

    String _doctorNameOf(dynamic d) {
      try {
        if (d is Map) {
          final mm = Map<String, dynamic>.from(d);
          final n = mm['name'];
          return (n == null) ? '' : n.toString();
        }
        return d?.toString() ?? '';
      } catch (_) {
        return '';
      }
    }

    final dynamic paymentIdDyn = (m['payment_id'] ?? m['id']);
    final int paymentId = (paymentIdDyn is num)
        ? paymentIdDyn.toInt()
        : int.tryParse('${paymentIdDyn ?? 0}') ?? 0;

    final dynamic apptIdDyn = (m['appointment_id'] ?? m['appointment']?['id'] ?? 0);
    final int apptId = (apptIdDyn is num)
        ? apptIdDyn.toInt()
        : int.tryParse('$apptIdDyn') ?? 0;

    final String docName = _doctorNameOf(m['doctor']);
    final String txnId = (m['transaction_id'] ?? '').toString();
    final String method = (m['method'] ?? m['gateway'] ?? '').toString();
    final String status = (m['status'] ?? '').toString();

    final dynamic amountDyn = (m['amount'] ?? m['total'] ?? 0);
    final num amount = (amountDyn is num)
        ? amountDyn
        : (num.tryParse(amountDyn.toString()) ?? 0);

    DateTime? paidAt;
    final paidVal = m['paid_at'];
    if (paidVal is DateTime) {
      paidAt = paidVal;
    } else if (paidVal is String && paidVal.isNotEmpty) {
      paidAt = DateTime.tryParse(paidVal);
    }

    final appt = (m['appointment'] is Map) ? Map<String, dynamic>.from(m['appointment']) : <String, dynamic>{};
    DateTime? apptStart;
    final st = appt['start_time'];
    if (st is DateTime) apptStart = st;
    else if (st is String && st.isNotEmpty) apptStart = DateTime.tryParse(st);

    return {
      'payment_id': paymentId,
      'appointment_id': apptId,
      'doctor_name': docName,
      'transaction_id': txnId,
      'method': method,
      'status': status,
      'amount': amount,
      'paid_at': paidAt,
      'appointment': {'start_time': apptStart},
      '_raw': m,
    };
  }

  Future<void> _load() async {
    setState(() => loading = true);
    try {
      final urls = <String>[
        '/me/payments',
        '/payments/me',
        '/payments',
        '/patient/payments',
        '/billing/payments',
        '/billing/history',
        '/api/me/payments',
        '/api/payments/me',
        '/api/payments',
      ];
      final query = {'page': page, 'page_size': pageSize};

      List<Map<String, dynamic>> rows = [];
      int pages = 1;

      for (final u in urls) {
        try {
          final r = await Api.get(u, query: query);
          if (r is Map) {
            final map = Map<String, dynamic>.from(r);
            late final List list;
            if (map['items'] is List) {
              list = map['items'] as List;
              if (map['total_pages'] is int) pages = map['total_pages'] as int;
            } else if (map['results'] is List) {
              list = map['results'] as List;
              if (map['pages'] is int) pages = map['pages'] as int;
            } else if (map['data'] is Map && (map['data']['items'] is List)) {
              list = map['data']['items'] as List;
              final tp = map['data']['total_pages'];
              if (tp is int) pages = tp;
            } else if (map['payments'] is List) {
              list = map['payments'] as List;
              if (map['pages'] is int) pages = map['pages'] as int;
            } else if (map['data'] is List) {
              list = map['data'] as List;
            } else {
              continue;
            }
            rows = list.map<Map<String, dynamic>>((e) => _normalize(e as Map)).toList();
            break;
          } else if (r is List) {
            rows = r.map<Map<String, dynamic>>((e) => _normalize(e as Map)).toList();
            pages = (rows.length / pageSize).ceil().clamp(1, 9999);
            final start = (page - 1) * pageSize;
            rows = rows.skip(start).take(pageSize).toList();
            break;
          }
        } catch (_) {}
      }

      // ── client-side filtering ──────────────────────────────────────────────
      // Wide toolbar inputs
      final apptText = apptController.text.trim();
      final txnText  = txnController.text.trim();

      if (apptText.isNotEmpty) {
        final apptNum = int.tryParse(apptText);
        if (apptNum != null) {
          rows = rows.where((e) => (e['appointment_id'] as int) == apptNum).toList();
        }
      }
      if (txnText.isNotEmpty) {
        final q = txnText.toLowerCase();
        rows = rows.where((e) =>
          (e['transaction_id'] ?? '').toString().toLowerCase().contains(q)
        ).toList();
      }

      // Phone “Smart Search”: #123 filters appointment; otherwise matches txn/doctor
      final smart = searchController.text.trim();
      if (smart.isNotEmpty) {
        if (smart.startsWith('#')) {
          final numStr = smart.substring(1);
          final apptNum = int.tryParse(numStr);
          if (apptNum != null) {
            rows = rows.where((e) => (e['appointment_id'] as int) == apptNum).toList();
          }
        } else if (int.tryParse(smart) != null) {
          final q = smart.toLowerCase();
          rows = rows.where((e) =>
              (e['transaction_id'] ?? '').toString().toLowerCase().contains(q)
          ).toList();
        } else {
          final q = smart.toLowerCase();
          rows = rows.where((e) =>
              (e['doctor_name'] ?? '').toString().toLowerCase().contains(q) ||
              (e['transaction_id'] ?? '').toString().toLowerCase().contains(q)
          ).toList();
        }
      }

      // Sort
      rows.sort((a, b) {
        int cmp = 0;
        if (sortKey == 'appointment_id') {
          cmp = (a['appointment_id'] as int).compareTo(b['appointment_id'] as int);
        } else {
          final A = a['paid_at'] as DateTime?;
          final B = b['paid_at'] as DateTime?;
          if (A == null && B == null) cmp = 0;
          else if (A == null) cmp = -1;
          else if (B == null) cmp = 1;
          else cmp = A.compareTo(B);
        }
        return sortDesc ? -cmp : cmp;
      });

      setState(() {
        items = rows;
        totalPages = pages;
      });
    } catch (e) {
      showSnack(context, 'Load failed: $e');
      setState(() {
        items = [];
        totalPages = 1;
      });
    } finally {
      setState(() => loading = false);
    }
  }

  // ─────────── Download / Print (uses your existing helpers) ───────────
  Future<void> _downloadReceipt(int id) async {
    try {
      final bytes = await Api.getBytes('/payments/$id/receipt');
      await downloadBytes(bytes, 'receipt-$id.pdf');
    } catch (e) {
      showSnack(context, 'Receipt download failed: $e');
    }
  }

  Future<void> _printReceipt(int id) async {
    try {
      final bytes = await Api.getBytes('/payments/$id/receipt');
      await printPdfBytes(bytes);
    } catch (e) {
      showSnack(context, 'Print failed: $e');
    }
  }

  Future<Map<String, dynamic>?> _fetchAppointment(int apptId) async {
    try {
      final r = await Api.get('/appointments/$apptId');
      if (r is Map) return Map<String, dynamic>.from(r);
    } catch (_) {}
    return null;
  }

  // ─────────────────────────── details sheet (kept) ───────────────────────────
  void _showDetails(Map<String, dynamic> row) async {
    final df = DateFormat.yMMMd().add_jm();

    final int paymentId = row['payment_id'] as int;
    final String txnId = (row['transaction_id'] ?? '').toString();
    final num amount = (row['amount'] ?? 0) as num;
    final String method = (row['method'] ?? '').toString();
    final String status = (row['status'] ?? '').toString();
    final DateTime? paidAt = row['paid_at'] as DateTime?;
    final String paidStr = paidAt != null ? df.format(paidAt.toLocal()) : '—';
    final int apptId = row['appointment_id'] as int;
    final String doctor = (row['doctor_name'] ?? '').toString();

    String mode = '-';
    String whenStr = '—';
    final appt = (row['appointment'] is Map) ? Map<String, dynamic>.from(row['appointment']) : <String, dynamic>{};
    final DateTime? start = appt['start_time'] as DateTime?;
    if (start != null) whenStr = df.format(start.toLocal());

    final apptJson = await _fetchAppointment(apptId);
    if (apptJson != null) {
      final vm = (apptJson['visit_mode'] ?? '').toString();
      if (vm.isNotEmpty) mode = vm;
      final st = apptJson['start_time'];
      if (start == null && st is String && st.isNotEmpty) {
        final parsed = DateTime.tryParse(st);
        if (parsed != null) whenStr = df.format(parsed.toLocal());
      }
    }

    showModalBottomSheet(
      context: context,
      useSafeArea: true,
      isScrollControlled: true,
      backgroundColor: Theme.of(context).colorScheme.surface,
      shape: const RoundedRectangleBorder(
        borderRadius: BorderRadius.vertical(top: Radius.circular(24)),
      ),
      builder: (_) {
        return DraggableScrollableSheet(
          expand: false,
          initialChildSize: 0.70,
          minChildSize: 0.45,
          maxChildSize: 0.95,
          builder: (_, controller) {
            return ListView(
              controller: controller,
              padding: const EdgeInsets.fromLTRB(16, 12, 16, 24),
              children: [
                Center(
                  child: Container(
                    width: 36, height: 4,
                    margin: const EdgeInsets.only(bottom: 12),
                    decoration: BoxDecoration(
                      color: Theme.of(context).colorScheme.outlineVariant,
                      borderRadius: BorderRadius.circular(2),
                    ),
                  ),
                ),
                Padding(
                  padding: const EdgeInsets.only(bottom: 4),
                  child: Row(
                    crossAxisAlignment: CrossAxisAlignment.center,
                    children: [
                      const CircleAvatar(radius: 20, child: Icon(Icons.person)),
                      const SizedBox(width: 12),

                      // Name + #ID
                      Expanded(
                        child: Column(
                          mainAxisSize: MainAxisSize.min,
                          crossAxisAlignment: CrossAxisAlignment.start,
                          children: [
                            Text(
                              doctor.isNotEmpty ? doctor : '—',
                              style: Theme.of(context).textTheme.titleMedium,
                              maxLines: 1,
                              overflow: TextOverflow.ellipsis,
                            ),
                            const SizedBox(height: 2),
                            Text(
                              '#$apptId',
                              maxLines: 1,
                              overflow: TextOverflow.ellipsis,
                            ),
                          ],
                        ),
                      ),

                      const SizedBox(width: 12),

                      // Amount + status (shrink-to-fit to avoid overflow)
                      Column(
                        mainAxisSize: MainAxisSize.min,
                        crossAxisAlignment: CrossAxisAlignment.end,
                        children: [
                          FittedBox(
                            fit: BoxFit.scaleDown,
                            alignment: Alignment.centerRight,
                            child: Text(
                              '৳ ${amount.toStringAsFixed(2)}',
                              style: Theme.of(context)
                                  .textTheme
                                  .titleMedium
                                  ?.copyWith(fontWeight: FontWeight.w700),
                            ),
                          ),
                          const SizedBox(height: 4),
                          _statusChip(status),
                        ],
                      ),
                    ],
                  ),
                ),
                const SizedBox(height: 12),
                _kv('Transaction ID', txnId),
                _kv('Method', method),
                _kv('Paid at', paidStr),
                _kv('Mode', mode),
                _kv('Appointment Time', whenStr),
                Wrap(
                  spacing: 12,
                  runSpacing: 12,
                  children: [
                    SizedBox(
                      width: double.infinity,
                      child: FilledButton.icon(
                        onPressed: () => _downloadReceipt(paymentId),
                        icon: const Icon(Icons.download_rounded),
                        label: const Text('Download'),
                      ),
                    ),
                    SizedBox(
                      width: double.infinity,
                      child: OutlinedButton.icon(
                        onPressed: () => _printReceipt(paymentId),
                        icon: const Icon(Icons.print_rounded),
                        label: const Text('Print'),
                      ),
                    ),
                  ],
                ),

              ],
            );
          },
        );
      },
    );
  }

  Widget _statusChip(String status) {
    final s = status.toLowerCase();
    Color bg, fg;
    if (s.contains('paid') || s.contains('success')) {
      bg = Colors.green.withOpacity(.15);
      fg = Colors.green.shade800;
    } else if (s.contains('pending')) {
      bg = Colors.amber.withOpacity(.15);
      fg = Colors.amber.shade800;
    } else {
      bg = Colors.red.withOpacity(.15);
      fg = Colors.red.shade800;
    }
    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 4),
      decoration: BoxDecoration(color: bg, borderRadius: BorderRadius.circular(12)),
      child: Text(status, style: TextStyle(color: fg, fontSize: 12, fontWeight: FontWeight.w600)),
    );
  }

  Widget _kv(String k, String v) => Padding(
        padding: const EdgeInsets.symmetric(vertical: 8),
        child: Row(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            SizedBox(width: 120, child: Text(k, style: const TextStyle(fontWeight: FontWeight.w600))),
            const SizedBox(width: 8),
            Expanded(child: Text(v)),
          ],
        ),
      );

  // ───────────────────────────── search UI ─────────────────────────────
  Widget _phoneSearchRow() {
    return Row(
      children: [
        Expanded(
          child: TextField(
            controller: searchController,
            textInputAction: TextInputAction.search,
            decoration: InputDecoration(
              hintText: 'Search: #123, TXN, or Doctor',
              prefixIcon: const Icon(Icons.search),
              suffixIcon: (searchController.text.isEmpty)
                  ? null
                  : IconButton(
                      tooltip: 'Clear',
                      icon: const Icon(Icons.close),
                      onPressed: () {
                        searchController.clear();
                        page = 1;
                        _load();
                        setState(() {});
                      },
                    ),
              border: OutlineInputBorder(borderRadius: BorderRadius.circular(24)),
              isDense: true,
              filled: true,
            ),
            onChanged: (_) => setState(() {}), // show/hide clear
            onSubmitted: (_) { page = 1; _load(); },
          ),
        ),
        const SizedBox(width: 8),
        PopupMenuButton<String>(
          tooltip: 'Sort',
          icon: Icon(sortDesc ? Icons.south : Icons.north),
          onSelected: (v) {
            if (v == 'dir') setState(() => sortDesc = !sortDesc);
            if (v == 'paid_at' || v == 'appointment_id') setState(() => sortKey = v);
            page = 1;
            _load();
          },
          itemBuilder: (context) => [
            PopupMenuItem(
              value: 'paid_at',
              child: Row(children: [
                Icon(sortKey == 'paid_at' ? Icons.radio_button_checked : Icons.radio_button_unchecked, size: 18),
                const SizedBox(width: 8),
                const Text('Payment date'),
              ]),
            ),
            PopupMenuItem(
              value: 'appointment_id',
              child: Row(children: [
                Icon(sortKey == 'appointment_id' ? Icons.radio_button_checked : Icons.radio_button_unchecked, size: 18),
                const SizedBox(width: 8),
                const Text('Appointment #'),
              ]),
            ),
            const PopupMenuDivider(),
            PopupMenuItem(
              value: 'dir',
              child: Row(children: [
                Icon(sortDesc ? Icons.south : Icons.north, size: 18),
                const SizedBox(width: 8),
                Text(sortDesc ? 'Descending' : 'Ascending'),
              ]),
            ),
          ],
        ),
        IconButton(
          tooltip: 'Refresh',
          onPressed: _load,
          icon: const Icon(Icons.refresh),
        ),
      ],
    );
  }

  Widget _wideToolbarRow() {
    return Row(
      children: [
        Expanded(
          child: TextField(
            controller: apptController,
            keyboardType: TextInputType.number,
            decoration: const InputDecoration(
              prefixIcon: Icon(Icons.receipt_long),
              labelText: 'Appointment #',
              border: UnderlineInputBorder(),
            ),
            onSubmitted: (_) { page = 1; _load(); },
          ),
        ),
        const SizedBox(width: 16),
        Expanded(
          child: TextField(
            controller: txnController,
            decoration: const InputDecoration(
              prefixIcon: Icon(Icons.badge_outlined),
              labelText: ' ID',
              border: UnderlineInputBorder(),
            ),
            onSubmitted: (_) { page = 1; _load(); },
          ),
        ),
        const SizedBox(width: 16),
        ElevatedButton.icon(
          onPressed: () { page = 1; _load(); },
          icon: const Icon(Icons.search),
          label: const Text('Search'),
        ),
        const SizedBox(width: 8),
        PopupMenuButton<String>(
          tooltip: 'Sort',
          icon: Icon(sortDesc ? Icons.south : Icons.north),
          onSelected: (v) {
            if (v == 'dir') setState(() => sortDesc = !sortDesc);
            if (v == 'paid_at' || v == 'appointment_id') setState(() => sortKey = v);
            page = 1;
            _load();
          },
          itemBuilder: (context) => [
            const PopupMenuItem(value: 'paid_at', child: Text('Payment date')),
            const PopupMenuItem(value: 'appointment_id', child: Text('Appointment #')),
            const PopupMenuDivider(),
            PopupMenuItem(value: 'dir', child: Text(sortDesc ? 'Descending' : 'Ascending')),
          ],
        ),
        const SizedBox(width: 8),
        IconButton(
          tooltip: 'Refresh',
          onPressed: _load,
          icon: const Icon(Icons.refresh),
        ),
      ],
    );
  }

  // ──────────────────────────────── build ────────────────────────────────────
  @override
  Widget build(BuildContext context) {
    final df = DateFormat.yMMMd().add_jm();
    final isPhone = MediaQuery.of(context).size.width < 600;

    if (loading) return const Center(child: CircularProgressIndicator());

    return Column(
      children: [
        Padding(
          padding: const EdgeInsets.fromLTRB(12, 8, 12, 6),
          child: isPhone ? _phoneSearchRow() : _wideToolbarRow(),
        ),

        Expanded(
          child: items.isEmpty
              ? const Center(child: Text('No payments found.'))
              : ListView.builder(
                  padding: const EdgeInsets.fromLTRB(12, 0, 12, 12),
                  itemCount: items.length,
                  itemBuilder: (_, i) {
                    final p = items[i];

                    final int id       = p['payment_id'] as int;
                    final String doctor = (p['doctor_name'] ?? '').toString();
                    final num amount    = (p['amount'] ?? 0) as num;
                    final String method = (p['method'] ?? '').toString();
                    final String status = (p['status'] ?? '').toString();
                    final DateTime? paidAt = p['paid_at'] as DateTime?;
                    final String paidStr   = paidAt != null ? df.format(paidAt.toLocal()) : '—';

                    return Card(
                      margin: const EdgeInsets.symmetric(vertical: 8),
                      elevation: 0,
                      shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(16)),
                      child: InkWell(
                        borderRadius: BorderRadius.circular(16),
                        onTap: () => _showDetails(p),
                        onLongPress: () => _downloadReceipt(id),
                        child: Padding(
                          padding: const EdgeInsets.fromLTRB(12, 10, 12, 10),
                          child: Row(
                            crossAxisAlignment: CrossAxisAlignment.center,
                            children: [
                              const CircleAvatar(radius: 22, child: Icon(Icons.event_note)),
                              const SizedBox(width: 12),
                              Expanded(
                                child: Column(
                                  crossAxisAlignment: CrossAxisAlignment.start,
                                  children: [
                                    Text(
                                      doctor.isNotEmpty ? doctor : '—',
                                      maxLines: 1,
                                      overflow: TextOverflow.ellipsis,
                                      style: const TextStyle(fontWeight: FontWeight.w600),
                                    ),
                                    const SizedBox(height: 4),
                                    Text('$method • $paidStr',
                                        maxLines: 1, overflow: TextOverflow.ellipsis),
                                  ],
                                ),
                              ),
                              const SizedBox(width: 12),
                              Column(
                                crossAxisAlignment: CrossAxisAlignment.end,
                                children: [
                                  Text('৳ ${amount.toStringAsFixed(2)}',
                                      style: const TextStyle(
                                          fontWeight: FontWeight.w700, fontSize: 16)),
                                  const SizedBox(height: 6),
                                  _statusChip(status),
                                ],
                              ),
                            ],
                          ),
                        ),
                      ),
                    );
                  },
                ),
        ),

        if (totalPages > 1)
          Padding(
            padding: const EdgeInsets.only(bottom: 10),
            child: Wrap(
              spacing: 6,
              children: List.generate(totalPages, (i) => i + 1).map((pno) {
                return ChoiceChip(
                  selected: pno == page,
                  label: Text('$pno'),
                  onSelected: (_) {
                    setState(() => page = pno);
                    _load();
                  },
                );
              }).toList(),
            ),
          ),
      ],
    );
  }
}

// ─────────────────────────────────────────────────────────────────────────────
// Profile tab — reads /whoami and /patient/profile, shows photo_path,
// ─────────────────────────────────────────────────────────────────────────────
class _ProfileTab extends StatefulWidget {
        const _ProfileTab();

        @override
        State<_ProfileTab> createState() => _ProfileTabState();
        }

        class _ProfileTabState extends State<_ProfileTab> {
        Map<String, dynamic>? profileJson; // from /patient/profile
        Map<String, dynamic>? whoami;       // from /whoami
        bool loading = true;

        // Edit toggles
        bool editingAccount = false;
        bool editingMedical = false;

        // Photo handling
        String? _photoPath;          
        Uint8List? _localPreview;    // local preview immediately after picking
        int _bust = DateTime.now().millisecondsSinceEpoch; // cache-buster for Image.network

        // Account controllers
        final name = TextEditingController();
        final email = TextEditingController();
        final phone = TextEditingController();
        final currentPassword = TextEditingController();   // NEW
        final newPassword = TextEditingController();
        final confirmPassword = TextEditingController();

        // Medical controllers
        final age = TextEditingController();
        final weight = TextEditingController();
        final heightCm = TextEditingController();
        String? gender;
        String? bloodGroup;
        final desc = TextEditingController();
        final meds = TextEditingController();
        final hist = TextEditingController();

        static const _genderOptions = ['Male', 'Female', 'Other', 'Prefer not to say'];
        static const _bloodGroups   = ['A+', 'A-', 'B+', 'B-', 'AB+', 'AB-', 'O+', 'O-'];

        @override
        void initState() {
            super.initState();
            _loadAll();
        }

        @override
        void dispose() {
            // account
            name.dispose();
            email.dispose();
            phone.dispose();
            currentPassword.dispose();
            newPassword.dispose();
            confirmPassword.dispose();
            // medical
            age.dispose();
            weight.dispose();
            heightCm.dispose();
            desc.dispose();
            meds.dispose();
            hist.dispose();
            super.dispose();
        }

        // ====================== Load ======================
        Future<void> _loadAll() async {
            if (!mounted) return;
            setState(() => loading = true);
            try {
            final resWho = await Api.get('/whoami') as Map<String, dynamic>;
            final resProf = await Api.get('/patient/profile') as Map<String, dynamic>;

            whoami = resWho;
            profileJson = resProf;

            // account fill
            name.text  = (whoami?['name']  ?? '').toString();
            email.text = (whoami?['email'] ?? '').toString();
            phone.text = (whoami?['phone'] ?? '').toString();
            _photoPath = (whoami?['photo_path'] ?? '') as String?;
            if (_photoPath != null && _photoPath!.startsWith('./')) {
                _photoPath = _photoPath!.substring(2);
            }

            // medical fill
            final p = (profileJson?['profile'] ?? {}) as Map<String, dynamic>;
            age.text    = (p['age'] ?? '').toString();
            weight.text = (p['weight'] ?? '').toString();
            heightCm.text = (p['height'] ?? '').toString(); // backend stores "height" (cm)
            gender     = (p['gender'] ?? '')?.toString().isEmpty == true ? null : p['gender']?.toString();
            bloodGroup = (p['blood_group'] ?? '')?.toString().isEmpty == true ? null : p['blood_group']?.toString();
            desc.text  = (p['description'] ?? '').toString();
            meds.text  = (p['current_medicine'] ?? '').toString();
            hist.text  = (p['medical_history'] ?? '').toString();
            } catch (e) {
            _snack('Load failed: $e');
            } finally {
            if (!mounted) return;
            setState(() => loading = false);
            }
        }

        // ====================== Save ======================
        Future<void> _save() async {
            try {
            // ----- Account (name/email/phone + optional password change)
            if (editingAccount) {
                // 1) Patch /me with only changed fields
                final Map<String, dynamic> changes = {};
                if (name.text.trim() != (whoami?['name'] ?? '')) {
                changes['name'] = name.text.trim();
                }
                if (email.text.trim() != (whoami?['email'] ?? '')) {
                changes['email'] = email.text.trim().isEmpty ? null : email.text.trim();
                }
                if (phone.text.trim() != (whoami?['phone'] ?? '')) {
                changes['phone'] = phone.text.trim().isEmpty ? null : phone.text.trim();
                }
                if (changes.isNotEmpty) {
                await Api.patch('/me', data: changes); // JSON body supported by backend
                }

                // 2) Handle password change if provided
                final oldPw = currentPassword.text;
                final newPw = newPassword.text;
                final conf  = confirmPassword.text;
                final wantsPwChange = oldPw.isNotEmpty || newPw.isNotEmpty || conf.isNotEmpty;

                if (wantsPwChange) {
                if (oldPw.isEmpty) {
                    _snack('Enter your current password to change it.');
                    return;
                }
                if (newPw.isEmpty || conf.isEmpty) {
                    _snack('Enter and confirm your new password.');
                    return;
                }
                if (newPw != conf) {
                    _snack('Passwords do not match');
                    return;
                }

                final form = FormData.fromMap({
                    'old': oldPw,
                    'new': newPw,
                });
                await Api.post('/auth/change_password', data: form, multipart: true);
                }
            }

            // ----- Medical profile
            if (editingMedical) {
                final body = {
                'age': int.tryParse(age.text),
                'weight': int.tryParse(weight.text),
                'height': int.tryParse(heightCm.text), // backend uses "height" (cm)
                'blood_group': bloodGroup,
                'gender': gender,
                'description': desc.text,
                'current_medicine': meds.text,
                'medical_history': hist.text,
                };
                await Api.patch('/patient/profile', data: body);
            }

            _snack('Saved');
            if (!mounted) return;
            setState(() {
                editingAccount = false;
                editingMedical = false;
                currentPassword.clear();
                newPassword.clear();
                confirmPassword.clear();
            });
            await _loadAll();
            } catch (e) {
            _snack('Save failed: $e');
            }
        }

        // ====================== Photo ======================
        String? _photoUrl() {
            if (_localPreview != null) return null; // local bytes will be shown via Image.memory
            final p = _photoPath;
            if (p == null || p.isEmpty) return null;
            // Serve static from FastAPI StaticFiles: ensure single leading slash
            final path = p.startsWith('/') ? p.substring(1) : p;
            return '${Api.baseUrl}/$path?v=$_bust';
        }

        Future<void> _uploadPhoto() async {
            final pick = await FilePicker.platform.pickFiles(
            withData: true,
            type: FileType.image,
            );
            if (pick == null || pick.files.isEmpty) return;
            final f = pick.files.first;
            if (f.bytes == null) {
            _snack('Could not read file bytes.');
            return;
            }

            // show immediate preview
            setState(() => _localPreview = f.bytes);

            try {
            final form = FormData.fromMap({
                'file': MultipartFile.fromBytes(f.bytes as Uint8List, filename: f.name),
            });
            final res = await Api.post('/me/photo', data: form, multipart: true) as Map<String, dynamic>;
            final newPath = (res['photo_path'] ?? '') as String?;
            setState(() {
                _photoPath = newPath ?? _photoPath;
                _bust = DateTime.now().millisecondsSinceEpoch; // force reload
                _localPreview = null; // swap to server path
            });
            _snack('Profile photo updated');
            } catch (e) {
            _snack('Upload failed: $e');
            setState(() => _localPreview = null);
            }
        }

        // ====================== UI ======================
        @override
        Widget build(BuildContext context) {
            if (loading) return const Center(child: CircularProgressIndicator());
            final anyEditing = editingAccount || editingMedical;

            return Stack(
            children: [
                SingleChildScrollView(
                padding: const EdgeInsets.fromLTRB(12, 12, 12, 100),
                child: Column(
                    children: [
                    _headerCard(context),
                    const SizedBox(height: 12),
                    _accountCard(context),
                    const SizedBox(height: 12),
                    _medicalCard(context),
                    ],
                ),
                ),
                if (anyEditing)
                Positioned(left: 0, right: 0, bottom: 0, child: _bottomActionBar(context)),
            ],
            );
        }

        Widget _headerCard(BuildContext context) {
            final scheme = Theme.of(context).colorScheme;

            Widget avatar;
            if (_localPreview != null) {
            avatar = Image.memory(_localPreview!, fit: BoxFit.cover);
            } else {
            final url = _photoUrl();
            if (url != null) {
                avatar = Image.network(
                url,
                fit: BoxFit.cover,
                errorBuilder: (_, __, ___) => const ColoredBox(
                    color: Color(0x11000000),
                    child: Icon(Icons.person, size: 56),
                ),
                );
            } else {
                avatar = const ColoredBox(
                color: Color(0x11000000),
                child: Icon(Icons.person, size: 56),
                );
            }
            }

            final displayName = (whoami?['name'] ?? '').toString();

            return Card(
            elevation: 2,
            shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(20)),
            child: Container(
                decoration: BoxDecoration(
                gradient: LinearGradient(
                    colors: [scheme.primary.withOpacity(0.06), scheme.secondary.withOpacity(0.04)],
                    begin: Alignment.topLeft,
                    end: Alignment.bottomRight,
                ),
                borderRadius: BorderRadius.circular(20),
                ),
                padding: const EdgeInsets.fromLTRB(16, 20, 16, 18),
                child: Column(
                children: [
                    Stack(
                    alignment: Alignment.bottomRight,
                    children: [
                        ClipOval(child: SizedBox(width: 108, height: 108, child: avatar)),
                        Material(
                        color: scheme.primary,
                        elevation: 3,
                        shape: const CircleBorder(),
                        child: InkWell(
                            customBorder: const CircleBorder(),
                            onTap: _uploadPhoto,
                            child: const Padding(
                            padding: EdgeInsets.all(10),
                            child: Icon(Icons.photo_camera, size: 20, color: Colors.white),
                            ),
                        ),
                        ),
                    ],
                    ),
                    const SizedBox(height: 12),
                    Text(
                    displayName.isEmpty ? 'Profile' : displayName,
                    style: Theme.of(context).textTheme.titleMedium?.copyWith(fontWeight: FontWeight.w600),
                    ),
                ],
                ),
            ),
            );
        }

        Widget _accountCard(BuildContext context) {
            final cols = _colsForWidth(context);
            return _sectionCard(
            title: 'Account',
            trailing: IconButton(
                tooltip: editingAccount ? 'Editing...' : 'Edit account',
                onPressed: editingAccount ? null : () => setState(() => editingAccount = true),
                icon: const Icon(Icons.edit),
            ),
            children: [
                _grid([
                _tf(name, 'Name',  enabled: editingAccount, icon: Icons.person_outline),
                _tf(email, 'Email', enabled: editingAccount, icon: Icons.email_outlined, keyboardType: TextInputType.emailAddress),
                _tf(phone, 'Phone', enabled: editingAccount, icon: Icons.phone_outlined, keyboardType: TextInputType.phone),
                ], cols, gap: 12),
                const SizedBox(height: 12),
                _grid([
                _tf(currentPassword, 'Current Password', enabled: editingAccount, icon: Icons.lock_outline, obscure: true), // NEW
                _tf(newPassword, 'New Password (optional)', enabled: editingAccount, icon: Icons.lock_outline, obscure: true),
                _tf(confirmPassword, 'Confirm New Password', enabled: editingAccount, icon: Icons.lock_outline, obscure: true),
                ], cols == 1 ? 1 : 3, gap: 12),
                if (editingAccount)
                Padding(
                    padding: const EdgeInsets.only(top: 8),
                    child: Text(
                    'Tip: Leave password fields empty if you don’t want to change it.',
                    style: Theme.of(context).textTheme.bodySmall?.copyWith(color: Theme.of(context).hintColor),
                    ),
                ),
            ],
            );
        }

        Widget _medicalCard(BuildContext context) {
            final cols = _colsForWidth(context);
            return _sectionCard(
            title: 'Medical',
            trailing: IconButton(
                tooltip: editingMedical ? 'Editing...' : 'Edit medical info',
                onPressed: editingMedical ? null : () => setState(() => editingMedical = true),
                icon: const Icon(Icons.edit),
            ),
            children: [
                _grid([
                _tf(age, 'Age', enabled: editingMedical, icon: Icons.cake_outlined, keyboardType: TextInputType.number),
                _tf(weight, 'Weight (kg)', enabled: editingMedical, icon: Icons.monitor_weight_outlined, keyboardType: TextInputType.number),
                _tf(heightCm, 'Height (cm)', enabled: editingMedical, icon: Icons.height, keyboardType: TextInputType.number),
                ], cols, gap: 12),
                const SizedBox(height: 12),
                _grid([
                _dd<String>(
                    value: gender,
                    label: 'Gender',
                    enabled: editingMedical,
                    items: _genderOptions,
                    icon: Icons.wc,
                    onChanged: (v) => setState(() => gender = v),
                ),
                _dd<String>(
                    value: bloodGroup,
                    label: 'Blood Group',
                    enabled: editingMedical,
                    items: _bloodGroups,
                    icon: Icons.bloodtype_outlined,
                    onChanged: (v) => setState(() => bloodGroup = v),
                ),
                ], cols, gap: 12),
                const SizedBox(height: 12),
                _tf(desc, 'Description', enabled: editingMedical, maxLines: 3, icon: Icons.description_outlined),
                const SizedBox(height: 12),
                _tf(meds, 'Current Medicine', enabled: editingMedical, maxLines: 2, icon: Icons.medication_outlined),
                const SizedBox(height: 12),
                _tf(hist, 'Medical History', enabled: editingMedical, maxLines: 3, icon: Icons.history_edu_outlined),
            ],
            );
        }

        Widget _bottomActionBar(BuildContext context) {
            final scheme = Theme.of(context).colorScheme;
            return SafeArea(
            top: false,
            child: Container(
                decoration: BoxDecoration(
                color: Theme.of(context).colorScheme.surface,
                boxShadow: [BoxShadow(color: Colors.black.withOpacity(0.08), blurRadius: 10, offset: const Offset(0, -2))],
                border: Border(top: BorderSide(color: Theme.of(context).dividerColor)),
                ),
                padding: const EdgeInsets.fromLTRB(16, 10, 16, 10),
                child: Row(
                children: [
                    OutlinedButton.icon(
                    onPressed: () async {
                        setState(() {
                        editingAccount = false;
                        editingMedical = false;
                        currentPassword.clear();
                        newPassword.clear();
                        confirmPassword.clear();
                        });
                        await _loadAll(); // restore from server
                    },
                    icon: const Icon(Icons.close),
                    label: const Text('Cancel'),
                    ),
                    const Spacer(),
                    FilledButton.icon(
                    onPressed: _save,
                    icon: const Icon(Icons.save_rounded),
                    label: const Text('Save changes'),
                    style: FilledButton.styleFrom(
                        padding: const EdgeInsets.symmetric(horizontal: 18, vertical: 12),
                        shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(12)),
                        backgroundColor: scheme.primary,
                    ),
                    ),
                ],
                ),
            ),
            );
        }

        // ---- Small helpers --------------------------------------------------------
        void _snack(String msg) {
            if (!mounted) return;
            ScaffoldMessenger.of(context).showSnackBar(SnackBar(content: Text(msg)));
        }

        int _colsForWidth(BuildContext context) {
            final w = MediaQuery.of(context).size.width;
            if (w >= 1000) return 3;
            if (w >= 680) return 2;
            return 1;
        }

        Widget _grid(List<Widget> children, int cols, {double gap = 12}) {
            if (cols <= 1) {
            return Column(
                children: [
                for (int i = 0; i < children.length; i++) ...[
                    children[i],
                    if (i != children.length - 1) SizedBox(height: gap),
                ]
                ],
            );
            }
            final rows = <Widget>[];
            for (int i = 0; i < children.length; i += cols) {
            final slice = children.sublist(i, (i + cols).clamp(0, children.length));
            rows.add(Row(
                children: [
                for (int j = 0; j < slice.length; j++) ...[
                    Expanded(child: slice[j]),
                    if (j != slice.length - 1) SizedBox(width: gap),
                ]
                ],
            ));
            if (i + cols < children.length) rows.add(SizedBox(height: gap));
            }
            return Column(children: rows);
        }

        Widget _tf(
            TextEditingController c,
            String label, {
            bool enabled = false,
            int maxLines = 1,
            TextInputType? keyboardType,
            IconData? icon,
            bool obscure = false,
        }) {
            final scheme = Theme.of(context).colorScheme;
            return TextField(
            controller: c,
            enabled: enabled,
            maxLines: maxLines,
            obscureText: obscure,
            keyboardType: keyboardType,
            decoration: InputDecoration(
                prefixIcon: icon != null ? Icon(icon) : null,
                labelText: label,
                filled: true,
                fillColor: enabled ? null : scheme.surfaceVariant.withOpacity(0.35),
                border: OutlineInputBorder(borderRadius: BorderRadius.circular(14)),
                enabledBorder: OutlineInputBorder(
                borderRadius: BorderRadius.circular(14),
                borderSide: BorderSide(color: Theme.of(context).dividerColor),
                ),
                focusedBorder: OutlineInputBorder(
                borderRadius: BorderRadius.circular(14),
                borderSide: BorderSide(color: Theme.of(context).colorScheme.primary, width: 2),
                ),
                contentPadding: const EdgeInsets.symmetric(horizontal: 14, vertical: 14),
            ),
            );
        }

        Widget _dd<T>({
            required T? value,
            required String label,
            required bool enabled,
            required List<T> items,
            IconData? icon,
            required ValueChanged<T?> onChanged,
        }) {
            final scheme = Theme.of(context).colorScheme;
            return DropdownButtonFormField<T>(
            value: value,
            onChanged: enabled ? onChanged : null,
            decoration: InputDecoration(
                    prefixIcon: icon != null ? Icon(icon) : null,
                    labelText: label,
                    filled: true,
                    fillColor: enabled ? null : scheme.surfaceVariant.withOpacity(0.35),
                    border: OutlineInputBorder(borderRadius: BorderRadius.circular(14)),
                    enabledBorder: OutlineInputBorder(
                    borderRadius: BorderRadius.circular(14),
                    borderSide: BorderSide(color: Theme.of(context).dividerColor),
                    ),
                    focusedBorder: OutlineInputBorder(
                    borderRadius: BorderRadius.circular(14),
                    borderSide: BorderSide(color: Theme.of(context).colorScheme.primary, width: 2),
                    ),
                    contentPadding: const EdgeInsets.symmetric(horizontal: 14, vertical: 14),
                ),
                items: items.map((e) => DropdownMenuItem<T>(value: e, child: Text(e.toString()))).toList(),
                );
            }

            Widget _sectionCard({required String title, required List<Widget> children, Widget? trailing}) {
                return Card(
                elevation: 2,
                shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(20)),
                child: Padding(
                    padding: const EdgeInsets.fromLTRB(14, 10, 14, 16),
                    child: Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                        Row(children: [
                        Expanded(
                            child: Text(title, style: Theme.of(context).textTheme.titleMedium?.copyWith(fontWeight: FontWeight.w600)),
                        ),
                        if (trailing != null) trailing,
                        ]),
                        const SizedBox(height: 8),
                        ...children,
                    ],
                    ),
                ),
                );
            }
    }

// ─────────────────────────────────────────────────────────────────────────────
// Simple placeholder chat page for online appointments
// ─────────────────────────────────────────────────────────────────────────────
class _ChatStubPage extends StatelessWidget {
  const _ChatStubPage({required this.apptId});
  final int apptId;

  @override
  Widget build(BuildContext context) {
    // Immediately navigate to ChatScreen so the button behaviour
    // matches user expectation: the Chat button opens the real chat.
    WidgetsBinding.instance.addPostFrameCallback((_) {
      Navigator.of(context).pushReplacement(
        MaterialPageRoute(builder: (_) => ChatScreen(apptId: apptId),),
      );
    });

    // While pushing replacement, show a short loading UI
    return Scaffold(
      appBar: AppBar(title: Text('Chat — #$apptId')),
      body: const Center(child: CircularProgressIndicator()),
    );
  }
}