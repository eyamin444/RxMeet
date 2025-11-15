import 'package:flutter/material.dart';
import '../../services/api.dart';
import '../../widgets/snack.dart';

class PaymentScreen extends StatefulWidget {
  const PaymentScreen({super.key, required this.appointmentId});
  final int appointmentId;

  @override
  State<PaymentScreen> createState() => _PaymentScreenState();
}

class _PaymentScreenState extends State<PaymentScreen> {
  final txn = TextEditingController();
  final method = ValueNotifier<String>('cash');
  final amount = TextEditingController();

  Future<void> _pay() async {
    try {
      await Api.post('/appointments/${widget.appointmentId}/pay', data: {
        'transaction_id': txn.text.isEmpty ? 'manual-${DateTime.now().millisecondsSinceEpoch}' : txn.text,
        'method': method.value,
        'amount': double.tryParse(amount.text),
        'raw': '',
      });
      if (!mounted) return;
      showSnack(context, 'Payment saved');
      Navigator.of(context).pop();
    } catch (e) {
      showSnack(context, 'Pay failed: $e');
    }
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: AppBar(title: Text('Payment — Appt #${widget.appointmentId}')),
      body: ListView(
        padding: const EdgeInsets.all(12),
        children: [
          DropdownButtonFormField<String>(
            value: method.value,
            decoration: const InputDecoration(border: OutlineInputBorder(), labelText: 'Method'),
            items: const [
              DropdownMenuItem(value: 'cash', child: Text('Cash')),
              DropdownMenuItem(value: 'bkash', child: Text('bKash')),
              DropdownMenuItem(value: 'card', child: Text('Card')),
              DropdownMenuItem(value: 'other', child: Text('Other')),
            ],
            onChanged: (v) => method.value = v ?? 'cash',
          ),
          const SizedBox(height: 10),
          TextField(
            controller: amount,
            decoration: const InputDecoration(border: OutlineInputBorder(), labelText: 'Amount (optional)'),
            keyboardType: const TextInputType.numberWithOptions(decimal: true),
          ),
          const SizedBox(height: 10),
          TextField(
            controller: txn,
            decoration: const InputDecoration(border: OutlineInputBorder(), labelText: 'Transaction ID (optional)'),
          ),
          const SizedBox(height: 14),
          FilledButton.icon(onPressed: _pay, icon: const Icon(Icons.check), label: const Text('Save payment')),
        ],
      ),
    );
  }
}
