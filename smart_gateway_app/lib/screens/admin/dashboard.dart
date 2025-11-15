// lib/screens/admin/dashboard.dart
import 'package:flutter/material.dart';
import 'package:intl/intl.dart';

import '../../models.dart';
import '../../services/api.dart';
import '../../services/auth.dart';
import '../../widgets/snack.dart';

/// ───────────────────────────── Shared helpers ─────────────────────────────
Widget _kv(String k, String v) => Padding(
  padding: const EdgeInsets.symmetric(vertical: 6),
  child: Row(
    crossAxisAlignment: CrossAxisAlignment.start,
    children: [
      SizedBox(width: 120, child: Text(k, style: const TextStyle(fontWeight: FontWeight.w600))),
      const SizedBox(width: 8),
      Expanded(child: Text(v)),
    ],
  ),
);

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
                    style: theme.textTheme.titleMedium?.copyWith(fontWeight: FontWeight.w600),
                  ),
                  const SizedBox(height: 2),
                  Text(subtitle, maxLines: 1, overflow: TextOverflow.ellipsis),
                ],
              ),
            ),
            if (trailing != null) ...[
              const SizedBox(width: 12),
              Text(trailing, style: const TextStyle(fontWeight: FontWeight.w600)),
            ],
          ],
        ),
      ),
    ),
  );
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
      _AdminProfileTab(me: widget.me),
    ];

    return Scaffold(
      appBar: AppBar(
        title: const Text('Admin Dashboard'),
        actions: [
          IconButton(
            tooltip: 'Logout',
            onPressed: () async {
              await AuthService.logout();
              if (!mounted) return;
              // Navigate to login like other roles
              Navigator.of(context).pushNamedAndRemoveUntil('/login', (route) => false);
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
          NavigationDestination(icon: Icon(Icons.person_add), label: 'Create Doctor'),
          NavigationDestination(icon: Icon(Icons.people_alt), label: 'Patients'),
          NavigationDestination(icon: Icon(Icons.event), label: 'Appointments'),
          NavigationDestination(icon: Icon(Icons.account_circle), label: 'Profile'),
        ],
      ),
    );
  }
}

/// ───────────────────── Doctors (search; patient-style list) ─────────────────────
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
                      border: OutlineInputBorder(borderRadius: BorderRadius.circular(24)),
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
                IconButton(tooltip: 'Refresh', onPressed: _load, icon: const Icon(Icons.refresh)),
              ],
            ),
          ),
          Expanded(
            child: items.isEmpty
                ? const Center(child: Text('No doctors found'))
                : ListView.builder(
                    physics: const AlwaysScrollableScrollPhysics(),
                    itemCount: items.length,
                    itemBuilder: (_, i) {
                      final d = items[i];
                      return personTile(
                        context: _,
                        title: d.name,
                        subtitle: '${d.specialty} • ${d.category ?? 'General'}',
                        trailing: '★ ${d.rating ?? 5}',
                        // CTRL+F: [DOCTORS onTap → push detail page]
                        onTap: () => Navigator.of(context).push(
                          MaterialPageRoute(builder: (_) => DoctorDetailPage(doctorId: d.id)),
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
      name.clear(); email.clear(); phone.clear(); pass.clear();
      specialty.clear(); category.text = 'General'; keywords.clear(); bio.clear(); background.clear();
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
        children: fields.map((w) => Padding(padding: const EdgeInsets.only(bottom: 10), child: w)).toList(),
      ),
    );
  }

  Widget _tf(TextEditingController c, String label, {bool obscure = false}) {
    return TextField(
      controller: c,
      obscureText: obscure,
      decoration: InputDecoration(labelText: label, border: const OutlineInputBorder()),
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
      setState(() => view = cache.values.toList()..sort((a, b) => a.name.compareTo(b.name)));
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
      // hydrate patient details
      for (final id in ids) {
        if (!cache.containsKey(id)) {
          try {
            final m = await Api.get('/patients/$id');
            cache[id] = _PatientRow(
              id: id,
              name: (m['name'] ?? '').toString(),
              email: (m['email'] ?? '').toString().isEmpty ? null : (m['email'] ?? '').toString(),
              phone: (m['phone'] ?? '').toString().isEmpty ? null : (m['phone'] ?? '').toString(),
            );
          } catch (_) {
            // best-effort; skip bad rows
          }
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
                      border: OutlineInputBorder(borderRadius: BorderRadius.circular(24)),
                      isDense: true,
                      filled: true,
                      suffixIcon: q.text.isEmpty
                          ? null
                          : IconButton(
                              icon: const Icon(Icons.close),
                              onPressed: () {
                                q.clear();
                              },
                            ),
                    ),
                    textInputAction: TextInputAction.search,
                    onSubmitted: (_) => _filter(),
                  ),
                ),
                IconButton(tooltip: 'Refresh', onPressed: _load, icon: const Icon(Icons.refresh)),
              ],
            ),
          ),
          Expanded(
            child: view.isEmpty
                ? const Center(child: Text('No patients found'))
                : ListView.builder(
                    physics: const AlwaysScrollableScrollPhysics(),
                    itemCount: view.length,
                    itemBuilder: (_, i) {
                      final p = view[i];
                      final subtitle = [
                        if (p.email != null) p.email!,
                        if (p.phone != null) p.phone!,
                      ].join(' • ');
                      return personTile(
                        context: _,
                        title: p.name.isEmpty ? 'Patient #${p.id}' : p.name,
                        subtitle: subtitle.isEmpty ? 'ID: ${p.id}' : subtitle,
                        trailing: null,
                        // CTRL+F: [PATIENTS onTap → push detail page]
                        onTap: () => Navigator.of(context).push(
                          MaterialPageRoute(builder: (_) => PatientDetailPage(patientId: p.id)),
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
  _PatientRow({required this.id, required this.name, this.email, this.phone, this.address, this.visitingFee});
}

/// ───────────────────── Appointments (approve/reject + detail) ─────────────────────
class _AdminAppointmentsTab extends StatefulWidget {
  const _AdminAppointmentsTab();

  @override
  State<_AdminAppointmentsTab> createState() => _AdminAppointmentsTabState();
}

class _AdminAppointmentsTabState extends State<_AdminAppointmentsTab> {
  final df = DateFormat.yMMMd().add_jm();

  List<dynamic> items = [];
  bool loading = true;

  @override
  void initState() {
    super.initState();
    _load();
  }

  Future<void> _load() async {
    setState(() => loading = true);
    try {
      final res = await Api.get('/admin/appointments');
      items = res as List;
    } catch (e) {
      if (mounted) showSnack(context, 'Load failed: $e');
      items = [];
    } finally {
      if (mounted) setState(() => loading = false);
    }
  }

  Future<void> _approve(int id, bool ok) async {
    try {
      await Api.patch('/admin/appointments/$id/approve', data: {'approve': ok});
      await _load();
    } catch (e) {
      if (mounted) showSnack(context, 'Action failed: $e');
    }
  }

  @override
  Widget build(BuildContext context) {
    if (loading) return const Center(child: CircularProgressIndicator());
    if (items.isEmpty) {
      return RefreshIndicator(
        onRefresh: _load,
        child: ListView(children: const [SizedBox(height: 240), Center(child: Text('No appointments'))]),
      );
    }
    return RefreshIndicator(
      onRefresh: _load,
      child: ListView.builder(
        itemCount: items.length,
        itemBuilder: (_, i) {
          final a = items[i] as Map<String, dynamic>;
          final idDyn = a['id'];
          final apptId = (idDyn is num) ? idDyn.toInt() : int.tryParse('$idDyn') ?? 0;

          final st = a['start_time'];
          final en = a['end_time'];
          DateTime? s, e;
          if (st is String) s = DateTime.tryParse(st);
          if (st is DateTime) s = st;
          if (en is String) e = DateTime.tryParse(en);
          if (en is DateTime) e = en;

          final when = [
            if (s != null) df.format(s.toLocal()),
            if (e != null) '→ ${df.format(e.toLocal())}',
          ].join(' ');

          final status = (a['status'] ?? '').toString();
          final pay = (a['payment_status'] ?? '').toString();

          return InkWell(
            borderRadius: BorderRadius.circular(14),
            // CTRL+F: [APPOINTMENT onTap → push detail page]
            onTap: () {
              if (apptId > 0) {
                Navigator.of(context).push(
                  MaterialPageRoute(builder: (_) => AppointmentDetailPage(apptId: apptId)),
                );
              }
            },
            child: Card(
              margin: const EdgeInsets.symmetric(horizontal: 12, vertical: 6),
              shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(14)),
              child: Padding(
                padding: const EdgeInsets.fromLTRB(12, 12, 12, 8),
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.stretch,
                  children: [
                    Text('Appointment #$apptId', style: const TextStyle(fontWeight: FontWeight.w700)),
                    const SizedBox(height: 2),
                    Text(when.isEmpty ? '—' : when, maxLines: 2, overflow: TextOverflow.ellipsis),
                    const SizedBox(height: 6),
                    Wrap(
                      spacing: 8,
                      runSpacing: 8,
                      children: [
                        _chip(status),
                        _chip(pay, tone: 'info'),
                        OutlinedButton.icon(
                          onPressed: apptId == 0 ? null : () => _approve(apptId, true),
                          icon: const Icon(Icons.check, size: 18),
                          label: const Text('Approve'),
                        ),
                        OutlinedButton.icon(
                          onPressed: apptId == 0 ? null : () => _approve(apptId, false),
                          icon: const Icon(Icons.close, size: 18),
                          label: const Text('Reject'),
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
    );
  }

  Widget _chip(String text, {String tone = 'ok'}) {
    Color bg, fg;
    switch (tone) {
      case 'info':
        bg = Colors.blue.withOpacity(.12);
        fg = Colors.blue.shade800;
        break;
      case 'warn':
        bg = Colors.amber.withOpacity(.18);
        fg = Colors.amber.shade900;
        break;
      default:
        if (text.toLowerCase().contains('approved') || text.toLowerCase().contains('paid')) {
          bg = Colors.green.withOpacity(.15);
          fg = Colors.green.shade800;
        } else if (text.toLowerCase().contains('pending') || text.toLowerCase().contains('requested')) {
          bg = Colors.orange.withOpacity(.15);
          fg = Colors.orange.shade800;
        } else {
          bg = Colors.red.withOpacity(.15);
          fg = Colors.red.shade800;
        }
    }
    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 6),
      decoration: BoxDecoration(color: bg, borderRadius: BorderRadius.circular(24)),
      child: Text(text, style: TextStyle(color: fg, fontWeight: FontWeight.w600)),
    );
  }
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
            shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(16)),
            child: Padding(
              padding: const EdgeInsets.all(16),
              child: Row(
                children: [
                  CircleAvatar(
                    radius: 30,
                    child: Text(
                      widget.me.name.isNotEmpty ? widget.me.name[0].toUpperCase() : '?',
                      style: theme.textTheme.titleLarge?.copyWith(color: Colors.white),
                    ),
                  ),
                  const SizedBox(width: 16),
                  Expanded(
                    child: Text(widget.me.name, style: theme.textTheme.titleLarge),
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
      decoration: InputDecoration(
        labelText: label,
        border: const OutlineInputBorder(),
      ),
    );
  }
}

/// ─────────────────────────── Detail Pages (full screen) ───────────────────────────

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
      showSnack(context, 'Load failed: $e');
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
    final bg  = (m?['background'] ?? '').toString();

    return Scaffold(
      appBar: AppBar(title: Text(name.isNotEmpty ? name : 'Doctor #${widget.doctorId}')),
      body: loading
          ? const Center(child: CircularProgressIndicator())
          : ListView(
              padding: const EdgeInsets.fromLTRB(16, 16, 16, 24),
              children: [
                Row(
                  children: [
                    const CircleAvatar(radius: 28, child: Icon(Icons.local_hospital)),
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
                            builder: (_) => DoctorAvailabilityPage(doctorId: widget.doctorId),
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

class DoctorAvailabilityPage extends StatefulWidget {
  const DoctorAvailabilityPage({super.key, required this.doctorId});
  final int doctorId;

  @override
  State<DoctorAvailabilityPage> createState() => _DoctorAvailabilityPageState();
}

class _DoctorAvailabilityPageState extends State<DoctorAvailabilityPage> {
  final dfDate = DateFormat.yMMMd();
  final dfTime = DateFormat.Hm();

  bool loading = true;
  bool loadingWeek = true;

  // Week window
  late DateTime _from;
  late DateTime _to;

  // Availability slots grouped per day
  final Map<DateTime, List<Map<String, DateTime>>> _slotsByDay = {};
  // Appointments for this doctor within the week
  List<Map<String, dynamic>> _appts = [];

  int _tabIndex = 0; // 0 = Availability, 1 = Appointments

  @override
  void initState() {
    super.initState();
    _initWeek(DateTime.now());
    _load();
  }

  void _initWeek(DateTime anchor) {
    final start = DateTime(anchor.year, anchor.month, anchor.day);
    _from = start;
    _to = start.add(const Duration(days: 7));
  }

  Future<void> _load() async {
    setState(() { loading = true; loadingWeek = true; _slotsByDay.clear(); _appts = []; });
    await Future.wait([_loadAvailability(), _loadAppointments()]);
    if (mounted) setState(() { loading = false; loadingWeek = false; });
  }

  Future<void> _loadAvailability() async {
    final id = widget.doctorId;
    final qs = {
      'doctor_id': id,
      'start': _from.toIso8601String(),
      'end': _to.toIso8601String(),
    };

    final urls = <String>[
      '/doctors/$id/availability',
      '/doctor/$id/availability',
      '/availability',
      '/appointments/slots',
      '/doctors/$id/slots',
    ];

    dynamic res;
    for (final u in urls) {
      try {
        res = await Api.get(u, query: qs);
        if (res != null) break;
      } catch (_) {}
    }
    if (res == null) return;

    // Normalize into list of {start: DateTime, end: DateTime}
    List<Map<String, DateTime>> slots = [];
    if (res is Map && res['slots'] is List) {
      for (final s in (res['slots'] as List)) {
        final m = s is Map ? Map<String, dynamic>.from(s) : {};
        final st = DateTime.tryParse('${m['start'] ?? m['from'] ?? ''}');
        final en = DateTime.tryParse('${m['end'] ?? m['to'] ?? ''}');
        if (st != null && en != null) slots.add({'start': st, 'end': en});
      }
    } else if (res is List) {
      for (final s in res) {
        if (s is String) {
          final st = DateTime.tryParse(s);
          if (st != null) slots.add({'start': st, 'end': st.add(const Duration(minutes: 30))});
        } else if (s is Map) {
          final m = Map<String, dynamic>.from(s);
          final st = DateTime.tryParse('${m['start'] ?? m['from'] ?? ''}');
          final en = DateTime.tryParse('${m['end'] ?? m['to'] ?? ''}');
          if (st != null && en != null) slots.add({'start': st, 'end': en});
        }
      }
    }

    // Group by calendar day
    for (final slot in slots) {
      final st = slot['start']!;
      final key = DateTime(st.year, st.month, st.day);
      (_slotsByDay[key] ??= []).add(slot);
    }

    // Sort each day’s slots
    for (final k in _slotsByDay.keys) {
      _slotsByDay[k]!.sort((a, b) => a['start']!.compareTo(b['start']!));
    }
  }

  Future<void> _loadAppointments() async {
    final id = widget.doctorId;
    final urls = <String>[
      '/admin/appointments',
      '/appointments',
      '/admin/doctor/$id/appointments',
    ];

    dynamic res;
    for (final u in urls) {
      try {
        res = await Api.get(u, query: {
          'doctor_id': id,
          'from': _from.toIso8601String(),
          'to': _to.toIso8601String(),
        });
        if (res != null) break;
      } catch (_) {}
    }

    List<Map<String, dynamic>> rows = [];
    if (res is List) {
      rows = res.map((e) => Map<String, dynamic>.from(e as Map)).toList();
    } else if (res is Map && res['items'] is List) {
      rows = (res['items'] as List).map((e) => Map<String, dynamic>.from(e as Map)).toList();
    }

    // Client-side window filter
    _appts = rows.where((a) {
      DateTime? st;
      final v = a['start_time'];
      if (v is String) st = DateTime.tryParse(v);
      if (v is DateTime) st = v;
      if (st == null) return false;
      return st.isAfter(_from.subtract(const Duration(seconds: 1))) &&
             st.isBefore(_to.add(const Duration(seconds: 1)));
    }).toList()
      ..sort((a, b) {
        DateTime A = DateTime.tryParse('${a['start_time']}') ?? DateTime(1970);
        DateTime B = DateTime.tryParse('${b['start_time']}') ?? DateTime(1970);
        return A.compareTo(B);
      });
  }

  void _prevWeek() {
    setState(() {
      _from = _from.subtract(const Duration(days: 7));
      _to = _to.subtract(const Duration(days: 7));
      loadingWeek = true;
    });
    _load();
  }

  void _nextWeek() {
    setState(() {
      _from = _from.add(const Duration(days: 7));
      _to = _to.add(const Duration(days: 7));
      loadingWeek = true;
    });
    _load();
  }

  @override
  Widget build(BuildContext context) {
    final title = '${dfDate.format(_from)}  →  ${dfDate.format(_to.subtract(const Duration(days: 1)))}';

    return Scaffold(
      appBar: AppBar(
        title: const Text('Doctor Availability'),
        actions: [
          IconButton(
            tooltip: 'Refresh',
            onPressed: loadingWeek ? null : _load,
            icon: const Icon(Icons.refresh),
          ),
        ],
      ),
      body: loading
          ? const Center(child: CircularProgressIndicator())
          : Column(
              children: [
                // Week navigator
                Padding(
                  padding: const EdgeInsets.fromLTRB(12, 8, 12, 0),
                  child: Row(
                    children: [
                      IconButton(onPressed: loadingWeek ? null : _prevWeek, icon: const Icon(Icons.chevron_left)),
                      Expanded(
                        child: Text(title, textAlign: TextAlign.center, style: const TextStyle(fontWeight: FontWeight.w600)),
                      ),
                      IconButton(onPressed: loadingWeek ? null : _nextWeek, icon: const Icon(Icons.chevron_right)),
                    ],
                  ),
                ),

                // Tabs
                Padding(
                  padding: const EdgeInsets.fromLTRB(12, 6, 12, 4),
                  child: SegmentedButton<int>(
                    segments: const [
                      ButtonSegment(value: 0, icon: Icon(Icons.event_available), label: Text('Availability')),
                      ButtonSegment(value: 1, icon: Icon(Icons.event_note), label: Text('Appointments')),
                    ],
                    selected: {_tabIndex},
                    onSelectionChanged: (s) => setState(() => _tabIndex = s.first),
                  ),
                ),

                const SizedBox(height: 4),

                Expanded(
                  child: RefreshIndicator(
                    onRefresh: _load,
                    child: _tabIndex == 0 ? _buildAvailabilityList() : _buildAppointmentsList(),
                  ),
                ),
              ],
            ),
    );
  }

  Widget _buildAvailabilityList() {
    if (_slotsByDay.isEmpty) {
      return ListView(
        children: const [
          SizedBox(height: 220),
          Center(child: Text('No available slots in this window')),
        ],
      );
    }

    final days = _slotsByDay.keys.toList()..sort();
    return ListView.builder(
      padding: const EdgeInsets.fromLTRB(12, 4, 12, 12),
      itemCount: days.length,
      itemBuilder: (_, i) {
        final day = days[i];
        final slots = _slotsByDay[day]!;
        return Card(
          margin: const EdgeInsets.symmetric(vertical: 6),
          shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(14)),
          child: Padding(
            padding: const EdgeInsets.fromLTRB(12, 10, 12, 12),
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Text(dfDate.format(day), style: const TextStyle(fontWeight: FontWeight.w700)),
                const SizedBox(height: 8),
                Wrap(
                  spacing: 10,
                  runSpacing: 10,
                  children: slots.map((s) {
                    final st = s['start']!;
                    final en = s['end']!;
                    return Container(
                      padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 6),
                      decoration: BoxDecoration(
                        borderRadius: BorderRadius.circular(999),
                        color: Theme.of(context).colorScheme.primary.withOpacity(.10),
                      ),
                      child: Text('${dfTime.format(st.toLocal())} – ${dfTime.format(en.toLocal())}'),
                    );
                  }).toList(),
                ),
              ],
            ),
          ),
        );
      },
    );
  }

  Widget _buildAppointmentsList() {
    if (_appts.isEmpty) {
      return ListView(
        children: const [
          SizedBox(height: 220),
          Center(child: Text('No appointments in this window')),
        ],
      );
    }

    final df = DateFormat.yMMMd().add_jm();

    return ListView.builder(
      padding: const EdgeInsets.fromLTRB(12, 4, 12, 12),
      itemCount: _appts.length,
      itemBuilder: (_, i) {
        final a = _appts[i];
        final id = a['id'];
        DateTime? s, e;
        final st = a['start_time'];
        final en = a['end_time'];
        if (st is String) s = DateTime.tryParse(st);
        if (st is DateTime) s = st;
        if (en is String) e = DateTime.tryParse(en);
        if (en is DateTime) e = en;

        final when = [
          if (s != null) df.format(s.toLocal()),
          if (e != null) '→ ${df.format(e.toLocal())}',
        ].join(' ');

        final status = (a['status'] ?? '').toString();
        final pay = (a['payment_status'] ?? '').toString();
        final pat = a['patient'];
        final patientName = (pat is Map && pat['name'] != null) ? '${pat['name']}' : '';

        return Card(
          margin: const EdgeInsets.symmetric(vertical: 6),
          shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(14)),
          child: InkWell(
            borderRadius: BorderRadius.circular(14),
            onTap: () {
              final apptId = (id is num) ? id.toInt() : int.tryParse('$id');
              if (apptId != null) {
                Navigator.of(context).push(
                  MaterialPageRoute(builder: (_) => AppointmentDetailPage(apptId: apptId)),
                );
              }
            },
            child: Padding(
              padding: const EdgeInsets.fromLTRB(12, 12, 12, 8),
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.stretch,
                children: [
                  Text('Appointment #$id', style: const TextStyle(fontWeight: FontWeight.w700)),
                  const SizedBox(height: 2),
                  Text(
                    [
                      if (patientName.isNotEmpty) patientName,
                      if (when.isNotEmpty) when,
                    ].join(' • '),
                    maxLines: 2,
                    overflow: TextOverflow.ellipsis,
                  ),
                  const SizedBox(height: 6),
                  Wrap(
                    spacing: 8,
                    runSpacing: 8,
                    children: [
                      _pill('Status: $status'),
                      _pill('Payment: $pay', color: Colors.blue),
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

  // Use MaterialColor so .shade800 exists at compile time
  Widget _pill(String text, {MaterialColor? color}) {
    final mat = color ?? Colors.green;
    final bg = mat.withOpacity(.14);
    final fg = mat.shade800;
    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 6),
      decoration: BoxDecoration(color: bg, borderRadius: BorderRadius.circular(24)),
      child: Text(text, style: TextStyle(color: fg, fontWeight: FontWeight.w600)),
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
    if (end != null && end.isBefore(DateTime.now())) {
      return false;
    }
    return true; // not_yet, in_progress, hold, requested
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

      // appointments for patient
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

      List<Map<String, dynamic>> rows = [];
      if (res is List) {
        rows = res.map((e) => Map<String, dynamic>.from(e as Map)).toList();
      } else if (res is Map && res['items'] is List) {
        rows = (res['items'] as List).map((e) => Map<String, dynamic>.from(e as Map)).toList();
      }
      _appts = rows..sort((a, b) {
        DateTime A = DateTime.tryParse('${a['start_time']}') ?? DateTime(1970);
        DateTime B = DateTime.tryParse('${b['start_time']}') ?? DateTime(1970);
        return B.compareTo(A); // latest first
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
    final name  = (m?['name'] ?? '').toString();
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
          if (_running.isEmpty)
            const Text('None')
          else
            ..._running.map(_apptTile).toList(),

          const SizedBox(height: 16),
          Text('Appointment History', style: Theme.of(context).textTheme.titleMedium),
          const SizedBox(height: 6),
          if (_history.isEmpty)
            const Text('No past appointments')
          else
            ..._history.map(_apptTile).toList(),
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
            Navigator.of(context).push(
              MaterialPageRoute(builder: (_) => AppointmentDetailPage(apptId: apptId)),
            );
          }
        },
      ),
    );
  }
}

/// ─────────────────────────── Appointment Detail (incl. prescriptions & reports) ───────────────────────────
class AppointmentDetailPage extends StatefulWidget {
  const AppointmentDetailPage({super.key, required this.apptId});
  final int apptId;

  @override
  State<AppointmentDetailPage> createState() => _AppointmentDetailPageState();
}

class _AppointmentDetailPageState extends State<AppointmentDetailPage> {
  Map<String, dynamic>? m;
  bool loading = true;

  final df = DateFormat.yMMMd().add_jm();

  List<Map<String, dynamic>> _prescriptions = [];
  List<Map<String, dynamic>> _reports = [];
  bool loadingExtras = true;

  @override
  void initState() {
    super.initState();
    _load();
  }

  Future<void> _load() async {
    setState(() { loading = true; loadingExtras = true; });
    try {
      final r = await Api.get('/appointments/${widget.apptId}');
      if (r is Map) m = Map<String, dynamic>.from(r);
    } catch (e) {
      showSnack(context, 'Load failed: $e');
    } finally {
      if (mounted) setState(() => loading = false);
    }

    await _loadExtras();
  }

  Future<void> _loadExtras() async {
    setState(() => loadingExtras = true);
    try {
      dynamic pres, reps;

      // Prescriptions
      try {
        pres = await Api.get('/appointments/${widget.apptId}/prescriptions');
      } catch (_) {
        pres = await Api.get('/prescriptions', query: {'appointment_id': widget.apptId});
      }

      // Reports
      try {
        reps = await Api.get('/appointments/${widget.apptId}/reports');
      } catch (_) {
        reps = await Api.get('/reports', query: {'appointment_id': widget.apptId});
      }

      if (pres is List) {
        _prescriptions = pres.map((e) => Map<String, dynamic>.from(e as Map)).toList();
      } else if (pres is Map && pres['items'] is List) {
        _prescriptions = (pres['items'] as List).map((e) => Map<String, dynamic>.from(e as Map)).toList();
      }

      if (reps is List) {
        _reports = reps.map((e) => Map<String, dynamic>.from(e as Map)).toList();
      } else if (reps is Map && reps['items'] is List) {
        _reports = (reps['items'] as List).map((e) => Map<String, dynamic>.from(e as Map)).toList();
      }
    } catch (e) {
      // best-effort
    } finally {
      if (mounted) setState(() => loadingExtras = false);
    }
  }

  Future<void> _approve(bool ok) async {
    try {
      await Api.patch('/admin/appointments/${widget.apptId}/approve', data: {'approve': ok});
      await _load();
      if (mounted) showSnack(context, ok ? 'Approved' : 'Rejected');
    } catch (e) {
      if (mounted) showSnack(context, 'Action failed: $e');
    }
  }

  Future<void> _addReportDialog() async {
    final title = TextEditingController();
    final note = TextEditingController();

    await showDialog(
      context: context,
      builder: (_) => AlertDialog(
        title: const Text('Add Report'),
        content: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            TextField(controller: title, decoration: const InputDecoration(labelText: 'Title')),
            const SizedBox(height: 8),
            TextField(controller: note, minLines: 3, maxLines: 6, decoration: const InputDecoration(labelText: 'Note')),
          ],
        ),
        actions: [
          TextButton(onPressed: () => Navigator.pop(context), child: const Text('Cancel')),
          FilledButton(
            onPressed: () async {
              try {
                // Try admin-first, then generic
                try {
                  await Api.post('/appointments/${widget.apptId}/reports', data: {
                    'title': title.text.isEmpty ? null : title.text,
                    'note': note.text,
                  });
                } catch (_) {
                  await Api.post('/reports', data: {
                    'appointment_id': widget.apptId,
                    'title': title.text.isEmpty ? null : title.text,
                    'note': note.text,
                  });
                }
                if (mounted) Navigator.pop(context);
                await _loadExtras();
                if (mounted) showSnack(context, 'Report added');
              } catch (e) {
                if (mounted) showSnack(context, 'Add failed: $e');
              }
            },
            child: const Text('Save'),
          ),
        ],
      ),
    );
  }

  @override
  Widget build(BuildContext context) {
    final id = widget.apptId;
    final status = (m?['status'] ?? '').toString();
    final pay = (m?['payment_status'] ?? '').toString();
    final mode = (m?['visit_mode'] ?? m?['mode'] ?? '').toString();

    DateTime? s, e;
    final st = m?['start_time'];
    final en = m?['end_time'];
    if (st is String) s = DateTime.tryParse(st);
    if (st is DateTime) s = st;
    if (en is String) e = DateTime.tryParse(en);
    if (en is DateTime) e = en;

    final doc = (m?['doctor'] is Map) ? Map<String, dynamic>.from(m?['doctor']) : null;
    final pat = (m?['patient'] is Map) ? Map<String, dynamic>.from(m?['patient']) : null;
    final doctorId = (doc?['id'] is num) ? (doc?['id'] as num).toInt() : null;
    final patientId = (pat?['id'] is num) ? (pat?['id'] as num).toInt() : null;
    final doctorName = (doc?['name'] ?? (doctorId != null ? 'Doctor #$doctorId' : '—')).toString();
    final patientName = (pat?['name'] ?? (patientId != null ? 'Patient #$patientId' : '—')).toString();

    if (loading) return const Center(child: CircularProgressIndicator());

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
            onTap: doctorId == null ? null : () {
              Navigator.of(context).push(MaterialPageRoute(
                builder: (_) => DoctorDetailPage(doctorId: doctorId),
              ));
            },
          ),
          ListTile(
            contentPadding: EdgeInsets.zero,
            leading: const CircleAvatar(child: Icon(Icons.person)),
            title: Text(patientName, maxLines: 1, overflow: TextOverflow.ellipsis),
            subtitle: const Text('View patient profile'),
            onTap: patientId == null ? null : () {
              Navigator.of(context).push(MaterialPageRoute(
                builder: (_) => PatientDetailPage(patientId: patientId),
              ));
            },
          ),
          const Divider(),
          _kv('Status', status.isNotEmpty ? status : '—'),
          _kv('Payment', pay.isNotEmpty ? pay : '—'),
          if (mode.isNotEmpty) _kv('Mode', mode),
          if (s != null) _kv('Start', df.format(s.toLocal())),
          if (e != null) _kv('End',   df.format(e.toLocal())),
          const SizedBox(height: 12),
          Wrap(
            spacing: 12,
            runSpacing: 12,
            children: [
              FilledButton.icon(
                onPressed: () => _approve(true),
                icon: const Icon(Icons.check),
                label: const Text('Approve'),
              ),
              OutlinedButton.icon(
                onPressed: () => _approve(false),
                icon: const Icon(Icons.close),
                label: const Text('Reject'),
              ),
              OutlinedButton.icon(
                onPressed: _addReportDialog,
                icon: const Icon(Icons.note_add),
                label: const Text('Add Report'),
              ),
            ],
          ),

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
              return Card(
                margin: const EdgeInsets.symmetric(vertical: 6),
                child: ListTile(
                  leading: const Icon(Icons.medical_services_outlined),
                  title: Text(title, maxLines: 1, overflow: TextOverflow.ellipsis),
                  subtitle: when.isEmpty ? null : Text(when),
                ),
              );
            }),

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
                    ],
                  ),
                ),
              );
            }),
        ],
      ),
    );
  }
}
