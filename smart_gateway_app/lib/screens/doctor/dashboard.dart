// lib/screens/doctor/dashboard.dart
//
// Doctor dashboard (tabs: Appointments, Patients, Schedule, Profile)
//
// ✅ Appointments tab with filters & sorting
// ✅ Schedule tab: list weekly/date rules with ON/OFF, inline edit, delete,
//    sorting options, and created-at shown via tooltip (no inline text for weekly)
// ✅ Daily create form has its own maxPatients/mode (sent as `mode` to API)
// ✅ Patients and Profile tabs
// ✅ Appointment detail: progress + TEXT PRESCRIPTION composer with preview
//    (pad-style), per-appointment list (text/file) with open/zoom + delete,
//    edit allowed until 24h after completed. File delete fixed.
// ✅ Photo upload fixed for web/mobile with clear UX

// lib/screens/doctor/dashboard.dart
// Doctor dashboard (tabs: Appointments, Patients, Schedule, Profile)

import 'dart:typed_data';
import 'dart:async';
import 'dart:convert';
import 'dart:ui' as ui;
import 'dart:io';

import 'package:flutter/foundation.dart' show defaultTargetPlatform, TargetPlatform, kIsWeb;
import 'package:dio/dio.dart' as dio;

import 'package:file_picker/file_picker.dart';
import 'package:flutter/material.dart';
import 'package:intl/intl.dart';
import 'package:url_launcher/url_launcher.dart';
import 'package:flutter/services.dart';
import 'package:flutter/rendering.dart' as fr;
import 'package:barcode/barcode.dart' as bc; 
import 'package:http/http.dart' as http_pkg;
import 'package:pdf/widgets.dart' as pw;
import 'package:pdf/pdf.dart' as pdf;  
import 'package:path_provider/path_provider.dart';
import 'package:flutter/services.dart' show rootBundle;      
import '../../main.dart' show LoginPage; 
import '../../models.dart';
import '../../services/api.dart';
import 'package:smart_gateway_app/screens/video/video_screen.dart';

import '../../services/auth.dart';
import 'package:flutter/rendering.dart' show RenderRepaintBoundary;
import 'package:printing/printing.dart';

typedef DioException = dio.DioException;
typedef MultipartFile = dio.MultipartFile;
typedef FormData = dio.FormData;



// ====== helpers

String fmtSlot(DateTime s, DateTime e) =>
    '${DateFormat.MMMd().format(s)}  ${DateFormat.Hm().format(s)} - ${DateFormat.Hm().format(e)}';

String labelize(String s) => s.replaceAll('_', ' ');

const _chipPadding = EdgeInsets.symmetric(horizontal: 8, vertical: 4);

const List<String> kProgressOrder = [
  'not_yet',
  'in_progress',
  'hold',
  'completed',
];

// Simple data holder for a medicine row in the Text Rx editor


// Pad-style preview for text prescriptions
class _RxPadPreview extends StatelessWidget {
  const _RxPadPreview({
    super.key,
    required this.payload,
    this.patient,
    this.doctor,
  });

  final Map<String, dynamic> payload;
  final Map<String, dynamic>? patient;
  final Map<String, dynamic>? doctor;

  @override
  Widget build(BuildContext context) {
    final p = payload;
    final meds = (p['medicines'] as List? ?? const [])
        .whereType<Map>()
        .map((e) => e.cast<String, dynamic>())
        .toList();

    String _str(dynamic v) => (v ?? '').toString().trim();

    final diagnosis = _str(p['diagnosis']);
    final advice = _str(p['advice']);
    final followUp = _str(p['follow_up']);

    final patientName = _str(patient?['name'] ?? patient?['profile']?['name']);
    final patientAge = _str(patient?['age'] ?? patient?['profile']?['age']);
    final patientId = _str(patient?['id'] ?? patient?['patient_id']);

    final doctorName = _str(doctor?['name']);
    final doctorSpec = _str(doctor?['specialty']);
    final doctorReg = _str(doctor?['reg_no'] ?? doctor?['registration'] ?? doctor?['license']);

    final now = DateFormat.yMMMd().add_Hm().format(DateTime.now());

    return Container(
      width: 680,
      padding: const EdgeInsets.all(20),
      decoration: BoxDecoration(
        color: Theme.of(context).colorScheme.surface,
        border: Border.all(color: Theme.of(context).dividerColor),
        borderRadius: BorderRadius.circular(12),
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          // Header
          Row(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Icon(Icons.local_hospital, size: 32, color: Theme.of(context).colorScheme.primary),
              const SizedBox(width: 10),
              Expanded(
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Text(doctorName.isEmpty ? 'Doctor' : doctorName,
                        style: Theme.of(context).textTheme.titleLarge?.copyWith(fontWeight: FontWeight.w700)),
                    Row(
                      children: [
                        if (doctorSpec.isNotEmpty) Text(doctorSpec),
                        if (doctorSpec.isNotEmpty && doctorReg.isNotEmpty) const SizedBox(width: 10),
                        if (doctorReg.isNotEmpty) Text('Reg: $doctorReg', style: const TextStyle(color: Colors.black54)),
                      ],
                    ),
                  ],
                ),
              ),
              Text(now, style: const TextStyle(color: Colors.black54)),
            ],
          ),
          const SizedBox(height: 12),
          const Divider(),

          // Patient line
          Padding(
            padding: const EdgeInsets.symmetric(vertical: 8),
            child: Wrap(
              spacing: 14,
              runSpacing: 6,
              children: [
                _Pill(patientName.isEmpty ? 'Patient' : patientName, icon: Icons.person_outline),
                if (patientId.isNotEmpty) _Pill('ID: $patientId', icon: Icons.numbers),
                if (patientAge.isNotEmpty) _Pill('Age: $patientAge', icon: Icons.cake_outlined),
              ],
            ),
          ),

          // Diagnosis
          if (diagnosis.isNotEmpty) ...[
            const SizedBox(height: 6),
            Text('Diagnosis', style: Theme.of(context).textTheme.titleMedium),
            const SizedBox(height: 4),
            Text(diagnosis),
          ],

          // Medicines
          const SizedBox(height: 10),
          Text('Medicines', style: Theme.of(context).textTheme.titleMedium),
          const SizedBox(height: 6),
          if (meds.isEmpty)
            const Text('— None —', style: TextStyle(color: Colors.black54))
          else
            ...List.generate(meds.length, (i) {
              final m = meds[i];
              final name = _str(m['name']);
              final dose = _str(m['dose']);
              final form = _str(m['form']);
              final freq = _str(m['frequency']);
              final dur = _str(m['duration']);
              final notes = _str(m['notes']);

              final lineTop = [
                if (name.isNotEmpty) name,
                if (dose.isNotEmpty) '($dose)',
                if (form.isNotEmpty) '• $form',
              ].join(' ');
              final lineBottom = [
                if (freq.isNotEmpty) 'Frequency: $freq',
                if (dur.isNotEmpty) 'Duration: $dur',
                if (notes.isNotEmpty) 'Notes: $notes',
              ].join('   ');

              return Padding(
                padding: const EdgeInsets.symmetric(vertical: 6),
                child: Row(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Text('${i + 1}.  ', style: const TextStyle(fontWeight: FontWeight.w600)),
                    Expanded(
                      child: Column(
                        crossAxisAlignment: CrossAxisAlignment.start,
                        children: [
                          Text(lineTop, style: const TextStyle(fontWeight: FontWeight.w600)),
                          if (lineBottom.isNotEmpty)
                            Padding(
                              padding: const EdgeInsets.only(top: 2),
                              child: Text(lineBottom),
                            ),
                        ],
                      ),
                    ),
                  ],
                ),
              );
            }),

          // Advice
          if (advice.isNotEmpty) ...[
            const SizedBox(height: 10),
            Text('Advice / Instructions', style: Theme.of(context).textTheme.titleMedium),
            const SizedBox(height: 4),
            Text(advice),
          ],

          // Follow up
          if (followUp.isNotEmpty) ...[
            const SizedBox(height: 10),
            Row(
              children: [
                const Icon(Icons.event_available, size: 18),
                const SizedBox(width: 6),
                Text('Follow-up: $followUp'),
              ],
            ),
          ],
        ],
      ),
    );
  }
}

// Keep exactly one copy of this in the file
class _Pill extends StatelessWidget {
  const _Pill(this.text, {this.bg, this.icon, super.key});

  final String text;
  final Color? bg;
  final IconData? icon;

  @override
  Widget build(BuildContext context) {
    final color = bg ?? Theme.of(context).colorScheme.surfaceVariant;
    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 6),
      decoration: BoxDecoration(
        color: color,
        borderRadius: BorderRadius.circular(20),
      ),
      child: Row(
        mainAxisSize: MainAxisSize.min,
        children: [
          if (icon != null) ...[
            Icon(icon, size: 14),
            const SizedBox(width: 6),
          ],
          Text(text, style: Theme.of(context).textTheme.bodySmall),
        ],
      ),
    );
  }
}

// Robust file picker for web/mobile with clear errors
Future<dio.MultipartFile?> _pickMultipartFile({
  List<String>? allowedExtensions,
  FileType? type, // nullable so we can decide when to use custom
  String fieldName = 'file',
}) async {
  try {
    final useCustom = allowedExtensions != null && allowedExtensions.isNotEmpty;
    final res = await FilePicker.platform.pickFiles(
      type: useCustom ? FileType.custom : (type ?? FileType.any),
      allowedExtensions: allowedExtensions,
      withData: true, // important for web
    );
    if (res == null || res.files.isEmpty) return null;
    final f = res.files.single;
    if (f.bytes != null) {
      return MultipartFile.fromBytes(
        f.bytes as Uint8List,
        filename: f.name,
      );
    }
    if (f.path != null) {
      return MultipartFile.fromFile(
        f.path!,
        filename: f.name,
      );
    }
    return null;
  } catch (e) {
    throw Exception('File pick failed: $e');
  }
}

// Turn any relative-ish path into absolute
String _absUrlFromString(String? maybePathOrUrl) {
  if (maybePathOrUrl == null || maybePathOrUrl.isEmpty) return '';
  if (maybePathOrUrl.startsWith('http')) return maybePathOrUrl;
  final path = maybePathOrUrl.startsWith('/') ? maybePathOrUrl : '/$maybePathOrUrl';
  return '${Api.baseUrl}$path';
}

String? _absUrlFromMap(Map<String, dynamic> m) {
  final candidates = [
    m['file_url']?.toString(),
    m['url']?.toString(),
    m['file_path']?.toString(),
    m['path']?.toString(),
  ];
  for (final c in candidates) {
    if (c != null && c.toString().isNotEmpty) {
      final s = c.toString();
      if (s.startsWith('http')) return s;
      return '${Api.baseUrl}${s.startsWith('/') ? s : '/$s'}';
    }
  }
  return null;
}

bool _looksLikeImage(String url) {
  final lower = url.toLowerCase();
  return lower.endsWith('.png') || lower.endsWith('.jpg') || lower.endsWith('.jpeg') || lower.endsWith('.webp') || lower.endsWith('.gif');
}
//// === START ADD: prescription url helpers ===

// Detect text/file type (fallbacks to 'text')
String _rxType(Map<String, dynamic> p) {
  final t = (p['type'] ?? p['kind'] ?? '').toString();
  if (t.isNotEmpty) return t;
  // crude but useful: if there is a content field -> text
  if ((p['content'] ?? '').toString().isNotEmpty ||
      (p['data'] is Map && (p['data']['diagnosis'] != null || p['data']['medicines'] != null))) {
    return 'text';
  }
  return 'file';
}

// Extract *any* usable URL from varied API shapes.
String? _rxFileUrl(Map<String, dynamic> p) {
  // flat keys first
  final flatCandidates = [
    p['file_url'],
    p['pdf_url'],
    p['url'],
    p['file_path'],
    p['path'],
    p['file'], // some APIs return { file: "https://..." }
  ].whereType<String>().toList();

  for (final s in flatCandidates) {
    if (s.trim().isEmpty) continue;
    if (s.startsWith('http')) return s.trim();
    // relative → absolute
    return '${Api.baseUrl}${s.startsWith('/') ? s : '/$s'}';
  }

  // nested: data.file_url / data.url / data.pdf_url
  final data = (p['data'] is Map) ? (p['data'] as Map).cast<String, dynamic>() : null;
  if (data != null) {
    for (final k in ['file_url', 'pdf_url', 'url', 'path']) {
      final v = data[k]?.toString();
      if (v != null && v.trim().isNotEmpty) {
        if (v.startsWith('http')) return v.trim();
        return '${Api.baseUrl}${v.startsWith('/') ? v : '/$v'}';
      }
    }
  }
  return null;
}

//// === END ADD: prescription url helpers ===

// ====== main screen

class DoctorDashboard extends StatefulWidget {
  const DoctorDashboard({super.key, required this.me});
  final User me;

  @override
  State<DoctorDashboard> createState() => _DoctorDashboardState();
}

class _DoctorDashboardState extends State<DoctorDashboard>
    with SingleTickerProviderStateMixin {
  late final TabController _tabs = TabController(length: 4, vsync: this);

  Future<void> _logout() async {
    try {
      await AuthService.logout();
    } catch (_) {}
    if (!mounted) return;
    Navigator.of(context).pushAndRemoveUntil(
      MaterialPageRoute(builder: (_) => const LoginPage()),
      (r) => false,
    );
  }

  // === UPDATE NAV: patient-style bottom tabbar ===
  @override
  Widget build(BuildContext context) {
    const nav = [
      (Icons.event_available, 'Appointments'),
      (Icons.groups_2_outlined, 'Patients'),
      (Icons.schedule, 'Schedule'),
      (Icons.person_outline, 'Profile'),
    ];

    return Scaffold(
      appBar: AppBar(
        title: const Text('Doctor Dashboard'),
        actions: [
          IconButton(icon: const Icon(Icons.logout), onPressed: _logout),
        ],
      ),
      body: TabBarView(
        controller: _tabs,
        // Keep bottom nav and pages in perfect sync (no swipe mis-sync).
        physics: const NeverScrollableScrollPhysics(),
        children: const [
          _AppointmentsTab(),
          PatientsTab(),
          ScheduleTab(),
          ProfileTab(),
        ],
      ),
      bottomNavigationBar: NavigationBar(
        selectedIndex: _tabs.index,
        onDestinationSelected: (i) => setState(() => _tabs.index = i),
        labelBehavior: NavigationDestinationLabelBehavior.alwaysShow,
        destinations: nav
            .map(
              (e) => NavigationDestination(
                icon: Icon(e.$1),
                selectedIcon: Icon(e.$1),
                label: e.$2,
              ),
            )
            .toList(),
      ),
    );
  }
  // === END UPDATE NAV: patient-style bottom tabbar ===


}

// ====== models for UI

class _Appt {
  final int id, doctorId, patientId;
  final DateTime start, end;
  final String status, progress, visitMode, patientName;
  final String? videoRoom;

  _Appt.fromJson(Map<String, dynamic> j)
      : id = (j['id'] as num).toInt(),
        doctorId = (j['doctor_id'] as num).toInt(),
        patientId = (j['patient_id'] as num).toInt(),
        start = DateTime.parse(j['start_time'].toString()),
        end = DateTime.parse(j['end_time'].toString()),
        status = (j['status'] ?? '').toString(),
        progress = (() {
          final raw = j['progress'];
          if (raw is int) {
            final idx = raw.clamp(0, kProgressOrder.length - 1);
            return kProgressOrder[idx];
          }
          return (raw ?? 'not_yet').toString();
        })(),
        visitMode = (j['visit_mode'] ?? 'offline').toString(),
        patientName = (j['patient_name'] ?? '').toString(),
        videoRoom = j['video_room']?.toString();
}
// Add at the top with your other imports


// ─────────────────────────────────────────────────────────────────────────────
// Appointments tab — dropdown date presets (PC & mobile friendly)
// ─────────────────────────────────────────────────────────────────────────────

class _AppointmentsTab extends StatefulWidget {
  const _AppointmentsTab();
  @override
  State<_AppointmentsTab> createState() => _AppointmentsTabState();
}

enum _DatePreset { today, tomorrow, next7, after7, all }
enum _SortDir { asc, desc }
enum _ProgressView { pendingAll, notYet, inProgress, hold, completed, all }

class _AppointmentsTabState extends State<_AppointmentsTab> {
  // Data
  List<_Appt> _allApproved = [];
  bool _loading = true;

  // Patient cache
  final Map<int, Map<String, String>> _patientCache = {};

  // Search
  final TextEditingController _q = TextEditingController();

  // Filters
  _DatePreset _preset = _DatePreset.today;
  DateTime? _pickedDate;
  _ProgressView _progressView = _ProgressView.pendingAll;

  // Sort
  _SortDir _dir = _SortDir.desc;

  // Pagination
  static const int _pageSize = 20;
  int _page = 1;

  bool get _isFilterActive =>
      _q.text.trim().isNotEmpty ||
      _pickedDate != null ||
      _preset != _DatePreset.today ||
      _progressView != _ProgressView.pendingAll ||
      _dir != _SortDir.desc;

  void _clearFilters() {
    setState(() {
      _q.clear();
      _pickedDate = null;
      _preset = _DatePreset.today;
      _progressView = _ProgressView.pendingAll;
      _dir = _SortDir.desc;
      _page = 1;
    });
  }

  @override
  void initState() {
    super.initState();
    _load();
  }

  @override
  void dispose() {
    _q.dispose();
    super.dispose();
  }

  Future<void> _load() async {
    setState(() => _loading = true);
    try {
      final list = await _fetchAllApprovedAppointments();
      setState(() {
        _allApproved = list;
        _page = 1;
        _loading = false;
      });
    } catch (e) {
      if (!mounted) return;
      setState(() => _loading = false);
      ScaffoldMessenger.of(context)
          .showSnackBar(SnackBar(content: Text('Load failed: $e')));
    }
  }

  /// Fetch and keep only approved
  Future<List<_Appt>> _fetchAllApprovedAppointments() async {
    final out = <int, _Appt>{};

    Future<void> addFrom(dynamic res) async {
      if (res is List) {
        for (final e in res) {
          final a = _Appt.fromJson((e as Map).cast<String, dynamic>());
          if (a.status == 'approved') out[a.id] = a;
        }
      } else if (res is Map && res['data'] is List) {
        for (final e in (res['data'] as List)) {
          final a = _Appt.fromJson((e as Map).cast<String, dynamic>());
          if (a.status == 'approved') out[a.id] = a;
        }
      }
    }

    for (final q in [
      {'status': 'approved'},
      {'view': 'approved'},
      null,
      {'view': 'today'},
      {'view': 'upcoming'},
      {'view': 'pending'},
      {'view': 'completed'},
    ]) {
      try {
        final r = await Api.get('/doctor/appointments', query: q);
        await addFrom(r);
      } catch (_) {}
    }

    return out.values.toList();
  }

  // -------------------- Filtering & sorting --------------------

  bool _matchesSearch(_Appt a) {
    final s = _q.text.trim().toLowerCase();
    if (s.isEmpty) return true;

    // Any common ID format → capture digits
    final m = RegExp(r'(\d{1,})').firstMatch(s);
    if (m != null) {
      final id = int.tryParse(m.group(1)!);
      if (id != null) return a.id == id;
    }

    // Patient name from payload OR cached profile
    final payloadName = a.patientName.toLowerCase();
    final cachedName = (_patientCache[a.patientId]?['name'] ?? '').toLowerCase();
    return payloadName.contains(s) || cachedName.contains(s);
  }

  bool _matchesProgress(_Appt a) {
    switch (_progressView) {
      case _ProgressView.pendingAll:
        return a.progress == 'not_yet' ||
            a.progress == 'in_progress' ||
            a.progress == 'hold';
      case _ProgressView.notYet:
        return a.progress == 'not_yet';
      case _ProgressView.inProgress:
        return a.progress == 'in_progress';
      case _ProgressView.hold:
        return a.progress == 'hold';
      case _ProgressView.completed:
        return a.progress == 'completed';
      case _ProgressView.all:
        return true;
    }
  }

  bool _matchesDate(DateTime d) {
    DateTime day(DateTime x) => DateTime(x.year, x.month, x.day);
    final now = DateTime.now();
    final today = day(now);
    final dd = day(d);

    if (_pickedDate != null) return dd == day(_pickedDate!);

    switch (_preset) {
      case _DatePreset.today:
        return dd == today;
      case _DatePreset.tomorrow:
        return dd == day(now.add(const Duration(days: 1)));
      case _DatePreset.next7:
        final last = day(now.add(const Duration(days: 7)));
        return !dd.isBefore(today) && !dd.isAfter(last);
      case _DatePreset.after7:
        final after = day(now.add(const Duration(days: 7)));
        return dd.isAfter(after);
      case _DatePreset.all:
        return true;
    }
  }

  // Outer: Date (DESC/ASC). Within day: Time ASC, ID ASC.
  int _cmpAppt(_Appt a, _Appt b) {
    int dayKey(DateTime x) =>
        DateTime(x.year, x.month, x.day).millisecondsSinceEpoch;
    final ad = dayKey(a.start), bd = dayKey(b.start);
    if (ad != bd) {
      return _dir == _SortDir.desc ? bd.compareTo(ad) : ad.compareTo(bd);
    }
    final at = a.start.millisecondsSinceEpoch,
        bt = b.start.millisecondsSinceEpoch;
    if (at != bt) return at.compareTo(bt);
    return a.id.compareTo(b.id);
  }

  List<({ _Appt appt, int serial })> get _rows {
    Iterable<_Appt> it = _allApproved
        .where(_matchesSearch)
        .where((a) => _matchesProgress(a) && _matchesDate(a.start));
    final list = it.toList()..sort(_cmpAppt);

    final out = <({ _Appt appt, int serial })>[];
    int? currentDayKey;
    int serial = 0;
    int dayKey(DateTime x) =>
        DateTime(x.year, x.month, x.day).millisecondsSinceEpoch;

    for (final a in list) {
      final dk = dayKey(a.start);
      if (currentDayKey != dk) {
        currentDayKey = dk;
        serial = 1;
      } else {
        serial += 1;
      }
      out.add((appt: a, serial: serial));
    }
    return out;
  }

  List<({ _Appt appt, int serial })> get _pageItems {
    final rows = _rows;
    final total = rows.length;
    final totalPages = (total / _pageSize).ceil().clamp(1, 1 << 30);
    if (_page > totalPages) _page = totalPages;

    final start = (_page - 1) * _pageSize;
    final end = (start + _pageSize).clamp(0, total);
    return rows.sublist(start, end);
  }

  int get _totalPages {
    final total = _rows.length;
    return (total / _pageSize).ceil().clamp(1, 1 << 30);
  }

  void _goto(int p) => setState(() => _page = p.clamp(1, _totalPages));

  // -------------------- Patient photo helpers --------------------

  String? _absPhotoUrl(String? raw) {
    if (raw == null || raw.trim().isEmpty) return null;
    var s = raw.trim();
    if (s.startsWith('./')) s = s.substring(2);
    if (s.startsWith('http')) return s;
    if (!s.startsWith('/')) s = '/$s';
    return '${Api.baseUrl}$s';
  }

  String? _extractPhotoUrl(Map<String, dynamic> m) {
    final keys = [
      'photo_url',
      'photoPath',
      'photo_path',
      'avatar',
      'image',
      'picture',
      'photo'
    ];
    for (final k in keys) {
      final v = m[k]?.toString();
      final url = _absPhotoUrl(v);
      if (url != null) return url;
    }
    if (m['profile'] is Map) {
      final p = (m['profile'] as Map).cast<String, dynamic>();
      for (final k in keys) {
        final v = p[k]?.toString();
        final url = _absPhotoUrl(v);
        if (url != null) return url;
      }
    }
    return null;
  }

  Future<void> _ensurePatientInCache(int patientId) async {
    if (_patientCache.containsKey(patientId)) return;
    try {
      final res = await Api.get('/patients/$patientId');
      final m = (res as Map).cast<String, dynamic>();

      final url = _extractPhotoUrl(m);
      final name = (m['name'] ??
              m['full_name'] ??
              m['profile']?['name'] ??
              'Patient #$patientId')
          .toString();

      final bust = DateTime.now().millisecondsSinceEpoch;
      _patientCache[patientId] = {
        'name': name,
        'photo': url == null ? '' : '$url?v=$bust',
      };
      if (mounted) setState(() {});
    } catch (_) {}
  }

  // -------------------- UI --------------------

  @override
  Widget build(BuildContext context) {
    final w = MediaQuery.of(context).size.width;
    final isWide = w >= 860;

    return Column(
      children: [
        Padding(
          padding: const EdgeInsets.fromLTRB(12, 12, 12, 6),
          child: isWide ? _toolbarWide() : _toolbarCompact(),
        ),
        Expanded(
          child: RefreshIndicator(
            onRefresh: _load,
            child: _loading
                ? const Center(child: CircularProgressIndicator())
                : _buildList(),
          ),
        ),
        if (!_loading) _pager(),
      ],
    );
  }

  BoxDecoration get _panel => BoxDecoration(
        color: Theme.of(context).colorScheme.surface,
        borderRadius: BorderRadius.circular(14),
        boxShadow: [
          BoxShadow(
            color: Colors.black.withOpacity(.04),
            blurRadius: 10,
            offset: const Offset(0, 2),
          )
        ],
      );

  // -------- Toolbar (wide/desktop) --------
  Widget _toolbarWide() {
    return Container(
      decoration: _panel,
      padding: const EdgeInsets.all(10),
      child: Row(
        children: [
          Expanded(child: _searchField()),
          const SizedBox(width: 10),
          SizedBox(width: 230, child: _progressDropdown()),
          const SizedBox(width: 8),
          SizedBox(width: 180, child: _presetDropdown()),
          const SizedBox(width: 8),
          _datePickButton(),
          const SizedBox(width: 8),
          _sortToggle(),
          const SizedBox(width: 8),
          if (_isFilterActive)
            OutlinedButton.icon(
              onPressed: _clearFilters,
              icon: const Icon(Icons.filter_alt_off),
              label: const Text('Clear'),
            ),
        ],
      ),
    );
  }

  // -------- Toolbar (compact/mobile) --------
  Widget _toolbarCompact() {
    return Container(
      decoration: _panel,
      padding: const EdgeInsets.all(10),
      child: Column(
        children: [
          _searchField(),
          const SizedBox(height: 8),
          Row(
            children: [
              Expanded(
                child: OutlinedButton.icon(
                  onPressed: _openFilters,
                  icon: const Icon(Icons.tune),
                  label: const Text('Filters'),
                ),
              ),
              const SizedBox(width: 8),
              _sortIconOnly(),
            ],
          ),
          if (_isFilterActive) ...[
            const SizedBox(height: 8),
            Align(
              alignment: Alignment.centerRight,
              child: TextButton.icon(
                onPressed: _clearFilters,
                icon: const Icon(Icons.filter_alt_off),
                label: const Text('Clear filters'),
              ),
            ),
          ],
        ],
      ),
    );
  }

  // ----- Controls -----

  Widget _searchField() {
    return TextField(
      controller: _q,
      decoration: InputDecoration(
        hintText: 'Search by #ID or patient name',
        prefixIcon: const Icon(Icons.search),
        isDense: true,
        border: const OutlineInputBorder(),
        contentPadding:
            const EdgeInsets.symmetric(horizontal: 10, vertical: 10),
        suffixIcon: _q.text.isEmpty
            ? null
            : IconButton(
                tooltip: 'Clear',
                onPressed: () => setState(() {
                  _q.clear();
                  _page = 1;
                }),
                icon: const Icon(Icons.close),
              ),
      ),
      onChanged: (_) => setState(() => _page = 1),
      onSubmitted: (_) => setState(() => _page = 1),
    );
  }

  Widget _progressDropdown() {
    const items = [
      DropdownMenuItem(
          value: _ProgressView.pendingAll, child: Text('Pending (all)')),
      DropdownMenuItem(value: _ProgressView.notYet, child: Text('Not yet')),
      DropdownMenuItem(
          value: _ProgressView.inProgress, child: Text('In progress')),
      DropdownMenuItem(value: _ProgressView.hold, child: Text('Hold')),
      DropdownMenuItem(
          value: _ProgressView.completed, child: Text('Completed')),
      DropdownMenuItem(value: _ProgressView.all, child: Text('All')),
    ];
    return DropdownButtonFormField<_ProgressView>(
      value: _progressView,
      items: items,
      onChanged: (v) => setState(() {
        _progressView = v ?? _ProgressView.pendingAll;
        _page = 1;
      }),
      decoration: const InputDecoration(
        isDense: true,
        border: OutlineInputBorder(),
        contentPadding: EdgeInsets.symmetric(horizontal: 10, vertical: 10),
        prefixIcon: Icon(Icons.pending_actions_outlined),
        labelText: 'Progress',
      ),
    );
  }

  Widget _presetDropdown() {
    return DropdownButtonFormField<_DatePreset>(
      value: _pickedDate == null ? _preset : null,
      items: const [
        DropdownMenuItem(value: _DatePreset.today, child: Text('Today')),
        DropdownMenuItem(value: _DatePreset.tomorrow, child: Text('Tomorrow')),
        DropdownMenuItem(value: _DatePreset.next7, child: Text('Next 7 days')),
        DropdownMenuItem(value: _DatePreset.after7, child: Text('After 7 days')),
        DropdownMenuItem(value: _DatePreset.all, child: Text('All')),
      ],
      onChanged: (v) => setState(() {
        _pickedDate = null;
        _preset = v ?? _DatePreset.today;
        _page = 1;
      }),
      decoration: InputDecoration(
        isDense: true,
        border: const OutlineInputBorder(),
        contentPadding:
            const EdgeInsets.symmetric(horizontal: 10, vertical: 10),
        prefixIcon: const Icon(Icons.event_available),
        labelText:
            _pickedDate == null ? 'Date preset' : 'Preset (locked by date)',
      ),
    );
  }

  Widget _datePickButton() {
    return Tooltip(
      message: _pickedDate == null
          ? 'Pick a specific date'
          : 'Picked: ${DateFormat.yMMMd().format(_pickedDate!)}',
      child: OutlinedButton.icon(
        onPressed: () async {
          final now = DateTime.now();
          final d = await showDatePicker(
            context: context,
            firstDate: now.subtract(const Duration(days: 365)),
            lastDate: now.add(const Duration(days: 365 * 2)),
            initialDate: _pickedDate ?? now,
          );
          if (d != null) {
            setState(() {
              _pickedDate = DateTime(d.year, d.month, d.day);
              _page = 1;
            });
          }
        },
        icon: const Icon(Icons.calendar_today, size: 18),
        label: Text(
          _pickedDate == null ? 'Date' : DateFormat.MMMd().format(_pickedDate!),
        ),
      ),
    );
  }

  Widget _sortToggle() {
    return Tooltip(
      message:
          _dir == _SortDir.desc ? 'Date: newest → oldest' : 'Date: oldest → newest',
      child: OutlinedButton.icon(
        onPressed: () => setState(() {
          _dir = _dir == _SortDir.desc ? _SortDir.asc : _SortDir.desc;
          _page = 1;
        }),
        icon: Icon(_dir == _SortDir.desc ? Icons.south : Icons.north, size: 18),
        label: Text(_dir == _SortDir.desc ? 'DESC' : 'ASC'),
      ),
    );
  }

  Widget _sortIconOnly() {
    return IconButton.filledTonal(
      onPressed: () => setState(() {
        _dir = _dir == _SortDir.desc ? _SortDir.asc : _SortDir.desc;
        _page = 1;
      }),
      icon: Icon(_dir == _SortDir.desc ? Icons.south : Icons.north),
      tooltip: _dir == _SortDir.desc ? 'DESC' : 'ASC',
    );
  }

  Future<void> _openFilters() async {
    await showModalBottomSheet(
      context: context,
      useSafeArea: true,
      isScrollControlled: true,
      shape: const RoundedRectangleBorder(
        borderRadius: BorderRadius.vertical(top: Radius.circular(18)),
      ),
      builder: (ctx) {
        return Padding(
          padding: EdgeInsets.only(
            left: 16,
            right: 16,
            top: 16,
            bottom: MediaQuery.of(ctx).viewInsets.bottom + 16,
          ),
          child: Column(
            mainAxisSize: MainAxisSize.min,
            children: [
              Row(children: [
                const Text('Filters',
                    style:
                        TextStyle(fontSize: 16, fontWeight: FontWeight.w600)),
                const Spacer(),
                if (_isFilterActive)
                  TextButton.icon(
                    onPressed: () {
                      Navigator.pop(ctx);
                      _clearFilters();
                    },
                    icon: const Icon(Icons.filter_alt_off),
                    label: const Text('Clear'),
                  ),
                IconButton(
                  onPressed: () => Navigator.pop(ctx),
                  icon: const Icon(Icons.close),
                )
              ]),
              const SizedBox(height: 8),
              _progressDropdown(),
              const SizedBox(height: 10),
              _presetDropdown(),
              const SizedBox(height: 10),
              Align(alignment: Alignment.centerLeft, child: _datePickButton()),
              const SizedBox(height: 10),
            ],
          ),
        );
      },
    );
    setState(() => _page = 1);
  }

  // -------------------- List --------------------

  Widget _buildList() {
    final rows = _pageItems;
    if (rows.isEmpty) return const Center(child: Text('No appointments'));

    for (final r in rows) {
      _ensurePatientInCache(r.appt.patientId);
    }

    String dayKey(DateTime d) => DateFormat('yyyy-MM-dd').format(d);
    final groups = <String, List<({ _Appt appt, int serial })>>{};
    for (final r in rows) {
      groups.putIfAbsent(dayKey(r.appt.start), () => []).add(r);
    }
    final orderedKeys = groups.keys.toList()
      ..sort((a, b) => _dir == _SortDir.desc ? b.compareTo(a) : a.compareTo(b));

    return ListView.builder(
      padding: const EdgeInsets.fromLTRB(12, 8, 12, 8),
      itemCount:
          orderedKeys.fold<int>(0, (sum, k) => sum + 1 + groups[k]!.length),
      itemBuilder: (_, idx) {
        int cursor = 0;
        for (final k in orderedKeys) {
          if (idx == cursor) {
            final d = DateTime.parse(k);
            final label = DateFormat.yMMMd().format(d);
            return Padding(
              padding: const EdgeInsets.fromLTRB(2, 12, 2, 6),
              child: Row(
                children: [
                  Text(label, style: Theme.of(context).textTheme.titleMedium),
                  const SizedBox(width: 8),
                  Expanded(
                      child: Divider(color: Theme.of(context).dividerColor)),
                ],
              ),
            );
          }
          cursor += 1;
          final list = groups[k]!;
          if (idx < cursor + list.length) {
            final row = list[idx - cursor];
            return _apptTile(row.appt, row.serial);
          }
          cursor += list.length;
        }
        return const SizedBox.shrink();
      },
    );
  }

  Future<void> _copyId(int id) async {
    await Clipboard.setData(ClipboardData(text: id.toString()));
    if (!mounted) return;
    ScaffoldMessenger.of(context)
        .showSnackBar(SnackBar(content: Text('Copied #$id')));
  }

  Widget _apptTile(_Appt a, int serial) {
    final time =
        '${DateFormat.Hm().format(a.start)} - ${DateFormat.Hm().format(a.end)}';
    final isOnline = a.visitMode.toLowerCase() == 'online';

    final cached = _patientCache[a.patientId];
    final name = (cached?['name']?.isNotEmpty == true)
        ? cached!['name']!
        : (a.patientName.isEmpty ? 'Patient #${a.patientId}' : a.patientName);
    final photoUrl = (cached?['photo'] ?? '').toString();

    Color progressColor() {
      switch (a.progress) {
        case 'not_yet':
          return Colors.orange.shade300;
        case 'in_progress':
          return Colors.lightBlue.shade300;
        case 'hold':
          return Colors.amber.shade400;
        case 'completed':
          return Colors.green.shade400;
        default:
          return Theme.of(context).colorScheme.surfaceVariant;
      }
    }

    Widget avatar() => CircleAvatar(
          radius: 22,
          backgroundColor: Theme.of(context).colorScheme.surfaceVariant,
          foregroundImage:
              photoUrl.isNotEmpty ? NetworkImage(photoUrl) : null,
          child: photoUrl.isEmpty
              ? Text(_initials(name),
                  style: const TextStyle(fontWeight: FontWeight.w600))
              : null,
        );

    // Desktop hover-to-copy + Mobile long-press-to-copy
    final idWidget = _HoverCopyId(
      id: a.id,
      onCopy: () => _copyId(a.id),
      labelBuilder: (id) => Text(
        'ID #$id', // accepted styles: 'ID #123' / '#ID-123' / 'ID-123'
        style: const TextStyle(fontWeight: FontWeight.w600),
      ),
      hoverDelay: const Duration(seconds: 2), // 2s reveal
      reserveSpace: true, // avoid layout shift so it’s always noticeable
    );

    return LayoutBuilder(builder: (ctx, c) {
      final narrow = c.maxWidth < 520;
      return Container(
        margin: const EdgeInsets.symmetric(vertical: 6),
        decoration: BoxDecoration(
          borderRadius: BorderRadius.circular(16),
          gradient: LinearGradient(
            colors: [
              Theme.of(context).colorScheme.surface,
              Theme.of(context).colorScheme.surfaceVariant.withOpacity(.35),
            ],
            begin: Alignment.topLeft,
            end: Alignment.bottomRight,
          ),
          border: Border.all(color: Theme.of(context).dividerColor),
        ),
        child: InkWell(
          borderRadius: BorderRadius.circular(16),
          onLongPress: () => _copyId(a.id), // mobile long-press
          onTap: () => Navigator.of(context).push(
            MaterialPageRoute(
              builder: (_) => AppointmentDetail(apptId: a.id, onChanged: _load),
            ),
          ),
          child: Padding(
            padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 12),
            child: Row(
              crossAxisAlignment: CrossAxisAlignment.center,
              children: [
                // Serial
                Container(
                  width: 44,
                  height: 44,
                  alignment: Alignment.center,
                  decoration: BoxDecoration(
                    color: Theme.of(context).colorScheme.primaryContainer,
                    borderRadius: BorderRadius.circular(12),
                  ),
                  child: Text('$serial',
                      style: const TextStyle(fontWeight: FontWeight.w700)),
                ),
                const SizedBox(width: 12),

                // Avatar
                avatar(),
                const SizedBox(width: 12),

                // Name + meta
                Expanded(
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      Text(
                        name,
                        maxLines: 1,
                        overflow: TextOverflow.ellipsis,
                        style: Theme.of(context)
                            .textTheme
                            .titleMedium
                            ?.copyWith(fontWeight: FontWeight.w700),
                      ),
                      const SizedBox(height: 6),
                      Wrap(
                        spacing: 14,
                        runSpacing: 6,
                        crossAxisAlignment: WrapCrossAlignment.center,
                        children: [
                          const Icon(Icons.schedule, size: 16),
                          Text(time),
                          Icon(isOnline ? Icons.wifi : Icons.apartment, size: 16),
                          Text(isOnline ? 'ONLINE' : 'OFFLINE'),
                          if (!narrow) idWidget,
                        ],
                      ),
                      if (narrow) ...[
                        const SizedBox(height: 6),
                        Row(
                          children: [
                            const Icon(Icons.numbers, size: 16),
                            const SizedBox(width: 6),
                            idWidget,
                          ],
                        ),
                      ],
                    ],
                  ),
                ),

                // Progress chip (right)
                Container(
                  padding:
                      const EdgeInsets.symmetric(horizontal: 12, vertical: 8),
                  decoration: BoxDecoration(
                    color: progressColor().withOpacity(.22),
                    borderRadius: BorderRadius.circular(18),
                    border: Border.all(color: progressColor().withOpacity(.7)),
                  ),
                  child: Text(
                    a.progress == 'not_yet'
                        ? 'Pending'
                        : a.progress == 'in_progress'
                            ? 'In progress'
                            : a.progress == 'hold'
                                ? 'Hold'
                                : labelize(a.progress),
                    style: const TextStyle(
                        fontSize: 12, fontWeight: FontWeight.w600),
                  ),
                ),
              ],
            ),
          ),
        ),
      );
    });
  }

  // Pagination
  Widget _pager() {
    final totalPages = _totalPages;
    if (totalPages <= 1) return const SizedBox.shrink();

    List<int> window() {
      const span = 2;
      final set = <int>{1, totalPages};
      for (int i = _page - span; i <= _page + span; i++) {
        if (i >= 1 && i <= totalPages) set.add(i);
      }
      final arr = set.toList()..sort();
      return arr;
    }

    final pages = window();

    Widget pageBtn(int p) => OutlinedButton(
          onPressed: p == _page ? null : () => _goto(p),
          child: Text('$p'),
        );

    final children = <Widget>[
      IconButton(
        tooltip: 'First',
        onPressed: _page > 1 ? () => _goto(1) : null,
        icon: const Icon(Icons.first_page),
      ),
      IconButton(
        tooltip: 'Previous',
        onPressed: _page > 1 ? () => _goto(_page - 1) : null,
        icon: const Icon(Icons.chevron_left),
      ),
    ];

    for (int i = 0; i < pages.length; i++) {
      if (i > 0 && pages[i] != pages[i - 1] + 1) {
        children.add(const Padding(
          padding: EdgeInsets.symmetric(horizontal: 6),
          child: Text('…'),
        ));
      }
      children.add(pageBtn(pages[i]));
    }

    children.addAll([
      IconButton(
        tooltip: 'Next',
        onPressed: _page < totalPages ? () => _goto(_page + 1) : null,
        icon: const Icon(Icons.chevron_right),
      ),
      IconButton(
        tooltip: 'Last',
        onPressed: _page < totalPages ? () => _goto(totalPages) : null,
        icon: const Icon(Icons.last_page),
      ),
    ]);

    return Padding(
      padding: const EdgeInsets.fromLTRB(12, 4, 12, 10),
      child: Row(
        children: [
          Text('Page $_page of $totalPages'),
          const Spacer(),
          Wrap(
            spacing: 4,
            runSpacing: 6,
            crossAxisAlignment: WrapCrossAlignment.center,
            children: children,
          ),
        ],
      ),
    );
  }

  String _initials(String s) {
    final parts = s.trim().split(RegExp(r'\s+'));
    if (parts.isEmpty || parts.first.isEmpty) return '#';
    if (parts.length == 1) return parts.first.characters.first.toUpperCase();
    return (parts.first.characters.first + parts.last.characters.first)
        .toUpperCase();
  }
}

// ---------- Desktop hover-to-copy (appears after 2 seconds) ----------
class _HoverCopyId extends StatefulWidget {
  const _HoverCopyId({
    required this.id,
    required this.onCopy,
    this.labelBuilder,
    this.hoverDelay = const Duration(seconds: 2),
    this.reserveSpace = false,
  });

  final int id;
  final VoidCallback onCopy;
  final Widget Function(int id)? labelBuilder;
  final Duration hoverDelay;
  final bool reserveSpace; // keep space for the icon to avoid layout shift

  @override
  State<_HoverCopyId> createState() => _HoverCopyIdState();
}

class _HoverCopyIdState extends State<_HoverCopyId> {
  bool _showBtn = false;
  Timer? _timer;

  static const _iconSize = 18.0;
  static const _gap = 6.0;

  @override
  void dispose() {
    _timer?.cancel();
    super.dispose();
  }

  void _startTimer() {
    _timer?.cancel();
    _timer = Timer(widget.hoverDelay, () {
      if (mounted) setState(() => _showBtn = true);
    });
  }

  void _hide() {
    _timer?.cancel();
    if (mounted) setState(() => _showBtn = false);
  }

  @override
  Widget build(BuildContext context) {
    final label = widget.labelBuilder?.call(widget.id) ??
        Text('ID #${widget.id}', style: const TextStyle(fontWeight: FontWeight.w600));

    final copyBtn = IconButton(
      visualDensity: VisualDensity.compact,
      tooltip: 'Copy #${widget.id}',
      onPressed: widget.onCopy,
      icon: const Icon(Icons.copy, size: _iconSize),
    );

    return MouseRegion(
      onEnter: (_) => _startTimer(),
      onHover: (_) {},
      onExit: (_) => _hide(),
      child: FocusableActionDetector(
        onShowHoverHighlight: (h) {
          if (!h) _hide();
        },
        child: GestureDetector(
          onTap: () {}, // prevent InkWell focus stealing
          child: Row(
            mainAxisSize: MainAxisSize.min,
            children: [
              label,
              SizedBox(width: widget.reserveSpace ? _gap : (_showBtn ? _gap : 0)),
              AnimatedOpacity(
                duration: const Duration(milliseconds: 150),
                opacity: _showBtn ? 1 : 0,
                child: IgnorePointer(
                  ignoring: !_showBtn,
                  child: copyBtn,
                ),
              ),
              if (widget.reserveSpace && !_showBtn)
                SizedBox(width: _iconSize + 8), // reserve icon width
            ],
          ),
        ),
      ),
    );
  }
}
// ─────────────────────────────────────────────────────────────────────────────
// AppointmentDetail —  tab 
// ─────────────────────────────────────────────────────────────────────────────

class AppointmentDetail extends StatefulWidget {
  const AppointmentDetail({
    super.key,
    required this.apptId,
    required this.onChanged,
  });

  final int apptId;
  final VoidCallback onChanged;

  @override
  State<AppointmentDetail> createState() => _AppointmentDetailState();
}

class _AppointmentDetailState extends State<AppointmentDetail> {
  Map<String, dynamic>? appt;

  // progress
  String? progressVal;
  String? initialProgress;
  DateTime? completedAt;

  // file Rx
  MultipartFile? _rxFile;

  // profiles for pad header
  Map<String, dynamic>? patientProfile;
  Map<String, dynamic>? doctorProfile;

  // reports list for this appointment
  List<Map<String, dynamic>> apptReports = [];

  // computed flags
  bool get isStarted => (progressVal ?? 'not_yet') != 'not_yet';
  bool get isCompleted => (progressVal ?? '') == 'completed';

  //  allow edits within 7 days after Completed
  bool get _within7dAfterCompleted {
    if ((progressVal ?? '') != 'completed') return true;
    if (completedAt == null) return false;
    return DateTime.now().difference(completedAt!).inDays < 7;
  }

  // progress can be changed unless it has been >7 days since completion
  bool get canChangeProgress =>
      !((initialProgress ?? '') == 'completed' && !_within7dAfterCompleted);

  //  all prescription edit/upload/delete gated on Start + 7-day window
  bool get canEdit => isStarted && _within7dAfterCompleted;

  // delete-guards (so only the relevant delete button disables)
  bool _deletingText = false;
  bool _deletingFile = false;

  @override
  void initState() {
    super.initState();
    _loadAll();
  }

  // -------- data load --------

  Future<void> _loadAll() async {
    final r = await Api.get('/appointments/${widget.apptId}');
    final j = (r as Map).cast<String, dynamic>();

    String _progressOf(Map<String, dynamic> jj) {
      final raw = jj['progress'];
      if (raw is int) {
        const order = ['not_yet', 'in_progress', 'hold', 'completed', 'no_show'];
        return order[raw.clamp(0, order.length - 1)];
      }
      return (raw ?? 'not_yet').toString();
    }

    DateTime? _ts(dynamic x) {
      final s = (x ?? '').toString();
      if (s.isEmpty) return null;
      try {
        return DateTime.parse(s);
      } catch (_) {
        return null;
      }
    }

    setState(() {
      appt = j;
      progressVal = _progressOf(j);
      initialProgress = progressVal;
      completedAt = _ts(j['completed_at']) ??
          _ts(j['progress_changed_at']) ??
          _ts(j['updated_at']) ??
          _ts(j['created_at']);
    });

    // profiles (best effort)
    try {
      final pid = (j['patient_id'] as num).toInt();
      patientProfile =
          (await Api.get('/patients/$pid') as Map).cast<String, dynamic>();
    } catch (_) {}
    try {
      doctorProfile =
          (await Api.get('/doctor/me') as Map).cast<String, dynamic>();
    } catch (_) {}

    await _loadApptReports();

    if (mounted) setState(() {});
  }

  Future<void> _loadApptReports() async {
    try {
      final rr = await Api.get('/appointments/${widget.apptId}/reports');
      apptReports = (rr as List)
          .map((e) => (e as Map).cast<String, dynamic>())
          .toList()
        ..sort((a, b) => (b['created_at'] ?? '')
            .toString()
            .compareTo((a['created_at'] ?? '').toString()));
    } catch (_) {
      apptReports = [];
    }
  }

  // -------- progress controls --------

  Future<void> _startAppointment() async {
    if (appt == null) return;
    final s = DateTime.parse(appt!['start_time'].toString());
    final now = DateTime.now();
    final isSameDay =
        s.year == now.year && s.month == now.month && s.day == now.day;
    if (!isSameDay) {
      if (!mounted) return;
      ScaffoldMessenger.of(context).showSnackBar(
        const SnackBar(content: Text('You can start only on appointment date')),
      );
      return;
    }
    try {
      await Api.patch('/appointments/${widget.apptId}/progress',
          data: FormData.fromMap({'progress': 'in_progress'}));
      await _loadAll();
      widget.onChanged();
      if (!mounted) return;
      ScaffoldMessenger.of(context).showSnackBar(
        const SnackBar(content: Text('Appointment started')),
      );
    } catch (e) {
      if (!mounted) return;
      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(content: Text('Failed to start: $e')),
      );
    }
  }

  Future<void> _updateProgress() async {
    if (progressVal == null || progressVal!.isEmpty) {
      ScaffoldMessenger.of(context)
          .showSnackBar(const SnackBar(content: Text('Choose a progress value')));
      return;
    }
    if ((initialProgress ?? '') == 'completed' && !_within7dAfterCompleted) {
      ScaffoldMessenger.of(context).showSnackBar(const SnackBar(
          content: Text('Progress is locked (completed > 7 days).')));
      return;
    }
    try {
      await Api.patch('/appointments/${widget.apptId}/progress',
          data: FormData.fromMap({'progress': progressVal}));
      if (!mounted) return;
      ScaffoldMessenger.of(context)
          .showSnackBar(const SnackBar(content: Text('Progress updated')));
      await _loadAll();
      widget.onChanged();
    } on DioException catch (e) {
      if (!mounted) return;
      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(
            content:
                Text('HTTP ${e.response?.statusCode}: ${e.response?.data}')),
      );
    }
  }


// -------- text prescription (fetch/save) --------
// ─────────────────────────────────────────────────────────────────────────────
bool showComposer = false;
bool editing = false;

// Allowed forms (instance-final so it compiles inside a State class)
final List<String> _rxForms = const ['tab', 'cap', 'syrup', 'drop', 'inj', 'cream', 'gel'];

// main text fields
String diagnosis = '';
String advice = '';

// legacy absolute follow-up (kept for compatibility with old code/servers)
DateTime? followUp; // not used by the new UI; kept to avoid getter/setter errors

// NEW: relative follow-up fields
// mode: 'none' | 'after' | 'before'
String followUpMode = 'none';
String followUpDays = ''; // raw while typing

// vitals (raw while typing; normalize on save)
String bp = '';
String temp = '';  
String spo2 = '';  
String pulse = ''; 

// lab tests (raw)
String labTests = '';

// list of medicines (raw while typing; normalize/validate on save)
List<_ApptRxMedRow> meds = [_ApptRxMedRow()];

// --- STABLE ROW IDS to prevent new-row drop when selecting Form ---
int _medRowAutoId = 1;         
List<int> _medRowIds = [1];     

void _reseedMedRowIds() {
  // regenerate stable keys matching the current meds list
  _medRowIds = [];
  for (int i = 0; i < meds.length; i++) {
    _medRowAutoId += 1;
    _medRowIds.add(_medRowAutoId);
  }
  }

// timestamps
DateTime? rxCreatedAt; // first creation time
DateTime? rxUpdatedAt; // last edit time

/// ---------- HELPERS ----------
bool _isInt(String s) => RegExp(r'^\d+$').hasMatch(s.trim());
bool _isNum(String s) => RegExp(r'^\d+(?:\.\d+)?$').hasMatch(s.trim());
String _t(String? s) => (s ?? '').trim();

String _normalizeDays(String input) {
  final t = input.trim();
  if (t.isEmpty) return '';
  if (_isInt(t)) {
    final n = int.parse(t);
    return '$n ${n == 1 ? "day" : "days"}';
  }
  final m = RegExp(r'^(\d+)\s*(?:d|day|days)\b', caseSensitive: false).firstMatch(t);
  if (m != null) {
    final n = int.parse(m.group(1)!);
    return '$n ${n == 1 ? "day" : "days"}';
  }
  final m2 = RegExp(r'^(\d+)\s+(.+)$').firstMatch(t);
  if (m2 != null && RegExp(r'\bdays?\b', caseSensitive: false).hasMatch(m2.group(2)!)) {
    final n = int.parse(m2.group(1)!);
    return '$n ${n == 1 ? "day" : "days"}';
  }
  return t;
  }

String _hyphenizeTriples(String input) {
  final t = input.trim();
  if (t.isEmpty) return '';
  if (RegExp(r'^\d+(?:-\d+){1,3}$').hasMatch(t)) return t;
  final parts = t.split(RegExp(r'[\s,_-]+')).where((p) => p.isNotEmpty).toList();
  if (parts.length >= 2 && parts.length <= 4 && parts.every((p) => RegExp(r'^\d+$').hasMatch(p))) {
    return parts.join('-');
  }
  return t;
  }

String _normalizeFrequency(String input) {
  final raw = input.trim();
  if (raw.isEmpty) return '';
  if (RegExp(r'[a-zA-Z]', caseSensitive: false).hasMatch(raw)) {
    final m = RegExp(r'^\s*(\d+(?:[\s,_-]+\d+){1,3})\s*$').firstMatch(raw);
    if (m != null) return _hyphenizeTriples(m.group(1)!);
    return raw;
  }
  if (RegExp(r'^\d+(?:[\s,_-]+\d+){1,3}$').hasMatch(raw)) return _hyphenizeTriples(raw);
  if (_isNum(raw)) return '${raw.replaceAll(RegExp(r'\.0+$'), '')} times/day';
  return raw;
}

String _normalizeDose(String input) {
  final t = input.trim();
  if (t.isEmpty) return '';
  final m = RegExp(r'^\s*([\d.]+)\s*(mg|mcg|g|ml|iu)\s*$', caseSensitive: false).firstMatch(t);
  if (m != null) {
    final num = m.group(1)!.replaceAll(RegExp(r'\.0+$'), '');
    final unit = m.group(2)!.toLowerCase();
    return '$num $unit';
  }
  if (_isNum(t)) return '${t.replaceAll(RegExp(r'\.0+$'), '')} mg';
  return t;
}

String _normalizeSpO2(String input) {
  final t = input.trim();
  if (t.isEmpty) return '';
  if (_isNum(t)) return '${t.replaceAll(RegExp(r'\.0+$'), '')}%';
  final m = RegExp(r'^\s*([\d.]+)\s*%$').firstMatch(t);
  if (m != null) return '${m.group(1)!.replaceAll(RegExp(r'\.0+$'), '')}%';
  return t;
}

String _normalizePulse(String input) {
  final t = input.trim();
  if (t.isEmpty) return '';
  if (_isNum(t)) return '${t.replaceAll(RegExp(r'\.0+$'), '')} bpm';
  final m = RegExp(r'^\s*(\d+)\s*bpm$', caseSensitive: false).firstMatch(t);
  if (m != null) return '${m.group(1)} bpm';
  return t;
}

// Normalize temperature to °F. Accepts "98.6", "98.6F", "37C" (converts), etc.
String _normalizeTempF(String input) {
  final t = input.trim();
  if (t.isEmpty) return '';
  final mF = RegExp(r'^\s*([\d.]+)\s*(?:°\s*)?[Ff]\s*$').firstMatch(t);
  if (mF != null) {
    final n = mF.group(1)!.replaceAll(RegExp(r'\.0+$'), '');
    return '$n°F';
  }
  final mC = RegExp(r'^\s*([\d.]+)\s*(?:°\s*)?[Cc]\s*$').firstMatch(t);
  if (mC != null) {
    final c = double.tryParse(mC.group(1)!) ?? 0.0;
    final f = c * 9 / 5 + 32;
    final s = f.toStringAsFixed(1).replaceAll(RegExp(r'\.0+$'), '');
    return '$s°F';
  }
  if (_isNum(t)) return '${t.replaceAll(RegExp(r'\.0+$'), '')}°F';
  return t;
}

List<String> _splitLabTests(String s) => s
    .split(RegExp(r'[\n,;]+'))
    .map((e) => e.trim())
    .where((e) => e.isNotEmpty)
    .toList();

String? _followUpRelativeText() {
  final mode = followUpMode.trim().toLowerCase();
  final dStr = followUpDays.trim();
  if (mode == 'none' || dStr.isEmpty || !_isInt(dStr)) return null;
  final n = int.tryParse(dStr);
  if (n == null || n <= 0) return null;
  return '$mode $n ${n == 1 ? "day" : "days"}';
}

/// ---------- FETCH EXISTING TEXT RX ----------
Future<Map<String, dynamic>?> _fetchTextRx() async {
  Map<String, dynamic>? _tryParse(dynamic rawMap) {
    final m = (rawMap as Map?)?.cast<String, dynamic>() ?? {};
    if (_rxType(m) != 'text') return null;
    final content = (m['content'] ?? m['data'] ?? '').toString().trim();
    if (content.isEmpty) return null;
    try {
      final parsed = (jsonDecode(content) as Map).cast<String, dynamic>();

      // timestamps
      final created = _t(parsed['created_at']);
      final updated = _t(parsed['updated_at']);
      rxCreatedAt = created.isEmpty ? rxCreatedAt : DateTime.tryParse(created);
      rxUpdatedAt = updated.isEmpty ? rxUpdatedAt : DateTime.tryParse(updated);

      // vitals (keep raw)
      final vit = (parsed['vitals'] is Map)
          ? (parsed['vitals'] as Map).cast<String, dynamic>()
          : const <String, dynamic>{};
      bp    = _t(vit['bp'] ?? bp);
      temp  = _t(vit['temp'] ?? temp);
      spo2  = _t(vit['spo2'] ?? vit['SpO2'] ?? spo2);
      pulse = _t(vit['pulse'] ?? pulse);

      // lab tests
      if (parsed['lab_tests'] is List) {
        labTests = (parsed['lab_tests'] as List)
            .map((e) => e?.toString().trim() ?? '')
            .where((e) => e.isNotEmpty)
            .join('\n');
      } else if (parsed['lab_tests'] is String) {
        labTests = parsed['lab_tests'].toString();
      }

      // follow-up
      final fu = parsed['follow_up'];
      if (fu is String) {
        final s = fu.trim();
        final maybeDt = DateTime.tryParse(s);
        if (maybeDt != null) {
          followUp = maybeDt;
          followUpMode = 'none';
          followUpDays = '';
        } else {
          final mRel = RegExp(r'^(after|before)\s+(\d+)\s+days?$', caseSensitive: false).firstMatch(s);
          if (mRel != null) {
            followUpMode = mRel.group(1)!.toLowerCase();
            followUpDays = mRel.group(2)!;
            followUp = null;
          }
        }
      } else if (fu is Map) {
        final type = _t(fu['type']);
        final daysRaw = fu['days']?.toString() ?? '';
        if (type.isNotEmpty && _isInt(daysRaw)) {
          followUpMode = type.toLowerCase();
          followUpDays = daysRaw;
          followUp = null;
        }
      }

      // diagnosis/advice/meds
      diagnosis = _t(parsed['diagnosis'] ?? diagnosis);
      advice    = _t(parsed['advice'] ?? advice);

      meds = [];
      if (parsed['medicines'] is List) {
        for (final x in (parsed['medicines'] as List)) {
          final mm = (x as Map?)?.cast<String, dynamic>() ?? {};
          meds.add(_ApptRxMedRow(
            name: _t(mm['name']),
            dose: _t(mm['dose']),
            form: _t(mm['form']),
            frequency: _t(mm['frequency']),
            duration: _t(mm['duration']),
            notes: _t(mm['notes']),
          ));
        }
      }
      if (meds.isEmpty) meds = [_ApptRxMedRow()];

      // reseed stable keys 1:1 with the freshly loaded meds list
      _reseedMedRowIds();

      return parsed;
    } catch (_) {
      return {
        'diagnosis': content,
        'advice': '',
        'follow_up': null,
        'medicines': <Map<String, dynamic>>[],
      };
    }
  }

  try {
    final raw = await Api.get('/appointments/${widget.apptId}/prescription/text');
    final parsed = _tryParse(raw);
    if (parsed != null) return parsed;
  } catch (_) {}

  try {
    final raw = await Api.get('/appointments/${widget.apptId}/prescription');
    return _tryParse(raw);
  } catch (_) {
    return null;
  }
}

/// ---------- BUILD PAYLOAD (normalize + validate) ----------
Map<String, dynamic> _textPayload({DateTime? createdAt, DateTime? updatedAt}) {
  // VALIDATE: if a row has any content, require a valid form to avoid silent drop by backend.
  for (int i = 0; i < meds.length; i++) {
    final m = meds[i];
    final hasAny = [
      m.name, m.dose, m.frequency, m.duration, m.notes
    ].any((s) => _t(s).isNotEmpty);
    final validForm = _rxForms.contains(m.form);
    if (hasAny && !validForm) {
      throw StateError('Select a form for medicine #${i + 1}.');
    }
  }

  final medsPayload = meds
      .where((m) => m.name.trim().isNotEmpty)
      .map((m) => {
            'name'     : m.name.trim(),
            'dose'     : _normalizeDose(m.dose),
            // Keep exactly what the user chose (validation above ensures correctness)
            'form'     : m.form.trim(),
            'frequency': _normalizeFrequency(m.frequency),
            'duration' : _normalizeDays(m.duration),
            'notes'    : m.notes.trim(),
          })
      .toList();

  final vitals = <String, String>{
    if (_t(bp).isNotEmpty) 'bp': _t(bp),
    if (_t(temp).isNotEmpty) 'temp': _normalizeTempF(temp), // always °F
    if (_t(spo2).isNotEmpty) 'spo2': _normalizeSpO2(spo2),
    if (_t(pulse).isNotEmpty) 'pulse': _normalizePulse(pulse),
  };

  final labsList = _splitLabTests(labTests);
  final labsValue = labsList.isEmpty ? '' : labsList;

  final followUpText = _followUpRelativeText();

  final map = <String, dynamic>{
    'diagnosis' : diagnosis.trim(),
    'advice'    : advice.trim(),
    'follow_up' : followUpText,
    'medicines' : medsPayload,
    if (vitals.isNotEmpty) 'vitals': vitals,
    if (labsValue != '') 'lab_tests': labsValue,
  };

  if (createdAt != null) map['created_at'] = createdAt.toIso8601String();
  if (updatedAt != null) map['updated_at'] = updatedAt.toIso8601String();

  return map;
}

/// ---------- SAVE (CREATE/UPDATE) ----------
Future<void> _saveTextPrescription() async {
  if (!canEdit) {
    ScaffoldMessenger.of(context).showSnackBar(const SnackBar(
      content: Text('Editing locked: start appointment first or window expired.'),
    ));
    return;
  }

  // ensure createdAt if editing an existing Rx
  if (editing && rxCreatedAt == null) {
    try {
      final existing = await _fetchTextRx();
      final created = _t(existing?['created_at']);
      if (created.isNotEmpty) rxCreatedAt = DateTime.tryParse(created);
    } catch (_) {}
  }

  final now = DateTime.now();

  Map<String, dynamic> payload;
  try {
    payload = _textPayload(
      createdAt: rxCreatedAt ?? now,
      updatedAt: editing ? now : null,
    );
  } on StateError catch (e) {
    ScaffoldMessenger.of(context).showSnackBar(SnackBar(content: Text(e.message)));
    return;
  }

  final hasAnyMed = (payload['medicines'] as List).isNotEmpty;
  final hasText   = (payload['diagnosis'] as String).isNotEmpty ||
                    (payload['advice'] as String).isNotEmpty;

  if (!hasAnyMed && !hasText) {
    ScaffoldMessenger.of(context).showSnackBar(
      const SnackBar(content: Text('Add a medicine or fill diagnosis/advice.')),
    );
    return;
  }

  try {
    await Api.post(
      '/appointments/${widget.apptId}/prescription',
      data: FormData.fromMap({'content': jsonEncode(payload)}),
    );

    if (!mounted) return;
    ScaffoldMessenger.of(context).showSnackBar(const SnackBar(content: Text('Saved')));

    rxCreatedAt = DateTime.tryParse(payload['created_at'] as String);
    rxUpdatedAt = payload['updated_at'] == null
        ? null
        : DateTime.tryParse(payload['updated_at'] as String);

    editing = false;
    setState(() => showComposer = false);
  } on DioException catch (e) {
    if (!mounted) return;
    ScaffoldMessenger.of(context)
        .showSnackBar(SnackBar(content: Text('HTTP ${e.response?.statusCode}: ${e.response?.data}')));
  }
}

/// ---------- MEDICINE ROW (stable keys stop new-row drop on form select) ----------
Widget _medicineRow(int i) {
  final m = meds[i];
  final formItems = <String>['', ..._rxForms]; // include empty option for "none"

  return Card(
    margin: const EdgeInsets.only(bottom: 8),
    child: Padding(
      padding: const EdgeInsets.all(8),
      child: Column(
        children: [
          Row(children: [
            Expanded(
              child: TextField(
                decoration: const InputDecoration(labelText: 'Name'),
                controller: TextEditingController(text: m.name),
                onChanged: (v) => m.name = v,
              ),
            ),
            const SizedBox(width: 8),
            Expanded(
              child: TextField(
                decoration: const InputDecoration(labelText: 'Dose'),
                controller: TextEditingController(text: m.dose),
                onChanged: (v) => m.dose = v,
                keyboardType: const TextInputType.numberWithOptions(decimal: true),
                inputFormatters: <TextInputFormatter>[
                  FilteringTextInputFormatter.allow(RegExp(r'[0-9.\sA-Za-z]+')),
                ],
              ),
            ),
          ]),
          const SizedBox(height: 8),
          Row(children: [
            Expanded(
              child: DropdownButtonFormField<String>(
                isExpanded: true,
                value: formItems.contains(m.form) ? m.form : '',
                items: formItems
                    .map((f) => DropdownMenuItem<String>(
                          value: f,
                          child: Text(f.isEmpty ? '— Select form —' : f),
                        ))
                    .toList(),
                onChanged: (v) => setState(() {
                  m.form = v ?? '';
                }),
                decoration: const InputDecoration(labelText: 'Form'),
              ),
            ),
            const SizedBox(width: 8),
            Expanded(
              child: TextField(
                decoration: const InputDecoration(labelText: 'Frequency'),
                controller: TextEditingController(text: m.frequency),
                onChanged: (v) => m.frequency = v,
              ),
            ),
          ]),
          const SizedBox(height: 8),
          Row(children: [
            Expanded(
              child: TextField(
                decoration: const InputDecoration(labelText: 'Duration'),
                controller: TextEditingController(text: m.duration),
                onChanged: (v) => m.duration = v,
                keyboardType: const TextInputType.numberWithOptions(decimal: false),
                inputFormatters: <TextInputFormatter>[
                  FilteringTextInputFormatter.allow(RegExp(r'[0-9\sA-Za-z]+')),
                ],
              ),
            ),
            const SizedBox(width: 8),
            Expanded(
              child: TextField(
                decoration: const InputDecoration(labelText: 'Notes'),
                controller: TextEditingController(text: m.notes),
                onChanged: (v) => m.notes = v,
              ),
            ),
            IconButton(
              tooltip: 'Clear form',
              onPressed: () => setState(() => m.form = ''),
              icon: const Icon(Icons.backspace_outlined),
            ),
            IconButton(
              tooltip: 'Remove',
              onPressed: meds.length == 1
                  ? null
                  : () => setState(() {
                        meds.removeAt(i);
                        _medRowIds.removeAt(i);
                      }),
              icon: const Icon(Icons.remove_circle_outline),
            ),
          ]),
        ],
      ),
    ),
  );
}

/// ---------- FOLLOW-UP (RELATIVE) ----------
Widget _followUpRowRelative() {
  final chips = [3, 5, 7, 14, 30];

  return Column(
    crossAxisAlignment: CrossAxisAlignment.start,
    children: [
      Text('Follow-up', style: Theme.of(context).textTheme.titleSmall),
      const SizedBox(height: 8),
      Row(
        children: [
          Expanded(
            child: DropdownButtonFormField<String>(
              value: ['none','after','before'].contains(followUpMode) ? followUpMode : 'none',
              items: const [
                DropdownMenuItem(value: 'none', child: Text('No follow-up')),
                DropdownMenuItem(value: 'after', child: Text('After N days')),
                DropdownMenuItem(value: 'before', child: Text('Before N days')),
              ],
              onChanged: (v) => setState(() {
                followUpMode = v ?? 'none';
                if (followUpMode == 'none') followUpDays = '';
              }),
              decoration: const InputDecoration(labelText: 'Type'),
            ),
          ),
          const SizedBox(width: 8),
          Expanded(
            child: TextField(
              enabled: followUpMode != 'none',
              decoration: const InputDecoration(labelText: 'Days'),
              keyboardType: TextInputType.number,
              controller: TextEditingController(text: followUpDays),
              onChanged: (v) => followUpDays = v,
            ),
          ),
        ],
      ),
      const SizedBox(height: 8),
      Wrap(
        spacing: 6,
        runSpacing: 6,
        children: chips.map((d) {
          final isSel = followUpDays.trim() == d.toString();
          return ChoiceChip(
            label: Text('$d'),
            selected: isSel,
            onSelected: followUpMode == 'none'
                ? null
                : (sel) => setState(() => followUpDays = d.toString()),
          );
        }).toList(),
      ),
    ],
  );
}

/// ---------- COMPOSER UI ----------
Widget _composerCard() {
  String _ts(DateTime? d) =>
      d == null ? '' : DateFormat.yMMMd().add_Hm().format(d);

  return Card(
    margin: const EdgeInsets.only(top: 10, bottom: 12),
    child: Padding(
      padding: const EdgeInsets.all(12),
      child: LayoutBuilder(builder: (ctx, c) {
        final wide = c.maxWidth >= 720;

        return Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Row(
              children: [
                Text(
                  editing ? 'Edit text prescription' : 'New text prescription',
                  style: Theme.of(ctx).textTheme.titleSmall,
                ),
                const Spacer(),
                if (rxCreatedAt != null) _Pill('Created: ${_ts(rxCreatedAt)}'),
                if (rxUpdatedAt != null) ...[
                  const SizedBox(width: 6),
                  _Pill('Edited: ${_ts(rxUpdatedAt)}'),
                ],
              ],
            ),
            const SizedBox(height: 10),

            TextField(
              decoration: const InputDecoration(
                labelText: 'Diagnosis',
                border: OutlineInputBorder(),
              ),
              minLines: 1,
              maxLines: 3,
              controller: TextEditingController(text: diagnosis),
              onChanged: (v) => diagnosis = v,
            ),
            const SizedBox(height: 12),

            Text('Vitals', style: Theme.of(ctx).textTheme.titleSmall),
            const SizedBox(height: 6),
            Wrap(
              spacing: 10,
              runSpacing: 10,
              children: [
                SizedBox(
                  width: wide ? (c.maxWidth - 30) / 4 : c.maxWidth,
                  child: TextField(
                    decoration: const InputDecoration(
                      labelText: 'BP (e.g., 120/80 mmHg)',
                      border: OutlineInputBorder(),
                    ),
                    controller: TextEditingController(text: bp),
                    onChanged: (v) => bp = v,
                  ),
                ),
                SizedBox(
                  width: wide ? (c.maxWidth - 30) / 4 : c.maxWidth,
                  child: TextField(
                    decoration: const InputDecoration(
                      labelText: 'Temp',
                      hintText: '98.6, 98.6F, or 37C',
                      border: OutlineInputBorder(),
                    ),
                    controller: TextEditingController(text: temp),
                    onChanged: (v) => temp = v,
                  ),
                ),
                SizedBox(
                  width: wide ? (c.maxWidth - 30) / 4 : c.maxWidth,
                  child: TextField(
                    decoration: const InputDecoration(
                      labelText: 'SpO₂',
                      border: OutlineInputBorder(),
                    ),
                    controller: TextEditingController(text: spo2),
                    onChanged: (v) => spo2 = v,
                  ),
                ),
                SizedBox(
                  width: wide ? (c.maxWidth - 30) / 4 : c.maxWidth,
                  child: TextField(
                    decoration: const InputDecoration(
                      labelText: 'Pulse',
                      border: OutlineInputBorder(),
                    ),
                    controller: TextEditingController(text: pulse),
                    onChanged: (v) => pulse = v,
                  ),
                ),
              ],
            ),

            const SizedBox(height: 14),

            Row(
              children: [
                Text('Medicines', style: Theme.of(ctx).textTheme.titleSmall),
                const Spacer(),
              ],
            ),
            const SizedBox(height: 8),

            // IMPORTANT: wrap each row with a stable Key so selecting Form never drops the row
            ...List.generate(meds.length, (i) {
              return KeyedSubtree(
                key: ValueKey<int>(_medRowIds[i]),
                child: _medicineRow(i),
              );
            }),

            Align(
              alignment: Alignment.centerLeft,
              child: FilledButton.tonalIcon(
                onPressed: () => setState(() {
                  meds.add(_ApptRxMedRow());
                  _medRowAutoId += 1;
                  _medRowIds.add(_medRowAutoId);
                }),
                icon: const Icon(Icons.add),
                label: const Text('Add medicine'),
              ),
            ),

            const SizedBox(height: 14),

            TextField(
              decoration: const InputDecoration(
                labelText: 'Advice / Instructions',
                border: OutlineInputBorder(),
              ),
              minLines: 2,
              maxLines: 6,
              controller: TextEditingController(text: advice),
              onChanged: (v) => advice = v,
            ),

            const SizedBox(height: 12),

            TextField(
              decoration: const InputDecoration(
                labelText: 'Lab tests (comma or newline separated)',
                border: OutlineInputBorder(),
              ),
              minLines: 1,
              maxLines: 4,
              controller: TextEditingController(text: labTests),
              onChanged: (v) => labTests = v,
            ),

            const SizedBox(height: 12),

            _followUpRowRelative(),

            const SizedBox(height: 14),

            Row(
              children: [
                OutlinedButton.icon(
                  onPressed: () async {
                    try {
                      final payload = _textPayload(
                        createdAt: rxCreatedAt ?? DateTime.now(),
                        updatedAt: editing ? DateTime.now() : null,
                      );
                      showDialog(
                        context: context,
                        builder: (_) => Dialog(
                          clipBehavior: Clip.antiAlias,
                          child: Padding(
                            padding: const EdgeInsets.all(16),
                            child: SingleChildScrollView(
                              child: _RxPadPreview(
                                payload: payload,
                                patient: patientProfile,
                                doctor: doctorProfile,
                              ),
                            ),
                          ),
                        ),
                      );
                    } on StateError catch (e) {
                      ScaffoldMessenger.of(context)
                          .showSnackBar(SnackBar(content: Text(e.message)));
                    }
                  },
                  icon: const Icon(Icons.visibility),
                  label: const Text('Preview'),
                ),
                const Spacer(),
                FilledButton.icon(
                  onPressed: _saveTextPrescription,
                  icon: const Icon(Icons.save),
                  label: const Text('Save'),
                ),
              ],
            ),
          ],
        );
      }),
    ),
  );
}

// -------- file prescription (upload/fetch) --------
// ─────────────────────────────────────────────────────────────────────────────

Future<void> _attachRxFile() async {
    final f = await _pickMultipartFile(
      type: null,
      allowedExtensions: ['pdf', 'jpg', 'jpeg', 'png', 'webp'],
    );
    if (f != null) setState(() => _rxFile = f);
  }

  Future<void> _uploadFilePrescription() async {
    if (!canEdit) {
      ScaffoldMessenger.of(context).showSnackBar(const SnackBar(
          content: Text('Editing locked: start appointment first or window expired.')));
      return;
    }
    if (_rxFile == null) {
      ScaffoldMessenger.of(context)
          .showSnackBar(const SnackBar(content: Text('Attach a file first')));
      return;
    }
    try {
      await Api.post('/appointments/${widget.apptId}/prescription',
          data: FormData.fromMap({'file': _rxFile!}), multipart: true);
      if (!mounted) return;
      ScaffoldMessenger.of(context)
          .showSnackBar(const SnackBar(content: Text('Saved file prescription')));
      _rxFile = null;
      setState(() {});
    } on DioException catch (e) {
      if (!mounted) return;
      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(
            content:
                Text('HTTP ${e.response?.statusCode}: ${e.response?.data}'),),
      );
    }
  }

  // Robust: ask server for file-specific rx; fallback to legacy combined
  Future<String?> _fetchFileRxUrl() async {
    try {
      final raw =
          await Api.get('/appointments/${widget.apptId}/prescription/file');
            final m = (raw as Map?)?.cast<String, dynamic>() ?? {};
            if (_rxType(m) != 'file') return null;
            final url = _extractRxFileUrl(m);
            return url;

    } catch (_) {
      try {
        final raw =
            await Api.get('/appointments/${widget.apptId}/prescription');
              final m = (raw as Map).cast<String, dynamic>();
              if (_rxType(m) != 'file') return null;
              return _extractRxFileUrl(m);
      } catch (_) {
        return null;
      }
    }
  }

  // Extract robust file URL from a prescription map
  String? _extractRxFileUrl(Map<String, dynamic> m) {
    String? fileUrl = _absUrlFromMap(m);
    if (fileUrl == null) {
      final rawPath = (m['file_path'] ?? m['path'] ?? '').toString();
      if (rawPath.isNotEmpty) {
        fileUrl = _absUrlFromString(rawPath);
      }
    }
    // Extra candidates
    fileUrl ??= _rxFileUrl(m);
    return fileUrl;
  }

  // -------- local helpers --------

  String _fmtSlot(DateTime s, DateTime e) =>
      '${DateFormat.MMMd().format(s)}  ${DateFormat.Hm().format(s)} - ${DateFormat.Hm().format(e)}';

  String _labelize(String s) => s.replaceAll('_', ' ');

  String _textRxSummary(Map<String, dynamic> p) {
    final dx = (p['diagnosis'] ?? '').toString().trim();
    final medsLen = ((p['medicines'] as List?) ?? const []).length;
    final fu = (p['follow_up'] ?? '').toString().trim();
    final parts = <String>[];
    if (dx.isNotEmpty) parts.add('Dx: $dx');
    parts.add('$medsLen meds');
    parts.add(fu.isEmpty ? 'No follow-up' : 'FU: $fu');
    return parts.join(' • ');
  }

  // Open text prescription as an in-app PREVIEW (not PDF)
  Future<void> _openTextRxPreview() async {
    final payload = await _fetchTextRx();
    if (payload == null) {
      if (!mounted) return;
      ScaffoldMessenger.of(context)
          .showSnackBar(const SnackBar(content: Text('No text prescription found')));
      return;
    }
    showDialog(
      context: context,
      builder: (_) => Dialog(
        clipBehavior: Clip.antiAlias,
        child: Padding(
          padding: const EdgeInsets.all(16),
          child: SingleChildScrollView(
            child: _RxPadPreview( // ← your existing visual preview widget
              payload: payload,
              patient: patientProfile,
              doctor: doctorProfile,
            ),
          ),
        ),
      ),
    );
}

Future<void> _downloadServerPdf() async {
  try {
    // ---------------- Preconditions ----------------
    final j = appt;
    if (j == null) {
      if (!mounted) return;
      ScaffoldMessenger.of(context).showSnackBar(
        const SnackBar(content: Text('Appointment not loaded')),
      );
      return;
    }
    final payload = await _fetchTextRx();
    if (payload == null) {
      if (!mounted) return;
      ScaffoldMessenger.of(context).showSnackBar(
        const SnackBar(content: Text('No text prescription found')),
      );
      return;
    }

    // ---------------- Helpers ----------------
    String v(dynamic x) => (x ?? '').toString().trim();
    String first(Map<String, dynamic>? m, List<String> keys) {
      if (m == null) return '';
      for (final k in keys) {
        final s = v(m[k]);
        if (s.isNotEmpty) return s;
      }
      return '';
    }

    DateTime? parseDt(dynamic iso) {
      final s = v(iso);
      if (s.isEmpty) return null;
      return DateTime.tryParse(s);
    }

    String fmt(DateTime? d) =>
        d == null ? '' : DateFormat('dd-MMM-yyyy, hh:mm a').format(d);

    String formAbbrev(String f) {
      final x = f.trim().toLowerCase();
      switch (x) {
        case 'tab': return 'TAB.';
        case 'cap': return 'CAP.';
        case 'syrup': return 'SYR.';
        case 'drop': return 'DROP';
        case 'inj': return 'INJ.';
        case 'cream': return 'CRM.';
        case 'gel': return 'GEL';
        default: return x.isEmpty ? '' : x.toUpperCase();
      }
    }

    // ---------------- Data extraction ----------------
    // Patient
    final patientName = v(patientProfile?['name'] ?? j['patient_name'] ?? 'Patient');
    final patientId   = v(j['id'] ?? widget.apptId);
    final gender      = first(patientProfile, ['gender', 'sex']);
    final address     = first(patientProfile, ['address', 'addr', 'location']);
    final age         = first(patientProfile, ['age', 'patient_age', 'years']);
    final weight      = first(patientProfile, ['weight', 'patient_weight', 'wt']);
    final height      = first(patientProfile, ['height', 'patient_height', 'ht']);
    final bloodGroup  = first(patientProfile, ['blood_group', 'blood', 'blood_type']);

    // Doctor / clinic
    final doctorName  = v(doctorProfile?['name'] ?? 'Doctor');
    final degrees     = first(doctorProfile, ['degrees', 'qualification', 'qualifications']);
    final regNo       = first(doctorProfile, ['reg_no', 'registration', 'license']);
    final clinicName  = first(doctorProfile, ['clinic_name', 'hospital', 'organization']);
    final clinicAddr  = first(doctorProfile, ['address', 'clinic_address', 'location']);
    final phone       = first(doctorProfile, ['phone', 'mobile', 'contact', 'tel']);

    // Dates
    final createdAt = parseDt(j['created_at'] ?? j['start_time']);
    final editedAt  = parseDt(payload['updated_at'] ?? j['updated_at']);
    final createdAtStr = fmt(createdAt);
    final editedAtStr  = (editedAt != null && createdAt != null && editedAt.isAfter(createdAt))
        ? fmt(editedAt)
        : '—';

    // Rx content
    final diagnosis   = v(payload['diagnosis']);
    final adviceText  = v(payload['advice']);
    final followUp    = v(payload['follow_up']);

    // Vitals
    final vit = (payload['vitals'] is Map)
        ? (payload['vitals'] as Map).cast<String, dynamic>()
        : const <String, dynamic>{};
    final temp  = v(vit['temp']);
    final bp    = v(vit['bp']);
    final pulse = v(vit['pulse']);

    // Medicines
    final List<Map<String, dynamic>> meds = ((payload['medicines'] as List?) ?? [])
        .whereType<Map>()
        .map((e) => e.cast<String, dynamic>())
        .toList();

    // Lab tests
    final List<String> labTests = () {
      final src = payload['lab_tests'];
      final out = <String>[];
      if (src is String) {
        out.addAll(src.split(RegExp(r'[\n,;]+')).map((e) => e.trim()).where((e) => e.isNotEmpty));
      } else if (src is List) {
        for (final e in src) {
          if (e is String) {
            final s = e.trim();
            if (s.isNotEmpty) out.add(s);
          } else if (e is Map) {
            final m = e.cast<String, dynamic>();
            final line = [v(m['name']), v(m['result']).isEmpty ? '' : '— ${v(m['result'])}']
                .where((s) => s.isNotEmpty)
                .join(' ');
            if (line.isNotEmpty) out.add(line);
          }
        }
      }
      return out;
    }();

    // Verify URL for QR
    final verifyUrl =
        '${Api.baseUrl}/verify/prescription/${widget.apptId}?t=${DateTime.now().millisecondsSinceEpoch}';

    // ---------------- Fonts (from your zip files) ----------------
    final fontRegular = pw.Font.ttf(await rootBundle.load('assets/fonts/DejaVuSans.ttf'));
    final fontBold    = pw.Font.ttf(await rootBundle.load('assets/fonts/DejaVuSans-Bold.ttf'));
    final fontMono    = pw.Font.ttf(await rootBundle.load('assets/fonts/DejaVuSansMono.ttf'));
    final emojiFont   = pw.Font.ttf(await rootBundle.load('assets/fonts/NotoEmoji-Regular.ttf')); // fallback

    // ---------------- Theme ----------------
    final ink      = pdf.PdfColor.fromHex('#0b1220'); // premium deep text
    final muted    = pdf.PdfColor.fromHex('#6b7280'); // gray-500
    final line     = pdf.PdfColor.fromHex('#e5e7eb'); // gray-200
    final band1    = pdf.PdfColor.fromHex('#0ea5e9'); // sky-500
    final band2    = pdf.PdfColor.fromHex('#10b981'); // emerald-500
    final pillBg   = pdf.PdfColor.fromHex('#f1f5f9'); // slate-100

    pw.TextStyle txt(double size,
        {bool bold = false, pdf.PdfColor? color, bool mono = false, double? letterSpacing}) {
      return pw.TextStyle(
        font: mono ? fontMono : fontRegular,
        fontBold: fontBold,
        fontSize: size,
        color: color ?? ink,
        letterSpacing: letterSpacing,
        fontFallback: [emojiFont],
      );
    }

    pw.Widget ruleH({double thickness = 2, pdf.PdfColor? color, double top=10, double bottom=10}) => pw.Container(
      margin: pw.EdgeInsets.only(top: top, bottom: bottom),
      height: thickness,
      color: color ?? line,
    );

    // ---------------- Premium Header ----------------
    // Top band with gradient + doctor/clinic + Appointment barcode (Code128)
    pw.Widget headerBand() {
      return pw.Container(
        decoration: pw.BoxDecoration(
          gradient: pw.LinearGradient(
            begin: pw.Alignment.centerLeft,
            end: pw.Alignment.centerRight,
            colors: [band1, band2],
          ),
          borderRadius: pw.BorderRadius.circular(14),
        ),
        padding: const pw.EdgeInsets.fromLTRB(16, 14, 16, 12),
        child: pw.Row(
          crossAxisAlignment: pw.CrossAxisAlignment.start,
          children: [
            // Left: Doctor & clinic
            pw.Expanded(
              child: pw.Column(
                crossAxisAlignment: pw.CrossAxisAlignment.start,
                children: [
                  pw.Text(doctorName, style: txt(16, bold: true, color: pdf.PdfColors.white)),
                  if (degrees.isNotEmpty || regNo.isNotEmpty)
                    pw.Text(
                      [
                        if (degrees.isNotEmpty) degrees,
                        if (regNo.isNotEmpty) 'Reg. No: $regNo',
                      ].join(' | '),
                      style: txt(11, color: pdf.PdfColors.white),
                    ),
                  if (clinicName.isNotEmpty || clinicAddr.isNotEmpty)
                    pw.Padding(
                      padding: const pw.EdgeInsets.only(top: 4),
                      child: pw.Text(
                        [clinicName, clinicAddr].where((e) => v(e).isNotEmpty).join(' • '),
                        style: txt(10, color: pdf.PdfColors.white),
                      ),
                    ),
                  if (phone.isNotEmpty)
                    pw.Text('☎ $phone', style: txt(10, color: pdf.PdfColors.white)),
                ],
              ),
            ),
            pw.SizedBox(width: 12),
            // Right: Appointment barcode (top requirement)
            pw.Container(
              width: 140,
              padding: const pw.EdgeInsets.all(6),
              decoration: pw.BoxDecoration(
                color: pdf.PdfColors.white,
                borderRadius: pw.BorderRadius.circular(10),
              ),
              child: pw.Column(
                crossAxisAlignment: pw.CrossAxisAlignment.stretch,
                children: [
                  pw.Text('APPOINTMENT ID', style: txt(8, color: muted)),
                  pw.SizedBox(height: 2),
                  pw.BarcodeWidget(
                    barcode: pw.Barcode.code128(),
                    data: patientId,
                    height: 42,
                    drawText: true,
                    textStyle: txt(8, color: ink),
                  ),
                ],
              ),
            ),
          ],
        ),
      );
    }

    // ---------------- Patient & Dates block ----------------
pw.Widget patientMeta() {
  return pw.Column(
    crossAxisAlignment: pw.CrossAxisAlignment.start,
    children: [
      // ─── Patient Info Box ───────────────────────────────
      pw.Container(
        padding: const pw.EdgeInsets.fromLTRB(14, 10, 14, 10),
        decoration: pw.BoxDecoration(
          borderRadius: pw.BorderRadius.circular(12),
          border: pw.Border.all(color: line, width: 0.8),
          color: pdf.PdfColors.white,
        ),
        child: pw.Column(
          crossAxisAlignment: pw.CrossAxisAlignment.start,
          children: [
            // Patient Name
            pw.Text(patientName, style: txt(14, bold: true)),
            pw.SizedBox(height: 6),

            // Invisible Table for Details (2×4 grid)
            pw.Table(
              border: null, // no visible lines
              columnWidths: {
                0: const pw.FlexColumnWidth(1),
                1: const pw.FlexColumnWidth(1),
              },
              children: [
                pw.TableRow(
                  children: [
                    pw.Text('Age: ${age.isEmpty ? "—" : "$age years"}', style: txt(10, color: muted)),
                    pw.Text('Gender: ${gender.isEmpty ? "—" : gender}', style: txt(10, color: muted)),
                  ],
                ),
                pw.TableRow(
                  children: [
                    pw.Text('Weight: ${weight.isEmpty ? "—" : "$weight kg"}', style: txt(10, color: muted)),
                    pw.Text('Blood: ${bloodGroup.isEmpty ? "—" : bloodGroup}', style: txt(10, color: muted)),
                  ],
                ),
                pw.TableRow(
                  children: [
                    pw.Text('BP: ${bp.isEmpty ? "—" : bp}', style: txt(10, color: muted)),
                    pw.Text('Pulse: ${pulse.isEmpty ? "—" : "$pulse "}', style: txt(10, color: muted)),
                  ],
                ),
                pw.TableRow(
                  children: [
                    pw.Text('Temp: ${temp.isEmpty ? "—" : "$temp"}', style: txt(10, color: muted)),
                    pw.Text('SpO₂: ${spo2.isEmpty ? "—" : "$spo2"}', style: txt(10, color: muted)),
                  ],
                ),
              ],
            ),

            // Optional Address
            if (address.isNotEmpty) ...[
              pw.SizedBox(height: 6),
              pw.Text('Address: $address', style: txt(10, color: muted)),
            ],
          ],
        ),
      ),

      // ─── Created / Edited Dates (Below Box) ──────────────
      pw.SizedBox(height: 4),
      pw.Row(
        mainAxisAlignment: pw.MainAxisAlignment.end,
        children: [
          pw.Text('Created: ', style: txt(9, color: muted)),
          pw.Text(
            createdAtStr.isEmpty ? '—' : createdAtStr,
            style: txt(9, bold: true),
          ),
          pw.Text('   •   ', style: txt(9, color: muted)),
          pw.Text('Edited: ', style: txt(9, color: muted)),
          pw.Text(
            editedAtStr.isEmpty ? '—' : editedAtStr,
            style: txt(9, bold: true),
          ),
        ],
      ),
    ],
  );
}


    // ---------------- Rx Section Title (no overlap) ----------------
    pw.Widget rxHeader() {
      return pw.Row(
        children: [
          pw.Container(
            width: 28,
            height: 28,
            alignment: pw.Alignment.center,
            decoration: pw.BoxDecoration(
              
              borderRadius: pw.BorderRadius.circular(8),
            ),
            child: pw.Text('℞', style: txt(30, bold: true, color: pdf.PdfColors.black)),
          ),
          

        ],
      );
    }

    // ---------------- Medicines table (stable layout) ----------------
    pw.Widget medsTable() {
      // column widths tuned to avoid crowding & wrap elegantly
      const wName = pw.FlexColumnWidth(52);
      const wDos  = pw.FlexColumnWidth(28);
      const wDur  = pw.FlexColumnWidth(20);

      return pw.Table(
        columnWidths: const {0: wName, 1: wDos, 2: wDur},
        border: pw.TableBorder(
          top: pw.BorderSide(color: line, width: 1.2),
          bottom: pw.BorderSide(color: line, width: 1.2),
          horizontalInside: pw.BorderSide(color: line, width: 0.6),
        ),
        children: [
          pw.TableRow(
            decoration: pw.BoxDecoration(color: pdf.PdfColor.fromHex('#f8fafc')), // subtle header bg
            children: [
              pw.Padding(
                padding: const pw.EdgeInsets.fromLTRB(8, 9, 8, 7),
                child: pw.Text('Medicine', style: txt(11, color: muted, letterSpacing: .3)),
              ),
              pw.Padding(
                padding: const pw.EdgeInsets.fromLTRB(8, 9, 8, 7),
                child: pw.Text('Dosage / Notes', style: txt(11, color: muted, letterSpacing: .3)),
              ),
              pw.Padding(
                padding: const pw.EdgeInsets.fromLTRB(8, 9, 8, 7),
                child: pw.Text('Duration', style: txt(11, color: muted, letterSpacing: .3)),
              ),
            ],
          ),
          if (meds.isEmpty)
            pw.TableRow(
              children: [
                pw.Padding(
                  padding: const pw.EdgeInsets.all(8),
                  child: pw.Text('— no medicines —', style: txt(11, color: muted)),
                ),
                pw.SizedBox(), pw.SizedBox(),
              ],
            )
          else
            ...List.generate(meds.length, (i) {
              String m(String k) => v(meds[i][k]);
              final name = m('name');
              final dose = m('dose');
              final form = formAbbrev(m('form'));
              final freq = m('frequency');
              final notes = m('notes');
              final duration = m('duration');

              return pw.TableRow(
                children: [
                  // NAME
                  pw.Padding(
                    padding: const pw.EdgeInsets.fromLTRB(8, 8, 8, 8),
                    child: pw.Column(
                      crossAxisAlignment: pw.CrossAxisAlignment.start,
                      children: [
                        // Medicine name and form on top
                        pw.Row(
                          crossAxisAlignment: pw.CrossAxisAlignment.start,
                          children: [
                            pw.Text('${i + 1}) ', style: txt(11, mono: true, color: muted)),
                            pw.Expanded(
                              child: pw.Text(
                                [if (form.isNotEmpty) '$form ', name].join(),
                                style: txt(12),
                              ),
                            ),
                          ],
                        ),
                        // Dose below name
                        if (dose.isNotEmpty)
                          pw.Padding(
                            padding: const pw.EdgeInsets.only(top: 2, left: 16), // indent to align with name text
                            child: pw.Text(dose, style: txt(11, color: muted)),
                          ),
                      ],
                    ),
                  ),
                  // DOSAGE + NOTES
                  pw.Padding(
                    padding: const pw.EdgeInsets.fromLTRB(8, 8, 8, 8),
                    child: pw.Column(
                      crossAxisAlignment: pw.CrossAxisAlignment.start,
                      children: [
                        if (freq.isNotEmpty) pw.Text(freq, style: txt(12)),
                        
                        if (notes.isNotEmpty)
                          pw.Padding(
                            padding: const pw.EdgeInsets.only(top: 2),
                            child: pw.Text(notes, style: txt(11, color: muted)),
                          ),
                      ],
                    ),
                  ),
                  // DURATION
                  pw.Padding(
                    padding: const pw.EdgeInsets.fromLTRB(8, 8, 8, 8),
                    child: pw.Text(duration.isEmpty ? '—' : duration, style: txt(12)),
                  ),
                ],
              );
            }),
        ],
      );
    }

    // ---------------- Sections ----------------
    pw.Widget diagBox() => diagnosis.isEmpty
        ? pw.SizedBox()
        : pw.Column(
            crossAxisAlignment: pw.CrossAxisAlignment.start,
            children: [
              pw.Text('Diagnosis', style: txt(12, color: muted)),
              pw.SizedBox(height: 6),
              pw.Text(diagnosis, style: txt(12)),
            ],
          );

    pw.Widget adviceBox() => adviceText.isEmpty
        ? pw.SizedBox()
        : pw.Column(
            crossAxisAlignment: pw.CrossAxisAlignment.start,
            children: [
              pw.Text('Advice Given', style: txt(12, color: muted)),
              pw.SizedBox(height: 4),
              pw.Bullet(text: adviceText.replaceAll('\n', '\n• '), style: txt(12)),
            ],
          );

    pw.Widget labsBox() => labTests.isEmpty
        ? pw.SizedBox()
        : pw.Column(
            crossAxisAlignment: pw.CrossAxisAlignment.start,
            children: [
              pw.Text('Lab Tests', style: txt(12, color: muted)),
              pw.SizedBox(height: 4),
              pw.Column(
                crossAxisAlignment: pw.CrossAxisAlignment.start,
                children: labTests.map((t) => pw.Bullet(text: t, style: txt(12))).toList(),
              ),
            ],
          );

    pw.Widget followBox() => followUp.isEmpty
        ? pw.SizedBox()
        : pw.RichText(
            text: pw.TextSpan(
              children: [
                pw.TextSpan(text: 'Follow Up: ', style: txt(12, bold: true)),
                pw.TextSpan(text: followUp, style: txt(12, mono: true)),
              ],
            ),
          );

    // ---------------- Footer with QR (bottom requirement) ----------------
    pw.Widget footerVerify() {
      return pw.Container(
        margin: const pw.EdgeInsets.only(top: 14),
        padding: const pw.EdgeInsets.all(10),
        decoration: pw.BoxDecoration(
          border: pw.Border(top: pw.BorderSide(color: band2, width: 3)),
        ),
        child: pw.Row(
          mainAxisAlignment: pw.MainAxisAlignment.spaceBetween,
          crossAxisAlignment: pw.CrossAxisAlignment.center,
          children: [
            pw.Text('Scan the QR to verify online', style: txt(11, color: muted)),
            pw.Container(
              width: 28 * pdf.PdfPageFormat.mm,
              height: 28 * pdf.PdfPageFormat.mm,
              decoration: pw.BoxDecoration(
                border: pw.Border.all(color: line, width: 1),
                borderRadius: pw.BorderRadius.circular(4),
              ),
              child: pw.Center(
                child: pw.BarcodeWidget(
                  barcode: pw.Barcode.qrCode(),
                  data: verifyUrl,
                ),
              ),
            ),
          ],
        ),
      );
    }

    // ---------------- Build document ----------------
    final doc = pw.Document();

    doc.addPage(
      pw.Page(
        pageFormat: pdf.PdfPageFormat.a4,
        margin: pw.EdgeInsets.only(
          left: 18 * pdf.PdfPageFormat.mm,
          right: 16 * pdf.PdfPageFormat.mm,
          top: 18 * pdf.PdfPageFormat.mm,
          bottom: 18 * pdf.PdfPageFormat.mm,
        ),
        build: (context) {
          return pw.Stack(
            children: [
              // Subtle background watermark (no overlap with content)
              pw.Positioned.fill(
                child: pw.Center(
                  child: pw.Opacity(
                    opacity: 0.04,
                    child: pw.Text('℞', style: pw.TextStyle(
                      font: fontBold,
                      fontSize: 180,
                      color: ink,
                    )),
                  ),
                ),
              ),
              // Foreground content
              pw.Column(
                crossAxisAlignment: pw.CrossAxisAlignment.stretch,
                children: [
                  headerBand(),
                  pw.SizedBox(height: 10),
                  patientMeta(),
                  pw.SizedBox(height: 12),
                  rxHeader(),
                  pw.SizedBox(height: 6),
                  medsTable(),
                  pw.SizedBox(height: 10),
                  if (diagnosis.isNotEmpty) ...[
                    diagBox(),
                    pw.SizedBox(height: 8),
                  ],
                  if (adviceText.isNotEmpty) ...[
                    adviceBox(),
                    pw.SizedBox(height: 8),
                  ],
                  if (labTests.isNotEmpty) ...[
                    labsBox(),
                    pw.SizedBox(height: 8),
                  ],
                  if (followUp.isNotEmpty) followBox(),
                  footerVerify(),
                ],
              ),
            ],
          );
        },
      ),
    );

    final bytes = await doc.save();
    await Printing.sharePdf(bytes: bytes, filename: 'prescription-${widget.apptId}.pdf');
  } catch (e) {
    if (!mounted) return;
    ScaffoldMessenger.of(context).showSnackBar(
      SnackBar(content: Text('PDF build failed: $e')),
    );
  }
}


// Helper that builds the PDF bytes from a text-prescription payload
Future<Uint8List> _buildTextPrescriptionPdf(Map<String, dynamic> payload) async {
  final doc = pw.Document();

  String _val(dynamic x) => (x ?? '').toString().trim();

  final medsList = ((payload['medicines'] as List?) ?? [])
      .map((e) => (e as Map).cast<String, dynamic>())
      .toList();

  final patient = patientProfile;
  final doctor  = doctorProfile;
  final apptMap = appt;

  final patientName =
      _val(patient?['name'] ?? apptMap?['patient_name'] ?? 'Patient');
  final doctorName = _val(doctor?['name'] ?? 'Doctor');
  final apptId     = apptMap?['id']?.toString() ?? '${widget.apptId}';
  final apptDate   = apptMap?['start_time']?.toString();
  final apptDateFmt = (apptDate == null || apptDate.isEmpty)
      ? DateFormat.yMMMd().format(DateTime.now())
      : DateFormat.yMMMd().format(DateTime.tryParse(apptDate) ?? DateTime.now());
  final followUpStr = _val(payload['follow_up']);

  pw.Widget _kv(String k, String v) => pw.Row(
        crossAxisAlignment: pw.CrossAxisAlignment.start,
        children: [
          pw.Container(width: 90, child: pw.Text('$k:')),
          pw.Expanded(child: pw.Text(v)),
        ],
      );
      

doc.addPage(
    pw.MultiPage(
      pageTheme: pw.PageTheme(
        margin: const pw.EdgeInsets.symmetric(horizontal: 28, vertical: 32),
      ),
      build: (ctx) => [
        pw.Column(
          mainAxisAlignment: pw.MainAxisAlignment.spaceBetween,
          children: [
            // Top content
            pw.Column(
              crossAxisAlignment: pw.CrossAxisAlignment.start,
              children: [
                // Header
                pw.Row(
                  mainAxisAlignment: pw.MainAxisAlignment.spaceBetween,
                  children: [
                    pw.Column(
                      crossAxisAlignment: pw.CrossAxisAlignment.start,
                      children: [
                        pw.Text(doctorName,
                            style: pw.TextStyle(fontSize: 18, fontWeight: pw.FontWeight.bold)),
                        if (_val(doctor?['speciality']).isNotEmpty)
                          pw.Text(_val(doctor?['speciality'])),
                        if (_val(doctor?['reg_no']).isNotEmpty)
                          pw.Text('Reg: ${_val(doctor?['reg_no'])}'),
                      ],
                    ),
                    pw.Column(
                      crossAxisAlignment: pw.CrossAxisAlignment.end,
                      children: [
                        pw.Text('Prescription', style: pw.TextStyle(fontSize: 16)),
                        pw.Text('Appt #$apptId'),
                        pw.Text(apptDateFmt),
                      ],
                    ),
                  ],
                ),
                pw.SizedBox(height: 18),
                pw.Divider(),

                // Patient
                pw.SizedBox(height: 8),
                pw.Text('Patient: $patientName'),
                if (_val(patient?['age']).isNotEmpty || _val(patient?['gender']).isNotEmpty)
                  pw.Text(
                    'Age/Gender: ${_val(patient?['age'])}${_val(patient?['age']).isEmpty ? '' : ' • '}${_val(patient?['gender'])}',
                  ),
                pw.SizedBox(height: 12),

                // Diagnosis & Advice
                pw.Text('Diagnosis', style: pw.TextStyle(fontSize: 14, fontWeight: pw.FontWeight.bold)),
                pw.SizedBox(height: 4),
                pw.Text(_val(payload['diagnosis']).isEmpty ? '-' : _val(payload['diagnosis'])),
                pw.SizedBox(height: 10),
                pw.Text('Advice / Instructions',
                    style: pw.TextStyle(fontSize: 14, fontWeight: pw.FontWeight.bold)),
                pw.SizedBox(height: 4),
                pw.Text(_val(payload['advice']).isEmpty ? '-' : _val(payload['advice'])),
                pw.SizedBox(height: 12),

                // Medicines
                pw.Text('Medicines', style: pw.TextStyle(fontSize: 14, fontWeight: pw.FontWeight.bold)),
                pw.SizedBox(height: 6),
                if (medsList.isEmpty)
                  pw.Text('- none -')
                else
                  pw.Table(
                    border: pw.TableBorder.all(width: 0.3),
                    defaultVerticalAlignment: pw.TableCellVerticalAlignment.middle,
                    columnWidths: const {
                      0: pw.FlexColumnWidth(3),
                      1: pw.FlexColumnWidth(2),
                      2: pw.FlexColumnWidth(2),
                      3: pw.FlexColumnWidth(2),
                      4: pw.FlexColumnWidth(2),
                    },
                    children: [
                      pw.TableRow(children: [
                        pw.Padding(
                            padding: const pw.EdgeInsets.all(6),
                            child: pw.Text('Name', style: pw.TextStyle(fontWeight: pw.FontWeight.bold))),
                        pw.Padding(
                            padding: const pw.EdgeInsets.all(6),
                            child: pw.Text('Dose', style: pw.TextStyle(fontWeight: pw.FontWeight.bold))),
                        pw.Padding(
                            padding: const pw.EdgeInsets.all(6),
                            child: pw.Text('Form', style: pw.TextStyle(fontWeight: pw.FontWeight.bold))),
                        pw.Padding(
                            padding: const pw.EdgeInsets.all(6),
                            child: pw.Text('Frequency', style: pw.TextStyle(fontWeight: pw.FontWeight.bold))),
                        pw.Padding(
                            padding: const pw.EdgeInsets.all(6),
                            child: pw.Text('Duration', style: pw.TextStyle(fontWeight: pw.FontWeight.bold))),
                      ]),
                      ...medsList.map((m) {
                        String v(String k) => _val(m[k]);
                        return pw.TableRow(children: [
                          pw.Padding(padding: const pw.EdgeInsets.all(6), child: pw.Text(v('name'))),
                          pw.Padding(padding: const pw.EdgeInsets.all(6), child: pw.Text(v('dose'))),
                          pw.Padding(padding: const pw.EdgeInsets.all(6), child: pw.Text(v('form'))),
                          pw.Padding(padding: const pw.EdgeInsets.all(6), child: pw.Text(v('frequency'))),
                          pw.Padding(padding: const pw.EdgeInsets.all(6), child: pw.Text(v('duration'))),
                        ]);
                      }),
                    ],
                  ),
                pw.SizedBox(height: 12),

                // Follow-up
                pw.Row(children: [
                  pw.Text('Follow-up: ', style: pw.TextStyle(fontWeight: pw.FontWeight.bold)),
                  pw.Text(followUpStr.isEmpty ? '—' : followUpStr),
                ]),
                pw.SizedBox(height: 24),
                pw.Align(alignment: pw.Alignment.centerRight, child: pw.Text('— $doctorName')),
              ],
            ),

            // Bottom center QR code using existing bc.Barcode
            pw.Center(
              child: pw.BarcodeWidget(
                barcode: bc.Barcode.qrCode(),
                data: 'https://your-verification-link.com?id=$apptId',
                width: 100,
                height: 100,
              ),
            ),
          ],
        ),
      ],
    ),
  );



  return doc.save();
}


  Future<void> _openExternal(String url) async {
    final uri = Uri.parse(url);
    if (!await canLaunchUrl(uri)) {
      if (!mounted) return;
      ScaffoldMessenger.of(context)
          .showSnackBar(const SnackBar(content: Text('Cannot open link')));
      return;
    }
    await launchUrl(uri, mode: LaunchMode.externalApplication);
  }

  void _openInAppFile(String title, String url) {
    Navigator.of(context).push(
      MaterialPageRoute(
        builder: (_) => _InAppFileViewerPage(title: title, url: url),
      ),
    );
  }

  // -------- SAFE, TYPE-SCOPED DELETE --------
  //
  // This ONLY calls endpoints that target a single type:
  //   DELETE /appointments/{id}/prescription/text
  //   DELETE /appointments/{id}/prescription/file
  //
  // If those aren’t supported, we REFUSE to call the legacy
  // catch-all delete (which removed both). That’s intentional.
  Future<void> _deletePrescription({required String type}) async {
    if (!canEdit) {
      if (!mounted) return;
      ScaffoldMessenger.of(context).showSnackBar(
        const SnackBar(content: Text('Editing locked: start appointment first or window expired.')),
      );
      return;
    }

    final isText = type == 'text';
    final isFile = type == 'file';
    if (!isText && !isFile) return;

    final ok = await showDialog<bool>(
      context: context,
      barrierDismissible: false,
      builder: (_) => AlertDialog(
        title: const Text('Delete prescription'),
        content: Text('This will delete the $type prescription for this appointment. Continue?'),
        actions: [
          TextButton(onPressed: () => Navigator.pop(context, false), child: const Text('Cancel')),
          FilledButton(onPressed: () => Navigator.pop(context, true), child: const Text('Delete')),
        ],
      ),
    );
    if (ok != true) return;

    setState(() {
      if (isText) _deletingText = true;
      if (isFile) _deletingFile = true;
    });

    final path = '/appointments/${widget.apptId}/prescription/$type';

    try {
      await Api.delete(path);
    } on DioException catch (e1) {
      final code = e1.response?.statusCode ?? 0;
      if (code == 404 || code == 405) {
        try {
          await Api.delete('/appointments/${widget.apptId}/prescriptions/$type');
        } on DioException catch (e2) {
          if (!mounted) return;
          ScaffoldMessenger.of(context).showSnackBar(
            SnackBar(
              content: Text(
                'The API does not support deleting only the $type prescription '
                '(HTTP ${e2.response?.statusCode ?? 'ERR'}). To avoid deleting both, no action was taken.',
              ),
            ),
          );
          setState(() {
            if (isText) _deletingText = false;
            if (isFile) _deletingFile = false;
          });
          return;
        }
      } else {
        if (!mounted) return;
        ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(content: Text('HTTP ${e1.response?.statusCode}: ${e1.response?.data}')),
        );
        setState(() {
          if (isText) _deletingText = false;
          if (isFile) _deletingFile = false;
        });
        return;
      }
    }

    if (!mounted) return;
    ScaffoldMessenger.of(context).showSnackBar(
      SnackBar(content: Text('Deleted $type prescription')),
    );

    if (isText) {
      editing = false;
      showComposer = false;
    }

    setState(() {
      if (isText) _deletingText = false;
      if (isFile) _deletingFile = false;
    });

    await _loadAll();
  }

  // -------- UI --------

  @override
  Widget build(BuildContext context) {
    final j = appt;
    if (j == null) {
      return const Scaffold(body: Center(child: CircularProgressIndicator()));
    }

    final s = DateTime.parse(j['start_time'].toString());
    final e = DateTime.parse(j['end_time'].toString());
    final pid = (j['patient_id'] as num).toInt();
    final visitMode = (j['visit_mode'] ?? 'offline').toString();
    final videoRoom = (j['video_room'] ?? '').toString();

    final now = DateTime.now();
    final isToday = now.year == s.year && now.month == s.month && now.day == s.day;
    final canStart = !isStarted && isToday;

    final progressOptions = const [
      DropdownMenuItem(value: 'in_progress', child: Text('In progress')),
      DropdownMenuItem(value: 'hold', child: Text('Hold')),
      DropdownMenuItem(value: 'completed', child: Text('Completed')),
    ];

    return Scaffold(
      appBar: AppBar(title: const Text('Appointment')),
      body: ListView(
        padding: const EdgeInsets.all(12),
        children: [
          // header
          Row(
            children: [
              Expanded(
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Text((j['patient_name'] ?? 'Patient #$pid').toString(),
                        style: Theme.of(context).textTheme.titleMedium),
                    const SizedBox(height: 4),
                    Text(_fmtSlot(s, e)),
                    const SizedBox(height: 8),
                    Wrap(spacing: 10, runSpacing: 6, children: [
                      Chip(label: Text('status: ${j['status']}')),
                      Chip(label: Text('progress: ${_labelize(progressVal ?? 'not_yet')}')),
                      Chip(label: Text(visitMode.toUpperCase())),
                    ]),
                  ],
                ),
              ),
              // quick actions: patient profile / video / chat  (available even before start)
              Column(
                crossAxisAlignment: CrossAxisAlignment.end,
                children: [
                  OutlinedButton.icon(
                    icon: const Icon(Icons.person_search),
                    label: const Text('Patient profile'),
                    onPressed: () => Navigator.of(context).push(
                      MaterialPageRoute(
                        builder: (_) => PatientProfilePage(patientId: pid),
                      ),
                    ),
                  ),
                  const SizedBox(height: 6),
                  Wrap(
                    spacing: 6,
                    children: [
                      OutlinedButton.icon(
                        onPressed: () => Navigator.of(context).push(
                          MaterialPageRoute(
                            builder: (_) => VideoScreen(
                              appointmentId: widget.apptId,
                            ),
                          ),
                        ),
                        icon: const Icon(Icons.video_call_outlined),
                        label: const Text('Join video'),
                      ),
                      OutlinedButton.icon(
                        onPressed: () => Navigator.of(context).push(
                          MaterialPageRoute(
                            builder: (_) =>
                                _ChatStubPage(apptId: widget.apptId),
                          ),
                        ),
                        icon: const Icon(Icons.chat_bubble_outline),
                        label: const Text('Chat'),
                      ),
                    ],
                  ),
                ],
              ),
            ],
          ),

          const SizedBox(height: 12),

          // Start + progress
          Row(
            children: [
              ElevatedButton.icon(
                onPressed: canStart ? _startAppointment : null,
                icon: const Icon(Icons.play_arrow),
                label: const Text('Start'),
              ),
              const SizedBox(width: 12),
              Expanded(
                child: DropdownButtonFormField<String>(
                  value: isStarted ? progressVal : 'in_progress',
                  items: progressOptions,
                  onChanged: (!isStarted || !canChangeProgress)
                      ? null
                      : (v) => setState(() => progressVal = v),
                  decoration: const InputDecoration(labelText: 'Progress'),
                ),
              ),
              const SizedBox(width: 8),
              FilledButton.icon(
                onPressed:
                    (isStarted && canChangeProgress) ? _updateProgress : null,
                icon: const Icon(Icons.save),
                label: const Text('Save'),
              ),
            ],
          ),

          const Divider(height: 32),

          // -------- TEXT PRESCRIPTION (separate) --------
          Row(
            children: [
              Text('Text prescription',
                  style: Theme.of(context).textTheme.titleMedium),
              const Spacer(),
              FilledButton.tonal(
                onPressed: !canEdit
                    ? null
                    : () async {
                        final existing = await _fetchTextRx();
                        if (existing != null) {
                          diagnosis = (existing['diagnosis'] ?? '').toString();
                          advice = (existing['advice'] ?? '').toString();
                          final fu = (existing['follow_up'] ?? '').toString();
                          followUp = fu.isEmpty ? null : DateTime.tryParse(fu);

                          final medsList =
                              (existing['medicines'] as List?) ?? const [];
                          meds = medsList.map((e) {
                            final m = (e as Map).cast<String, dynamic>();
                            return _ApptRxMedRow(
                              name: m['name']?.toString() ?? '',
                              dose: m['dose']?.toString() ?? '',
                              form: m['form']?.toString() ?? '',
                              frequency: m['frequency']?.toString() ?? '',
                              duration: m['duration']?.toString() ?? '',
                              notes: m['notes']?.toString() ?? '',
                            );
                          }).toList();
                          if (meds.isEmpty) meds = [_ApptRxMedRow()];
                          editing = true;
                        } else {
                          diagnosis = '';
                          advice = '';
                          followUp = null;
                          meds = [_ApptRxMedRow()];
                          editing = false;
                        }
                        setState(() => showComposer = !showComposer);
                      },
                child: Text(showComposer ? 'Close' : 'Compose'),
              ),
            ],
          ),
          if (showComposer) _composerCard(),

          const SizedBox(height: 8),
          FutureBuilder<Map<String, dynamic>?>(
            future: _fetchTextRx(),
            builder: (_, snap) {
              if (snap.connectionState != ConnectionState.done) {
                return const SizedBox(
                    height: 40, child: Center(child: LinearProgressIndicator()));
              }
              final payload = snap.data;
              if (payload == null) {
                return const Text('No text prescription yet.',
                    style: TextStyle(color: Colors.black54));
              }
              return Card(
                child: ListTile(
                  leading: const Icon(Icons.description_outlined),
                  title: const Text('View text prescription'),
                  subtitle: Text(
                    _textRxSummary(payload),
                    maxLines: 2,
                    overflow: TextOverflow.ellipsis,
                    style: Theme.of(context).textTheme.bodySmall,
                  ),
                  // Tap → show in-app preview (NOT PDF)
                  onTap: _openTextRxPreview,
                  trailing: Wrap(
                    spacing: 6,
                    children: [
                      // Download → build & save/share as PDF
                      IconButton(
                        tooltip: 'Download as PDF',
                        onPressed: _downloadServerPdf,
                        icon: const Icon(Icons.picture_as_pdf_outlined),
                      ),
                      IconButton(
                        tooltip: 'Delete text prescription',
                        onPressed: (!canEdit || _deletingText)
                            ? null
                            : () => _deletePrescription(type: 'text'),
                        icon: const Icon(Icons.delete_forever),
                      ),
                    ],
                  ),
                ),
              );
            },
          ),

          const Divider(height: 32),

          // -------- FILE PRESCRIPTION (own card; open INSIDE app) --------
          Text('File prescription',
              style: Theme.of(context).textTheme.titleMedium),
          const SizedBox(height: 6),
          Row(
            children: [
              OutlinedButton.icon(
                onPressed: canEdit ? _attachRxFile : null,
                icon: const Icon(Icons.attach_file),
                label: Text(_rxFile == null ? 'Attach file' : '1 file attached'),
              ),
              const Spacer(),
              FilledButton(
                onPressed: canEdit ? _uploadFilePrescription : null,
                child: const Text('Upload'),
              ),
            ],
          ),
          if (!canEdit)
            Padding(
              padding: const EdgeInsets.only(top: 6),
              child: Text(
                isStarted
                    ? 'Locked because progress is Completed for more than 7 days.'
                    : 'Locked until the appointment is started.',
                style: Theme.of(context).textTheme.bodySmall,
              ),
            ),
          const SizedBox(height: 8),
          FutureBuilder<String?>(
            future: _fetchFileRxUrl(),
            builder: (_, snap) {
              if (snap.connectionState != ConnectionState.done) {
                return const SizedBox(
                  height: 40,
                  child: Center(child: LinearProgressIndicator()),
                );
              }
              final fileUrl = snap.data;
              if (fileUrl == null || fileUrl.isEmpty) {
                return const Text('No file prescription uploaded.',
                    style: TextStyle(color: Colors.black54));
              }
              final isPdf = fileUrl.toLowerCase().endsWith('.pdf');

              return Card(
                child: ListTile(
                  leading: Icon(
                    isPdf
                        ? Icons.picture_as_pdf_outlined
                        : Icons.insert_photo_outlined,
                  ),
                  title: const Text('Open file prescription'),
                  subtitle: Text(
                    fileUrl.split('/').last,
                    maxLines: 1,
                    overflow: TextOverflow.ellipsis,
                  ),
                  onTap: () => _openInAppFile('Prescription (file)', fileUrl),
                  trailing: Wrap(
                    spacing: 6,
                    children: [
                      IconButton(
                        tooltip: 'Open inside app',
                        onPressed: () => _openInAppFile('Prescription (file)', fileUrl),
                        icon: const Icon(Icons.open_in_full),
                      ),
                      // ✅ download original
                      IconButton(
                        tooltip: 'Download',
                        onPressed: () => _openExternal(fileUrl),
                        icon: const Icon(Icons.download),
                      ),
                      IconButton(
                        tooltip: 'Delete file prescription',
                        onPressed: (!canEdit || _deletingFile)
                            ? null
                            : () => _deletePrescription(type: 'file'),
                        icon: const Icon(Icons.delete_forever),
                      ),
                    ],
                  ),
                ),
              );
            },
          ),

          const Divider(height: 32),

          // -------- Reports (open INSIDE app + download) --------
          Text('Reports', style: Theme.of(context).textTheme.titleMedium),
          const SizedBox(height: 8),
          if (apptReports.isEmpty)
            const Text('No reports for this appointment.')
          else
            ...apptReports.map((r) {
              final url = _absUrlFromMap(r);
              final title = (r['title'] ?? r['name'] ?? 'Report').toString();
              final created = (r['created_at'] ?? '').toString();

              return Card(
                child: ListTile(
                  leading: const Icon(Icons.insert_drive_file_outlined),
                  title:
                      Text(title, maxLines: 1, overflow: TextOverflow.ellipsis),
                  subtitle: Text(created),
                  onTap: url == null ? null : () => _openInAppFile(title, url),
                  trailing: url == null
                      ? null
                      : Wrap(spacing: 6, children: [
                          IconButton(
                            tooltip: 'Open inside app',
                            icon: const Icon(Icons.open_in_full),
                            onPressed: () => _openInAppFile(title, url),
                          ),
                          // ✅ download original
                          IconButton(
                            tooltip: 'Download',
                            icon: const Icon(Icons.download),
                            onPressed: () => _openExternal(url),
                          ),
                        ]),
                ),
              );
            }),
        ],
      ),
    );
  }


  Widget _followUpRow() {
    final text =
        followUp == null ? 'No date' : DateFormat.yMMMd().format(followUp!);
    final quickDays = [3, 7, 10, 15, 30];

    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Text('Follow-up: $text'),
        const SizedBox(height: 6),
        SingleChildScrollView(
          scrollDirection: Axis.horizontal,
          child: Row(
            children: [
              ...quickDays.map((d) => Padding(
                    padding: const EdgeInsets.only(right: 6),
                    child: OutlinedButton(
                      onPressed: () => setState(
                          () => followUp = DateTime.now().add(Duration(days: d))),
                      child: Text('$d days'),
                    ),
                  )),
              const SizedBox(width: 6),
              FilledButton.tonal(
                onPressed: () async {
                  final now = DateTime.now();
                  final picked = await showDatePicker(
                    context: context,
                    firstDate: now.subtract(const Duration(days: 1)),
                    lastDate: now.add(const Duration(days: 730)),
                    initialDate: followUp ?? now,
                  );
                  if (picked != null) setState(() => followUp = picked);
                },
                child: const Text('Pick date'),
              ),
              IconButton(
                tooltip: 'Clear',
                onPressed: () => setState(() => followUp = null),
                icon: const Icon(Icons.close),
              ),
            ],
          ),
        ),
      ],
    );
  }
}

/// Minimal chat placeholder so the button opens a page
class _ChatStubPage extends StatelessWidget {
  const _ChatStubPage({required this.apptId});
  final int apptId;

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: AppBar(title: Text('Chat — #$apptId')),
      body: const Center(
        child: Text('Chat coming soon…'),
      ),
    );
  }
}

// ─────────────────────────────────────────────────────────────────────────────
// In-app file viewer (images & PDFs) used by reports and file prescriptions
// ─────────────────────────────────────────────────────────────────────────────

class _InAppFileViewerPage extends StatefulWidget {
  const _InAppFileViewerPage({required this.title, required this.url, super.key});
  final String title;
  final String url;

  @override
  State<_InAppFileViewerPage> createState() => _InAppFileViewerPageState();
}

class _InAppFileViewerPageState extends State<_InAppFileViewerPage> {
  // Uses URL heuristics to decide whether to render as image.
  late final bool _isImage = _looksLikeImage(widget.url);
  late final bool _isPdf = RegExp(r'(?:\.pdf($|\?)|/pdf($|\?))', caseSensitive: false)
    .hasMatch(widget.url);
  Future<Uint8List>? _pdfBytes;

  @override
  void initState() {
    super.initState();
    if (_isPdf) {
      _pdfBytes = _fetchBytes(widget.url);
    }
  }

  bool _looksLikeImage(String url) {
    final u = url.toLowerCase();
    return RegExp(r'\.(png|jpe?g|webp|gif|bmp|heic|heif)(?:$|\?)').hasMatch(u) ||
        u.contains('/image') ||
        u.contains('mime=image') ||
        u.contains('contentType=image');
  }

  Future<Uint8List> _fetchBytes(String url) async {
    // If your URLs require Authorization, replace this with your Api client.
    final res = await http_pkg.get(Uri.parse(url));
    if (res.statusCode != 200) {
      throw Exception('Failed to load file (${res.statusCode})');
    }
    return res.bodyBytes;
  }

  @override
  Widget build(BuildContext context) {
    final title = widget.title.isEmpty ? 'File' : widget.title;

    return Scaffold(
      appBar: AppBar(title: Text(title)),
      body: _isImage
          ? InteractiveViewer(
              minScale: 0.5,
              maxScale: 4,
              child: Center(
                child: Image.network(widget.url, fit: BoxFit.contain),
              ),
            )
          : _isPdf
              ? FutureBuilder<Uint8List>(
                  future: _pdfBytes,
                  builder: (_, snap) {
                    if (snap.connectionState != ConnectionState.done) {
                      return const Center(child: CircularProgressIndicator());
                    }
                    if (snap.hasError || snap.data == null) {
                      return Center(
                          child: Text('Unable to load PDF: ${snap.error ?? 'Unknown error'}'));
                    }
                    final bytes = snap.data!;
                    return PdfPreview(
                      canChangePageFormat: false,
                      allowPrinting: true,
                      allowSharing: true,
                      build: (format) async => bytes,
                    );
                  },
                )
              : _UnsupportedFile(url: widget.url),
    );
  }
}

class _UnsupportedFile extends StatelessWidget {
  const _UnsupportedFile({required this.url});
  final String url;

  @override
  Widget build(BuildContext context) {
    return Center(
      child: Padding(
        padding: const EdgeInsets.all(20),
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            const Icon(Icons.insert_drive_file_outlined, size: 48),
            const SizedBox(height: 12),
            const Text('Preview not supported'),
            const SizedBox(height: 6),
            Text(
              url,
              textAlign: TextAlign.center,
              style: Theme.of(context).textTheme.bodySmall,
            ),
            const SizedBox(height: 12),
            OutlinedButton.icon(
              onPressed: () async {
                final uri = Uri.parse(url);
                await launchUrl(uri, mode: LaunchMode.externalApplication);
              },
              icon: const Icon(Icons.open_in_new),
              label: const Text('Open externally'),
            ),
          ],
        ),
      ),
    );
  }
}

// ---- small private types with unique names to avoid conflicts ----

class _ApptRxMedRow {
  _ApptRxMedRow({
    this.name = '',
    this.dose = '',
    this.form = '',
    this.frequency = '',
    this.duration = '',
    this.notes = '',
  });
  String name, dose, form, frequency, duration, notes;
}

//// ===  Chat & Video stubs ===

// ====== patients tab

class PatientsTab extends StatefulWidget {
  const PatientsTab({super.key});
  @override
  State<PatientsTab> createState() => _PatientsTabState();
}

class _PatientsTabState extends State<PatientsTab> {
  final TextEditingController _q = TextEditingController();
  List<Map<String, dynamic>> items = [];
  bool loading = true;

  @override
  void initState() {
    super.initState();
    _load();
  }

  Future<void> _load() async {
    setState(() => loading = true);
    try {
      final r = await Api.get('/doctor/patients',
          query: _q.text.trim().isEmpty ? null : {'q': _q.text.trim()});
      final list =
          (r as List).map((e) => (e as Map).cast<String, dynamic>()).toList();
      if (!mounted) return;
      setState(() {
        items = list;
        loading = false;
      });
    } catch (e) {
      if (!mounted) return;
      setState(() => loading = false);
      ScaffoldMessenger.of(context)
          .showSnackBar(SnackBar(content: Text('Load failed: $e')));
    }
  }

  @override
  void dispose() {
    _q.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    return Column(children: [
      Padding(
        padding: const EdgeInsets.all(12),
        child: Row(
          children: [
            Expanded(
              child: TextField(
                controller: _q,
                decoration: const InputDecoration(
                  hintText: 'Search by name / phone / email',
                  prefixIcon: Icon(Icons.search),
                  border: OutlineInputBorder(),
                ),
                onSubmitted: (_) => _load(),
              ),
            ),
            const SizedBox(width: 8),
            FilledButton.tonal(onPressed: _load, child: const Text('Search')),
          ],
        ),
      ),
      Expanded(
        child: loading
            ? const Center(child: CircularProgressIndicator())
            : ListView.separated(
                itemCount: items.length,
                separatorBuilder: (_, __) => const Divider(height: 1),
                itemBuilder: (ctx, i) {
                  final p = items[i];
                  final pid = (p['patient_id'] ?? p['id']) as int?;
                  return ListTile(
                    title: Text(p['name'] ?? (pid != null ? 'Patient #$pid' : 'Patient')),
                    subtitle: Text('${p['email'] ?? ''}  ${p['phone'] ?? ''}'),
                    trailing: const Icon(Icons.chevron_right),
                    onTap: pid == null
                        ? null
                        : () => Navigator.of(context).push(
                              MaterialPageRoute(
                                builder: (_) => PatientProfilePage(patientId: pid),
                              ),
                            ),
                  );
                }),
      ),
    ]);
  }
}

class PatientProfilePage extends StatefulWidget {
  final int patientId;
  const PatientProfilePage({super.key, required this.patientId});
  @override
  State<PatientProfilePage> createState() => _PatientProfilePageState();
}

class _PatientProfilePageState extends State<PatientProfilePage> {
  Map<String, dynamic>? data;
  List<Map<String, dynamic>> reports = [];
  List<Map<String, dynamic>> prescriptions = [];

  @override
  void initState() {
    super.initState();
    _load();
  }

  String? _absUrl(Map<String, dynamic> m) => _absUrlFromMap(m);

  Future<void> _openImage(String url) async {
    showDialog(
      context: context,
      builder: (_) => Dialog(
        clipBehavior: Clip.antiAlias,
        child: InteractiveViewer(
          minScale: 0.5,
          maxScale: 4,
          child: Image.network(url, fit: BoxFit.contain),
        ),
      ),
    );
  }

  Future<void> _openFile(Map<String, dynamic> m) async {
    final url = _absUrl(m);
    if (url == null) return;
    if (_looksLikeImage(url)) {
      await _openImage(url);
      return;
    }
    final uri = Uri.parse(url);
    if (!await canLaunchUrl(uri)) return;
    await launchUrl(uri, mode: LaunchMode.externalApplication);
  }

  Future<void> _load() async {
    try {
      final p = await Api.get('/patients/${widget.patientId}');
      final r = await Api.get('/patients/${widget.patientId}/reports');
      setState(() {
        data = (p as Map).cast<String, dynamic>();
        reports = (r as List).map((e) => (e as Map).cast<String, dynamic>()).toList();
      });
    } catch (_) {}
    try {
      final pr = await Api.get('/patients/${widget.patientId}/prescriptions');
      prescriptions =
          (pr as List).map((e) => (e as Map).cast<String, dynamic>()).toList();
      setState(() {});
    } catch (_) {}
  }

  Widget _grid(List<Map<String, dynamic>> items) {
    if (items.isEmpty) return const Text('No files');
    return GridView.builder(
      shrinkWrap: true,
      physics: const NeverScrollableScrollPhysics(),
      itemCount: items.length,
      gridDelegate: const SliverGridDelegateWithFixedCrossAxisCount(
          crossAxisCount: 3, crossAxisSpacing: 6, mainAxisSpacing: 6),
      itemBuilder: (_, i) {
        final it = items[i];
        final url = _absUrl(it);
        return InkWell(
          onTap: url == null ? null : () => _openImage(url),
          child: Container(
            decoration: BoxDecoration(
              border: Border.all(color: Theme.of(context).dividerColor),
              borderRadius: BorderRadius.circular(8),
            ),
            child: url == null
                ? const Center(child: Icon(Icons.insert_drive_file))
                : ClipRRect(
                    borderRadius: BorderRadius.circular(8),
                    child: Image.network(url, fit: BoxFit.cover),
                  ),
          ),
        );
      },
    );
  }

  @override
  Widget build(BuildContext context) {
    final d = data;
    if (d == null) {
      return const Scaffold(body: Center(child: CircularProgressIndicator()));
    }
    final profile = (d['profile'] as Map?) ?? d;

    return Scaffold(
      appBar: AppBar(title: Text(d['name'] ?? 'Patient #${widget.patientId}')),
      body: ListView(
        padding: const EdgeInsets.all(12),
        children: [
          Wrap(spacing: 10, runSpacing: 6, children: [
            _Pill('Age: ${profile['age'] ?? '-'}'),
            _Pill('Weight: ${profile['weight'] ?? '-'}'),
            _Pill('Height: ${profile['height'] ?? '-'}'),
            _Pill('Blood: ${profile['blood_group'] ?? '-'}'),
            _Pill('Gender: ${profile['gender'] ?? '-'}'),
          ]),
          const SizedBox(height: 12),
          Text('Description: ${profile['description'] ?? ''}'),
          const SizedBox(height: 6),
          Text('Current medicine: ${profile['current_medicine'] ?? ''}'),
          const SizedBox(height: 6),
          Text('History: ${profile['medical_history'] ?? ''}'),
          const Divider(height: 32),
          Text('Reports', style: Theme.of(context).textTheme.titleMedium),
          const SizedBox(height: 8),
          _grid(reports),
          const Divider(height: 32),
          Text('Prescriptions', style: Theme.of(context).textTheme.titleMedium),
          const SizedBox(height: 8),
          if (prescriptions.isEmpty)
            const Text('No prescriptions yet.')
          else
            ...prescriptions.map((p) => ListTile(
                  leading: const Icon(Icons.medication_liquid),
                  title: Text(p['title']?.toString() ?? 'Prescription'),
                  subtitle: Text(p['created_at']?.toString() ?? ''),
                  onTap: () => _openFile(p),
                )),
        ],
      ),
    );
  }
}

// ====== schedule tab (list first, then create; inline edit for date rules)

class ScheduleTab extends StatefulWidget {
  const ScheduleTab({super.key});
  @override
  State<ScheduleTab> createState() => _ScheduleTabState();
}

enum WeeklySort { byDay, byCreatedNewest, byCreatedOldest }
enum DatedSort { byDateNewest, byDateOldest, byCreatedNewest, byCreatedOldest }

class _ScheduleTabState extends State<ScheduleTab> {
  // creation form state (hidden by default, shown when pressing "Create new")
  bool showCreate = false;

  // weekly creation
  final Set<int> selectedDays = {}; // Mon=0..Sun=6
  int startHour = 9;
  int endHour = 17;

  // date-specific creation (independent hours, max, mode)
  int dateStartHour = 9;
  int dateEndHour = 17;
  int dateMaxPatients = 4;
  String dateMode = 'offline';

  // 'defaults' copied from weekly tab on demand button
  int maxPatientsWeekly = 4;
  String visitModeWeekly = 'offline';

  // date creation
  DateTime currentMonth =
      DateTime(DateTime.now().year, DateTime.now().month, 1);
  final Set<DateTime> selectedDates = {};

  // existing rules
  List<Map<String, dynamic>> weeklyRules = [];
  List<Map<String, dynamic>> datedRules = [];
  bool loading = true;

  // sorting
  WeeklySort weeklySort = WeeklySort.byDay;
  DatedSort datedSort = DatedSort.byDateNewest;

  @override
  void initState() {
    super.initState();
    _loadSchedule();
  }

  String _fmtDate(DateTime d) => DateFormat('yyyy-MM-dd').format(d);

  Future<void> _loadSchedule() async {
    setState(() => loading = true);
    try {
      final r = await Api.get('/doctor/schedule');
      final j = (r as Map).cast<String, dynamic>();

      final weekly = (j['weekly'] ?? j['weekly_rules']) as List? ?? const [];
      final dated = (j['dated'] ?? j['date_rules']) as List? ?? const [];

      setState(() {
        weeklyRules =
            weekly.map((e) => (e as Map).cast<String, dynamic>()).toList();
        datedRules =
            dated.map((e) => (e as Map).cast<String, dynamic>()).toList();
        loading = false;
      });
    } on DioException {
      // Fallback to the legacy availability endpoint so the UI still works
      try {
        final alt = await Api.get('/doctor/availability');
        final list = (alt as List)
            .map((e) => (e as Map).cast<String, dynamic>())
            .toList();

        final weekly = list
            .map((a) => {
                  'id': a['id'],
                  'dow': a['day_of_week'],
                  'start': '${a['start_hour'].toString().padLeft(2, '0')}:00',
                  'end': '${a['end_hour'].toString().padLeft(2, '0')}:00',
                  'start_hour': a['start_hour'],
                  'end_hour': a['end_hour'],
                  'active': a['active'] == true,
                  'mode': a['mode'] ?? 'offline',
                  'max_patients': a['max_patients'] ?? 4,
                  'created_at': null,
                })
            .toList();

        setState(() {
          weeklyRules = weekly;
          datedRules = const [];
          loading = false;
        });
      } catch (e2) {
        setState(() => loading = false);
        if (!mounted) return;
        ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(content: Text('Load schedule failed (fallback): $e2')),
        );
      }
    }
  }

  // helpers
  int _dowSun0ToMon0(int dowSun0) => (dowSun0 + 6) % 7;

  List<Map<String, dynamic>> get _weeklySorted {
    final list = [...weeklyRules];
    switch (weeklySort) {
      case WeeklySort.byDay:
        list.sort((a, b) {
          final am = _dowSun0ToMon0((a['dow'] as num).toInt());
          final bm = _dowSun0ToMon0((b['dow'] as num).toInt());
          final c = am.compareTo(bm);
          if (c != 0) return c;
          final ash = (a['start_hour'] ?? 0) as int;
          final bsh = (b['start_hour'] ?? 0) as int;
          return ash.compareTo(bsh);
        });
        break;
      case WeeklySort.byCreatedNewest:
        list.sort((a, b) =>
            (b['created_at'] ?? '').toString().compareTo((a['created_at'] ?? '').toString()));
        break;
      case WeeklySort.byCreatedOldest:
        list.sort((a, b) =>
            (a['created_at'] ?? '').toString().compareTo((b['created_at'] ?? '').toString()));
        break;
    }
    return list;
  }

  List<Map<String, dynamic>> get _datedSorted {
    final list = [...datedRules];
    int cmpDate(a, b) => (b['date'] ?? '').toString().compareTo((a['date'] ?? '').toString());
    int cmpDateAsc(a, b) => (a['date'] ?? '').toString().compareTo((b['date'] ?? '').toString());
    int cmpCreated(a, b) => (b['created_at'] ?? '').toString().compareTo((a['created_at'] ?? '').toString());
    int cmpCreatedAsc(a, b) => (a['created_at'] ?? '').toString().compareTo((b['created_at'] ?? '').toString());
    switch (datedSort) {
      case DatedSort.byDateNewest:
        list.sort(cmpDate);
        break;
      case DatedSort.byDateOldest:
        list.sort(cmpDateAsc);
        break;
      case DatedSort.byCreatedNewest:
        list.sort(cmpCreated);
        break;
      case DatedSort.byCreatedOldest:
        list.sort(cmpCreatedAsc);
        break;
    }
    return list;
  }

  Future<void> _saveWeekly() async {
    try {
      final form = FormData.fromMap({
        'selected_days': selectedDays.toList(), // Mon=0..Sun=6
        'start_hour': startHour,
        'end_hour': endHour,
        'max_patients': maxPatientsWeekly,
        'visit_mode': visitModeWeekly, // endpoint expects visit_mode
      });
      await Api.post('/doctor/schedule/weekly_set', data: form, multipart: true);

      if (!mounted) return;
      ScaffoldMessenger.of(context)
          .showSnackBar(const SnackBar(content: Text('Weekly schedule saved')));
      setState(() => showCreate = false);
      _loadSchedule();
    } on DioException catch (e) {
      _showHttp(e);
    }
  }

  Future<void> _saveDates() async {
    try {
      final dates = selectedDates.map(_fmtDate).toList();
      if (dates.isEmpty) return;

      // Build multipart with repeated "dates" + send **mode** (API expects 'mode')
      final form = FormData();
      for (final d in dates) {
        form.fields.add(MapEntry('dates', d));
      }
      form.fields.addAll([
        MapEntry('start_hour', dateStartHour.toString()),
        MapEntry('end_hour', dateEndHour.toString()),
        MapEntry('max_patients', dateMaxPatients.toString()),
        MapEntry('mode', dateMode), // <-- important
        const MapEntry('active', 'true'),
      ]);

      await Api.post('/doctor/schedule/date_rule', data: form, multipart: true);

      if (!mounted) return;
      ScaffoldMessenger.of(context)
          .showSnackBar(const SnackBar(content: Text('Daily plan saved')));
      selectedDates.clear();
      setState(() => showCreate = false);
      _loadSchedule();
    } on DioException catch (e) {
      _showHttp(e);
    }
  }

  Future<void> _editDateRule(Map<String, dynamic> r) async {
    final startText = TextEditingController(
        text: (r['start'] ?? '${r['start_hour']}:00').toString());
    final endText = TextEditingController(
        text: (r['end'] ?? '${r['end_hour']}:00').toString());
    final maxText =
        TextEditingController(text: (r['max_patients'] ?? '4').toString());
    String mode = (r['visit_mode'] ?? r['mode'] ?? 'offline').toString();

    await showModalBottomSheet(
      context: context,
      isScrollControlled: true,
      builder: (_) => Padding(
        padding: EdgeInsets.only(
            bottom: MediaQuery.of(context).viewInsets.bottom,
            left: 16,
            right: 16,
            top: 16),
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            Text('Edit ${r['date']}',
                style: Theme.of(context).textTheme.titleMedium),
            const SizedBox(height: 12),
            TextField(
              controller: startText,
              decoration: const InputDecoration(labelText: 'Start (HH:mm)'),
            ),
            const SizedBox(height: 8),
            TextField(
              controller: endText,
              decoration: const InputDecoration(labelText: 'End (HH:mm)'),
            ),
            const SizedBox(height: 8),
            TextField(
              controller: maxText,
              decoration: const InputDecoration(labelText: 'Max patients'),
              keyboardType: TextInputType.number,
            ),
            const SizedBox(height: 8),
            DropdownButtonFormField<String>(
              value: mode,
              items: const [
                DropdownMenuItem(value: 'offline', child: Text('Offline')),
                DropdownMenuItem(value: 'online', child: Text('Online')),
              ],
              onChanged: (v) => mode = v ?? 'offline',
              decoration: const InputDecoration(labelText: 'Mode'),
            ),
            const SizedBox(height: 12),
            Align(
              alignment: Alignment.centerRight,
              child: FilledButton.icon(
                onPressed: () async {
                  try {
                    await Api.patch('/doctor/schedule/date_rule/${r['id']}',
                        data: {
                          'start': startText.text,
                          'end': endText.text,
                          'max_patients': int.tryParse(maxText.text) ??
                              r['max_patients'],
                          'mode': mode,
                        });
                    if (!mounted) return;
                    Navigator.pop(context);
                    _loadSchedule();
                    ScaffoldMessenger.of(context).showSnackBar(
                        const SnackBar(content: Text('Updated')));
                  } on DioException catch (e) {
                    if (!mounted) return;
                    ScaffoldMessenger.of(context).showSnackBar(SnackBar(
                        content: Text(
                            'HTTP ${e.response?.statusCode}: ${e.response?.data}')));
                  }
                },
                icon: const Icon(Icons.save),
                label: const Text('Save'),
              ),
            ),
            const SizedBox(height: 12),
          ],
        ),
      ),
    );
  }

  void _toggleRule(bool active, int id, String kind) async {
    try {
      await Api.post('/doctor/schedule/toggle',
          data: FormData.fromMap(
              {'item_id': id, 'kind': kind, 'active': active}),
          multipart: true);
    } on DioException catch (e) {
      _showHttp(e);
    } finally {
      _loadSchedule();
    }
  }

  Future<void> _deleteRule(int id, String kind) async {
    try {
      if (kind == 'weekly') {
        await Api.delete('/doctor/schedule/weekly/$id');
      } else {
        await Api.delete('/doctor/schedule/date_rule/$id');
      }
      if (!mounted) return;
      ScaffoldMessenger.of(context)
          .showSnackBar(const SnackBar(content: Text('Deleted')));
      _loadSchedule();
    } on DioException catch (e) {
      _showHttp(e);
    }
  }

  void _showHttp(DioException e) {
    final code = e.response?.statusCode;
    final body = e.response?.data;
    final msg = e.message ?? e.error?.toString() ?? 'Network error';
    ScaffoldMessenger.of(context).showSnackBar(
      SnackBar(
          content:
              Text(code == null ? 'Network error: $msg' : 'HTTP $code: $body')),
    );
  }

  @override
  Widget build(BuildContext context) {
    if (loading) {
      return const Center(child: CircularProgressIndicator());
    }

    final weeklyList = _weeklySorted;
    final datedList = _datedSorted;

    String _fmtCreated(Map<String, dynamic> r) {
      final s = (r['created_at'] ?? r['created'] ?? '').toString();
      if (s.isEmpty) return '';
      try {
        final d = DateTime.parse(s);
        return DateFormat.yMMMd().add_Hm().format(d);
      } catch (_) {
        return s;
      }
    }

    return ListView(
      padding: const EdgeInsets.all(12),
      children: [
        // header row + sorters
        Row(
          children: [
            Text('Schedules', style: Theme.of(context).textTheme.titleLarge),
            const Spacer(),
            DropdownButton<WeeklySort>(
              value: weeklySort,
              onChanged: (v) => setState(() => weeklySort = v ?? weeklySort),
              items: const [
                DropdownMenuItem(
                    value: WeeklySort.byDay, child: Text('Weekly: by day')),
                DropdownMenuItem(
                    value: WeeklySort.byCreatedNewest,
                    child: Text('Weekly: created ↓')),
                DropdownMenuItem(
                    value: WeeklySort.byCreatedOldest,
                    child: Text('Weekly: created ↑')),
              ],
            ),
            const SizedBox(width: 8),
            DropdownButton<DatedSort>(
              value: datedSort,
              onChanged: (v) => setState(() => datedSort = v ?? datedSort),
              items: const [
                DropdownMenuItem(
                    value: DatedSort.byDateNewest, child: Text('Dates: date ↓')),
                DropdownMenuItem(
                    value: DatedSort.byDateOldest, child: Text('Dates: date ↑')),
                DropdownMenuItem(
                    value: DatedSort.byCreatedNewest,
                    child: Text('Dates: created ↓')),
                DropdownMenuItem(
                    value: DatedSort.byCreatedOldest,
                    child: Text('Dates: created ↑')),
              ],
            ),
            const SizedBox(width: 12),
            FilledButton.icon(
              onPressed: () => setState(() => showCreate = !showCreate),
              icon: Icon(showCreate ? Icons.close : Icons.add),
              label: Text(showCreate ? 'Close' : 'Create new'),
            ),
          ],
        ),
        const SizedBox(height: 12),

        if (!showCreate) ...[
          Text('Weekly rules', style: Theme.of(context).textTheme.titleMedium),
          const SizedBox(height: 8),
          if (weeklyList.isEmpty)
            Text(
              'No weekly rules yet. Tap "Create new" to add.',
              style: Theme.of(context).textTheme.bodySmall,
            )
          else
            ...weeklyList.map((w) {
              final id = (w['id'] as num).toInt();
              final active = w['active'] == true;
              final start = w['start'] ?? '${w['start_hour']}:00';
              final end = w['end'] ?? '${w['end_hour']}:00';
              final mode =
                  (w['visit_mode'] ?? w['mode'] ?? 'offline').toString();
              final dowSun0 = (w['dow'] as num).toInt();
              final dowMon0 = _dowSun0ToMon0(dowSun0);
              const dows = ['Mon', 'Tue', 'Wed', 'Thu', 'Fri', 'Sat', 'Sun'];
              final created = _fmtCreated(w);

              final tile = SwitchListTile(
                title: Text(
                    '${dows[dowMon0]}  $start - $end  • $mode (max ${w['max_patients'] ?? '-'})'),
                value: active,
                onChanged: (v) => _toggleRule(v, id, 'weekly'),
                secondary: IconButton(
                  tooltip: 'Delete',
                  icon: const Icon(Icons.delete_forever),
                  onPressed: () => _deleteRule(id, 'weekly'),
                ),
              );

              // Only tooltip (no inline created-at text)
              return created.isEmpty
                  ? tile
                  : Tooltip(message: 'Created $created', child: tile);
            }),
          const SizedBox(height: 16),
          Text('Date rules', style: Theme.of(context).textTheme.titleMedium),
          const SizedBox(height: 8),
          if (datedList.isEmpty)
            Text(
              'No date rules yet. Tap "Create new" to add.',
              style: Theme.of(context).textTheme.bodySmall,
            )
          else
            ...datedList.map((w) {
              final id = (w['id'] as num).toInt();
              final active = w['active'] == true;
              final start = w['start'] ?? '${w['start_hour']}:00';
              final end = w['end'] ?? '${w['end_hour']}:00';
              final mode =
                  (w['visit_mode'] ?? w['mode'] ?? 'offline').toString();
              final created = _fmtCreated(w);

              final tile = Card(
                child: ListTile(
                  title: Text(
                      '${w['date']}  $start - $end  • $mode (max ${w['max_patients'] ?? '-'})'),
                  trailing: Wrap(spacing: 6, children: [
                    IconButton(
                      tooltip: 'Edit hours',
                      onPressed: () => _editDateRule(w),
                      icon: const Icon(Icons.edit_calendar),
                    ),
                    Switch(
                      value: active,
                      onChanged: (v) => _toggleRule(v, id, 'dated'),
                    ),
                    IconButton(
                      tooltip: 'Delete',
                      onPressed: () => _deleteRule(id, 'dated'),
                      icon: const Icon(Icons.delete_forever),
                    ),
                  ]),
                ),
              );

              return created.isEmpty
                  ? tile
                  : Tooltip(message: 'Created $created', child: tile);
            }),
        ],

        if (showCreate) ...[
          const Divider(height: 24),
          Text('Create Weekly / Date Schedules',
              style: Theme.of(context).textTheme.titleMedium),
          const SizedBox(height: 8),

          // weekly picker
          Text('Weekly (choose days & hours)',
              style: Theme.of(context).textTheme.titleSmall),
          const SizedBox(height: 6),
          Wrap(
            spacing: 8,
            children: List.generate(7, (i) {
              const labels = ['Mon', 'Tue', 'Wed', 'Thu', 'Fri', 'Sat', 'Sun'];
              final on = selectedDays.contains(i);
              return FilterChip(
                label: Text(labels[i]),
                selected: on,
                onSelected: (v) => setState(
                    () => v ? selectedDays.add(i) : selectedDays.remove(i)),
              );
            }),
          ),
          const SizedBox(height: 8),
          Row(children: [
            Expanded(
              child: DropdownButtonFormField<int>(
                value: startHour,
                items: List.generate(
                    24,
                    (i) => DropdownMenuItem(
                        value: i,
                        child: Text('${i.toString().padLeft(2, '0')}:00'))),
                onChanged: (v) => setState(() => startHour = v ?? 9),
                decoration: const InputDecoration(labelText: 'Start hour'),
              ),
            ),
            const SizedBox(width: 10),
            Expanded(
              child: DropdownButtonFormField<int>(
                value: endHour,
                items: List.generate(
                    24,
                    (i) => DropdownMenuItem(
                        value: i,
                        child: Text('${i.toString().padLeft(2, '0')}:00'))),
                onChanged: (v) => setState(() => endHour = v ?? 17),
                decoration: const InputDecoration(labelText: 'End hour'),
              ),
            ),
          ]),
          const SizedBox(height: 8),
          Row(children: [
            Expanded(
              child: TextFormField(
                initialValue: maxPatientsWeekly.toString(),
                decoration: const InputDecoration(labelText: 'Max patients'),
                onChanged: (v) => maxPatientsWeekly = int.tryParse(v) ?? 4,
              ),
            ),
            const SizedBox(width: 10),
            Expanded(
              child: DropdownButtonFormField<String>(
                value: visitModeWeekly,
                items: const [
                  DropdownMenuItem(value: 'offline', child: Text('Offline')),
                  DropdownMenuItem(value: 'online', child: Text('Online')),
                ],
                onChanged: (v) => setState(() => visitModeWeekly = v ?? 'offline'),
                decoration: const InputDecoration(labelText: 'Mode'),
              ),
            ),
          ]),
          const SizedBox(height: 8),
          Align(
            alignment: Alignment.centerRight,
            child: FilledButton.icon(
              onPressed: selectedDays.isEmpty ? null : _saveWeekly,
              icon: const Icon(Icons.save),
              label: const Text('Save weekly'),
            ),
          ),
          const Divider(height: 24),

          // date picker + per-date options
          Text('Specific Dates (tap calendar cells)',
              style: Theme.of(context).textTheme.titleSmall),
          const SizedBox(height: 6),

          Row(children: [
            Expanded(
              child: DropdownButtonFormField<int>(
                value: dateStartHour,
                items: List.generate(
                    24,
                    (i) => DropdownMenuItem(
                        value: i,
                        child: Text('${i.toString().padLeft(2, '0')}:00'))),
                onChanged: (v) => setState(() => dateStartHour = v ?? 9),
                decoration:
                    const InputDecoration(labelText: 'Start hour (dates)'),
              ),
            ),
            const SizedBox(width: 10),
            Expanded(
              child: DropdownButtonFormField<int>(
                value: dateEndHour,
                items: List.generate(
                    24,
                    (i) => DropdownMenuItem(
                        value: i,
                        child: Text('${i.toString().padLeft(2, '0')}:00'))),
                onChanged: (v) => setState(() => dateEndHour = v ?? 17),
                decoration:
                    const InputDecoration(labelText: 'End hour (dates)'),
              ),
            ),
          ]),
          const SizedBox(height: 8),
          Row(children: [
            Expanded(
              child: TextFormField(
                initialValue: dateMaxPatients.toString(),
                decoration: const InputDecoration(labelText: 'Max patients (dates)'),
                onChanged: (v) => dateMaxPatients = int.tryParse(v) ?? 4,
              ),
            ),
            const SizedBox(width: 10),
            Expanded(
              child: DropdownButtonFormField<String>(
                value: dateMode,
                items: const [
                  DropdownMenuItem(value: 'offline', child: Text('Offline')),
                  DropdownMenuItem(value: 'online', child: Text('Online')),
                ],
                onChanged: (v) => setState(() => dateMode = v ?? 'offline'),
                decoration: const InputDecoration(labelText: 'Mode (dates)'),
              ),
            ),
          ]),
          const SizedBox(height: 8),

          _MonthGrid(
            month: currentMonth,
            selected: selectedDates,
            onChanged: (set) => setState(() {
              selectedDates
                ..clear()
                ..addAll(set);
            }),
          ),
          const SizedBox(height: 8),
          Align(
            alignment: Alignment.centerRight,
            child: FilledButton.icon(
              onPressed: selectedDates.isEmpty ? null : _saveDates,
              icon: const Icon(Icons.save),
              label: const Text('Save selected dates'),
            ),
          ),
          const SizedBox(height: 8),
        ],
      ],
    );
  }
}

class _MonthGrid extends StatelessWidget {
  final DateTime month;
  final Set<DateTime> selected;
  final ValueChanged<Set<DateTime>> onChanged;

  const _MonthGrid(
      {required this.month, required this.selected, required this.onChanged});

  @override
  Widget build(BuildContext context) {
    final first = DateTime(month.year, month.month, 1);
    final start =
        first.subtract(Duration(days: (first.weekday + 6) % 7)); // Monday start
    final days =
        List<DateTime>.generate(42, (i) => DateTime(start.year, start.month, start.day + i));

    bool isSameDay(DateTime a, DateTime b) =>
        a.year == b.year && a.month == b.month && a.day == b.day;

    Set<DateTime> sel = {...selected};

    return GridView.builder(
      shrinkWrap: true,
      itemCount: days.length,
      gridDelegate: const SliverGridDelegateWithFixedCrossAxisCount(
          crossAxisCount: 7, mainAxisExtent: 56, crossAxisSpacing: 4, mainAxisSpacing: 4),
      itemBuilder: (_, i) {
        final d = days[i];
        final inMonth = d.month == month.month;
        final on = sel.any((x) => isSameDay(x, d));
        return InkWell(
          onTap: () {
            if (on) {
              sel.removeWhere((x) => isSameDay(x, d));
            } else {
              sel.add(DateTime(d.year, d.month, d.day));
            }
            onChanged(sel);
          },
          child: Container(
            decoration: BoxDecoration(
              borderRadius: BorderRadius.circular(8),
              color: on ? Theme.of(context).colorScheme.primaryContainer : null,
              border: Border.all(color: Theme.of(context).dividerColor),
            ),
            child: Center(
              child: Text(
                '${d.day}',
                style: TextStyle(
                  fontWeight: FontWeight.w600,
                  color: inMonth ? null : Theme.of(context).disabledColor,
                ),
              ),
            ),
          ),
        );
      },
    );
  }
}

// ─────────────────────────────────────────────────────────────────────────────
// Doctor Profile tab — reads /whoami and /doctor/me, supports photo & document upload
// ─────────────────────────────────────────────────────────────────────────────
class ProfileTab extends StatefulWidget {
  const ProfileTab({super.key});
  @override
  State<ProfileTab> createState() => _ProfileTabState();
}

class _ProfileTabState extends State<ProfileTab> {
  Map<String, dynamic>? whoami;
  Map<String, dynamic>? profileJson;
  bool loading = true;

  bool editing = false;
  Uint8List? _localPreview;
  String? _photoPath;
  int _bust = DateTime.now().millisecondsSinceEpoch;

  // Controllers
  final name = TextEditingController();
  final email = TextEditingController();
  final specialty = TextEditingController();
  final category = TextEditingController();
  final keywords = TextEditingController();
  final bio = TextEditingController();
  final background = TextEditingController();
  final phone = TextEditingController();
  final address = TextEditingController();
  final visitingFee = TextEditingController();

  final oldPass = TextEditingController();
  final newPass = TextEditingController();
  final confirmPass = TextEditingController();

  @override
  void initState() {
    super.initState();
    _loadAll();
  }

  @override
  void dispose() {
    name.dispose();
    email.dispose();
    specialty.dispose();
    category.dispose();
    keywords.dispose();
    bio.dispose();
    background.dispose();
    phone.dispose();
    address.dispose();
    visitingFee.dispose();
    oldPass.dispose();
    newPass.dispose();
    confirmPass.dispose();
    super.dispose();
  }

  // =================== Load profile ===================
  Future<void> _loadAll() async {
    if (!mounted) return;
    setState(() => loading = true);
    try {
      final resWho = await Api.get('/whoami') as Map<String, dynamic>;
      final resProf = await Api.get('/doctor/me') as Map<String, dynamic>;
      whoami = resWho;
      profileJson = resProf;

      name.text = (resProf['name'] ?? '').toString();
      email.text = (resWho['email'] ?? '').toString();
      specialty.text = (resProf['specialty'] ?? '').toString();
      category.text = (resProf['category'] ?? 'General').toString();
      keywords.text = (resProf['keywords'] ?? '').toString();
      bio.text = (resProf['bio'] ?? '').toString();
      background.text = (resProf['background'] ?? '').toString();

      phone.text = ((resProf['phone'] ?? resWho['phone']) ?? '').toString();
      address.text = (resProf['address'] ?? '').toString();

      // Support multiple possible keys for fee coming from the API.
      final fee = resProf['visiting_fee'] ?? resProf['visit_fee'] ?? resProf['fee'];
      visitingFee.text = (fee == null) ? '' : fee.toString();

      _photoPath = (resWho['photo_path'] ?? '') as String?;
      if (_photoPath != null && _photoPath!.startsWith('./')) {
        _photoPath = _photoPath!.substring(2);
      }
    } catch (e) {
      _snack('Load failed: $e');
    } finally {
      if (!mounted) return;
      setState(() => loading = false);
    }
  }

  // =================== Save profile ===================
  Future<void> _save() async {
    try {
      await Api.patch('/doctor/profile', data: {
        'name': name.text.trim(),
        'specialty': specialty.text.trim(),
        'category': category.text.trim(),
        'keywords': keywords.text.trim(),
        'bio': bio.text.trim(),
        'background': background.text.trim(),
        'phone': phone.text.trim(),
        'address': address.text.trim(),
        'visiting_fee': visitingFee.text.trim(),
      });
      _snack('Profile updated successfully');
      setState(() => editing = false);
      await _loadAll();
    } catch (e) {
      _snack('Save failed: $e');
    }
  }

  // =================== Change password ===================
  Future<void> _changePassword() async {
    try {
      if (newPass.text != confirmPass.text) {
        _snack('New passwords do not match');
        return;
      }
      await Api.post('/auth/change_password',
          data: {'old': oldPass.text, 'new': newPass.text});
      _snack('Password changed successfully');
      oldPass.clear();
      newPass.clear();
      confirmPass.clear();
    } catch (e) {
      _snack('Password change failed: $e');
    }
  }

  // =================== Photo upload ===================
  String? _photoUrl() {
    if (_localPreview != null) return null;
    final p = _photoPath;
    if (p == null || p.isEmpty) return null;
    final path = p.startsWith('/') ? p.substring(1) : p;
    return '${Api.baseUrl}/$path?v=$_bust';
  }

  Future<void> _uploadPhoto() async {
    final pick =
        await FilePicker.platform.pickFiles(withData: true, type: FileType.image);
    if (pick == null || pick.files.isEmpty) return;
    final f = pick.files.first;
    if (f.bytes == null) {
      _snack('Could not read file bytes.');
      return;
    }
    setState(() => _localPreview = f.bytes);
    try {
      final form = FormData.fromMap({
        'file': MultipartFile.fromBytes(f.bytes as Uint8List, filename: f.name),
      });
      final res = await Api.post('/doctor/profile/photo',
          data: form, multipart: true) as Map<String, dynamic>;
      final newPath = (res['photo_path'] ?? '') as String?;
      setState(() {
        _photoPath = newPath ?? _photoPath;
        _bust = DateTime.now().millisecondsSinceEpoch;
        _localPreview = null;
      });
      _snack('Profile photo updated');
    } catch (e) {
      _snack('Upload failed: $e');
      setState(() => _localPreview = null);
    }
  }

  // =================== Document upload ===================
  Future<void> _uploadDocuments() async {
    final pick = await FilePicker.platform.pickFiles(
        withData: true,
        allowedExtensions: ['pdf', 'doc', 'docx', 'png', 'jpg', 'jpeg'],
        type: FileType.custom);
    if (pick == null || pick.files.isEmpty) return;
    final f = pick.files.first;
    if (f.bytes == null) {
      _snack('Invalid document');
      return;
    }
    try {
      final form = FormData.fromMap({
        'file': MultipartFile.fromBytes(f.bytes as Uint8List, filename: f.name),
      });
      await Api.post('/doctor/profile/document', data: form, multipart: true);
      _snack('Document uploaded successfully');
    } catch (e) {
      _snack('Upload failed: $e');
    }
  }

  // =================== UI ===================
  @override
  Widget build(BuildContext context) {
    if (loading) return const Center(child: CircularProgressIndicator());
    return Stack(children: [
      SingleChildScrollView(
        padding: const EdgeInsets.fromLTRB(12, 12, 12, 120),
        child: Column(children: [
          _headerCard(context),
          const SizedBox(height: 12),
          _profileCard(context),
          const SizedBox(height: 12),
          _passwordCard(context),
        ]),
      ),
      if (editing)
        Positioned(
          left: 0,
          right: 0,
          bottom: 0,
          child: _bottomActionBar(context),
        ),
    ]);
  }

  Widget _headerCard(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    Widget avatar;
    if (_localPreview != null) {
      avatar = Image.memory(_localPreview!, fit: BoxFit.cover);
    } else {
      final url = _photoUrl();
      avatar = url != null
          ? Image.network(url,
              fit: BoxFit.cover,
              errorBuilder: (_, __, ___) => const Icon(Icons.person, size: 60))
          : const Icon(Icons.person, size: 60);
    }

    return Card(
      shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(20)),
      child: Container(
        decoration: BoxDecoration(
          gradient: LinearGradient(
              colors: [
                scheme.primary.withOpacity(0.07),
                scheme.secondary.withOpacity(0.05)
              ],
              begin: Alignment.topLeft,
              end: Alignment.bottomRight),
          borderRadius: BorderRadius.circular(20),
        ),
        padding: const EdgeInsets.symmetric(vertical: 20, horizontal: 16),
        child: Column(children: [
          Stack(alignment: Alignment.bottomRight, children: [
            ClipOval(child: SizedBox(width: 110, height: 110, child: avatar)),
            Material(
              color: scheme.primary,
              shape: const CircleBorder(),
              elevation: 3,
              child: InkWell(
                onTap: _uploadPhoto,
                customBorder: const CircleBorder(),
                child: const Padding(
                  padding: EdgeInsets.all(10),
                  child: Icon(Icons.photo_camera, size: 20, color: Colors.white),
                ),
              ),
            ),
          ]),
          const SizedBox(height: 10),
          Text(name.text.isEmpty ? 'Doctor Profile' : name.text,
              style: Theme.of(context)
                  .textTheme
                  .titleMedium
                  ?.copyWith(fontWeight: FontWeight.w600)),
          const SizedBox(height: 6),
        ]),
      ),
    );
  }

  Widget _profileCard(BuildContext context) {
    final cols = _colsForWidth(context);
    return _sectionCard(
      title: 'Profile',
      trailing: IconButton(
          icon: const Icon(Icons.edit),
          onPressed: editing ? null : () => setState(() => editing = true)),
      children: [
        _grid([
          _tf(name, 'Name', enabled: editing, icon: Icons.person),
          _tf(email, 'Email', enabled: false, icon: Icons.email_outlined),
          _tf(phone, 'Phone',
              enabled: editing, icon: Icons.phone, keyboardType: TextInputType.phone),
          _tf(specialty, 'Specialty',
              enabled: editing, icon: Icons.medical_information),
        ], cols),
        const SizedBox(height: 12),
        _grid([
          _tf(category, 'Category', enabled: editing, icon: Icons.category),
          _tf(keywords, 'Keywords', enabled: editing, icon: Icons.key),
          _tf(visitingFee, 'Visiting Fee',
              enabled: editing,
              icon: Icons.payments_outlined,
              keyboardType: TextInputType.number),
        ], cols),
        const SizedBox(height: 12),
        _tf(bio, 'Bio', enabled: editing, maxLines: 3, icon: Icons.description_outlined),
        const SizedBox(height: 12),
        _tf(background, 'Background',
            enabled: editing, maxLines: 3, icon: Icons.school_outlined),
        const SizedBox(height: 12), // spacing to prevent overlap
        _tf(address, 'Address',
            enabled: editing, icon: Icons.location_on_outlined, maxLines: 2),
        const SizedBox(height: 12),
        Align(
          alignment: Alignment.centerLeft,
          child: OutlinedButton.icon(
            onPressed: _uploadDocuments,
            icon: const Icon(Icons.file_upload_outlined),
            label: const Text('Upload Documents'),
          ),
        ),
      ],
    );
  }

  Widget _passwordCard(BuildContext context) {
    final cols = _colsForWidth(context);
    return _sectionCard(
      title: 'Change Password',
      children: [
        _grid([
          _tf(oldPass, 'Current Password', icon: Icons.lock_outline, obscure: true),
          _tf(newPass, 'New Password', icon: Icons.lock_outline, obscure: true),
          _tf(confirmPass, 'Confirm Password', icon: Icons.lock_outline, obscure: true),
        ], cols),
        const SizedBox(height: 12),
        Align(
          alignment: Alignment.centerRight,
          child: FilledButton.icon(
            onPressed: _changePassword,
            icon: const Icon(Icons.lock_reset),
            label: const Text('Update Password'),
          ),
        ),
      ],
    );
  }

  Widget _bottomActionBar(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    return SafeArea(
      top: false,
      child: Container(
        decoration: BoxDecoration(
          color: scheme.surface,
          boxShadow: [BoxShadow(color: Colors.black.withOpacity(0.08), blurRadius: 8)],
          border: Border(top: BorderSide(color: Theme.of(context).dividerColor)),
        ),
        padding: const EdgeInsets.all(12),
        child: Row(children: [
          OutlinedButton.icon(
            onPressed: () async {
              setState(() => editing = false);
              await _loadAll();
            },
            icon: const Icon(Icons.close),
            label: const Text('Cancel'),
          ),
          const Spacer(),
          FilledButton.icon(
            onPressed: _save,
            icon: const Icon(Icons.save_rounded),
            label: const Text('Save Changes'),
          ),
        ]),
      ),
    );
  }

  // =================== Helpers ===================
  void _snack(String msg) {
    if (!mounted) return;
    ScaffoldMessenger.of(context).showSnackBar(SnackBar(content: Text(msg)));
  }

  int _colsForWidth(BuildContext context) {
    final w = MediaQuery.of(context).size.width;
    if (w >= 1000) return 3;
    if (w >= 700) return 2;
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
      final end = (i + cols) > children.length ? children.length : (i + cols);
      final slice = children.sublist(i, end);
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

  Widget _tf(TextEditingController c, String label,
      {bool enabled = false,
      int maxLines = 1,
      IconData? icon,
      TextInputType? keyboardType,
      bool obscure = false}) {
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
        contentPadding:
            const EdgeInsets.symmetric(horizontal: 14, vertical: 14),
      ),
    );
  }

  Widget _sectionCard(
      {required String title, required List<Widget> children, Widget? trailing}) {
    return Card(
      shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(20)),
      elevation: 2,
      child: Padding(
        padding: const EdgeInsets.fromLTRB(14, 12, 14, 16),
        child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
          Row(children: [
            Expanded(
                child: Text(title,
                    style: Theme.of(context)
                        .textTheme
                        .titleMedium
                        ?.copyWith(fontWeight: FontWeight.w600))),
            if (trailing != null) trailing,
          ]),
          const SizedBox(height: 8),
          ...children,
        ]),
      ),
    );
  }
}

