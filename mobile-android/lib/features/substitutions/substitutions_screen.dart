import 'package:flutter/material.dart';
import '../../core/database/app_database.dart';

/// "Zastępstwa" (hybrid dashboard milestone, P1 native + offline —
/// READ ONLY). Review round: the backend write-flow (accept/create a
/// substitution) has a known bug (see docs/HOTFIX-substitution_history.md)
/// and isn't safe to build on yet — this screen shows status only.
/// Actually requesting/accepting a substitution still goes through the
/// existing `substitution_finder.php` WebView module until a real,
/// verified write/actions mechanism exists for it.
class SubstitutionsScreen extends StatelessWidget {
  const SubstitutionsScreen({super.key, required this.db});

  final AppDatabase db;

  @override
  Widget build(BuildContext context) {
    return DefaultTabController(
      length: 2,
      child: Scaffold(
        appBar: AppBar(
          title: const Text('Zastępstwa'),
          bottom: const TabBar(tabs: [Tab(text: 'Moje prośby'), Tab(text: 'Dostępne')]),
        ),
        body: StreamBuilder<List<SubstitutionRequest>>(
          stream: db.watchSubstitutions(),
          builder: (context, snapshot) {
            if (!snapshot.hasData) {
              return const Center(child: CircularProgressIndicator());
            }
            final all = snapshot.data!;
            final mine = all.where((r) => r.isMine).toList();
            final available = all.where((r) => !r.isMine).toList();

            return TabBarView(
              children: [
                _RequestList(items: mine, emptyMessage: 'Nie masz żadnych aktywnych próśb o zastępstwo.'),
                _RequestList(items: available, emptyMessage: 'Brak dostępnych zastępstw do przejęcia.'),
              ],
            );
          },
        ),
      ),
    );
  }
}

class _RequestList extends StatelessWidget {
  const _RequestList({required this.items, required this.emptyMessage});
  final List<SubstitutionRequest> items;
  final String emptyMessage;

  @override
  Widget build(BuildContext context) {
    if (items.isEmpty) {
      return Center(child: Text(emptyMessage, textAlign: TextAlign.center, style: const TextStyle(color: Colors.grey)));
    }
    return ListView.builder(
      padding: const EdgeInsets.symmetric(vertical: 8),
      itemCount: items.length,
      itemBuilder: (context, i) => _RequestTile(request: items[i]),
    );
  }
}

class _RequestTile extends StatelessWidget {
  const _RequestTile({required this.request});
  final SubstitutionRequest request;

  @override
  Widget build(BuildContext context) {
    final date = request.eventDate?.toLocal();
    return Card(
      margin: const EdgeInsets.symmetric(horizontal: 12, vertical: 4),
      child: ListTile(
        leading: Icon(Icons.swap_horiz, color: _statusColor(request.status)),
        title: Text(request.eventDescription?.isNotEmpty == true ? request.eventDescription! : 'Msza'),
        subtitle: Text([
          if (date != null) '${date.day.toString().padLeft(2, '0')}.${date.month.toString().padLeft(2, '0')}.${date.year}',
          if (!request.isMine) 'Prosi: ${request.requestingUserName}',
          if (request.acceptedByName != null) 'Przejął: ${request.acceptedByName}',
        ].join(' • ')),
        trailing: Chip(
          label: Text(_statusLabel(request.status), style: const TextStyle(fontSize: 12)),
          backgroundColor: _statusColor(request.status).withOpacity(0.15),
        ),
      ),
    );
  }

  String _statusLabel(String status) {
    switch (status) {
      case 'pending':
        return 'Oczekuje';
      case 'accepted':
        return 'Zaakceptowane';
      case 'cancelled':
        return 'Anulowane';
      case 'expired':
        return 'Wygasłe';
      default:
        return status;
    }
  }

  Color _statusColor(String status) {
    switch (status) {
      case 'pending':
        return Colors.orange;
      case 'accepted':
        return Colors.green;
      case 'cancelled':
      case 'expired':
        return Colors.grey;
      default:
        return Colors.blueGrey;
    }
  }
}
