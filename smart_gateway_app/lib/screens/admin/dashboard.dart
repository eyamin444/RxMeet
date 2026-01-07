// lib/screens/admin/dashboard.dart
import 'dart:typed_data';
import 'dart:convert';
import 'package:http/http.dart' as http;
import 'package:dio/dio.dart' as dio_pkg;
import 'package:file_picker/file_picker.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:intl/intl.dart';
import 'package:pdf/pdf.dart';
import 'package:pdf/widgets.dart' as pw;
import 'package:printing/printing.dart';
import 'package:url_launcher/url_launcher.dart';

import '../../main.dart' show LoginPage;
import '../../models.dart';
import '../../services/api.dart';
import '../../services/auth.dart';
import '../../utils/download.dart';
import '../../widgets/snack.dart';


/// ───────────────────────────── Shared helpers ─────────────────────────────

Widget _kv(String k, String v) => Padding(
      padding: const EdgeInsets.symmetric(vertical: 6),
      child: Row(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          SizedBox(
              width: 120,
              child: Text(k,
                  style: const TextStyle(fontWeight: FontWeight.w600))),
          const SizedBox(width: 8),
          Expanded(child: Text(v)),
        ],
      ),
    );

String extractFilePath(dynamic row) {
  if (row == null) return '';

  // If backend already returns a string directly
  if (row is String) return row.trim();

  if (row is Map) {
    // possible keys backend might return
    const possibleKeys = [
      'file_path',
      'path',
      'url',
      'fileUrl',
      'file_url',
      'attachment',
      'attachment_url',
      'document',
      'document_url',
      'image',
      'image_url',
    ];

    // check direct keys first
    for (final k in possibleKeys) {
      final v = row[k];
      if (v is String && v.trim().isNotEmpty) return v.trim();
    }

    // check common nested objects
    const nestedObjects = ['file', 'attachment', 'document', 'report_file'];

    for (final nk in nestedObjects) {
      final nested = row[nk];
      if (nested is Map) {
        for (final k in possibleKeys) {
          final v = nested[k];
          if (v is String && v.trim().isNotEmpty) return v.trim();
        }
      }
    }
  }

  return '';
}

Widget personTile({
  required BuildContext context,
  required String title,
  required String subtitle,
  String? trailing,
  VoidCallback? onTap,
}) {
  final theme = Theme.of(context);
  return Card(
    elevation: 0,
    shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(14)),
    margin: const EdgeInsets.symmetric(vertical: 6, horizontal: 12),
    child: InkWell(
      borderRadius: BorderRadius.circular(14),
      onTap: onTap,
      child: Padding(
        padding: const EdgeInsets.fromLTRB(12, 10, 12, 10),
        child: Row(
          children: [
            CircleAvatar(
              radius: 20,
              child: Text(
                title.isNotEmpty ? title[0].toUpperCase() : '?',
                style: const TextStyle(color: Colors.white),
              ),
            ),
            const SizedBox(width: 12),
            Expanded(
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Text(
                    title,
                    maxLines: 1,
                    overflow: TextOverflow.ellipsis,
                    style: theme.textTheme.titleMedium
                        ?.copyWith(fontWeight: FontWeight.w600),
                  ),
                  const SizedBox(height: 2),
                  Text(subtitle, maxLines: 1, overflow: TextOverflow.ellipsis),
                ],
              ),
            ),
            if (trailing != null) ...[
              const SizedBox(width: 12),
              Text(trailing,
                  style: const TextStyle(fontWeight: FontWeight.w600)),
            ],
          ],
        ),
      ),
    ),
  );
}

Future<void> openFileUrl(BuildContext context, String url) async {
  final uri = Uri.parse(url);
  if (await canLaunchUrl(uri)) {
    await launchUrl(uri, mode: LaunchMode.externalApplication);
  } else {
    showSnack(context, 'Could not open file');
  }
}

Future<void> downloadBytes(Uint8List bytes, String filename) async {
  await Printing.sharePdf(bytes: bytes, filename: filename);
}

Future<void> printPdfBytes(Uint8List bytes) async {
  await Printing.layoutPdf(onLayout: (_) async => bytes);
}

Future<void> openAttachment(
  BuildContext context,
  String filePathOrUrl, {
  String filename = 'attachment',
}) async {
  if (filePathOrUrl.trim().isEmpty) {
    showSnack(context, 'No file path');
    return;
  }

  var p = filePathOrUrl.trim().replaceAll('\\', '/');

  // If backend returns full URL, directly open it
  if (p.startsWith('http://') || p.startsWith('https://')) {
    final uri = Uri.parse(p);
    if (await canLaunchUrl(uri)) {
      await launchUrl(uri, mode: LaunchMode.externalApplication);
      return;
    } else {
      showSnack(context, 'Could not open URL');
      return;
    }
  }

  // otherwise treat as server file path
  if (!p.startsWith('/')) p = '/$p';

  try {
    // Use auth download
    final bytes = await Api.getBytes(p);

    if (bytes.isEmpty) {
      showSnack(context, 'Empty file');
      return;
    }

    // detect file type
    final lowerName = filename.toLowerCase();
    final lowerPath = p.toLowerCase();
    final isPdf = lowerName.endsWith('.pdf') || lowerPath.endsWith('.pdf');

    // pdf -> share/download
    if (isPdf) {
      await downloadBytes(
        bytes,
        filename.endsWith('.pdf') ? filename : '$filename.pdf',
      );
      return;
    }

    // show image preview
    await showDialog(
      context: context,
      builder: (_) => AlertDialog(
        title: Text(filename),
        content: SingleChildScrollView(child: Image.memory(bytes)),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(context),
            child: const Text('Close'),
          ),
        ],
      ),
    );
  } catch (e) {
    // fallback try public URL
    final url = Api.filePathToUrl(p);
    final uri = Uri.parse(url);

    if (await canLaunchUrl(uri)) {
      await launchUrl(uri, mode: LaunchMode.externalApplication);
      return;
    }

    showSnack(context, 'Could not open file: $e');
  }
}

Future<void> openPaymentReceipt(BuildContext context, int paymentId) async {
  // 1) try bytes first
  try {
    final bytes = await Api.getBytes('/payments/$paymentId/receipt');
    if (bytes.isNotEmpty) {
      try {
        await downloadBytes(bytes, 'receipt-$paymentId.pdf');
        return;
      } catch (_) {
        try {
          await printPdfBytes(bytes);
          return;
        } catch (_) {}
      }
    }
  } catch (_) {}

  // 2) fallback open URL
  final base =
      (Api.baseUrl != null && (Api.baseUrl as String).trim().isNotEmpty)
          ? (Api.baseUrl as String)
          : 'http://127.0.0.1:8000';

  final url =
      '${base.replaceAll(RegExp(r'/$'), '')}/payments/$paymentId/receipt';
  final uri = Uri.parse(url);
  if (await canLaunchUrl(uri)) {
    await launchUrl(uri, mode: LaunchMode.externalApplication);
    return;
  }

  showSnack(context, 'Could not open receipt');
}

/// ───────────────────────────── Admin shell ─────────────────────────────

class AdminDashboard extends StatefulWidget {
  const AdminDashboard({super.key, required this.me});
  final User me;

  @override
  State<AdminDashboard> createState() => _AdminDashboardState();
}

class _AdminDashboardState extends State<AdminDashboard> {
  int idx = 0;

  @override
  Widget build(BuildContext context) {
    final tabs = <Widget>[
      const _AdminDoctorsTab(),
      const _AdminCreateDoctorTab(),
      const _AdminPatientsTab(),
      const _AdminAppointmentsTab(),
      const _AdminPaymentsTab(),
      _AdminProfileTab(me: widget.me),
    ];

    return Scaffold(
      appBar: AppBar(
        title: const Text('Admin Dashboard'),
        actions: [
          IconButton(
            tooltip: 'Logout',
            onPressed: () async {
              try {
                await AuthService.logout();
              } catch (_) {}
              if (!mounted) return;

              Navigator.of(context).pushAndRemoveUntil(
                MaterialPageRoute(builder: (_) => const LoginPage()),
                (route) => false,
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
          NavigationDestination(icon: Icon(Icons.group), label: 'Doctors'),
          NavigationDestination(
              icon: Icon(Icons.person_add), label: 'Create Doctor'),
          NavigationDestination(
              icon: Icon(Icons.people_alt), label: 'Patients'),
          NavigationDestination(icon: Icon(Icons.event), label: 'Appointments'),
          NavigationDestination(icon: Icon(Icons.payment), label: 'Payments'),
          NavigationDestination(
              icon: Icon(Icons.account_circle), label: 'Profile'),
        ],
      ),
    );
  }
}

/// ───────────────────── Doctors ─────────────────────

class _AdminDoctorsTab extends StatefulWidget {
  const _AdminDoctorsTab();

  @override
  State<_AdminDoctorsTab> createState() => _AdminDoctorsTabState();
}

class _AdminDoctorsTabState extends State<_AdminDoctorsTab> {
  final q = TextEditingController();
  bool loading = true;
  List<Doctor> items = [];

  @override
  void initState() {
    super.initState();
    _load();
    q.addListener(() => setState(() {}));
  }

  @override
  void dispose() {
    q.dispose();
    super.dispose();
  }

  Future<void> _load() async {
    setState(() => loading = true);
    try {
      final res = await Api.get('/doctors', query: {
        if (q.text.trim().isNotEmpty) 'q': q.text.trim(),
      });
      items = (res as List).map((e) => Doctor.fromJson(e)).toList();
    } catch (e) {
      if (mounted) showSnack(context, 'Load failed: $e');
      items = [];
    } finally {
      if (mounted) setState(() => loading = false);
    }
  }

  @override
  Widget build(BuildContext context) {
    if (loading) return const Center(child: CircularProgressIndicator());
    return RefreshIndicator(
      onRefresh: _load,
      child: Column(
        children: [
          Padding(
            padding: const EdgeInsets.fromLTRB(12, 8, 12, 6),
            child: Row(
              children: [
                Expanded(
                  child: TextField(
                    controller: q,
                    decoration: InputDecoration(
                      prefixIcon: const Icon(Icons.search),
                      hintText: 'Search doctors by name or specialty',
                      border: OutlineInputBorder(
                          borderRadius: BorderRadius.circular(24)),
                      isDense: true,
                      filled: true,
                      suffixIcon: q.text.isEmpty
                          ? null
                          : IconButton(
                              icon: const Icon(Icons.close),
                              onPressed: () {
                                q.clear();
                                _load();
                              },
                            ),
                    ),
                    textInputAction: TextInputAction.search,
                    onSubmitted: (_) => _load(),
                  ),
                ),
                IconButton(
                    tooltip: 'Refresh',
                    onPressed: _load,
                    icon: const Icon(Icons.refresh)),
              ],
            ),
          ),
          Expanded(
            child: items.isEmpty
                ? const Center(child: Text('No doctors found'))
                : ListView.builder(
                    physics: const AlwaysScrollableScrollPhysics(),
                    itemCount: items.length,
                    itemBuilder: (ctx, i) {
                      final d = items[i];
                      return personTile(
                        context: ctx,
                        title: d.name,
                        subtitle: '${d.specialty} • ${d.category ?? 'General'}',
                        trailing: '★ ${d.rating ?? 5}',
                        onTap: () => Navigator.of(ctx).push(
                          MaterialPageRoute(
                              builder: (_) =>
                                  DoctorDetailPage(doctorId: d.id)),
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

/// ─────────────────────────── Create Doctor (form) ───────────────────────────

class _AdminCreateDoctorTab extends StatefulWidget {
  const _AdminCreateDoctorTab();

  @override
  State<_AdminCreateDoctorTab> createState() => _AdminCreateDoctorTabState();
}

class _AdminCreateDoctorTabState extends State<_AdminCreateDoctorTab> {
  final name = TextEditingController();
  final email = TextEditingController();
  final phone = TextEditingController();
  final pass = TextEditingController();
  final specialty = TextEditingController();
  final category = TextEditingController(text: 'General');
  final keywords = TextEditingController();
  final bio = TextEditingController();
  final background = TextEditingController();
  bool busy = false;

  @override
  void dispose() {
    name.dispose();
    email.dispose();
    phone.dispose();
    pass.dispose();
    specialty.dispose();
    category.dispose();
    keywords.dispose();
    bio.dispose();
    background.dispose();
    super.dispose();
  }

  Future<void> _create() async {
    setState(() => busy = true);
    try {
      await Api.post('/admin/doctors', data: {
        'name': name.text,
        'email': email.text,
        'password': pass.text,
        'phone': phone.text.isEmpty ? null : phone.text,
        'specialty': specialty.text,
        'category': category.text,
        'keywords': keywords.text,
        'bio': bio.text,
        'background': background.text,
      });
      if (mounted) showSnack(context, 'Doctor created');
      name.clear();
      email.clear();
      phone.clear();
      pass.clear();
      specialty.clear();
      category.text = 'General';
      keywords.clear();
      bio.clear();
      background.clear();
    } catch (e) {
      if (mounted) showSnack(context, 'Failed: $e');
    } finally {
      if (mounted) setState(() => busy = false);
    }
  }

  @override
  Widget build(BuildContext context) {
    final fields = <Widget>[
      _tf(name, 'Name'),
      _tf(email, 'Email'),
      _tf(phone, 'Phone (optional)'),
      _tf(pass, 'Password', obscure: true),
      _tf(specialty, 'Specialty'),
      _tf(category, 'Category'),
      _tf(keywords, 'Keywords'),
      _tf(bio, 'Bio'),
      _tf(background, 'Background'),
      const SizedBox(height: 12),
      FilledButton.icon(
        onPressed: busy ? null : _create,
        icon: const Icon(Icons.check),
        label: Text(busy ? 'Saving…' : 'Create Doctor'),
      ),
    ];
    return SingleChildScrollView(
      padding: const EdgeInsets.all(16),
      child: Column(
        children: fields
            .map((w) => Padding(
                padding: const EdgeInsets.only(bottom: 10), child: w))
            .toList(),
      ),
    );
  }

  Widget _tf(TextEditingController c, String label, {bool obscure = false}) {
    return TextField(
      controller: c,
      obscureText: obscure,
      decoration:
          InputDecoration(labelText: label, border: const OutlineInputBorder()),
    );
  }
}

/// ─────────────────────────── Patients (searchable) ───────────────────────────

class _AdminPatientsTab extends StatefulWidget {
  const _AdminPatientsTab();

  @override
  State<_AdminPatientsTab> createState() => _AdminPatientsTabState();
}

class _AdminPatientsTabState extends State<_AdminPatientsTab> {
  final q = TextEditingController();
  bool loading = true;
  final Map<int, _PatientRow> cache = {};
  List<_PatientRow> view = [];

  @override
  void initState() {
    super.initState();
    _load();
    q.addListener(_filter);
  }

  @override
  void dispose() {
    q.dispose();
    super.dispose();
  }

  void _filter() {
    final s = q.text.trim().toLowerCase();
    if (s.isEmpty) {
      setState(() => view = cache.values.toList()
        ..sort((a, b) => a.name.compareTo(b.name)));
    } else {
      setState(() {
        view = cache.values
            .where((p) =>
                p.name.toLowerCase().contains(s) ||
                (p.email ?? '').toLowerCase().contains(s) ||
                (p.phone ?? '').toLowerCase().contains(s))
            .toList()
          ..sort((a, b) => a.name.compareTo(b.name));
      });
    }
  }

  Future<void> _load() async {
    setState(() => loading = true);
    try {
      final res = await Api.get('/admin/appointments');
      final list = (res as List);
      final ids = <int>{};
      for (final a in list) {
        final pid = (a['patient_id'] ?? 0) as int;
        if (pid > 0) ids.add(pid);
      }

      for (final id in ids) {
        if (!cache.containsKey(id)) {
          try {
            final m = await Api.get('/patients/$id');
            cache[id] = _PatientRow(
              id: id,
              name: (m['name'] ?? '').toString(),
              email: (m['email'] ?? '').toString().isEmpty
                  ? null
                  : (m['email'] ?? '').toString(),
              phone: (m['phone'] ?? '').toString().isEmpty
                  ? null
                  : (m['phone'] ?? '').toString(),
            );
          } catch (_) {}
        }
      }
      _filter();
    } catch (e) {
      if (mounted) showSnack(context, 'Load failed: $e');
      view = [];
    } finally {
      if (mounted) setState(() => loading = false);
    }
  }

  @override
  Widget build(BuildContext context) {
    if (loading) return const Center(child: CircularProgressIndicator());
    return RefreshIndicator(
      onRefresh: _load,
      child: Column(
        children: [
          Padding(
            padding: const EdgeInsets.fromLTRB(12, 8, 12, 6),
            child: Row(
              children: [
                Expanded(
                  child: TextField(
                    controller: q,
                    decoration: InputDecoration(
                      prefixIcon: const Icon(Icons.search),
                      hintText: 'Search patients by name, email, or phone',
                      border: OutlineInputBorder(
                          borderRadius: BorderRadius.circular(24)),
                      isDense: true,
                      filled: true,
                      suffixIcon: q.text.isEmpty
                          ? null
                          : IconButton(
                              icon: const Icon(Icons.close),
                              onPressed: () => q.clear(),
                            ),
                    ),
                    textInputAction: TextInputAction.search,
                    onSubmitted: (_) => _filter(),
                  ),
                ),
                IconButton(
                    tooltip: 'Refresh',
                    onPressed: _load,
                    icon: const Icon(Icons.refresh)),
              ],
            ),
          ),
          Expanded(
            child: view.isEmpty
                ? const Center(child: Text('No patients found'))
                : ListView.builder(
                    physics: const AlwaysScrollableScrollPhysics(),
                    itemCount: view.length,
                    itemBuilder: (ctx, i) {
                      final p = view[i];
                      final subtitle = [
                        if (p.email != null) p.email!,
                        if (p.phone != null) p.phone!,
                      ].join(' • ');
                      return personTile(
                        context: ctx,
                        title: p.name.isEmpty ? 'Patient #${p.id}' : p.name,
                        subtitle: subtitle.isEmpty ? 'ID: ${p.id}' : subtitle,
                        onTap: () => Navigator.of(context).push(
                          MaterialPageRoute(
                              builder: (_) =>
                                  PatientDetailPage(patientId: p.id)),
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

class _PatientRow {
  final int id;
  final String name;
  final String? email;
  final String? phone;
  final String? address;
  final double? visitingFee;

  _PatientRow({
    required this.id,
    required this.name,
    this.email,
    this.phone,
    this.address,
    this.visitingFee,
  });
}

/// ───────────────────── Appointments  ─────────────────────

class _AdminAppointmentsTab extends StatefulWidget {
  const _AdminAppointmentsTab();

  @override
  State<_AdminAppointmentsTab> createState() => _AdminAppointmentsTabState();
}

class _AdminAppointmentsTabState extends State<_AdminAppointmentsTab> {
  final dfFull = DateFormat.yMMMd().add_jm();
  final dfDay = DateFormat.yMMMMd();

  final qCtrl = TextEditingController();
  bool loading = true;

  // Raw server list
  List<Map<String, dynamic>> _all = [];

  // Filtered + sorted list (paged)
  List<Map<String, dynamic>> _view = [];

  // Filters
  String _statusFilter = 'all'; // all / requested / approved / rejected / cancelled
  DateTimeRange? _dateRange;

  // Pagination
  int page = 1;
  final int pageSize = 25;
  int total = 0;

  // Name caches (for search + display)
  final Map<int, String> _doctorNameCache = {};
  final Map<int, String> _patientNameCache = {};

  @override
  void initState() {
    super.initState();
    _load();
    qCtrl.addListener(() => _apply(resetPage: true));
  }

  @override
  void dispose() {
    qCtrl.dispose();
    super.dispose();
  }

  // Helpers
  int _apptId(Map<String, dynamic> a) {
    final idDyn = a['id'];
    return (idDyn is num) ? idDyn.toInt() : int.tryParse('$idDyn') ?? 0;
  }

  String _status(Map<String, dynamic> a) =>
      (a['status'] ?? '').toString().trim();

  DateTime? _parseDate(dynamic v) {
    if (v == null) return null;
    if (v is DateTime) return v;
    if (v is String) return DateTime.tryParse(v);
    if (v is int) {
      if (v < 10000000000) return DateTime.fromMillisecondsSinceEpoch(v * 1000);
      return DateTime.fromMillisecondsSinceEpoch(v);
    }
    if (v is double) {
      final n = v.toInt();
      if (n < 10000000000) return DateTime.fromMillisecondsSinceEpoch(n * 1000);
      return DateTime.fromMillisecondsSinceEpoch(n);
    }
    return null;
  }

  DateTime? _start(Map<String, dynamic> a) => _parseDate(a['start_time']);
  DateTime? _end(Map<String, dynamic> a) => _parseDate(a['end_time']);
  DateTime? _created(Map<String, dynamic> a) =>
      _parseDate(a['created_at'] ?? a['createdAt'] ?? a['created']);

  int? _doctorId(Map<String, dynamic> a) {
    final doc = a['doctor'];
    if (doc is Map && doc['id'] is num) return (doc['id'] as num).toInt();
    final did = a['doctor_id'] ?? a['doctorId'] ?? a['doctorID'];
    if (did is num) return did.toInt();
    return int.tryParse('$did');
  }

  int? _patientId(Map<String, dynamic> a) {
    final pat = a['patient'];
    if (pat is Map && pat['id'] is num) return (pat['id'] as num).toInt();
    final pid = a['patient_id'] ?? a['patientId'] ?? a['patientID'];
    if (pid is num) return pid.toInt();
    return int.tryParse('$pid');
  }

  String _doctorName(Map<String, dynamic> a) {
    final doc = a['doctor'];
    if (doc is Map && doc['name'] != null) return '${doc['name']}';

    final v = (a['doctor_name'] ?? a['_doctor_name'] ?? '').toString();
    if (v.trim().isNotEmpty) return v.trim();

    final id = _doctorId(a);
    if (id != null && _doctorNameCache[id] != null) return _doctorNameCache[id]!;
    return id != null ? 'Doctor #$id' : '';
  }

  String _patientName(Map<String, dynamic> a) {
    final pat = a['patient'];
    if (pat is Map && pat['name'] != null) return '${pat['name']}';

    final v = (a['patient_name'] ?? a['_patient_name'] ?? '').toString();
    if (v.trim().isNotEmpty) return v.trim();

    final id = _patientId(a);
    if (id != null && _patientNameCache[id] != null) return _patientNameCache[id]!;
    return id != null ? 'Patient #$id' : '';
  }

  bool _isUnapprovedStatus(String s) {
    final t = s.toLowerCase();
    return t.contains('requested') ||
        t.contains('pending') ||
        t.contains('unapproved') ||
        t.contains('waiting');
  }

  int _sortCompare(Map<String, dynamic> a, Map<String, dynamic> b) {
    final ua = _isUnapprovedStatus(_status(a));
    final ub = _isUnapprovedStatus(_status(b));

    if (ua != ub) return ua ? -1 : 1;

    if (ua && ub) {
      final ca = _created(a) ?? DateTime.fromMillisecondsSinceEpoch(0);
      final cb = _created(b) ?? DateTime.fromMillisecondsSinceEpoch(0);

      final c = ca.compareTo(cb);
      if (c != 0) return c;
      return _apptId(a).compareTo(_apptId(b));
    }

    final ta = _start(a) ?? DateTime.fromMillisecondsSinceEpoch(0);
    final tb = _start(b) ?? DateTime.fromMillisecondsSinceEpoch(0);

    final t = tb.compareTo(ta);
    if (t != 0) return t;

    final ca = _created(a) ?? DateTime.fromMillisecondsSinceEpoch(0);
    final cb = _created(b) ?? DateTime.fromMillisecondsSinceEpoch(0);
    return cb.compareTo(ca);
  }

  Future<void> _load() async {
    setState(() => loading = true);
    try {
      final res = await Api.get('/admin/appointments');
      final list =
          (res as List).map((e) => Map<String, dynamic>.from(e as Map)).toList();
      _all = list;

      await _enrichDoctorPatientNames(_all);

      _apply(resetPage: true);
    } catch (e) {
      if (mounted) showSnack(context, 'Load failed: $e');
      _all = [];
      _view = [];
      total = 0;
    } finally {
      if (mounted) setState(() => loading = false);
    }
  }

  Future<void> _enrichDoctorPatientNames(List<Map<String, dynamic>> rows) async {
    final doctorIds = <int>{};
    final patientIds = <int>{};

    for (final a in rows) {
      final did = _doctorId(a);
      final pid = _patientId(a);

      if (did != null && !_doctorNameCache.containsKey(did)) {
        final doc = a['doctor'];
        if (doc is Map && doc['name'] != null) {
          _doctorNameCache[did] = '${doc['name']}';
        } else {
          doctorIds.add(did);
        }
      }

      if (pid != null && !_patientNameCache.containsKey(pid)) {
        final pat = a['patient'];
        if (pat is Map && pat['name'] != null) {
          _patientNameCache[pid] = '${pat['name']}';
        } else {
          patientIds.add(pid);
        }
      }
    }

    for (final id in doctorIds) {
      try {
        final r = await Api.get('/doctors/$id');
        if (r is Map) {
          final name = (r['name'] ?? '').toString().trim();
          if (name.isNotEmpty) _doctorNameCache[id] = name;
        }
      } catch (_) {}
    }

    for (final id in patientIds) {
      try {
        dynamic r;
        try {
          r = await Api.get('/admin/patients/$id');
        } catch (_) {
          r = await Api.get('/patients/$id');
        }
        if (r is Map) {
          final name = (r['name'] ?? '').toString().trim();
          if (name.isNotEmpty) _patientNameCache[id] = name;
        }
      } catch (_) {}
    }

    for (final a in rows) {
      a['_doctor_name'] = _doctorName(a);
      a['_patient_name'] = _patientName(a);
    }
  }

  void _apply({bool resetPage = false}) {
    final q = qCtrl.text.trim().toLowerCase();

    List<Map<String, dynamic>> rows = List<Map<String, dynamic>>.from(_all);

    if (_statusFilter != 'all') {
      rows = rows
          .where((a) => _status(a).toLowerCase() == _statusFilter)
          .toList();
    }

    if (_dateRange != null) {
      final from = DateTime(_dateRange!.start.year, _dateRange!.start.month,
          _dateRange!.start.day);
      final to = DateTime(_dateRange!.end.year, _dateRange!.end.month,
          _dateRange!.end.day, 23, 59, 59);

      rows = rows.where((a) {
        final st = _start(a);
        if (st == null) return false;
        final local = st.toLocal();
        return !local.isBefore(from) && !local.isAfter(to);
      }).toList();
    }

    if (q.isNotEmpty) {
      rows = rows.where((a) {
        final id = _apptId(a).toString();
        final d = _doctorName(a).toLowerCase();
        final p = _patientName(a).toLowerCase();
        return id.contains(q) || d.contains(q) || p.contains(q);
      }).toList();
    }

    rows.sort(_sortCompare);
    total = rows.length;

    if (resetPage) page = 1;

    final pages = (total + pageSize - 1) ~/ pageSize;
    if (page < 1) page = 1;
    if (pages > 0 && page > pages) page = pages;
    if (pages == 0) page = 1;

    final startIndex = (page - 1) * pageSize;
    final endIndex = (startIndex + pageSize) > rows.length
        ? rows.length
        : (startIndex + pageSize);

    _view = rows.isEmpty ? [] : rows.sublist(startIndex, endIndex);

    if (mounted) setState(() {});
  }

  Future<void> _pickDateRange() async {
    final now = DateTime.now();
    final initial = _dateRange ??
        DateTimeRange(
          start: DateTime(now.year, now.month, now.day)
              .subtract(const Duration(days: 7)),
          end: DateTime(now.year, now.month, now.day),
        );

    final r = await showDateRangePicker(
      context: context,
      firstDate: DateTime(2020),
      lastDate: DateTime(now.year + 3),
      initialDateRange: initial,
    );

    if (r != null) {
      setState(() => _dateRange = r);
      _apply(resetPage: true);
    }
  }

  void _clearAll() {
    qCtrl.clear();
    setState(() {
      _statusFilter = 'all';
      _dateRange = null;
      page = 1;
    });
    _apply(resetPage: true);
  }

  List<_DayGroup> _groupByDay(List<Map<String, dynamic>> rows) {
    final map = <DateTime, List<Map<String, dynamic>>>{};

    for (final a in rows) {
      final st = _start(a)?.toLocal();
      if (st == null) continue;
      final key = DateTime(st.year, st.month, st.day);
      (map[key] ??= []).add(a);
    }

    final keys = map.keys.toList()..sort((a, b) => b.compareTo(a));

    return keys.map((k) {
      final list = map[k] ?? <Map<String, dynamic>>[];
      list.sort(_sortCompare);
      return _DayGroup(day: k, items: list);
    }).toList();
  }

  @override
  Widget build(BuildContext context) {
    final pages = (total + pageSize - 1) ~/ pageSize;
    final groups = _groupByDay(_view);

    return RefreshIndicator(
      onRefresh: _load,
      child: Column(
        children: [
          Padding(
            padding: const EdgeInsets.fromLTRB(12, 10, 12, 6),
            child: Row(
              children: [
                Expanded(
                  flex: 4,
                  child: TextField(
                    controller: qCtrl,
                    decoration: InputDecoration(
                      prefixIcon: const Icon(Icons.search),
                      hintText: 'Search doctor, patient, appointment id',
                      border: OutlineInputBorder(
                          borderRadius: BorderRadius.circular(28)),
                      isDense: true,
                      filled: true,
                    ),
                    textInputAction: TextInputAction.search,
                    onSubmitted: (_) => _apply(resetPage: true),
                  ),
                ),
                const SizedBox(width: 8),
                Expanded(
                  flex: 2,
                  child: DropdownButtonFormField<String>(
                    value: _statusFilter,
                    items: const [
                      DropdownMenuItem(value: 'all', child: Text('All')),
                      DropdownMenuItem(
                          value: 'requested', child: Text('Requested')),
                      DropdownMenuItem(
                          value: 'approved', child: Text('Approved')),
                      DropdownMenuItem(
                          value: 'rejected', child: Text('Rejected')),
                      DropdownMenuItem(
                          value: 'cancelled', child: Text('Cancelled')),
                    ],
                    onChanged: (v) {
                      if (v == null) return;
                      setState(() => _statusFilter = v);
                      _apply(resetPage: true);
                    },
                    decoration: const InputDecoration(
                      labelText: 'Status',
                      border: OutlineInputBorder(),
                      isDense: true,
                    ),
                  ),
                ),
                const SizedBox(width: 8),
                Expanded(
                  flex: 3,
                  child: OutlinedButton.icon(
                    icon: const Icon(Icons.date_range),
                    label: Text(
                      _dateRange == null
                          ? 'Date'
                          : '${DateFormat.yMMMd().format(_dateRange!.start)} → ${DateFormat.yMMMd().format(_dateRange!.end)}',
                      maxLines: 1,
                      overflow: TextOverflow.ellipsis,
                    ),
                    onPressed: _pickDateRange,
                  ),
                ),
                const SizedBox(width: 8),
                IconButton(
                  tooltip: 'Clear filters',
                  onPressed: _clearAll,
                  icon: const Icon(Icons.clear_all),
                ),
              ],
            ),
          ),
          if (loading) const LinearProgressIndicator(),
          Expanded(
            child: (!loading && total == 0)
                ? ListView(
                    children: const [
                      SizedBox(height: 220),
                      Center(child: Text('No appointments')),
                    ],
                  )
                : ListView.builder(
                    physics: const AlwaysScrollableScrollPhysics(),
                    padding: const EdgeInsets.fromLTRB(12, 6, 12, 12),
                    itemCount: groups.length,
                    itemBuilder: (ctx, idx) {
                      final g = groups[idx];
                      return Column(
                        crossAxisAlignment: CrossAxisAlignment.start,
                        children: [
                          Padding(
                            padding: const EdgeInsets.fromLTRB(6, 12, 6, 6),
                            child: Text(
                              dfDay.format(g.day),
                              style: const TextStyle(
                                  fontWeight: FontWeight.w800, fontSize: 16),
                            ),
                          ),
                          ...g.items.map((a) => _apptCard(ctx, a)).toList(),
                        ],
                      );
                    },
                  ),
          ),
          Padding(
            padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 10),
            child: Row(
              children: [
                Text(
                  'Page $page / ${pages == 0 ? 1 : pages}',
                  style: const TextStyle(fontWeight: FontWeight.w600),
                ),
                const Spacer(),
                Text('Total: $total'),
                const SizedBox(width: 10),
                IconButton(
                  tooltip: 'Prev',
                  onPressed: (page > 1 && !loading)
                      ? () {
                          setState(() => page -= 1);
                          _apply();
                        }
                      : null,
                  icon: const Icon(Icons.chevron_left),
                ),
                IconButton(
                  tooltip: 'Next',
                  onPressed: (page < pages && !loading)
                      ? () {
                          setState(() => page += 1);
                          _apply();
                        }
                      : null,
                  icon: const Icon(Icons.chevron_right),
                ),
              ],
            ),
          ),
        ],
      ),
    );
  }

  Widget _apptCard(BuildContext ctx, Map<String, dynamic> a) {
    final id = _apptId(a);

    final st = _start(a);
    final en = _end(a);

    final when = [
      if (st != null) dfFull.format(st.toLocal()),
      if (en != null) '→ ${dfFull.format(en.toLocal())}',
    ].join(' ');

    final status = _status(a);
    final pay = (a['payment_status'] ?? '').toString();

    final doctor = _doctorName(a);
    final patient = _patientName(a);

    return Card(
      margin: const EdgeInsets.symmetric(vertical: 6),
      shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(14)),
      child: InkWell(
        borderRadius: BorderRadius.circular(14),
        onTap: () {
          if (id > 0) {
            Navigator.of(context).push(
              MaterialPageRoute(
                  builder: (_) => AppointmentDetailPage(apptId: id)),
            );
          }
        },
        child: Padding(
          padding: const EdgeInsets.fromLTRB(12, 12, 12, 10),
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.stretch,
            children: [
              Text('Appointment #$id',
                  style: const TextStyle(fontWeight: FontWeight.w800)),
              const SizedBox(height: 4),
              Text(
                [
                  if (doctor.isNotEmpty) 'Doctor: $doctor',
                  if (patient.isNotEmpty) 'Patient: $patient',
                ].join(' • '),
                maxLines: 2,
                overflow: TextOverflow.ellipsis,
              ),
              if (when.isNotEmpty) ...[
                const SizedBox(height: 3),
                Text(when, maxLines: 2, overflow: TextOverflow.ellipsis),
              ],
              const SizedBox(height: 8),
              Wrap(
                spacing: 8,
                runSpacing: 8,
                children: [
                  _chip(status),
                  if (pay.isNotEmpty) _chip(pay, tone: 'info'),
                  TextButton.icon(
                    onPressed: id == 0
                        ? null
                        : () => Navigator.of(context).push(
                              MaterialPageRoute(
                                  builder: (_) =>
                                      AppointmentDetailPage(apptId: id)),
                            ),
                    icon: const Icon(Icons.open_in_new, size: 18),
                    label: const Text('Open'),
                  ),
                ],
              ),
            ],
          ),
        ),
      ),
    );
  }

  Widget _chip(String text, {String tone = 'ok'}) {
    Color bg, fg;
    final t = text.toLowerCase();

    switch (tone) {
      case 'info':
        bg = Colors.blue.withOpacity(.12);
        fg = Colors.blue.shade800;
        break;
      default:
        if (t.contains('requested') ||
            t.contains('pending') ||
            t.contains('unapproved')) {
          bg = Colors.orange.withOpacity(.16);
          fg = Colors.orange.shade900;
        } else if (t.contains('approved') || t.contains('paid')) {
          bg = Colors.green.withOpacity(.16);
          fg = Colors.green.shade800;
        } else if (t.contains('cancel') || t.contains('reject')) {
          bg = Colors.red.withOpacity(.16);
          fg = Colors.red.shade800;
        } else {
          bg = Colors.grey.withOpacity(.18);
          fg = Colors.grey.shade800;
        }
    }

    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 6),
      decoration:
          BoxDecoration(color: bg, borderRadius: BorderRadius.circular(24)),
      child: Text(text.isEmpty ? '—' : text,
          style: TextStyle(color: fg, fontWeight: FontWeight.w700)),
    );
  }
}

class _DayGroup {
  final DateTime day;
  final List<Map<String, dynamic>> items;
  _DayGroup({required this.day, required this.items});
}

/// ─────────────────────────── Admin Profile ───────────────────────────

class _AdminProfileTab extends StatefulWidget {
  const _AdminProfileTab({required this.me});
  final User me;

  @override
  State<_AdminProfileTab> createState() => _AdminProfileTabState();
}

class _AdminProfileTabState extends State<_AdminProfileTab> {
  final name = TextEditingController();
  final email = TextEditingController();
  final phone = TextEditingController();

  final oldPw = TextEditingController();
  final newPw = TextEditingController();

  bool savingInfo = false;
  bool changingPw = false;

  @override
  void initState() {
    super.initState();
    name.text = widget.me.name;
    if (widget.me.email != null) email.text = widget.me.email!;
    if (widget.me.phone != null) phone.text = widget.me.phone!;
  }

  @override
  void dispose() {
    name.dispose();
    email.dispose();
    phone.dispose();
    oldPw.dispose();
    newPw.dispose();
    super.dispose();
  }

  Future<void> _save() async {
    setState(() => savingInfo = true);
    try {
      await Api.patch('/me', data: {
        'name': name.text,
        'email': email.text.isEmpty ? null : email.text,
        'phone': phone.text.isEmpty ? null : phone.text,
      });
      if (mounted) showSnack(context, 'Profile updated');
    } catch (e) {
      if (mounted) showSnack(context, 'Update failed: $e');
    } finally {
      if (mounted) setState(() => savingInfo = false);
    }
  }

  Future<void> _changePw() async {
    if (oldPw.text.isEmpty || newPw.text.isEmpty) {
      showSnack(context, 'Provide current and new password');
      return;
    }
    setState(() => changingPw = true);
    try {
      await Api.post('/auth/change_password', data: {
        'old': oldPw.text,
        'new': newPw.text,
      });
      if (mounted) showSnack(context, 'Password changed');
      oldPw.clear();
      newPw.clear();
    } catch (e) {
      if (mounted) showSnack(context, 'Change failed: $e');
    } finally {
      if (mounted) setState(() => changingPw = false);
    }
  }

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    return SingleChildScrollView(
      padding: const EdgeInsets.all(16),
      child: Column(
        children: [
          Card(
            shape:
                RoundedRectangleBorder(borderRadius: BorderRadius.circular(16)),
            child: Padding(
              padding: const EdgeInsets.all(16),
              child: Row(
                children: [
                  CircleAvatar(
                    radius: 30,
                    child: Text(
                      widget.me.name.isNotEmpty
                          ? widget.me.name[0].toUpperCase()
                          : '?',
                      style: theme.textTheme.titleLarge
                          ?.copyWith(color: Colors.white),
                    ),
                  ),
                  const SizedBox(width: 16),
                  Expanded(
                    child:
                        Text(widget.me.name, style: theme.textTheme.titleLarge),
                  ),
                  FilledButton.icon(
                    onPressed: savingInfo ? null : _save,
                    icon: const Icon(Icons.save),
                    label: Text(savingInfo ? 'Saving…' : 'Save'),
                  ),
                ],
              ),
            ),
          ),
          const SizedBox(height: 12),
          _tf(name, 'Name'),
          const SizedBox(height: 10),
          _tf(email, 'Email (optional)'),
          const SizedBox(height: 10),
          _tf(phone, 'Phone (optional)'),
          const SizedBox(height: 24),
          Align(
            alignment: Alignment.centerLeft,
            child: Text('Security', style: theme.textTheme.titleMedium),
          ),
          const SizedBox(height: 10),
          _tf(oldPw, 'Current Password', obscure: true),
          const SizedBox(height: 10),
          _tf(newPw, 'New Password', obscure: true),
          const SizedBox(height: 8),
          Row(
            children: [
              FilledButton.icon(
                onPressed: changingPw ? null : _changePw,
                icon: const Icon(Icons.key),
                label: Text(changingPw ? 'Updating…' : 'Change Password'),
              ),
            ],
          ),
        ],
      ),
    );
  }

  Widget _tf(TextEditingController c, String label, {bool obscure = false}) {
    return TextField(
      controller: c,
      obscureText: obscure,
      decoration: const InputDecoration(
        border: OutlineInputBorder(),
      ).copyWith(labelText: label),
    );
  }
}

/// ─────────────────────────── Detail Pages ───────────────────────────

class DoctorDetailPage extends StatefulWidget {
  const DoctorDetailPage({super.key, required this.doctorId});
  final int doctorId;

  @override
  State<DoctorDetailPage> createState() => _DoctorDetailPageState();
}

class _DoctorDetailPageState extends State<DoctorDetailPage> {
  Map<String, dynamic>? m;
  bool loading = true;

  @override
  void initState() {
    super.initState();
    _load();
  }

  Future<void> _load() async {
    setState(() => loading = true);
    try {
      final r = await Api.get('/doctors/${widget.doctorId}');
      if (r is Map) m = Map<String, dynamic>.from(r);
    } catch (e) {
      if (mounted) showSnack(context, 'Load failed: $e');
    } finally {
      if (mounted) setState(() => loading = false);
    }
  }

  @override
  Widget build(BuildContext context) {
    final name = (m?['name'] ?? '').toString();
    final specialty = (m?['specialty'] ?? '').toString();
    final category = (m?['category'] ?? 'General').toString();
    final rating = (m?['rating'] ?? 5).toString();
    final email = (m?['email'] ?? '').toString();
    final phone = (m?['phone'] ?? '').toString();
    final bio = (m?['bio'] ?? '').toString();
    final bg = (m?['background'] ?? '').toString();

    return Scaffold(
      appBar:
          AppBar(title: Text(name.isNotEmpty ? name : 'Doctor #${widget.doctorId}')),
      body: loading
          ? const Center(child: CircularProgressIndicator())
          : ListView(
              padding: const EdgeInsets.fromLTRB(16, 16, 16, 24),
              children: [
                Row(
                  children: [
                    const CircleAvatar(
                        radius: 28, child: Icon(Icons.local_hospital)),
                    const SizedBox(width: 12),
                    Expanded(
                      child: Text(
                        name.isNotEmpty ? name : 'Doctor #${widget.doctorId}',
                        style: Theme.of(context).textTheme.titleLarge,
                      ),
                    ),
                  ],
                ),
                const SizedBox(height: 12),
                _kv('Specialty', specialty.isNotEmpty ? specialty : '—'),
                _kv('Category', category),
                _kv('Rating', rating),
                if (email.isNotEmpty) _kv('Email', email),
                if (phone.isNotEmpty) _kv('Phone', phone),
                if (bio.isNotEmpty) _kv('Bio', bio),
                if (bg.isNotEmpty) _kv('Background', bg),
                const SizedBox(height: 16),
                Wrap(
                  spacing: 12,
                  runSpacing: 12,
                  children: [
                    FilledButton.icon(
                      onPressed: () {
                        Navigator.of(context).push(
                          MaterialPageRoute(
                            builder: (_) => DoctorAvailabilityAndAppointmentsPage(
                              doctorId: widget.doctorId,
                              doctorName: name.isNotEmpty ? name : "Doctor #${widget.doctorId}",
                              visitingFee: null, // if you have fee put it here
                            ),
                          ),
                        );
                      },
                      icon: const Icon(Icons.event_available),
                      label: const Text('Availability & Appointments'),
                    ),

                  ],
                ),
              ],
            ),
    );
  }
}


// -----------------------------------------------------------------------------
// DoctorScheduleTimelineView
// - 7 day date window navigator (← / →)
// - Toggle: Availability / Appointments
// - Filter: All / Online / Offline
// - Appointment list cards like your screenshot
// -----------------------------------------------------------------------------

class DoctorScheduleTimelineView extends StatefulWidget {
  const DoctorScheduleTimelineView({
    super.key,
    required this.doctorId,
    required this.doctorName,
  });

  final int doctorId;
  final String doctorName;

  @override
  State<DoctorScheduleTimelineView> createState() =>
      _DoctorScheduleTimelineViewState();
}

class _DoctorScheduleTimelineViewState extends State<DoctorScheduleTimelineView> {
  final dfDay = DateFormat('MMM d, yyyy');
  final dfTime = DateFormat('h:mm a');

  // 7-day window
  late DateTime windowStart; // local date start
  late DateTime windowEnd; // local date end

  bool loading = false;

  // Tabs
  int tabIndex = 1; // 0 availability, 1 appointments (as screenshot)
  String modeFilter = 'all'; // all/online/offline

  // Appointments
  List<Map<String, dynamic>> appts = [];

  @override
  void initState() {
    super.initState();

    final now = DateTime.now();
    windowStart = DateTime(now.year, now.month, now.day);
    windowEnd = windowStart.add(const Duration(days: 6));

    _load();
  }

  DateTime? _parseDate(dynamic v) {
    if (v == null) return null;
    if (v is DateTime) return v;
    if (v is String) return DateTime.tryParse(v);
    if (v is int) {
      if (v < 10000000000) return DateTime.fromMillisecondsSinceEpoch(v * 1000);
      return DateTime.fromMillisecondsSinceEpoch(v);
    }
    if (v is double) {
      final n = v.toInt();
      if (n < 10000000000) return DateTime.fromMillisecondsSinceEpoch(n * 1000);
      return DateTime.fromMillisecondsSinceEpoch(n);
    }
    return null;
  }

  String _modeLabel(dynamic visitMode) {
    final m = (visitMode ?? '').toString().toLowerCase();
    if (m.contains('online')) return 'Online';
    return 'Offline';
  }

  IconData _modeIcon(dynamic visitMode) {
    final m = (visitMode ?? '').toString().toLowerCase();
    if (m.contains('online')) return Icons.wifi;
    return Icons.store_mall_directory_outlined;
  }

  Color _chipBg(String t) {
    final s = t.toLowerCase();
    if (s.contains('requested') || s.contains('pending')) return Colors.green.withOpacity(.12);
    if (s.contains('approved') || s.contains('paid')) return Colors.green.withOpacity(.12);
    if (s.contains('cancel') || s.contains('reject')) return Colors.red.withOpacity(.12);
    return Colors.grey.withOpacity(.15);
  }

  Color _chipFg(String t) {
    final s = t.toLowerCase();
    if (s.contains('requested') || s.contains('pending')) return Colors.green.shade900;
    if (s.contains('approved') || s.contains('paid')) return Colors.green.shade900;
    if (s.contains('cancel') || s.contains('reject')) return Colors.red.shade800;
    return Colors.grey.shade900;
  }

  Widget _pill(String text, {Color? bg, Color? fg, IconData? icon}) {
    final b = bg ?? Colors.grey.withOpacity(.15);
    final f = fg ?? Colors.grey.shade900;
    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 6),
      decoration: BoxDecoration(
        color: b,
        borderRadius: BorderRadius.circular(20),
      ),
      child: Row(
        mainAxisSize: MainAxisSize.min,
        children: [
          if (icon != null) ...[
            Icon(icon, size: 15, color: f),
            const SizedBox(width: 6),
          ],
          Text(
            text,
            style: TextStyle(fontWeight: FontWeight.w700, color: f, fontSize: 12),
          ),
        ],
      ),
    );
  }

  Future<void> _load() async {
    setState(() => loading = true);

    try {
      // Load appointments from admin endpoint then filter for this doctor + date range
      final res = await Api.get('/admin/appointments');
      final list = (res as List).map((e) => Map<String, dynamic>.from(e as Map)).toList();

      final start = DateTime(windowStart.year, windowStart.month, windowStart.day);
      final end = DateTime(windowEnd.year, windowEnd.month, windowEnd.day, 23, 59, 59);

      final filtered = list.where((a) {
        final did = a['doctor_id'] ?? a['doctorId'];
        final docId = (did is num) ? did.toInt() : int.tryParse('$did') ?? -1;
        if (docId != widget.doctorId) return false;

        final st = _parseDate(a['start_time']);
        if (st == null) return false;

        final local = st.toLocal();
        if (local.isBefore(start) || local.isAfter(end)) return false;

        // mode filter
        final vm = (a['visit_mode'] ?? a['visitMode'] ?? '').toString().toLowerCase();
        if (modeFilter == 'online' && !vm.contains('online')) return false;
        if (modeFilter == 'offline' && vm.contains('online')) return false;

        return true;
      }).toList();

      // sort by start time ascending (like a timeline)
      filtered.sort((a, b) {
        final sa = _parseDate(a['start_time']) ?? DateTime.fromMillisecondsSinceEpoch(0);
        final sb = _parseDate(b['start_time']) ?? DateTime.fromMillisecondsSinceEpoch(0);
        return sa.compareTo(sb);
      });

      appts = filtered;
    } catch (e) {
      appts = [];
      if (mounted) showSnack(context, 'Load failed: $e');
    } finally {
      if (mounted) setState(() => loading = false);
    }
  }

  void _shiftWindow(int days) {
    setState(() {
      windowStart = windowStart.add(Duration(days: days));
      windowEnd = windowStart.add(const Duration(days: 6));
    });
    _load();
  }

  @override
  Widget build(BuildContext context) {
    final rangeLabel = '${dfDay.format(windowStart)}  →  ${dfDay.format(windowEnd)}';

    return Column(
      children: [
        // HEADER BAR (range + arrows)
        Padding(
          padding: const EdgeInsets.fromLTRB(10, 6, 10, 6),
          child: Row(
            children: [
              IconButton(
                tooltip: 'Previous',
                onPressed: loading ? null : () => _shiftWindow(-7),
                icon: const Icon(Icons.chevron_left),
              ),
              Expanded(
                child: Center(
                  child: Text(
                    rangeLabel,
                    style: const TextStyle(fontWeight: FontWeight.w800),
                  ),
                ),
              ),
              IconButton(
                tooltip: 'Next',
                onPressed: loading ? null : () => _shiftWindow(7),
                icon: const Icon(Icons.chevron_right),
              ),
            ],
          ),
        ),

        // TAB SWITCH: Availability / Appointments
        Padding(
          padding: const EdgeInsets.only(bottom: 8),
          child: SegmentedButton<int>(
            segments: const [
              ButtonSegment(value: 0, label: Text('Availability'), icon: Icon(Icons.calendar_today)),
              ButtonSegment(value: 1, label: Text('Appointments'), icon: Icon(Icons.check_circle)),
            ],
            selected: {tabIndex},
            onSelectionChanged: (s) {
              setState(() => tabIndex = s.first);
              // if you later load availability, call _loadAvailability()
            },
          ),
        ),

        // MODE FILTER (All / Online / Offline)
        Padding(
          padding: const EdgeInsets.only(bottom: 10),
          child: SegmentedButton<String>(
            segments: const [
              ButtonSegment(value: 'all', label: Text('All')),
              ButtonSegment(value: 'online', label: Text('Online')),
              ButtonSegment(value: 'offline', label: Text('Offline')),
            ],
            selected: {modeFilter},
            onSelectionChanged: (s) {
              setState(() => modeFilter = s.first);
              _load();
            },
          ),
        ),

        if (loading) const LinearProgressIndicator(),

        Expanded(
          child: tabIndex == 0
              ? _availabilityPlaceholder()
              : _appointmentsList(),
        ),
      ],
    );
  }

  Widget _availabilityPlaceholder() {
    // You already have availability screen logic.
    // This placeholder is here because you asked ONLY for this appointment feature view.
    return ListView(
      padding: const EdgeInsets.fromLTRB(12, 8, 12, 12),
      children: const [
        SizedBox(height: 40),
        Center(
          child: Text(
            'Availability view can be shown here (your existing availability UI).',
            style: TextStyle(fontWeight: FontWeight.w600),
          ),
        ),
      ],
    );
  }

  Widget _appointmentsList() {
    if (!loading && appts.isEmpty) {
      return ListView(
        padding: const EdgeInsets.all(20),
        children: const [
          SizedBox(height: 120),
          Center(child: Text('No appointments found')),
        ],
      );
    }

    return ListView.builder(
      padding: const EdgeInsets.fromLTRB(12, 6, 12, 12),
      itemCount: appts.length,
      itemBuilder: (ctx, i) {
        final a = appts[i];

        final idDyn = a['id'];
        final apptId = (idDyn is num) ? idDyn.toInt() : int.tryParse('$idDyn') ?? 0;

        final st = _parseDate(a['start_time'])?.toLocal();
        final en = _parseDate(a['end_time'])?.toLocal();

        final when = [
          if (st != null) '${dfDay.format(st)} ${dfTime.format(st)}',
          if (en != null) '→ ${dfDay.format(en)} ${dfTime.format(en)}',
        ].join('  ');

        final status = (a['status'] ?? '').toString();
        final payment = (a['payment_status'] ?? '').toString();
        final mode = _modeLabel(a['visit_mode'] ?? a['visitMode']);
        final modeIcon = _modeIcon(a['visit_mode'] ?? a['visitMode']);

        return Card(
          elevation: 0,
          color: Colors.grey.withOpacity(.06),
          margin: const EdgeInsets.symmetric(vertical: 6),
          shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(14)),
          child: InkWell(
            borderRadius: BorderRadius.circular(14),
            onTap: apptId <= 0
                ? null
                : () {
                    Navigator.of(context).push(
                      MaterialPageRoute(builder: (_) => AppointmentDetailPage(apptId: apptId)),
                    );
                  },
            child: Padding(
              padding: const EdgeInsets.fromLTRB(12, 10, 12, 10),
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Text(
                    'Appointment #$apptId',
                    style: const TextStyle(fontWeight: FontWeight.w800),
                  ),
                  const SizedBox(height: 4),
                  Text(
                    when,
                    style: TextStyle(color: Colors.grey.shade800),
                  ),
                  const SizedBox(height: 10),
                  Wrap(
                    spacing: 10,
                    runSpacing: 10,
                    children: [
                      _pill(mode, icon: modeIcon),
                      _pill('Status: $status',
                          bg: _chipBg(status), fg: _chipFg(status)),
                      _pill('Payment: $payment',
                          bg: Colors.blue.withOpacity(.12),
                          fg: Colors.blue.shade800),
                    ],
                  ),
                ],
              ),
            ),
          ),
        );
      },
    );
  }
}
class DoctorAvailabilityAndAppointmentsPage extends StatefulWidget {
  const DoctorAvailabilityAndAppointmentsPage({
    super.key,
    required this.doctorId,
    required this.doctorName,
    this.visitingFee,
  });

  final int doctorId;
  final String doctorName;
  final double? visitingFee;

  @override
  State<DoctorAvailabilityAndAppointmentsPage> createState() =>
      _DoctorAvailabilityAndAppointmentsPageState();
}

class _DoctorAvailabilityAndAppointmentsPageState
    extends State<DoctorAvailabilityAndAppointmentsPage> {
  int tabIndex = 0; // 0 availability, 1 appointments

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: AppBar(
        title: Text("Dr. ${widget.doctorName}"),
      ),
      body: Column(
        children: [
          const SizedBox(height: 10),

          //    toggle
          Padding(
            padding: const EdgeInsets.symmetric(horizontal: 12),
            child: SegmentedButton<int>(
              segments: const [
                ButtonSegment(
                  value: 0,
                  icon: Icon(Icons.calendar_today),
                  label: Text("Availability"),
                ),
                ButtonSegment(
                  value: 1,
                  icon: Icon(Icons.check_circle),
                  label: Text("Appointments"),
                ),
              ],
              selected: {tabIndex},
              onSelectionChanged: (s) => setState(() => tabIndex = s.first),
            ),
          ),

          const SizedBox(height: 10),

          //    ONLY ONE Expanded
          Expanded(
            child: tabIndex == 0
                ? DoctorAvailabilityBody(
                    doctorId: widget.doctorId,
                    doctorName: widget.doctorName,
                    visitingFee: widget.visitingFee,
                  )
                : DoctorScheduleAppointmentsBody(
                    doctorId: widget.doctorId,
                    doctorName: widget.doctorName,
                  ),
          ),
        ],
      ),
    );
  }
}


/// ─────────────────────────── TOP-LEVEL typed slot model (FIX) ───────────────────────────


String _modeOf(dynamic row) {
  final m = (row is Map) ? row : <String, dynamic>{};
  final s = (m['visit_mode'] ?? m['mode'] ?? m['type'] ?? '')
      .toString()
      .toLowerCase()
      .trim();
  if (s.contains('on')) return 'online';
  if (s.contains('off')) return 'offline';
  return s.isEmpty ? 'unknown' : s;
}

IconData _modeIcon(String mode) {
  switch (mode) {
    case 'online':
      return Icons.wifi;
    case 'offline':
      return Icons.local_hospital;
    default:
      return Icons.help_outline;
  }
}

String _modeLabel(String mode) {
  switch (mode) {
    case 'online':
      return 'Online';
    case 'offline':
      return 'Offline';
    default:
      return '—';
  }
}

DateTime? _parseBlockTime(String raw, DateTime day) {
  final v = raw.trim();
  if (v.isEmpty) return null;

  // ISO date-time
  final iso = DateTime.tryParse(v);
  if (iso != null) return iso.toLocal();

  // HH:mm
  final m = RegExp(r'^(\d{1,2}):(\d{2})$').firstMatch(v);
  if (m != null) {
    final h = int.tryParse(m.group(1)!) ?? 0;
    final min = int.tryParse(m.group(2)!) ?? 0;
    return DateTime(day.year, day.month, day.day, h, min).toLocal();
  }

  return null;
}

// ===================== DoctorAvailabilityPage + CreateAppointmentPage =====================

class DoctorAvailabilityPage extends StatefulWidget {
  final int doctorId;
  final String doctorName;
  final double? visitingFee;

  const DoctorAvailabilityPage({
    super.key,
    required this.doctorId,
    required this.doctorName,
    this.visitingFee,
  });

  @override
  State<DoctorAvailabilityPage> createState() => _DoctorAvailabilityPageState();
}

class _DoctorAvailabilityPageState extends State<DoctorAvailabilityPage> {
  bool loading = false;

  // 7-day window start
  DateTime weekStart = DateTime.now();

  // filter: all / online / offline
  String modeFilter = "all";

  // Map<dayKey, blocks>
  final Map<String, List<Map<String, dynamic>>> blocksByDay = {};

  @override
  void initState() {
    super.initState();
    weekStart = DateTime(DateTime.now().year, DateTime.now().month, DateTime.now().day);
    _loadWeek();
  }

  String _dayKey(DateTime d) =>
      "${d.year.toString().padLeft(4, '0')}-${d.month.toString().padLeft(2, '0')}-${d.day.toString().padLeft(2, '0')}";

  List<DateTime> _daysOfWeek() {
    return List.generate(7, (i) {
      final d = weekStart.add(Duration(days: i));
      return DateTime(d.year, d.month, d.day);
    });
  }

  Future<void> _loadWeek() async {
    setState(() {
      loading = true;
      blocksByDay.clear();
    });

    final days = _daysOfWeek();

    try {
      // Load each day blocks
      for (final d in days) {
        final key = _dayKey(d);

        // If filter is "all", load both modes and merge.
        if (modeFilter == "all") {
          final online = await _fetchBlocksForDay(key, "online");
          final offline = await _fetchBlocksForDay(key, "offline");
          final merged = [...online, ...offline];

          // sort by start
          merged.sort((a, b) {
            final sa = DateTime.tryParse("${a["start"]}") ?? DateTime(1970);
            final sb = DateTime.tryParse("${b["start"]}") ?? DateTime(1970);
            return sa.compareTo(sb);
          });

          blocksByDay[key] = merged;
        } else {
          final list = await _fetchBlocksForDay(key, modeFilter);
          blocksByDay[key] = list;
        }
      }
    } catch (e) {
      if (mounted) showSnack(context, "Failed to load availability: $e");
    }

    if (mounted) {
      setState(() => loading = false);
    }
  }

  Future<List<Map<String, dynamic>>> _fetchBlocksForDay(String dayKey, String visitMode) async {
    final res = await Api.get(
      "/doctors/${widget.doctorId}/blocks",
      query: {
        "day": dayKey,
        "visit_mode": visitMode,
      },
    );

    if (res is List) {
      // Each block expected: { "start": "...", "end": "...", ... }
      // We'll inject mode into each row so UI can show it
      return res.map((e) {
        final m = Map<String, dynamic>.from(e as Map);
        m["_mode"] = visitMode;
        return m;
      }).toList();
    }
    return [];
  }

  void _prevWeek() {
    setState(() {
      weekStart = weekStart.subtract(const Duration(days: 7));
    });
    _loadWeek();
  }

  void _nextWeek() {
    setState(() {
      weekStart = weekStart.add(const Duration(days: 7));
    });
    _loadWeek();
  }

  String _fmtDayHeader(DateTime d) {
    return DateFormat("EEE, MMM d").format(d);
  }

  String _fmtTimeRange(DateTime start, DateTime end) {
    return "${DateFormat("h:mm a").format(start)} → ${DateFormat("h:mm a").format(end)}";
  }

  IconData _modeIcon(String mode) {
    if (mode == "online") return Icons.wifi;
    if (mode == "offline") return Icons.local_hospital;
    return Icons.help_outline;
  }

  String _modeLabel(String mode) {
    if (mode == "online") return "Online";
    if (mode == "offline") return "Offline";
    return "—";
  }

  @override
  Widget build(BuildContext context) {
    final days = _daysOfWeek();

    return Scaffold(
      appBar: AppBar(
        title: Text("Dr. ${widget.doctorName}"),
        actions: [
          IconButton(
            tooltip: "Refresh",
            onPressed: _loadWeek,
            icon: const Icon(Icons.refresh),
          ),
        ],
      ),
      body: Column(
        children: [
          // header controls
          Padding(
            padding: const EdgeInsets.fromLTRB(12, 12, 12, 8),
            child: Row(
              children: [
                IconButton(
                  tooltip: "Previous 7 days",
                  onPressed: loading ? null : _prevWeek,
                  icon: const Icon(Icons.chevron_left),
                ),
                Expanded(
                  child: Text(
                    "${DateFormat.yMMMd().format(days.first)}  →  ${DateFormat.yMMMd().format(days.last)}",
                    textAlign: TextAlign.center,
                    style: const TextStyle(fontWeight: FontWeight.w700),
                  ),
                ),
                IconButton(
                  tooltip: "Next 7 days",
                  onPressed: loading ? null : _nextWeek,
                  icon: const Icon(Icons.chevron_right),
                ),
              ],
            ),
          ),

          Padding(
            padding: const EdgeInsets.fromLTRB(12, 0, 12, 10),
            child: Row(
              children: [
                Expanded(
                  child: DropdownButtonFormField<String>(
                    value: modeFilter,
                    decoration: const InputDecoration(
                      labelText: "Filter",
                      border: OutlineInputBorder(),
                      isDense: true,
                    ),
                    items: const [
                      DropdownMenuItem(value: "all", child: Text("All")),
                      DropdownMenuItem(value: "online", child: Text("Online")),
                      DropdownMenuItem(value: "offline", child: Text("Offline")),
                    ],
                    onChanged: loading
                        ? null
                        : (v) {
                            if (v == null) return;
                            setState(() => modeFilter = v);
                            _loadWeek();
                          },
                  ),
                ),
              ],
            ),
          ),

          if (loading) const LinearProgressIndicator(),

          Expanded(
            child: ListView.builder(
              padding: const EdgeInsets.fromLTRB(12, 10, 12, 16),
              itemCount: days.length,
              itemBuilder: (context, i) {
                final d = days[i];
                final key = _dayKey(d);
                final blocks = blocksByDay[key] ?? [];

                return Card(
                  margin: const EdgeInsets.only(bottom: 12),
                  shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(14)),
                  child: Padding(
                    padding: const EdgeInsets.fromLTRB(12, 12, 12, 12),
                    child: Column(
                      crossAxisAlignment: CrossAxisAlignment.start,
                      children: [
                        Row(
                          children: [
                            Text(
                              _fmtDayHeader(d),
                              style: const TextStyle(fontWeight: FontWeight.w800, fontSize: 16),
                            ),
                            const Spacer(),
                            Text(
                              "${blocks.length} slots",
                              style: TextStyle(color: Colors.grey.shade700, fontWeight: FontWeight.w600),
                            ),
                          ],
                        ),
                        const SizedBox(height: 10),

                        if (blocks.isEmpty)
                          Padding(
                            padding: const EdgeInsets.symmetric(vertical: 10),
                            child: Text(
                              "No available blocks",
                              style: TextStyle(color: Colors.grey.shade600),
                            ),
                          )
                        else
                          ...blocks.map((b) {
                            final start = DateTime.tryParse("${b["start"]}")?.toLocal();
                            final end = DateTime.tryParse("${b["end"]}")?.toLocal();
                            final mode = (b["_mode"] ?? b["visit_mode"] ?? "offline").toString().toLowerCase();

                            if (start == null || end == null) return const SizedBox.shrink();

                            return ListTile(
                              contentPadding: EdgeInsets.zero,
                              leading: CircleAvatar(
                                child: Icon(_modeIcon(mode)),
                              ),
                              title: Text(
                                _fmtTimeRange(start, end),
                                style: const TextStyle(fontWeight: FontWeight.w700),
                              ),
                              subtitle: Text("Mode: ${_modeLabel(mode)}"),
                              trailing: const Icon(Icons.arrow_forward_ios, size: 16),
                              onTap: () async {
                                // Navigate to create appointment with LOCKED mode
                                final ok = await Navigator.push<bool>(
                                  context,
                                  MaterialPageRoute(
                                    builder: (_) => CreateAppointmentPage(
                                      doctorId: widget.doctorId,
                                      doctorName: widget.doctorName,
                                      visitingFee: widget.visitingFee,
                                      startTime: start,
                                      endTime: end,
                                      visitModeLocked: mode, // 🔒 locked
                                    ),
                                  ),
                                );

                                // Refresh if created
                                if (ok == true && mounted) {
                                  _loadWeek();
                                }
                              },
                            );
                          }).toList(),
                      ],
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
class DoctorAvailabilityBody extends StatefulWidget {
  final int doctorId;
  final String doctorName;
  final double? visitingFee;

  const DoctorAvailabilityBody({
    super.key,
    required this.doctorId,
    required this.doctorName,
    this.visitingFee,
  });

  @override
  State<DoctorAvailabilityBody> createState() => _DoctorAvailabilityBodyState();
}

class _DoctorAvailabilityBodyState extends State<DoctorAvailabilityBody> {
  bool loading = false;

  DateTime weekStart = DateTime.now();
  String modeFilter = "all";

  final Map<String, List<Map<String, dynamic>>> blocksByDay = {};

  @override
  void initState() {
    super.initState();
    weekStart = DateTime(DateTime.now().year, DateTime.now().month, DateTime.now().day);
    _loadWeek();
  }

  String _dayKey(DateTime d) =>
      "${d.year.toString().padLeft(4, '0')}-${d.month.toString().padLeft(2, '0')}-${d.day.toString().padLeft(2, '0')}";

  List<DateTime> _daysOfWeek() {
    return List.generate(7, (i) {
      final d = weekStart.add(Duration(days: i));
      return DateTime(d.year, d.month, d.day);
    });
  }

  Future<void> _loadWeek() async {
    setState(() {
      loading = true;
      blocksByDay.clear();
    });

    final days = _daysOfWeek();

    try {
      for (final d in days) {
        final key = _dayKey(d);

        if (modeFilter == "all") {
          final online = await _fetchBlocksForDay(key, "online");
          final offline = await _fetchBlocksForDay(key, "offline");
          final merged = [...online, ...offline];

          merged.sort((a, b) {
            final sa = DateTime.tryParse("${a["start"]}") ?? DateTime(1970);
            final sb = DateTime.tryParse("${b["start"]}") ?? DateTime(1970);
            return sa.compareTo(sb);
          });

          blocksByDay[key] = merged;
        } else {
          blocksByDay[key] = await _fetchBlocksForDay(key, modeFilter);
        }
      }
    } catch (e) {
      if (mounted) showSnack(context, "Failed to load availability: $e");
    }

    if (mounted) setState(() => loading = false);
  }

  Future<List<Map<String, dynamic>>> _fetchBlocksForDay(String dayKey, String visitMode) async {
    final res = await Api.get(
      "/doctors/${widget.doctorId}/blocks",
      query: {"day": dayKey, "visit_mode": visitMode},
    );

    if (res is List) {
      return res.map((e) {
        final m = Map<String, dynamic>.from(e as Map);
        m["_mode"] = visitMode;
        return m;
      }).toList();
    }
    return [];
  }

  void _prevWeek() {
    setState(() => weekStart = weekStart.subtract(const Duration(days: 7)));
    _loadWeek();
  }

  void _nextWeek() {
    setState(() => weekStart = weekStart.add(const Duration(days: 7)));
    _loadWeek();
  }

  String _fmtDayHeader(DateTime d) => DateFormat("EEE, MMM d").format(d);

  String _fmtTimeRange(DateTime start, DateTime end) =>
      "${DateFormat("h:mm a").format(start)} → ${DateFormat("h:mm a").format(end)}";

  IconData _modeIcon(String mode) {
    if (mode == "online") return Icons.wifi;
    if (mode == "offline") return Icons.local_hospital;
    return Icons.help_outline;
  }

  String _modeLabel(String mode) {
    if (mode == "online") return "Online";
    if (mode == "offline") return "Offline";
    return "—";
  }

  @override
  Widget build(BuildContext context) {
    final days = _daysOfWeek();

    return Column(
      children: [
        Padding(
          padding: const EdgeInsets.fromLTRB(12, 12, 12, 8),
          child: Row(
            children: [
              IconButton(
                tooltip: "Previous 7 days",
                onPressed: loading ? null : _prevWeek,
                icon: const Icon(Icons.chevron_left),
              ),
              Expanded(
                child: Text(
                  "${DateFormat.yMMMd().format(days.first)}  →  ${DateFormat.yMMMd().format(days.last)}",
                  textAlign: TextAlign.center,
                  style: const TextStyle(fontWeight: FontWeight.w700),
                ),
              ),
              IconButton(
                tooltip: "Next 7 days",
                onPressed: loading ? null : _nextWeek,
                icon: const Icon(Icons.chevron_right),
              ),
            ],
          ),
        ),

        Padding(
          padding: const EdgeInsets.fromLTRB(12, 0, 12, 10),
          child: DropdownButtonFormField<String>(
            value: modeFilter,
            decoration: const InputDecoration(
              labelText: "Filter",
              border: OutlineInputBorder(),
              isDense: true,
            ),
            items: const [
              DropdownMenuItem(value: "all", child: Text("All")),
              DropdownMenuItem(value: "online", child: Text("Online")),
              DropdownMenuItem(value: "offline", child: Text("Offline")),
            ],
            onChanged: loading
                ? null
                : (v) {
                    if (v == null) return;
                    setState(() => modeFilter = v);
                    _loadWeek();
                  },
          ),
        ),

        if (loading) const LinearProgressIndicator(),

        Expanded(
          child: ListView.builder(
            padding: const EdgeInsets.fromLTRB(12, 10, 12, 16),
            itemCount: days.length,
            itemBuilder: (context, i) {
              final d = days[i];
              final key = _dayKey(d);
              final blocks = blocksByDay[key] ?? [];

              return Card(
                margin: const EdgeInsets.only(bottom: 12),
                shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(14)),
                child: Padding(
                  padding: const EdgeInsets.fromLTRB(12, 12, 12, 12),
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      Row(
                        children: [
                          Text(
                            _fmtDayHeader(d),
                            style: const TextStyle(fontWeight: FontWeight.w800, fontSize: 16),
                          ),
                          const Spacer(),
                          Text(
                            "${blocks.length} slots",
                            style: TextStyle(
                              color: Colors.grey.shade700,
                              fontWeight: FontWeight.w600,
                            ),
                          ),
                        ],
                      ),
                      const SizedBox(height: 10),

                      if (blocks.isEmpty)
                        Padding(
                          padding: const EdgeInsets.symmetric(vertical: 10),
                          child: Text(
                            "No available blocks",
                            style: TextStyle(color: Colors.grey.shade600),
                          ),
                        )
                      else
                        ...blocks.map((b) {
                          final start = DateTime.tryParse("${b["start"]}")?.toLocal();
                          final end = DateTime.tryParse("${b["end"]}")?.toLocal();
                          final mode = (b["_mode"] ?? b["visit_mode"] ?? "offline")
                              .toString()
                              .toLowerCase();

                          if (start == null || end == null) return const SizedBox.shrink();

                          return ListTile(
                            contentPadding: EdgeInsets.zero,
                            leading: CircleAvatar(child: Icon(_modeIcon(mode))),
                            title: Text(
                              _fmtTimeRange(start, end),
                              style: const TextStyle(fontWeight: FontWeight.w700),
                            ),
                            subtitle: Text("Mode: ${_modeLabel(mode)}"),
                            trailing: const Icon(Icons.arrow_forward_ios, size: 16),
                            onTap: () async {
                              final ok = await Navigator.push<bool>(
                                context,
                                MaterialPageRoute(
                                  builder: (_) => CreateAppointmentPage(
                                    doctorId: widget.doctorId,
                                    doctorName: widget.doctorName,
                                    visitingFee: widget.visitingFee,
                                    startTime: start,
                                    endTime: end,
                                    visitModeLocked: mode,
                                  ),
                                ),
                              );

                              if (ok == true && mounted) _loadWeek();
                            },
                          );
                        }).toList(),
                    ],
                  ),
                ),
              );
            },
          ),
        ),
      ],
    );
  }
}

class DoctorScheduleAppointmentsBody extends StatefulWidget {
  const DoctorScheduleAppointmentsBody({
    super.key,
    required this.doctorId,
    required this.doctorName,
  });

  final int doctorId;
  final String doctorName;

  @override
  State<DoctorScheduleAppointmentsBody> createState() =>
      _DoctorScheduleAppointmentsBodyState();
}

class _DoctorScheduleAppointmentsBodyState
    extends State<DoctorScheduleAppointmentsBody> {
  final dfDay = DateFormat('MMM d, yyyy');
  final dfTime = DateFormat('h:mm a');

  // 7-day window
  late DateTime windowStart;
  late DateTime windowEnd;

  bool loading = false;

  // filter: all/online/offline
  String modeFilter = 'all';

  // appointments
  List<Map<String, dynamic>> appts = [];

  @override
  void initState() {
    super.initState();
    final now = DateTime.now();
    windowStart = DateTime(now.year, now.month, now.day);
    windowEnd = windowStart.add(const Duration(days: 6));
    _load();
  }

  DateTime? _parseDate(dynamic v) {
    if (v == null) return null;
    if (v is DateTime) return v;
    if (v is String) return DateTime.tryParse(v);
    if (v is int) {
      if (v < 10000000000) return DateTime.fromMillisecondsSinceEpoch(v * 1000);
      return DateTime.fromMillisecondsSinceEpoch(v);
    }
    if (v is double) {
      final n = v.toInt();
      if (n < 10000000000) return DateTime.fromMillisecondsSinceEpoch(n * 1000);
      return DateTime.fromMillisecondsSinceEpoch(n);
    }
    return null;
  }

  int _apptId(Map<String, dynamic> a) {
    final idDyn = a['id'];
    return (idDyn is num) ? idDyn.toInt() : int.tryParse('$idDyn') ?? 0;
  }

  String _modeOf(Map<String, dynamic> a) {
    final vm = (a['visit_mode'] ?? a['visitMode'] ?? a['mode'] ?? '')
        .toString()
        .toLowerCase()
        .trim();
    if (vm.contains('online')) return 'online';
    if (vm.contains('offline')) return 'offline';
    return vm.isEmpty ? 'unknown' : vm;
  }

  IconData _modeIcon(String mode) {
    switch (mode) {
      case 'online':
        return Icons.wifi;
      case 'offline':
        return Icons.local_hospital;
      default:
        return Icons.help_outline;
    }
  }

  String _modeLabel(String mode) {
    switch (mode) {
      case 'online':
        return 'Online';
      case 'offline':
        return 'Offline';
      default:
        return '—';
    }
  }

  Color _chipBg(String t, {String tone = 'status'}) {
    final s = t.toLowerCase();
    if (tone == 'pay') return Colors.blue.withOpacity(.12);

    if (s.contains('requested') || s.contains('pending') || s.contains('unapproved')) {
      return Colors.orange.withOpacity(.18);
    }
    if (s.contains('approved') || s.contains('paid')) {
      return Colors.green.withOpacity(.16);
    }
    if (s.contains('cancel') || s.contains('reject')) {
      return Colors.red.withOpacity(.16);
    }
    return Colors.grey.withOpacity(.18);
  }

  Color _chipFg(String t, {String tone = 'status'}) {
    final s = t.toLowerCase();
    if (tone == 'pay') return Colors.blue.shade800;

    if (s.contains('requested') || s.contains('pending') || s.contains('unapproved')) {
      return Colors.orange.shade900;
    }
    if (s.contains('approved') || s.contains('paid')) {
      return Colors.green.shade800;
    }
    if (s.contains('cancel') || s.contains('reject')) {
      return Colors.red.shade800;
    }
    return Colors.grey.shade800;
  }

  Widget _pill(String text, {Color? bg, Color? fg, IconData? icon}) {
    final b = bg ?? Colors.grey.withOpacity(.15);
    final f = fg ?? Colors.grey.shade900;

    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 6),
      decoration: BoxDecoration(
        color: b,
        borderRadius: BorderRadius.circular(20),
      ),
      child: Row(
        mainAxisSize: MainAxisSize.min,
        children: [
          if (icon != null) ...[
            Icon(icon, size: 15, color: f),
            const SizedBox(width: 6),
          ],
          Text(
            text,
            style: TextStyle(
              fontWeight: FontWeight.w700,
              color: f,
              fontSize: 12,
            ),
          ),
        ],
      ),
    );
  }

  Future<void> _load() async {
    setState(() => loading = true);

    try {
      final res = await Api.get('/admin/appointments');
      final list = (res as List)
          .map((e) => Map<String, dynamic>.from(e as Map))
          .toList();

      final start = DateTime(windowStart.year, windowStart.month, windowStart.day);
      final end = DateTime(windowEnd.year, windowEnd.month, windowEnd.day, 23, 59, 59);

      final filtered = list.where((a) {
        // doctor id match
        final did = a['doctor_id'] ?? a['doctorId'];
        final docId = (did is num) ? did.toInt() : int.tryParse('$did') ?? -1;
        if (docId != widget.doctorId) return false;

        // date window match
        final st = _parseDate(a['start_time']);
        if (st == null) return false;

        final local = st.toLocal();
        if (local.isBefore(start) || local.isAfter(end)) return false;

        // mode filter match
        final mode = _modeOf(a);
        if (modeFilter == 'online' && mode != 'online') return false;
        if (modeFilter == 'offline' && mode != 'offline') return false;

        return true;
      }).toList();

      // sort by start asc (timeline)
      filtered.sort((a, b) {
        final sa = _parseDate(a['start_time']) ?? DateTime.fromMillisecondsSinceEpoch(0);
        final sb = _parseDate(b['start_time']) ?? DateTime.fromMillisecondsSinceEpoch(0);
        return sa.compareTo(sb);
      });

      appts = filtered;
    } catch (e) {
      appts = [];
      if (mounted) showSnack(context, 'Load failed: $e');
    } finally {
      if (mounted) setState(() => loading = false);
    }
  }

  void _shiftWindow(int days) {
    setState(() {
      windowStart = windowStart.add(Duration(days: days));
      windowEnd = windowStart.add(const Duration(days: 6));
    });
    _load();
  }

  @override
  Widget build(BuildContext context) {
    final rangeLabel =
        '${dfDay.format(windowStart)}  →  ${dfDay.format(windowEnd)}';

    return Column(
      children: [
        // HEADER BAR (range + arrows)
        Padding(
          padding: const EdgeInsets.fromLTRB(10, 6, 10, 6),
          child: Row(
            children: [
              IconButton(
                tooltip: 'Previous',
                onPressed: loading ? null : () => _shiftWindow(-7),
                icon: const Icon(Icons.chevron_left),
              ),
              Expanded(
                child: Center(
                  child: Text(
                    rangeLabel,
                    style: const TextStyle(fontWeight: FontWeight.w800),
                  ),
                ),
              ),
              IconButton(
                tooltip: 'Next',
                onPressed: loading ? null : () => _shiftWindow(7),
                icon: const Icon(Icons.chevron_right),
              ),
            ],
          ),
        ),

        // MODE FILTER (All / Online / Offline)
        Padding(
          padding: const EdgeInsets.only(bottom: 10),
          child: SegmentedButton<String>(
            segments: const [
              ButtonSegment(value: 'all', label: Text('All')),
              ButtonSegment(value: 'online', label: Text('Online')),
              ButtonSegment(value: 'offline', label: Text('Offline')),
            ],
            selected: {modeFilter},
            onSelectionChanged: (s) {
              setState(() => modeFilter = s.first);
              _load();
            },
          ),
        ),

        if (loading) const LinearProgressIndicator(),

        Expanded(
          child: (!loading && appts.isEmpty)
              ? ListView(
                  padding: const EdgeInsets.all(20),
                  children: const [
                    SizedBox(height: 120),
                    Center(child: Text('No appointments found')),
                  ],
                )
              : ListView.builder(
                  padding: const EdgeInsets.fromLTRB(12, 6, 12, 12),
                  itemCount: appts.length,
                  itemBuilder: (ctx, i) {
                    final a = appts[i];

                    final apptId = _apptId(a);
                    final st = _parseDate(a['start_time'])?.toLocal();
                    final en = _parseDate(a['end_time'])?.toLocal();

                    final when = [
                      if (st != null) '${dfDay.format(st)} ${dfTime.format(st)}',
                      if (en != null) '→ ${dfDay.format(en)} ${dfTime.format(en)}',
                    ].join('  ');

                    final status = (a['status'] ?? '').toString();
                    final payment = (a['payment_status'] ?? '').toString();
                    final mode = _modeOf(a);

                    return Card(
                      elevation: 0,
                      color: Colors.grey.withOpacity(.06),
                      margin: const EdgeInsets.symmetric(vertical: 6),
                      shape: RoundedRectangleBorder(
                        borderRadius: BorderRadius.circular(14),
                      ),
                      child: InkWell(
                        borderRadius: BorderRadius.circular(14),
                        onTap: apptId <= 0
                            ? null
                            : () {
                                Navigator.of(context).push(
                                  MaterialPageRoute(
                                    builder: (_) =>
                                        AppointmentDetailPage(apptId: apptId),
                                  ),
                                );
                              },
                        child: Padding(
                          padding: const EdgeInsets.fromLTRB(12, 10, 12, 10),
                          child: Column(
                            crossAxisAlignment: CrossAxisAlignment.start,
                            children: [
                              Text(
                                'Appointment #$apptId',
                                style:
                                    const TextStyle(fontWeight: FontWeight.w800),
                              ),
                              const SizedBox(height: 4),
                              Text(
                                when,
                                style: TextStyle(color: Colors.grey.shade800),
                              ),
                              const SizedBox(height: 10),
                              Wrap(
                                spacing: 10,
                                runSpacing: 10,
                                children: [
                                  _pill(
                                    _modeLabel(mode),
                                    icon: _modeIcon(mode),
                                  ),
                                  _pill(
                                    'Status: ${status.isEmpty ? "—" : status}',
                                    bg: _chipBg(status),
                                    fg: _chipFg(status),
                                  ),
                                  if (payment.isNotEmpty)
                                    _pill(
                                      'Payment: $payment',
                                      bg: _chipBg(payment, tone: 'pay'),
                                      fg: _chipFg(payment, tone: 'pay'),
                                    ),
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
      ],
    );
  }
}


/// ---------------------------------------------------------------------------
/// CreateAppointmentPage
/// ---------------------------------------------------------------------------
class CreateAppointmentPage extends StatefulWidget {
  final int doctorId;
  final String doctorName;
  final double? visitingFee;

  final DateTime startTime;
  final DateTime endTime;

  /// locked visit mode (online/offline)
  final String visitModeLocked;

  const CreateAppointmentPage({
    super.key,
    required this.doctorId,
    required this.doctorName,
    this.visitingFee,
    required this.startTime,
    required this.endTime,
    required this.visitModeLocked,
  });

  @override
  State<CreateAppointmentPage> createState() => _CreateAppointmentPageState();
}

class _CreateAppointmentPageState extends State<CreateAppointmentPage> {
  // Existing patient search
  final phoneCtrl = TextEditingController();
  final patientIdCtrl = TextEditingController();

  bool finding = false;
  bool creating = false;

  bool foundPatient = false;
  int? foundPatientId;

  // New patient toggle
  bool createNewPatient = false;

  // New patient required fields
  final newPhoneCtrl = TextEditingController();
  final newEmailCtrl = TextEditingController();
  final newPasswordCtrl = TextEditingController(); // optional now

  // Patient info (shared)
  final nameCtrl = TextEditingController();
  final ageCtrl = TextEditingController();
  final heightCtrl = TextEditingController();
  final weightCtrl = TextEditingController();
  final bloodCtrl = TextEditingController();
  final genderCtrl = TextEditingController();
  final addressCtrl = TextEditingController();

  // Payment (same for existing & new)
  String paymentStatus = "pending"; // pending/paid
  String paymentMethod = "Cash"; // bKash/Rocket/Card/Cash/Bank Transfer/Other
  final txCtrl = TextEditingController();
  final amountCtrl = TextEditingController();

  @override
  void dispose() {
    phoneCtrl.dispose();
    patientIdCtrl.dispose();

    newPhoneCtrl.dispose();
    newEmailCtrl.dispose();
    newPasswordCtrl.dispose();

    nameCtrl.dispose();
    ageCtrl.dispose();
    heightCtrl.dispose();
    weightCtrl.dispose();
    bloodCtrl.dispose();
    genderCtrl.dispose();
    addressCtrl.dispose();

    txCtrl.dispose();
    amountCtrl.dispose();

    super.dispose();
  }

  String _fmt(DateTime dt) => DateFormat("MMM d, yyyy  h:mm a").format(dt);

  int? _tryInt(String s) {
    final v = s.trim();
    if (v.isEmpty) return null;
    return int.tryParse(v);
  }

  double? _tryDouble(String s) {
    final v = s.trim();
    if (v.isEmpty) return null;
    return double.tryParse(v);
  }

  void _toast(String msg) {
    if (!mounted) return;
    ScaffoldMessenger.of(context).showSnackBar(SnackBar(content: Text(msg)));
  }

  Future<void> _findPatient() async {
    setState(() {
      finding = true;
      foundPatient = false;
      foundPatientId = null;
    });

    final phone = phoneCtrl.text.trim();
    final pid = patientIdCtrl.text.trim();

    if (phone.isEmpty && pid.isEmpty) {
      _toast("Enter phone or patient ID");
      setState(() => finding = false);
      return;
    }

    try {
      final res = await Api.get(
        "/admin/patients/find",
        query: {
          if (phone.isNotEmpty) "phone": phone,
          if (pid.isNotEmpty) "patient_id": pid,
        },
      );

      if (res is! Map || res["found"] != true) {
        _toast("No patient found");
        setState(() => finding = false);
        return;
      }

      foundPatient = true;
      foundPatientId = (res["patient_id"] is num) ? (res["patient_id"] as num).toInt() : int.tryParse("${res["patient_id"]}");

      // Fill patient info (existing)
      nameCtrl.text = (res["name"] ?? "").toString();
      ageCtrl.text = (res["age"] ?? "").toString();
      heightCtrl.text = (res["height"] ?? "").toString();
      weightCtrl.text = (res["weight"] ?? "").toString();
      bloodCtrl.text = (res["blood_group"] ?? "").toString();
      genderCtrl.text = (res["gender"] ?? "").toString();
      addressCtrl.text = (res["address"] ?? "").toString();

      _toast("Patient found: ${res["name"]}");
    } catch (e) {
      _toast("Find failed: $e");
    }

    setState(() => finding = false);
  }

  Future<void> _createAppointment() async {
    if (!createNewPatient) {
      if (foundPatientId == null) {
        _toast("Please find and select an existing patient first");
        return;
      }
      await _createForExisting();
    } else {
      await _createForNew();
    }
  }

  Future<int?> _recordPaymentIfNeeded(int apptId) async {
    // Only record payment if status is paid OR method/tx/amount filled
    final wantPaid = paymentStatus == "paid";
    final method = paymentMethod.trim();
    final tx = txCtrl.text.trim();
    final amount = _tryDouble(amountCtrl.text);

    final hasAnyPaymentField = wantPaid || tx.isNotEmpty || (amount != null);

    if (!hasAnyPaymentField) return apptId;

    // Your backend "approve" endpoint can create payment rows if method provided.
    // Appointment is already approved, but calling approve again is OK (it just updates).
    try {
      await Api.patch(
        "/admin/appointments/$apptId/approve",
        data: {
          "approve": true,
          "method": method, // required to create payment
          "transaction_id": tx.isEmpty ? null : tx,
          "amount": amount,
        },
      );
      return apptId;
    } catch (e) {
      _toast("Payment record failed: $e");
      return apptId; // still return appointment created
    }
  }

  Future<void> _createForExisting() async {
    setState(() => creating = true);

    try {
      final res = await Api.post(
        "/admin/appointments/create_by_staff",
        data: {
          "doctor_id": widget.doctorId,
          "patient_id": foundPatientId,
          "start_time": widget.startTime.toIso8601String(),
          "end_time": widget.endTime.toIso8601String(),
          "visit_mode": widget.visitModeLocked, // 🔒 locked mode
          "patient_problem": "",
        },
      );

      if (res is Map) {
        final idDyn = res["id"];
        final apptId = (idDyn is num) ? idDyn.toInt() : int.tryParse("$idDyn");

        if (apptId != null) {
          await _recordPaymentIfNeeded(apptId);
          _toast("Appointment created! ID: $apptId");
          if (mounted) Navigator.pop(context, true);
          return;
        }
      }

      _toast("Appointment created but could not read ID");
    } catch (e) {
      _toast("Create failed: $e");
    }

    setState(() => creating = false);
  }

  Future<void> _createForNew() async {
    setState(() => creating = true);

    final phone = newPhoneCtrl.text.trim();
    final email = newEmailCtrl.text.trim();
    final pass = newPasswordCtrl.text.trim();

    if (nameCtrl.text.trim().isEmpty || phone.isEmpty) {
      _toast("New patient requires Name and Phone");
      setState(() => creating = false);
      return;
    }

    // PASSWORD OPTIONAL:
    // Backend requires "password" (string), so if user leaves empty we auto-generate one.
    final finalPassword = pass.isNotEmpty ? pass : "P@${phone.length >= 6 ? phone.substring(phone.length - 6) : phone}";

    try {
      final res = await Api.post(
        "/admin/appointments/create_new_patient_and_appointment",
        data: {
          "name": nameCtrl.text.trim(),
          "phone": phone,
          "password": finalPassword, // auto generated if empty
          "email": email.isEmpty ? null : email,

          "age": _tryInt(ageCtrl.text),
          "height": _tryInt(heightCtrl.text),
          "weight": _tryInt(weightCtrl.text),
          "blood_group": bloodCtrl.text.trim().isEmpty ? null : bloodCtrl.text.trim(),
          "gender": genderCtrl.text.trim().isEmpty ? null : genderCtrl.text.trim(),
          "address": addressCtrl.text.trim().isEmpty ? null : addressCtrl.text.trim(),

          "doctor_id": widget.doctorId,
          "start_time": widget.startTime.toIso8601String(),
          "end_time": widget.endTime.toIso8601String(),
          "visit_mode": widget.visitModeLocked, // 🔒 locked mode
          "patient_problem": "",
        },
      );

      if (res is Map) {
        final idDyn = res["id"];
        final apptId = (idDyn is num) ? idDyn.toInt() : int.tryParse("$idDyn");

        if (apptId != null) {
          await _recordPaymentIfNeeded(apptId);

          _toast("New patient + appointment created! ID: $apptId");
          if (pass.isEmpty) {
            _toast("Auto password for new patient: $finalPassword");
          }

          if (mounted) Navigator.pop(context, true);
          return;
        }
      }

      _toast("Created, but could not read appointment ID");
    } catch (e) {
      _toast("Create failed: $e");
    }

    setState(() => creating = false);
  }

  @override
  Widget build(BuildContext context) {
    final slotText = "Slot: ${_fmt(widget.startTime)}  →  ${_fmt(widget.endTime)}";
    final lockedModeLabel = widget.visitModeLocked.toLowerCase() == "online" ? "Online" : "Offline";

    return Scaffold(
      appBar: AppBar(title: const Text("Create Appointment")),
      body: SingleChildScrollView(
        padding: const EdgeInsets.all(16),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Text("Doctor: Dr. ${widget.doctorName}",
                style: const TextStyle(fontWeight: FontWeight.w700)),
            const SizedBox(height: 6),

            if (widget.visitingFee != null) ...[
              Text(
                "Visiting Fee: ৳${widget.visitingFee!.toStringAsFixed(0)}",
                style: TextStyle(color: Colors.grey.shade800, fontWeight: FontWeight.w600),
              ),
              const SizedBox(height: 6),
            ],

            Text(slotText, style: TextStyle(color: Colors.grey.shade700)),
            const SizedBox(height: 10),

            // MODE LOCKED
            Row(
              children: [
                const Text("Mode:", style: TextStyle(fontWeight: FontWeight.w700)),
                const SizedBox(width: 10),
                Chip(
                  label: Text(lockedModeLabel, style: const TextStyle(fontWeight: FontWeight.w700)),
                  avatar: Icon(widget.visitModeLocked == "online" ? Icons.wifi : Icons.local_hospital, size: 18),
                ),
                const Spacer(),
                const Icon(Icons.lock, size: 16),
                const SizedBox(width: 6),
                Text("Locked", style: TextStyle(color: Colors.grey.shade700, fontWeight: FontWeight.w600)),
              ],
            ),

            const Divider(height: 28),

            // NEW PATIENT TOGGLE
            Row(
              children: [
                Switch(
                  value: createNewPatient,
                  onChanged: creating
                      ? null
                      : (v) {
                          setState(() {
                            createNewPatient = v;
                            foundPatient = false;
                            foundPatientId = null;
                          });
                        },
                ),
                const SizedBox(width: 8),
                Text(
                  createNewPatient ? "New Patient" : "Existing Patient",
                  style: const TextStyle(fontWeight: FontWeight.w800),
                ),
                const Spacer(),
                if (!createNewPatient)
                  TextButton.icon(
                    onPressed: creating ? null : _findPatient,
                    icon: finding
                        ? const SizedBox(
                            height: 16,
                            width: 16,
                            child: CircularProgressIndicator(strokeWidth: 2),
                          )
                        : const Icon(Icons.search),
                    label: const Text("Find Patient"),
                  ),
              ],
            ),

            const SizedBox(height: 10),

            if (!createNewPatient) ...[
              // EXISTING PATIENT SEARCH UI
              Row(
                children: [
                  Expanded(
                    child: TextField(
                      controller: phoneCtrl,
                      decoration: const InputDecoration(
                        labelText: "Phone",
                        border: OutlineInputBorder(),
                      ),
                    ),
                  ),
                  const SizedBox(width: 10),
                  Expanded(
                    child: TextField(
                      controller: patientIdCtrl,
                      decoration: const InputDecoration(
                        labelText: "Patient ID",
                        border: OutlineInputBorder(),
                      ),
                      keyboardType: TextInputType.number,
                    ),
                  ),
                ],
              ),
              const SizedBox(height: 10),
              if (foundPatientId != null)
                Text("Selected Patient ID: $foundPatientId",
                    style: const TextStyle(fontWeight: FontWeight.w700)),
            ] else ...[
              // NEW PATIENT FIELDS
              const Text("New Patient Required Fields", style: TextStyle(fontWeight: FontWeight.w800)),
              const SizedBox(height: 10),
              TextField(
                controller: newPhoneCtrl,
                decoration: const InputDecoration(
                  labelText: "Phone (required)",
                  border: OutlineInputBorder(),
                ),
              ),
              const SizedBox(height: 10),
              TextField(
                controller: newEmailCtrl,
                decoration: const InputDecoration(
                  labelText: "Email (optional)",
                  border: OutlineInputBorder(),
                ),
              ),
              const SizedBox(height: 10),
              TextField(
                controller: newPasswordCtrl,
                decoration: const InputDecoration(
                  labelText: "Password (optional)",
                  border: OutlineInputBorder(),
                ),
                obscureText: true,
              ),
            ],

            const Divider(height: 28),

            // PATIENT INFO
            const Text("Patient Info", style: TextStyle(fontWeight: FontWeight.w800)),
            const SizedBox(height: 10),

            TextField(
              controller: nameCtrl,
              decoration: const InputDecoration(
                labelText: "Name",
                border: OutlineInputBorder(),
              ),
            ),
            const SizedBox(height: 10),

            Row(
              children: [
                Expanded(
                  child: TextField(
                    controller: ageCtrl,
                    decoration: const InputDecoration(
                      labelText: "Age",
                      border: OutlineInputBorder(),
                    ),
                    keyboardType: TextInputType.number,
                  ),
                ),
                const SizedBox(width: 10),
                Expanded(
                  child: TextField(
                    controller: heightCtrl,
                    decoration: const InputDecoration(
                      labelText: "Height",
                      border: OutlineInputBorder(),
                    ),
                    keyboardType: TextInputType.number,
                  ),
                ),
              ],
            ),
            const SizedBox(height: 10),

            Row(
              children: [
                Expanded(
                  child: TextField(
                    controller: weightCtrl,
                    decoration: const InputDecoration(
                      labelText: "Weight",
                      border: OutlineInputBorder(),
                    ),
                    keyboardType: TextInputType.number,
                  ),
                ),
                const SizedBox(width: 10),
                Expanded(
                  child: TextField(
                    controller: genderCtrl,
                    decoration: const InputDecoration(
                      labelText: "Gender",
                      border: OutlineInputBorder(),
                    ),
                  ),
                ),
              ],
            ),
            const SizedBox(height: 10),

            Row(
              children: [
                Expanded(
                  child: TextField(
                    controller: bloodCtrl,
                    decoration: const InputDecoration(
                      labelText: "Blood Group",
                      border: OutlineInputBorder(),
                    ),
                  ),
                ),
                const SizedBox(width: 10),
                Expanded(
                  child: TextField(
                    controller: addressCtrl,
                    decoration: const InputDecoration(
                      labelText: "Address",
                      border: OutlineInputBorder(),
                    ),
                  ),
                ),
              ],
            ),

            const Divider(height: 28),

            // PAYMENT
            const Text("Payment", style: TextStyle(fontWeight: FontWeight.w800)),
            const SizedBox(height: 10),

            DropdownButtonFormField<String>(
              value: paymentStatus,
              decoration: const InputDecoration(
                labelText: "Payment Status",
                border: OutlineInputBorder(),
              ),
              items: const [
                DropdownMenuItem(value: "pending", child: Text("Unpaid / Pending")),
                DropdownMenuItem(value: "paid", child: Text("Paid")),
              ],
              onChanged: creating ? null : (v) => setState(() => paymentStatus = v ?? "pending"),
            ),
            const SizedBox(height: 10),

            DropdownButtonFormField<String>(
              value: paymentMethod,
              decoration: const InputDecoration(
                labelText: "Method",
                border: OutlineInputBorder(),
              ),
              items: const [
                DropdownMenuItem(value: "bKash", child: Text("bKash")),
                DropdownMenuItem(value: "Rocket", child: Text("Rocket")),
                DropdownMenuItem(value: "Card", child: Text("Card")),
                DropdownMenuItem(value: "Cash", child: Text("Cash")),
                DropdownMenuItem(value: "Bank Transfer", child: Text("Bank Transfer")),
                DropdownMenuItem(value: "Other", child: Text("Other")),
              ],
              onChanged: creating ? null : (v) => setState(() => paymentMethod = v ?? "Cash"),
            ),
            const SizedBox(height: 10),

            TextField(
              controller: txCtrl,
              decoration: const InputDecoration(
                labelText: "Transaction ID (optional for Cash)",
                border: OutlineInputBorder(),
              ),
            ),
            const SizedBox(height: 10),

            TextField(
              controller: amountCtrl,
              keyboardType: TextInputType.number,
              decoration: const InputDecoration(
                labelText: "Amount (optional)",
                border: OutlineInputBorder(),
              ),
            ),

            const SizedBox(height: 18),

            SizedBox(
              width: double.infinity,
              height: 48,
              child: ElevatedButton(
                onPressed: creating ? null : _createAppointment,
                child: creating
                    ? const CircularProgressIndicator()
                    : Text(createNewPatient ? "Create Patient + Appointment" : "Create Appointment"),
              ),
            ),
          ],
        ),
      ),
    );
  }
}


/// ─────────────────────────── Patient Detail (with appt history) ───────────────────────────

class PatientDetailPage extends StatefulWidget {
  const PatientDetailPage({super.key, required this.patientId});
  final int patientId;

  @override
  State<PatientDetailPage> createState() => _PatientDetailPageState();
}

class _PatientDetailPageState extends State<PatientDetailPage> {
  Map<String, dynamic>? m;
  bool loading = true;

  List<Map<String, dynamic>> _appts = [];
  List<Map<String, dynamic>> _running = [];
  List<Map<String, dynamic>> _history = [];

  final df = DateFormat.yMMMd().add_jm();

  @override
  void initState() {
    super.initState();
    _load();
  }

  bool _isRunning(Map<String, dynamic> a) {
    final status = (a['status'] ?? '').toString().toLowerCase();
    final progress = (a['progress'] ?? '').toString().toLowerCase();
    if (status == 'cancelled' || status == 'rejected') return false;
    if (progress == 'completed' || progress == 'expired') return false;

    DateTime? end;
    final en = a['end_time'];
    if (en is String) end = DateTime.tryParse(en);
    if (en is DateTime) end = en;

    if (end != null && end.isBefore(DateTime.now())) return false;
    return true;
  }

  Future<void> _load() async {
    setState(() => loading = true);
    try {
      // patient info
      try {
        final r = await Api.get('/admin/patients/${widget.patientId}');
        if (r is Map) m = Map<String, dynamic>.from(r);
      } catch (_) {
        final r = await Api.get('/patients/${widget.patientId}');
        if (r is Map) m = Map<String, dynamic>.from(r);
      }

      // appointments
      dynamic res;
      final urls = <String>[
        '/admin/patients/${widget.patientId}/appointments',
        '/patients/${widget.patientId}/appointments',
        '/admin/appointments',
      ];
      for (final u in urls) {
        try {
          if (u.endsWith('/admin/appointments')) {
            res = await Api.get(u, query: {'patient_id': widget.patientId});
          } else {
            res = await Api.get(u);
          }
          if (res != null) break;
        } catch (_) {}
      }

      var rows = <Map<String, dynamic>>[];
      if (res is List) {
        rows = res.map((e) => Map<String, dynamic>.from(e as Map)).toList();
      } else if (res is Map && res['items'] is List) {
        rows = (res['items'] as List)
            .map((e) => Map<String, dynamic>.from(e as Map))
            .toList();
      }

      _appts = rows
        ..sort((a, b) {
          final A = DateTime.tryParse('${a['start_time']}') ?? DateTime(1970);
          final B = DateTime.tryParse('${b['start_time']}') ?? DateTime(1970);
          return B.compareTo(A);
        });

      _running = _appts.where(_isRunning).toList();
      _history = _appts.where((a) => !_isRunning(a)).toList();
    } catch (e) {
      showSnack(context, 'Load failed: $e');
    } finally {
      if (mounted) setState(() => loading = false);
    }
  }

  @override
  Widget build(BuildContext context) {
    final name = (m?['name'] ?? '').toString();
    final email = (m?['email'] ?? '').toString();
    final phone = (m?['phone'] ?? m?['mobile'] ?? '').toString();
    final gender = (m?['gender'] ?? '').toString();
    final dob = (m?['dob'] ?? m?['date_of_birth'] ?? '').toString();
    final address = (m?['address'] ?? '').toString();

    if (loading) return const Center(child: CircularProgressIndicator());

    return Scaffold(
      appBar: AppBar(title: Text(name.isNotEmpty ? name : 'Patient #${widget.patientId}')),
      body: ListView(
        padding: const EdgeInsets.fromLTRB(16, 16, 16, 24),
        children: [
          Row(
            children: [
              const CircleAvatar(radius: 28, child: Icon(Icons.person)),
              const SizedBox(width: 12),
              Expanded(
                child: Text(
                  name.isNotEmpty ? name : 'Patient #${widget.patientId}',
                  style: Theme.of(context).textTheme.titleLarge,
                ),
              ),
            ],
          ),
          const SizedBox(height: 12),
          _kv('Email', email.isNotEmpty ? email : '—'),
          _kv('Phone', phone.isNotEmpty ? phone : '—'),
          if (gender.isNotEmpty) _kv('Gender', gender),
          if (dob.isNotEmpty) _kv('DOB', dob),
          if (address.isNotEmpty) _kv('Address', address),
          const SizedBox(height: 16),
          Text('Current Appointments', style: Theme.of(context).textTheme.titleMedium),
          const SizedBox(height: 6),
          if (_running.isEmpty) const Text('None') else ..._running.map(_apptTile),
          const SizedBox(height: 16),
          Text('Appointment History', style: Theme.of(context).textTheme.titleMedium),
          const SizedBox(height: 6),
          if (_history.isEmpty) const Text('No past appointments') else ..._history.map(_apptTile),
        ],
      ),
    );
  }

  Widget _apptTile(Map<String, dynamic> a) {
    final id = a['id'];
    final st = a['start_time'];
    final en = a['end_time'];
    final status = (a['status'] ?? '').toString();
    final progress = (a['progress'] ?? '').toString();

    DateTime? s, e;
    if (st is String) s = DateTime.tryParse(st);
    if (st is DateTime) s = st;
    if (en is String) e = DateTime.tryParse(en);
    if (en is DateTime) e = en;

    final when = [
      if (s != null) df.format(s.toLocal()),
      if (e != null) '→ ${df.format(e.toLocal())}',
    ].join(' ');

    return Card(
      margin: const EdgeInsets.symmetric(vertical: 6),
      shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(14)),
      child: ListTile(
        title: Text('Appointment #$id'),
        subtitle: Text(when),
        trailing: Text(progress.isNotEmpty ? progress : status),
        onTap: () {
          final apptId = (id is num) ? id.toInt() : int.tryParse('$id');
          if (apptId != null) {
            Navigator.of(context).push(MaterialPageRoute(
              builder: (_) => AppointmentDetailPage(apptId: apptId),
            ));
          }
        },
      ),
    );
  }
}

/// ─────────────────────────── Appointment Detail Page ───────────────────────────

class AppointmentDetailPage extends StatefulWidget {
  const AppointmentDetailPage({super.key, required this.apptId});
  final int apptId;

  @override
  State<AppointmentDetailPage> createState() => _AppointmentDetailPageState();
}

class _AppointmentDetailPageState extends State<AppointmentDetailPage> {
  Map<String, dynamic>? m;
  bool loading = true;

  bool _actionsDisabled = false;
  bool _inFlight = false;

  final df = DateFormat.yMMMd().add_jm();

  List<Map<String, dynamic>> _prescriptions = [];
  List<Map<String, dynamic>> _reports = [];
  List<Map<String, dynamic>> _payments = [];
  bool loadingExtras = true;
  bool loadingPayments = true;

  final List<String> _paymentMethods = [
    'bKash',
    'Rocket',
    'Card',
    'Cash',
    'Bank Transfer',
    'Other'
  ];

  @override
  void initState() {
    super.initState();
    _load();
  }

  Future<void> _load() async {
    setState(() {
      loading = true;
      loadingExtras = true;
      loadingPayments = true;
      _prescriptions = [];
      _reports = [];
      _payments = [];
    });

    try {
      final r = await Api.get('/appointments/${widget.apptId}');
      if (r is Map) {
        m = Map<String, dynamic>.from(r);

        // payments summary if present
        try {
          final paySummary = m?['payments'];
          if (paySummary is Map) {
            if (paySummary['items'] is List) {
              _payments = (paySummary['items'] as List)
                  .map((e) => Map<String, dynamic>.from(e as Map))
                  .toList();
            } else if (paySummary['payment'] is Map) {
              _payments = [Map<String, dynamic>.from(paySummary['payment'] as Map)];
            }
          }
        } catch (_) {}

        final status = (m?['status'] ?? '').toString().toLowerCase();
        _actionsDisabled = status == 'approved' ||
            status == 'rejected' ||
            status == 'cancelled';
      }
    } catch (e) {
      showSnack(context, 'Load failed: $e');
    } finally {
      if (mounted) setState(() => loading = false);
    }

    await Future.wait([_loadExtras(), _maybeLoadPaymentsFromEndpoint()]);
  }

  Future<void> _loadExtras() async {
    setState(() => loadingExtras = true);
    try {
      dynamic pres;
      dynamic reps;

      // prescriptions
      try {
        //    correct backend endpoint (doctor uses this)
        pres = await Api.get('/appointments/${widget.apptId}/prescription');
      } catch (_) {
        //    fallback: try plural (only if exists in future)
        try {
          pres = await Api.get('/appointments/${widget.apptId}/prescriptions');
        } catch (_) {
          pres = null;
        }
      }

      // reports
      try {
        reps = await Api.get('/appointments/${widget.apptId}/reports');
      } catch (_) {
        reps = await Api.get('/reports', query: {'appointment_id': widget.apptId});
      }

      //  normalize prescriptions response
      _prescriptions = [];

      if (pres is List) {
        _prescriptions = pres.map((e) => Map<String, dynamic>.from(e as Map)).toList();
      } else if (pres is Map) {
        // if backend returns one object
        if (pres.containsKey('id') || pres.containsKey('file_path') || pres.containsKey('url')) {
          _prescriptions = [Map<String, dynamic>.from(pres)];
        } 
        // if backend returns items list
        else if (pres['items'] is List) {
          _prescriptions = (pres['items'] as List)
              .map((e) => Map<String, dynamic>.from(e as Map))
              .toList();
        } 
        // if backend returns something like {"data": [...]}
        else if (pres['data'] is List) {
          _prescriptions = (pres['data'] as List)
              .map((e) => Map<String, dynamic>.from(e as Map))
              .toList();
        }
      }


      // normalize reports
      if (reps is List) {
        _reports = reps.map((e) => Map<String, dynamic>.from(e as Map)).toList();
      } else if (reps is Map) {
        final list = reps['items'] ?? reps['data'] ?? reps['results'];
        if (list is List) {
          _reports = list.map((e) => Map<String, dynamic>.from(e as Map)).toList();
        } else {
          _reports = [];
        }
      } else {
        _reports = [];
      }
    } catch (_) {
      // best-effort
    } finally {
      if (mounted) setState(() => loadingExtras = false);
    }
  }

  Future<void> _maybeLoadPaymentsFromEndpoint() async {
    setState(() => loadingPayments = true);
    try {
      final r = await Api.get('/appointments/${widget.apptId}/payment');
      if (r is Map && r['ok'] == true) {
        if (r['items'] is List) {
          _payments = (r['items'] as List)
              .map((e) => Map<String, dynamic>.from(e as Map))
              .toList();
        } else if (r['payment'] is Map) {
          _payments = [Map<String, dynamic>.from(r['payment'] as Map)];
        }
      }
    } catch (_) {
      // ignore
    } finally {
      if (mounted) setState(() => loadingPayments = false);
    }
  }

  Future<void> _approve(
    bool ok, {
    String? transactionId,
    String? method,
    double? amount,
    String? reason,
  }) async {
    if (_inFlight) return;
    setState(() => _inFlight = true);

    try {
      // auto tx for cash
      final mLower = method?.toLowerCase();
      var tx = transactionId;
      if (ok && mLower == 'cash' && (tx == null || tx.trim().isEmpty)) {
        tx = 'CASH-${DateTime.now().toUtc().millisecondsSinceEpoch}';
      }

      // if approving + method provided -> create payment first
      if (ok && method != null && method.trim().isNotEmpty) {
        if ((tx == null || tx.isEmpty) && method.toLowerCase() != 'cash') {
          if (mounted) showSnack(context, 'Transaction id required for non-cash payment');
          setState(() => _inFlight = false);
          return;
        }

        try {
          await Api.post('/appointments/${widget.apptId}/pay', data: {
            'transaction_id': tx,
            'method': method,
            if (amount != null) 'amount': amount,
          });
        } catch (e) {
          if (mounted) showSnack(context, 'Failed to record payment: $e');
          setState(() => _inFlight = false);
          return;
        }
      }

      final data = <String, dynamic>{'approve': ok};
      if (!ok && reason != null && reason.trim().isNotEmpty) {
        data['reason'] = reason.trim();
      }

      await Api.patch('/admin/appointments/${widget.apptId}/approve', data: data);

      setState(() => _actionsDisabled = true);
      await _load();

      if (mounted) showSnack(context, ok ? 'Approved' : 'Rejected');
    } catch (e) {
      if (mounted) showSnack(context, 'Action failed: $e');
    } finally {
      if (mounted) setState(() => _inFlight = false);
    }
  }

  Future<void> _showRejectDialog() async {
    final noteCtrl = TextEditingController();
    final confirmed = await showDialog<bool>(
      context: context,
      builder: (_) => AlertDialog(
        title: const Text('Reject appointment'),
        content: TextField(
          controller: noteCtrl,
          minLines: 3,
          maxLines: 6,
          decoration: const InputDecoration(labelText: 'Reason (required)'),
        ),
        actions: [
          TextButton(onPressed: () => Navigator.pop(context, false), child: const Text('Cancel')),
          FilledButton(
            onPressed: () {
              if (noteCtrl.text.trim().isEmpty) {
                showSnack(context, 'Please provide a reason for rejection');
                return;
              }
              Navigator.pop(context, true);
            },
            child: const Text('Reject'),
          ),
        ],
      ),
    );

    if (confirmed == true) {
      await _approve(false, reason: noteCtrl.text.trim());
    }
    noteCtrl.dispose();
  }

  Future<void> _showCancelDialog() async {
    final noteCtrl = TextEditingController();
    final confirmed = await showDialog<bool>(
      context: context,
      builder: (_) => AlertDialog(
        title: const Text('Cancel appointment'),
        content: TextField(
          controller: noteCtrl,
          minLines: 2,
          maxLines: 4,
          decoration: const InputDecoration(labelText: 'Cancel reason (optional)'),
        ),
        actions: [
          TextButton(onPressed: () => Navigator.pop(context, false), child: const Text('Close')),
          FilledButton(
            onPressed: () => Navigator.pop(context, true),
            child: const Text('Cancel Appointment'),
          ),
        ],
      ),
    );

    if (confirmed == true) {
      try {
        await Api.patch('/appointments/${widget.apptId}/cancel', data: {
          'reason': noteCtrl.text.trim(),
        });
        setState(() => _actionsDisabled = true);
        await _load();
        if (mounted) showSnack(context, 'Appointment cancelled');
      } catch (e) {
        if (mounted) showSnack(context, 'Cancel failed: $e');
      }
    }
    noteCtrl.dispose();
  }

  Future<void> _showApproveDialog() async {
    final txCtrl = TextEditingController();
    final amountCtrl = TextEditingController();
    String? selectedMethod;

    await showDialog(
      context: context,
      builder: (_) => AlertDialog(
        title: const Text('Approve Appointment'),
        content: SingleChildScrollView(
          child: Column(
            mainAxisSize: MainAxisSize.min,
            children: [
              TextField(controller: txCtrl, decoration: const InputDecoration(labelText: 'Transaction ID (optional)')),
              const SizedBox(height: 8),
              StatefulBuilder(
                builder: (c, setLocal) => DropdownButtonFormField<String?>(
                  value: selectedMethod,
                  hint: const Text('Method (optional)'),
                  items: <DropdownMenuItem<String?>>[
                    const DropdownMenuItem<String?>(value: null, child: Text('No payment')),
                    ..._paymentMethods.map((m) => DropdownMenuItem<String?>(value: m, child: Text(m))),
                  ],
                  onChanged: (v) => setLocal(() => selectedMethod = v),
                  decoration: const InputDecoration(labelText: 'Method (optional)'),
                ),
              ),
              const SizedBox(height: 8),
              TextField(
                controller: amountCtrl,
                keyboardType: const TextInputType.numberWithOptions(decimal: true),
                decoration: const InputDecoration(labelText: 'Amount (optional)'),
              ),
              const SizedBox(height: 6),
              const Text(
                'Leave payment fields blank to approve without recording payment.',
                style: TextStyle(fontSize: 12, color: Colors.grey),
              ),
            ],
          ),
        ),
        actions: [
          TextButton(onPressed: () => Navigator.pop(context), child: const Text('Cancel')),
          FilledButton(
            onPressed: () async {
              final tx = txCtrl.text.trim();
              final method = selectedMethod?.trim();
              final amtText = amountCtrl.text.trim();

              double? amt;
              if (amtText.isNotEmpty) {
                try {
                  amt = double.parse(amtText);
                } catch (_) {
                  if (mounted) showSnack(context, 'Bad amount value');
                  return;
                }
              }

              if (method == null) {
                Navigator.pop(context);
                await _approve(true);
                return;
              }

              if (method.toLowerCase() != 'cash' && tx.isEmpty) {
                if (mounted) showSnack(context, 'Please provide transaction id for non-cash payments');
                return;
              }

              Navigator.pop(context);
              await _approve(
                true,
                transactionId: tx.isEmpty ? null : tx,
                method: method,
                amount: amt,
              );
            },
            child: const Text('Approve'),
          ),
        ],
      ),
    );

    txCtrl.dispose();
    amountCtrl.dispose();
  }

  Future<void> _showAddPaymentSheet() async {
    final txCtrl = TextEditingController();
    final amountCtrl = TextEditingController();
    var method = _paymentMethods.first;

    await showModalBottomSheet(
      context: context,
      isScrollControlled: true,
      builder: (_) => StatefulBuilder(
        builder: (context2, setLocal) => Padding(
          padding: EdgeInsets.only(
            bottom: MediaQuery.of(context2).viewInsets.bottom,
            left: 16,
            right: 16,
            top: 16,
          ),
          child: Column(
            mainAxisSize: MainAxisSize.min,
            children: [
              Text('Add Payment', style: Theme.of(context2).textTheme.titleMedium),
              const SizedBox(height: 12),
              TextField(
                controller: txCtrl,
                decoration: InputDecoration(
                  labelText: method.toLowerCase() == 'cash'
                      ? 'Transaction ID (optional for Cash)'
                      : 'Transaction ID',
                ),
              ),
              const SizedBox(height: 8),
              DropdownButtonFormField<String>(
                value: method,
                items: _paymentMethods.map((m) => DropdownMenuItem(value: m, child: Text(m))).toList(),
                onChanged: (v) {
                  if (v != null) setLocal(() => method = v);
                },
                decoration: const InputDecoration(labelText: 'Method'),
              ),
              const SizedBox(height: 8),
              TextField(
                controller: amountCtrl,
                keyboardType: const TextInputType.numberWithOptions(decimal: true),
                decoration: const InputDecoration(labelText: 'Amount'),
              ),
              const SizedBox(height: 12),
              Row(
                mainAxisAlignment: MainAxisAlignment.end,
                children: [
                  TextButton(onPressed: () => Navigator.pop(context2), child: const Text('Cancel')),
                  FilledButton(
                    onPressed: () async {
                      final tx = txCtrl.text.trim();
                      final amtText = amountCtrl.text.trim();

                      if (method.toLowerCase() != 'cash' && tx.isEmpty) {
                        showSnack(context, 'Provide transaction id for non-cash methods');
                        return;
                      }
                      if (amtText.isEmpty) {
                        showSnack(context, 'Provide amount');
                        return;
                      }

                      double amt;
                      try {
                        amt = double.parse(amtText);
                      } catch (_) {
                        showSnack(context, 'Bad amount');
                        return;
                      }

                      Navigator.pop(context2);

                      var finalTx = tx;
                      if (finalTx.isEmpty && method.toLowerCase() == 'cash') {
                        finalTx = 'CASH-${DateTime.now().toUtc().millisecondsSinceEpoch}';
                      }

                      try {
                        await Api.post('/appointments/${widget.apptId}/pay', data: {
                          'transaction_id': finalTx,
                          'method': method,
                          'amount': amt,
                        });
                        await _load();
                        if (mounted) showSnack(context, 'Payment added');
                      } catch (e) {
                        if (mounted) showSnack(context, 'Add payment failed: $e');
                      }
                    },
                    child: const Text('Save'),
                  ),
                ],
              ),
              const SizedBox(height: 8),
            ],
          ),
        ),
      ),
    );

    txCtrl.dispose();
    amountCtrl.dispose();
  }

  Future<void> _showAddReportDialogWithUpload() async {
    final titleCtrl = TextEditingController();
    final noteCtrl = TextEditingController();
    PlatformFile? selectedFile;

    await showModalBottomSheet(
      context: context,
      isScrollControlled: true,
      builder: (_) => StatefulBuilder(
        builder: (c, setLocal) => Padding(
          padding: EdgeInsets.only(
            bottom: MediaQuery.of(context).viewInsets.bottom,
            left: 16,
            right: 16,
            top: 16,
          ),
          child: Column(mainAxisSize: MainAxisSize.min, children: [
            Text('Add Report', style: Theme.of(context).textTheme.titleMedium),
            const SizedBox(height: 12),
            TextField(controller: titleCtrl, decoration: const InputDecoration(labelText: 'Title (optional)')),
            const SizedBox(height: 8),
            TextField(
              controller: noteCtrl,
              minLines: 3,
              maxLines: 6,
              decoration: const InputDecoration(labelText: 'Note'),
            ),
            const SizedBox(height: 8),
            Row(children: [
              FilledButton.icon(
                icon: const Icon(Icons.attach_file),
                label: Text(selectedFile == null ? 'Choose file' : selectedFile!.name),
                onPressed: () async {
                  final res = await FilePicker.platform.pickFiles(withData: true);
                  if (res != null && res.files.isNotEmpty) {
                    setLocal(() => selectedFile = res.files.first);
                  }
                },
              ),
              const SizedBox(width: 12),
              if (selectedFile != null)
                TextButton(
                  onPressed: () => setLocal(() => selectedFile = null),
                  child: const Text('Remove'),
                ),
            ]),
            const SizedBox(height: 12),
            Row(mainAxisAlignment: MainAxisAlignment.end, children: [
              TextButton(onPressed: () => Navigator.pop(context), child: const Text('Cancel')),
              FilledButton(
                onPressed: () async {
                  final title = titleCtrl.text.trim();
                  final note = noteCtrl.text.trim();

                  Navigator.pop(context);

                  try {
                    if (selectedFile == null) {
                      // no file: JSON
                      try {
                        await Api.post('/appointments/${widget.apptId}/reports', data: {
                          'title': title.isEmpty ? null : title,
                          'note': note,
                        });
                      } catch (_) {
                        await Api.post('/reports', data: {
                          'appointment_id': widget.apptId,
                          'title': title.isEmpty ? null : title,
                          'note': note,
                        });
                      }
                    } else {
                      final bytes = selectedFile!.bytes;
                      if (bytes == null || bytes.isEmpty) {
                        throw Exception('Selected file has no bytes');
                      }

                      final form = dio_pkg.FormData.fromMap({
                        'title': title.isEmpty ? null : title,
                        'note': note,
                        'file': dio_pkg.MultipartFile.fromBytes(bytes, filename: selectedFile!.name),
                      });

                      //    Use authenticated Api client multipart helper
                      try {
                        await Api.postMultipart('/appointments/${widget.apptId}/reports', formData: form);
                      } catch (_) {
                        await Api.postMultipart(
                          '/reports',
                          formData: dio_pkg.FormData.fromMap({
                            'appointment_id': widget.apptId,
                            'title': title.isEmpty ? null : title,
                            'note': note,
                            'file': dio_pkg.MultipartFile.fromBytes(bytes, filename: selectedFile!.name),
                          }),
                        );
                      }
                    }

                    await _loadExtras();
                    if (mounted) showSnack(context, 'Report added');
                  } catch (e) {
                    if (mounted) showSnack(context, 'Add failed: $e');
                  }
                },
                child: const Text('Save'),
              ),
            ]),
            const SizedBox(height: 12),
          ]),
        ),
      ),
    );

    titleCtrl.dispose();
    noteCtrl.dispose();
  }

  Future<void> _copyToClipboard(String text) async {
    try {
      await Clipboard.setData(ClipboardData(text: text));
      showSnack(context, 'Copied');
    } catch (_) {
      showSnack(context, 'Copy failed');
    }
  }

  DateTime? _parseEstimated(dynamic estRaw) {
    if (estRaw == null) return null;
    try {
      if (estRaw is DateTime) return estRaw;
      if (estRaw is String) {
        final dt = DateTime.tryParse(estRaw);
        if (dt != null) return dt;
        final n = int.tryParse(estRaw);
        if (n != null) return DateTime.fromMillisecondsSinceEpoch(n);
      }
      if (estRaw is int) {
        try {
          return DateTime.fromMillisecondsSinceEpoch(estRaw);
        } catch (_) {
          return DateTime.fromMillisecondsSinceEpoch(estRaw * 1000);
        }
      }
      if (estRaw is double) {
        return DateTime.fromMillisecondsSinceEpoch(estRaw.toInt());
      }
    } catch (_) {}
    return null;
  }

  @override
  Widget build(BuildContext context) {
    if (loading) return const Center(child: CircularProgressIndicator());

final id = widget.apptId;
final status = (m?['status'] ?? '').toString();
final pay = (m?['payment_status'] ?? '').toString();
final progress = (m?['progress'] ?? '').toString();
final mode = (m?['visit_mode'] ?? m?['mode'] ?? '').toString();

DateTime? s, e;
final st = m?['start_time'];
final en = m?['end_time'];
if (st is String) s = DateTime.tryParse(st);
if (st is DateTime) s = st;
if (en is String) e = DateTime.tryParse(en);
if (en is DateTime) e = en;

//    Doctor extraction (supports doctor, doctor_id)
final doc = (m?['doctor'] is Map)
    ? Map<String, dynamic>.from(m?['doctor'])
    : null;

final doctorIdRaw =
    (doc?['id'] ?? m?['doctor_id'] ?? m?['doctorId'] ?? m?['doctorID']);

final doctorId = (doctorIdRaw is num)
    ? doctorIdRaw.toInt()
    : int.tryParse('$doctorIdRaw');

final doctorName = (doc?['name'] ??
        m?['doctor_name'] ??
        (doctorId != null ? 'Doctor #$doctorId' : '—'))
    .toString();


    final pat = (m?['patient'] is Map) ? Map<String, dynamic>.from(m?['patient']) : null;
    final patientId = (pat?['id'] is num)
        ? (pat?['id'] as num).toInt()
        : ((m?['patient_id'] is num) ? (m?['patient_id'] as num).toInt() : null);
    final patientName = (pat?['name'] ?? m?['patient_name'] ?? (patientId != null ? 'Patient #$patientId' : '—')).toString();

    final serial = m?['serial_number'];
    final estDt = _parseEstimated(m?['estimated_visit_time']);

    double paymentsTotal = 0.0;
    for (final p in _payments) {
      try {
        final a = p['amount'];
        if (a != null) paymentsTotal += (a is num) ? a.toDouble() : double.tryParse('$a') ?? 0.0;
      } catch (_) {}
    }

    return Scaffold(
      appBar: AppBar(title: Text('Appointment #$id')),
      body: ListView(
        padding: const EdgeInsets.fromLTRB(16, 16, 16, 24),
        children: [
          ListTile(
            contentPadding: EdgeInsets.zero,
            leading: const CircleAvatar(child: Icon(Icons.local_hospital)),
            title: Text(doctorName, maxLines: 1, overflow: TextOverflow.ellipsis),
            subtitle: const Text('View doctor profile'),
            onTap: doctorId == null
                ? null
                : () => Navigator.of(context).push(
                      MaterialPageRoute(builder: (_) => DoctorDetailPage(doctorId: doctorId)),
                    ),
          ),
          ListTile(
            contentPadding: EdgeInsets.zero,
            leading: const CircleAvatar(child: Icon(Icons.person)),
            title: Text(patientName, maxLines: 1, overflow: TextOverflow.ellipsis),
            subtitle: Text(patientId != null ? 'Patient ID: $patientId' : 'View patient profile'),
            onTap: patientId == null
                ? null
                : () => Navigator.of(context).push(
                      MaterialPageRoute(builder: (_) => PatientDetailPage(patientId: patientId)),
                    ),
          ),
          const Divider(),
          _kv('Status', status.isNotEmpty ? status : '—'),
          if (progress.isNotEmpty) _kv('Progress', progress),
          _kv('Payment', pay.isNotEmpty ? pay : '—'),

          if (mode.isNotEmpty) _kv('Mode', mode),
          if (s != null) _kv('Start', df.format(s.toLocal())),
          if (e != null) _kv('End', df.format(e.toLocal())),
          const SizedBox(height: 12),
          Wrap(
            spacing: 12,
            runSpacing: 12,
            children: [
              FilledButton.icon(
                onPressed: (_actionsDisabled || _inFlight) ? null : _showApproveDialog,
                icon: const Icon(Icons.check),
                label: const Text('Approve'),
              ),
              OutlinedButton.icon(
                onPressed: (_actionsDisabled || _inFlight) ? null : _showRejectDialog,
                icon: const Icon(Icons.close),
                label: const Text('Reject'),
              ),
              OutlinedButton.icon(
                onPressed: _showAddReportDialogWithUpload,
                icon: const Icon(Icons.note_add),
                label: const Text('Add Report'),
              ),
              FilledButton.icon(
                onPressed: _showAddPaymentSheet,
                icon: const Icon(Icons.payment),
                label: const Text('Add Payment'),
              ),
              OutlinedButton.icon(
                onPressed: _showCancelDialog,
                icon: const Icon(Icons.cancel_outlined),
                label: const Text('Cancel'),
              ),
            ],
          ),
          const SizedBox(height: 20),
          if (serial != null) Padding(padding: const EdgeInsets.only(top: 12), child: _kv('Serial', serial.toString())),
          if (estDt != null)
            Padding(
              padding: const EdgeInsets.only(top: 6),
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  _kv('Est. Visit', df.format(estDt.toLocal())),
                  const SizedBox(height: 6),
                  const Padding(
                    padding: EdgeInsets.only(left: 128.0),
                    child: Text(
                      'Note: Visiting time is approximate. Actual visit may be before or after this time.',
                      style: TextStyle(fontSize: 12, color: Colors.grey),
                    ),
                  ),
                ],
              ),
            ),
          const SizedBox(height: 18),
          Row(
            children: [
              Text('Payments', style: Theme.of(context).textTheme.titleMedium),
              const Spacer(),
              if (!loadingPayments)
                Text('Total: ${paymentsTotal.toStringAsFixed(2)}', style: const TextStyle(fontWeight: FontWeight.w600)),
            ],
          ),
          const SizedBox(height: 8),
          if (loadingPayments)
            const Padding(padding: EdgeInsets.symmetric(vertical: 8), child: LinearProgressIndicator())
          else if (_payments.isEmpty)
            const Text('No payments recorded')
          else
            ..._payments.map((p) {
              final pid = p['id'];
              final tx = (p['transaction_id'] ?? '').toString();
              final method = (p['method'] ?? '').toString();
              final amount = p['amount'] == null
                  ? ''
                  : (p['amount'] is num ? (p['amount'] as num).toString() : p['amount'].toString());
              final paidAt = p['paid_at']?.toString();
              final dt = paidAt != null ? DateTime.tryParse(paidAt) : null;
              final when = dt != null ? df.format(dt.toLocal()) : '';

              return Card(
                margin: const EdgeInsets.symmetric(vertical: 6),
                child: ListTile(
                  leading: const Icon(Icons.receipt_long),
                  title: Text('$method — ${amount.isNotEmpty ? amount : '—'}',
                      maxLines: 1, overflow: TextOverflow.ellipsis),
                  subtitle: Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      if (tx.isNotEmpty) Text('TX: $tx'),
                      if (when.isNotEmpty) Text(when),
                    ],
                  ),
                  trailing: Row(
                    mainAxisSize: MainAxisSize.min,
                    children: [
                      if (tx.isNotEmpty)
                        IconButton(
                          tooltip: 'Copy transaction id',
                          icon: const Icon(Icons.copy, size: 20),
                          onPressed: () => _copyToClipboard(tx),
                        ),
                      IconButton(
                        tooltip: 'Open/Print receipt',
                        icon: const Icon(Icons.print, size: 20),
                        onPressed: pid == null
                            ? null
                            : () => openPaymentReceipt(
                                  context,
                                  (pid is num) ? pid.toInt() : int.tryParse('$pid') ?? 0,
                                ),
                      ),
                    ],
                  ),
                ),
              );
            }).toList(),
          const SizedBox(height: 20),
          Text('Prescriptions', style: Theme.of(context).textTheme.titleMedium),
          const SizedBox(height: 6),
          if (loadingExtras && _prescriptions.isEmpty)
            const Padding(padding: EdgeInsets.symmetric(vertical: 8), child: LinearProgressIndicator())
          else if (_prescriptions.isEmpty)
            const Text('None')
          else
            ..._prescriptions.map((p) {
              final title = (p['title'] ?? 'Prescription').toString();
              final created = p['created_at']?.toString();
              final dt = created != null ? DateTime.tryParse(created) : null;
              final when = dt != null ? df.format(dt.toLocal()) : '';
              final filePath = extractFilePath(p);

              return Card(
                margin: const EdgeInsets.symmetric(vertical: 6),
                child: ListTile(
                  leading: const Icon(Icons.medical_services_outlined),
                  title: Text(title, maxLines: 1, overflow: TextOverflow.ellipsis),
                  subtitle: when.isEmpty ? null : Text(when),
                  trailing: filePath.isEmpty
                      ? null
                      : IconButton(
                          tooltip: 'Open prescription',
                          icon: const Icon(Icons.open_in_new),
                          onPressed: () => openAttachment(
                            context,
                            filePath,
                            filename: (filePath.split('/').last.isEmpty ? 'prescription' : filePath.split('/').last),
                          ),
                        ),
                ),
              );
            }).toList(),
          const SizedBox(height: 16),
          Text('Reports', style: Theme.of(context).textTheme.titleMedium),
          const SizedBox(height: 6),
          if (loadingExtras && _reports.isEmpty)
            const Padding(padding: EdgeInsets.symmetric(vertical: 8), child: LinearProgressIndicator())
          else if (_reports.isEmpty)
            const Text('None')
          else
            ..._reports.map((r) {
              final title = (r['title'] ?? 'Report').toString();
              final note = (r['note'] ?? '').toString();
              final created = r['created_at']?.toString();
              final dt = created != null ? DateTime.tryParse(created) : null;
              final when = dt != null ? df.format(dt.toLocal()) : '';
              final filePath = extractFilePath(r);
              final fileUrl = filePath.isEmpty ? '' : Api.filePathToUrl(filePath);

              return Card(
                margin: const EdgeInsets.symmetric(vertical: 6),
                child: ListTile(
                  leading: const Icon(Icons.description_outlined),
                  title: Text(title, maxLines: 1, overflow: TextOverflow.ellipsis),
                  subtitle: Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      if (when.isNotEmpty) Text(when),
                      if (note.isNotEmpty) Text(note, maxLines: 2, overflow: TextOverflow.ellipsis),
                      if (fileUrl.isNotEmpty)
                        Text(
                          fileUrl,
                          maxLines: 1,
                          overflow: TextOverflow.ellipsis,
                          style: const TextStyle(fontSize: 11, color: Colors.grey),
                        ),
                    ],
                  ),
                  trailing: fileUrl.isEmpty
                      ? null
                      : IconButton(
                          tooltip: 'Open report',
                          icon: const Icon(Icons.open_in_new),
                          onPressed: () => openAttachment(
                            context,
                            filePath,
                            filename: (filePath.split('/').last.isEmpty ? 'report' : filePath.split('/').last),
                          ),
                        ),
                ),
              );
            }).toList(),
        ],
      ),
    );
  }
}

/// ─────────────────────────── Admin Payments Tab ───────────────────────────

class _AdminPaymentsTab extends StatefulWidget {
  const _AdminPaymentsTab();

  @override
  State<_AdminPaymentsTab> createState() => _AdminPaymentsTabState();
}

class _AdminPaymentsTabState extends State<_AdminPaymentsTab> {
  final qCtrl = TextEditingController();
  bool loading = true;
  bool searching = false;
  int page = 1;
  final int pageSize = 25;
  int total = 0;
  List<Map<String, dynamic>> items = [];

  @override
  void initState() {
    super.initState();
    _load();
  }

  @override
  void dispose() {
    qCtrl.dispose();
    super.dispose();
  }

  Future<void> _load({int p = 1}) async {
    setState(() {
      loading = true;
      page = p;
    });

    try {
      final res = await Api.get('/admin/payments', query: {
        if (qCtrl.text.trim().isNotEmpty) 'q': qCtrl.text.trim(),
        'page': p,
        'page_size': pageSize,
      });

      if (res is Map) {
        items = (res['items'] as List)
            .map((e) => Map<String, dynamic>.from(e as Map))
            .toList();
        total = (res['total'] as num?)?.toInt() ?? 0;
        page = (res['page'] as num?)?.toInt() ?? p;
      } else if (res is List) {
        items = res.map((e) => Map<String, dynamic>.from(e as Map)).toList();
        total = items.length;
        page = p;
      } else {
        items = [];
        total = 0;
      }
    } catch (e) {
      if (mounted) showSnack(context, 'Load failed: $e');
      items = [];
      total = 0;
    } finally {
      if (mounted) setState(() => loading = false);
    }
  }

  Future<void> _search() async {
    setState(() => searching = true);
    await _load(p: 1);
    if (mounted) setState(() => searching = false);
  }

  Future<void> _downloadPaymentReceipt(BuildContext context, int paymentId) async {
    try {
      final bytes = await Api.getBytes('/payments/$paymentId/receipt');
      if (bytes.isNotEmpty) {
        await downloadBytes(bytes, 'receipt-$paymentId.pdf');
        showSnack(context, 'Downloaded receipt-$paymentId.pdf');
        return;
      }
    } catch (_) {}
    await openPaymentReceipt(context, paymentId);
  }

  Future<void> _printPaymentReceipt(BuildContext context, int paymentId) async {
    try {
      final bytes = await Api.getBytes('/payments/$paymentId/receipt');
      if (bytes.isNotEmpty) {
        await printPdfBytes(bytes);
        return;
      }
    } catch (_) {}
    await openPaymentReceipt(context, paymentId);
  }

  @override
  Widget build(BuildContext context) {
    final pages = (total + pageSize - 1) ~/ pageSize;

    return RefreshIndicator(
      onRefresh: () => _load(p: page),
      child: Column(
        children: [
          Padding(
            padding: const EdgeInsets.fromLTRB(12, 10, 12, 6),
            child: Row(
              children: [
                Expanded(
                  child: TextField(
                    controller: qCtrl,
                    decoration: InputDecoration(
                      prefixIcon: const Icon(Icons.search),
                      hintText: 'Search transaction, method, patient, appointment id',
                      border: OutlineInputBorder(borderRadius: BorderRadius.circular(24)),
                      isDense: true,
                      filled: true,
                      suffixIcon: qCtrl.text.isEmpty
                          ? null
                          : IconButton(
                              icon: const Icon(Icons.close),
                              onPressed: () {
                                qCtrl.clear();
                                _load(p: 1);
                              },
                            ),
                    ),
                    onSubmitted: (_) => _search(),
                    textInputAction: TextInputAction.search,
                  ),
                ),
                const SizedBox(width: 8),
                IconButton(onPressed: () => _load(p: 1), icon: const Icon(Icons.refresh)),
              ],
            ),
          ),
          if (loading) const LinearProgressIndicator(),
          if (!loading && items.isEmpty)
            const Expanded(child: Center(child: Text('No payments found')))
          else
            Expanded(
              child: ListView.builder(
                padding: const EdgeInsets.fromLTRB(12, 8, 12, 12),
                itemCount: items.length,
                itemBuilder: (ctx, i) {
                  final p = items[i];
                  final tx = (p['transaction_id'] ?? '').toString();
                  final method = (p['method'] ?? '').toString();
                  final amount = p['amount'] == null
                      ? '—'
                      : (p['amount'] is num
                          ? (p['amount'] as num).toStringAsFixed(2)
                          : p['amount'].toString());
                  final paidAtRaw = p['paid_at'];
                  DateTime? dt;
                  if (paidAtRaw is String) dt = DateTime.tryParse(paidAtRaw);
                  final when = dt != null ? DateFormat.yMMMd().add_jm().format(dt.toLocal()) : '';
                  final patient = (p['patient_name'] ?? '').toString();
                  final apptId = p['appointment_id'];
                  final pid = (p['id'] is num) ? (p['id'] as num).toInt() : int.tryParse('${p['id']}') ?? 0;

                  return Card(
                    margin: const EdgeInsets.symmetric(vertical: 6),
                    child: ListTile(
                      leading: const Icon(Icons.receipt_long),
                      title: Text('$method • $amount', maxLines: 1, overflow: TextOverflow.ellipsis),
                      subtitle: Column(
                        crossAxisAlignment: CrossAxisAlignment.start,
                        children: [
                          if (tx.isNotEmpty) Text('TX: $tx', style: const TextStyle(fontSize: 12)),
                          if (patient.isNotEmpty) Text('Patient: $patient', style: const TextStyle(fontSize: 12)),
                          if (when.isNotEmpty) Text(when, style: const TextStyle(fontSize: 12)),
                          if (apptId != null) Text('Appt: #$apptId', style: const TextStyle(fontSize: 12)),
                        ],
                      ),
                      trailing: SizedBox(
                        width: 128,
                        child: Row(
                          mainAxisSize: MainAxisSize.min,
                          children: [
                            IconButton(
                              tooltip: 'Download',
                              icon: const Icon(Icons.download_rounded, size: 20),
                              onPressed: pid == 0 ? null : () => _downloadPaymentReceipt(context, pid),
                            ),
                            IconButton(
                              tooltip: 'Print',
                              icon: const Icon(Icons.print, size: 20),
                              onPressed: pid == 0 ? null : () => _printPaymentReceipt(context, pid),
                            ),
                            IconButton(
                              icon: const Icon(Icons.open_in_new),
                              tooltip: 'Open',
                              onPressed: () {
                                Navigator.of(context).push(MaterialPageRoute(
                                  builder: (_) => PaymentDetailPage(paymentRow: p),
                                ));
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
          Padding(
            padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 8),
            child: Row(
              children: [
                Text('Page $page / ${pages == 0 ? 1 : pages}', style: const TextStyle(fontWeight: FontWeight.w600)),
                const Spacer(),
                Text('Total: $total'),
                const SizedBox(width: 8),
                IconButton(
                  tooltip: 'Prev',
                  onPressed: page > 1 && !loading ? () => _load(p: page - 1) : null,
                  icon: const Icon(Icons.chevron_left),
                ),
                IconButton(
                  tooltip: 'Next',
                  onPressed: page < pages && !loading ? () => _load(p: page + 1) : null,
                  icon: const Icon(Icons.chevron_right),
                ),
              ],
            ),
          ),
        ],
      ),
    );
  }
}

/// ─────────────────────────── Payment Detail Page ───────────────────────────

class PaymentDetailPage extends StatelessWidget {
  final Map<String, dynamic> paymentRow;
  const PaymentDetailPage({super.key, required this.paymentRow});

  Future<void> _downloadReceipt(BuildContext context) async {
    final id = paymentRow['id'];
    if (id == null) {
      showSnack(context, 'Missing payment id');
      return;
    }

    try {
      final bytes = await Api.getBytes('/payments/$id/receipt');
      if (bytes.isNotEmpty) {
        await downloadBytes(bytes, 'receipt-$id.pdf');
        showSnack(context, 'Downloaded receipt-$id.pdf');
        return;
      }
    } catch (_) {}

    await openPaymentReceipt(context, id as int);
  }

  Future<void> _printReceipt(BuildContext context) async {
    final id = paymentRow['id'];
    if (id == null) {
      showSnack(context, 'Missing payment id');
      return;
    }

    try {
      final bytes = await Api.getBytes('/payments/$id/receipt');
      if (bytes.isNotEmpty) {
        await printPdfBytes(bytes);
        return;
      }
    } catch (_) {}

    await openPaymentReceipt(context, id as int);
  }

  @override
  Widget build(BuildContext context) {
    final tx = (paymentRow['transaction_id'] ?? '').toString();
    final method = (paymentRow['method'] ?? '').toString();
    final amount = paymentRow['amount'] == null
        ? '—'
        : (paymentRow['amount'] is num
            ? (paymentRow['amount'] as num).toStringAsFixed(2)
            : paymentRow['amount'].toString());
    final paidAtRaw = paymentRow['paid_at'];
    DateTime? dt;
    if (paidAtRaw is String) dt = DateTime.tryParse(paidAtRaw);
    final when = dt != null ? DateFormat.yMMMd().add_jm().format(dt.toLocal()) : '';

    return Scaffold(
      appBar: AppBar(title: const Text('Payment')),
      body: Padding(
        padding: const EdgeInsets.all(16),
        child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
          Text('Method: $method', style: const TextStyle(fontSize: 16)),
          const SizedBox(height: 8),
          Text('Amount: $amount',
              style: const TextStyle(fontSize: 16, fontWeight: FontWeight.w700)),
          const SizedBox(height: 8),
          if (tx.isNotEmpty) Text('Transaction: $tx'),
          if (when.isNotEmpty) Text('Paid at: $when'),
          const SizedBox(height: 20),
          Wrap(
            spacing: 8,
            runSpacing: 8,
            children: [
              FilledButton.icon(
                icon: const Icon(Icons.copy),
                label: const Text('Copy TX'),
                onPressed: tx.isEmpty
                    ? null
                    : () {
                        Clipboard.setData(ClipboardData(text: tx));
                        showSnack(context, 'Transaction copied');
                      },
              ),
              FilledButton.icon(
                icon: const Icon(Icons.download),
                label: const Text('Download'),
                onPressed: () => _downloadReceipt(context),
              ),
              FilledButton.icon(
                icon: const Icon(Icons.print),
                label: const Text('Print'),
                onPressed: () => _printReceipt(context),
              ),
              FilledButton.icon(
                icon: const Icon(Icons.open_in_new),
                label: const Text('Open Appointment'),
                onPressed: paymentRow['appointment_id'] == null
                    ? null
                    : () {
                        final apptId = paymentRow['appointment_id'] as int;
                        Navigator.of(context).push(
                          MaterialPageRoute(builder: (_) => AppointmentDetailPage(apptId: apptId)),
                        );
                      },
              ),
            ],
          ),
          const SizedBox(height: 12),
          Text('Patient: ${paymentRow['patient_name'] ?? '—'}'),
          const SizedBox(height: 8),
          Text('Payment ID: ${paymentRow['id']}'),
        ]),
      ),
    );
  }
}

/// ─────────────────────────── ReceiptPrintPage (Preview + Print + Download) ───────────────────────────

class ReceiptPrintPage extends StatefulWidget {
  final Map<String, dynamic> payment;
  const ReceiptPrintPage({super.key, required this.payment});

  @override
  State<ReceiptPrintPage> createState() => _ReceiptPrintPageState();
}

class _ReceiptPrintPageState extends State<ReceiptPrintPage> {
  Map<String, dynamic>? appointment;
  bool loading = true;

  final df = DateFormat.yMMMd().add_jm();
  static const String appName = 'RxMeet';

  @override
  void initState() {
    super.initState();
    _loadAppointment();
  }

  Future<void> _loadAppointment() async {
    setState(() => loading = true);
    try {
      final apptId = widget.payment['appointment_id'];
      if (apptId != null) {
        final r = await Api.get('/appointments/$apptId');
        if (r is Map) appointment = Map<String, dynamic>.from(r);
      }
    } catch (_) {
      // best-effort
    } finally {
      if (mounted) setState(() => loading = false);
    }
  }

  DateTime? _parseEstimated(dynamic estRaw) {
    if (estRaw == null) return null;
    try {
      if (estRaw is DateTime) return estRaw;

      if (estRaw is String) {
        final s = estRaw.trim();
        if (s.isEmpty) return null;

        final dt = DateTime.tryParse(s);
        if (dt != null) return dt;

        final n = int.tryParse(s);
        if (n != null) {
          if (n < 10000000000) return DateTime.fromMillisecondsSinceEpoch(n * 1000);
          return DateTime.fromMillisecondsSinceEpoch(n);
        }

        DateTime? tryTime(String pattern) {
          try {
            final t = DateFormat(pattern).parseLoose(s);
            final now = DateTime.now();
            return DateTime(now.year, now.month, now.day, t.hour, t.minute);
          } catch (_) {
            return null;
          }
        }

        return tryTime('HH:mm') ?? tryTime('hh:mm a') ?? tryTime('h:mm a');
      }

      if (estRaw is int) {
        if (estRaw < 10000000000) return DateTime.fromMillisecondsSinceEpoch(estRaw * 1000);
        return DateTime.fromMillisecondsSinceEpoch(estRaw);
      }

      if (estRaw is double) {
        final n = estRaw.toInt();
        if (n < 10000000000) return DateTime.fromMillisecondsSinceEpoch(n * 1000);
        return DateTime.fromMillisecondsSinceEpoch(n);
      }
    } catch (_) {}
    return null;
  }

  pw.Widget _row(String k, String v) {
    return pw.Padding(
      padding: const pw.EdgeInsets.only(bottom: 3),
      child: pw.Row(
        crossAxisAlignment: pw.CrossAxisAlignment.start,
        children: [
          pw.SizedBox(
            width: 120,
            child: pw.Text(
              '$k:',
              style: pw.TextStyle(fontSize: 10, fontWeight: pw.FontWeight.bold),
            ),
          ),
          pw.Expanded(child: pw.Text(v, style: const pw.TextStyle(fontSize: 10))),
        ],
      ),
    );
  }

  Future<Uint8List> _buildPdfBytes(PdfPageFormat format) async {
    final doc = pw.Document();
    final p = widget.payment;
    final appt = appointment;

    final txn = (p['transaction_id'] ?? '').toString();
    final amountVal = p['amount'];
    final amount = (amountVal is num) ? amountVal.toDouble() : double.tryParse('$amountVal') ?? 0.0;
    final method = (p['method'] ?? '').toString();
    final status = (p['status'] ?? '').toString();

    DateTime? paidAt;
    final paidAtRaw = p['paid_at'];
    if (paidAtRaw is String) paidAt = DateTime.tryParse(paidAtRaw);
    if (paidAtRaw is DateTime) paidAt = paidAtRaw;

    final apptId = appt != null ? (appt['id'] ?? appt['appointment_id']) : p['appointment_id'];

    final doctorMap = (appt != null && appt['doctor'] is Map)
        ? Map<String, dynamic>.from(appt['doctor'])
        : null;
    final patientMap = (appt != null && appt['patient'] is Map)
        ? Map<String, dynamic>.from(appt['patient'])
        : null;

    final doctorName = (doctorMap?['name'] ?? (p['doctor_name'] ?? '')).toString();
    final patientName = (patientMap?['name'] ?? (p['patient_name'] ?? '')).toString();

    final mode = (appt != null) ? (appt['visit_mode'] ?? appt['mode'] ?? '') : '';

    DateTime? when;
    final st = appt != null
        ? appt['start_time']
        : (p['appointment'] is Map ? (p['appointment']['start_time']) : null);
    if (st is String) when = DateTime.tryParse(st);
    if (st is DateTime) when = st;

    final serialNumber = appt?['serial_number'] ?? p['serial_number'] ?? '—';
    final estDt = _parseEstimated(appt?['estimated_visit_time'] ?? p['estimated_visit_time']);

    final paidAtStr = paidAt != null ? df.format(paidAt.toLocal()) : '—';
    final whenStr = when != null ? df.format(when.toLocal()) : '—';
    final estStr = estDt != null ? df.format(estDt.toLocal()) : '—';

    final barcodeData = (apptId != null && '$apptId'.isNotEmpty)
        ? 'APPT:$apptId'
        : (txn.isNotEmpty ? 'TX:$txn' : 'RECEIPT');

    doc.addPage(
      pw.Page(
        pageFormat: format,
        margin: const pw.EdgeInsets.all(28),
        build: (pw.Context ctx) {
          return pw.Column(
            crossAxisAlignment: pw.CrossAxisAlignment.start,
            children: [
              pw.Text('Payment Receipt',
                  style: pw.TextStyle(fontSize: 18, fontWeight: pw.FontWeight.bold)),
              pw.SizedBox(height: 6),
              pw.Text('App: $appName', style: const pw.TextStyle(fontSize: 10)),
              pw.SizedBox(height: 10),
              pw.Text('Appointment Barcode',
                  style: pw.TextStyle(fontSize: 11, fontWeight: pw.FontWeight.bold)),
              pw.SizedBox(height: 6),
              pw.BarcodeWidget(
                barcode: pw.Barcode.code128(),
                data: barcodeData,
                width: 220,
                height: 60,
                drawText: true,
              ),
              pw.SizedBox(height: 14),
              pw.Text('Payment',
                  style: pw.TextStyle(fontSize: 12, fontWeight: pw.FontWeight.bold)),
              pw.SizedBox(height: 6),
              _row('Transaction ID', txn.isNotEmpty ? txn : '—'),
              _row('Amount', amount.toStringAsFixed(2)),
              _row('Method', method.isNotEmpty ? method : '—'),
              _row('Status', status.isNotEmpty ? status : '—'),
              _row('Paid at', paidAtStr),
              pw.SizedBox(height: 14),
              pw.Text('Appointment',
                  style: pw.TextStyle(fontSize: 12, fontWeight: pw.FontWeight.bold)),
              pw.SizedBox(height: 6),
              _row('Appointment ID', apptId != null ? '#$apptId' : '—'),
              _row('Doctor', doctorName.isNotEmpty ? doctorName : '—'),
              _row('Patient', patientName.isNotEmpty ? patientName : '—'),
              _row('Mode', mode.toString().isNotEmpty ? mode.toString() : '—'),
              _row('When', whenStr),
              _row('Serial number', '$serialNumber'),
              _row('Approx. visiting time', estStr),
              pw.Spacer(),
              pw.Divider(),
              pw.SizedBox(height: 6),
              pw.Text(
                'Note: Visiting time is approximate. Actual visit may be before or after this time.',
                style: pw.TextStyle(fontSize: 8, color: PdfColors.grey),
              ),
            ],
          );
        },
      ),
    );

    return doc.save();
  }

  Future<void> _print() async {
    try {
      await Printing.layoutPdf(onLayout: (format) => _buildPdfBytes(format));
    } catch (e) {
      showSnack(context, 'Print failed: $e');
    }
  }

  Future<void> _download() async {
    try {
      final bytes = await _buildPdfBytes(PdfPageFormat.a4);
      await downloadBytes(bytes, 'receipt-${widget.payment['id']}.pdf');
      showSnack(context, 'Downloaded receipt-${widget.payment['id']}.pdf');
    } catch (e) {
      showSnack(context, 'Download failed: $e');
    }
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: AppBar(
        title: const Text('Receipt preview'),
        actions: [
          IconButton(onPressed: _download, icon: const Icon(Icons.download_rounded), tooltip: 'Download PDF'),
          IconButton(onPressed: _print, icon: const Icon(Icons.print), tooltip: 'Print'),
        ],
      ),
      body: loading
          ? const Center(child: CircularProgressIndicator())
          : Padding(
              padding: const EdgeInsets.all(12),
              child: Column(
                children: [
                  Expanded(
                    child: Card(
                      margin: EdgeInsets.zero,
                      shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(6)),
                      child: Padding(
                        padding: const EdgeInsets.all(18),
                        child: PdfPreview(
                          build: (format) => _buildPdfBytes(format),
                          canDebug: false,
                          initialPageFormat: PdfPageFormat.a4,
                        ),
                      ),
                    ),
                  ),
                  const SizedBox(height: 12),
                  Row(
                    children: [
                      Expanded(
                        child: FilledButton.icon(
                          icon: const Icon(Icons.print),
                          label: const Text('Print'),
                          onPressed: _print,
                        ),
                      ),
                      const SizedBox(width: 8),
                      Expanded(
                        child: OutlinedButton.icon(
                          icon: const Icon(Icons.download),
                          label: const Text('Download'),
                          onPressed: _download,
                        ),
                      ),
                    ],
                  ),
                ],
              ),
            ),
    );
  }
}
