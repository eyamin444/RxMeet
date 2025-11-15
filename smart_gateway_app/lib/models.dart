// lib/models.dart
// Robust, forward-compatible models with tolerant decoding.

// ───────────────────────── Shared decode helpers ─────────────────────────
int _asInt(dynamic v, {int fallback = 0}) {
  if (v == null) return fallback;
  if (v is num) return v.toInt();
  return int.tryParse('$v') ?? fallback;
}

double? _asDoubleN(dynamic v) {
  if (v == null) return null;
  if (v is num) return v.toDouble();
  final s = ('$v').trim();
  if (s.isEmpty) return null;
  return double.tryParse(s);
}

double _asDouble(dynamic v, {double fallback = 0}) {
  return _asDoubleN(v) ?? fallback;
}

String? _asStringN(dynamic v) {
  if (v == null) return null;
  final s = ('$v').trim();
  return s.isEmpty ? null : s;
}

String _asString(dynamic v, {String fallback = ''}) {
  return _asStringN(v) ?? fallback;
}

// ───────────────────────── User ─────────────────────────
class User {
  final int id;
  final String name;
  final String? email;
  final String? phone;
  final String role;
  final String? photoPath;

  User({
    required this.id,
    required this.name,
    this.email,
    this.phone,
    required this.role,
    this.photoPath,
  });

  factory User.fromJson(Map<String, dynamic> j) => User(
        id: _asInt(j['id']),
        name: _asString(j['name']),
        email: _asStringN(j['email']),
        phone: _asStringN(j['phone'] ?? j['mobile']),
        role: _asString(j['role'], fallback: 'patient'),
        photoPath: _asStringN(j['photo_path'] ?? j['photo']),
      );

  Map<String, dynamic> toJson() => {
        'id': id,
        'name': name,
        'email': email,
        'phone': phone,
        'role': role,
        'photo_path': photoPath,
      };
}

// ───────────────────────── Doctor ─────────────────────────
// Includes tolerant parsing for address/visiting_fee and mixed-type text fields.
class Doctor {
  final int id;
  final String name;
  final String? email;
  final String specialty;
  final String category;
  final String keywords;
  final String bio;
  final String background;
  final int rating;            // keep int for backwards-compat
  final String? photoPath;

  // Optional fields often added later
  final String? phone;
  final String? address;
  final double? visitingFee;

  Doctor({
    required this.id,
    required this.name,
    this.email,
    required this.specialty,
    required this.category,
    required this.keywords,
    required this.bio,
    required this.background,
    required this.rating,
    this.photoPath,
    this.phone,
    this.address,
    this.visitingFee,
  });

  factory Doctor.fromJson(Map<String, dynamic> j) => Doctor(
        id: _asInt(j['id'] ?? j['doctor_id']),
        name: _asString(j['name']),
        email: _asStringN(j['email']),
        specialty: _asString(j['specialty']),
        category: _asString(j['category'], fallback: 'General'),
        keywords: _asString(j['keywords']),
        bio: _asString(j['bio']),
        background: _asString(j['background']),
        rating: _asInt(j['rating']),
        photoPath: _asStringN(j['photo_path'] ?? j['photo']),
        phone: _asStringN(j['phone']),
        address: _asStringN(j['address']),
        visitingFee: _asDoubleN(j['visiting_fee'] ?? j['visitingFee'] ?? j['fee']),
      );

  Map<String, dynamic> toJson() => {
        'id': id,
        'name': name,
        'email': email,
        'specialty': specialty,
        'category': category,
        'keywords': keywords,
        'bio': bio,
        'background': background,
        'rating': rating,
        'photo_path': photoPath,
        'phone': phone,
        'address': address,
        'visiting_fee': visitingFee,
      };
}

// ───────────────────────── Appointment ─────────────────────────
class Appointment {
  final int id;
  final int doctorId;
  final int patientId;
  final DateTime start;
  final DateTime end;
  final String status;
  final String paymentStatus;
  final String visitMode;
  final String patientProblem;
  final String progress;
  final String? videoRoom;

  Appointment({
    required this.id,
    required this.doctorId,
    required this.patientId,
    required this.start,
    required this.end,
    required this.status,
    required this.paymentStatus,
    required this.visitMode,
    required this.patientProblem,
    required this.progress,
    this.videoRoom,
  });

  factory Appointment.fromJson(Map<String, dynamic> j) => Appointment(
        id: _asInt(j['id']),
        doctorId: _asInt(j['doctor_id']),
        patientId: _asInt(j['patient_id']),
        start: DateTime.tryParse(_asString(j['start_time'])) ??
            DateTime.fromMillisecondsSinceEpoch(0, isUtc: true),
        end: DateTime.tryParse(_asString(j['end_time'])) ??
            DateTime.fromMillisecondsSinceEpoch(0, isUtc: true),
        status: _asString(j['status'], fallback: 'pending'),
        paymentStatus: _asString(j['payment_status'], fallback: 'unpaid'),
        visitMode: _asString(j['visit_mode'] ?? j['mode'], fallback: 'offline'),
        patientProblem: _asString(j['patient_problem']),
        progress: _asString(j['progress'], fallback: 'not_yet'),
        videoRoom: _asStringN(j['video_room'] ?? j['room']),
      );

  Map<String, dynamic> toJson() => {
        'id': id,
        'doctor_id': doctorId,
        'patient_id': patientId,
        'start_time': start.toIso8601String(),
        'end_time': end.toIso8601String(),
        'status': status,
        'payment_status': paymentStatus,
        'visit_mode': visitMode,
        'patient_problem': patientProblem,
        'progress': progress,
        'video_room': videoRoom,
      };
}

// ───────────────────────── Local-only (UI) helpers ─────────────────────────
class _MedRow {
  final int id;
  String name;
  String dose;
  String form;
  String frequency;
  String duration;
  String notes;

  _MedRow({
    required this.id,
    this.name = '',
    this.dose = '',
    this.form = '',
    this.frequency = '',
    this.duration = '',
    this.notes = '',
  });
}
