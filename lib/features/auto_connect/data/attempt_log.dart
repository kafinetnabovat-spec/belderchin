import 'dart:collection';

import 'package:hiddify/features/auto_connect/model/connection_candidate.dart';
import 'package:meta/meta.dart';

/// Outcome of one candidate attempt, kept in memory only (never written to
/// disk, never uploaded). Shown on the troubleshooting page.
@immutable
class AttemptRecord {
  const AttemptRecord({
    required this.at,
    required this.candidateId,
    required this.candidateName,
    required this.layer,
    required this.outcome,
    this.detail,
    this.latency,
  });

  final DateTime at;
  final String candidateId;
  final String candidateName;
  final CandidateLayer layer;
  final AttemptOutcome outcome;

  /// Short technical hint (already masked, no addresses or tokens).
  final String? detail;
  final Duration? latency;
}

enum AttemptOutcome { success, bindFailed, startFailed, startTimeout, unhealthy, cancelled }

/// Fixed-size ring buffer of recent attempts.
class AttemptLog {
  AttemptLog({this.capacity = 30});

  final int capacity;
  final ListQueue<AttemptRecord> _records = ListQueue();

  List<AttemptRecord> get records => List.unmodifiable(_records);

  void add(AttemptRecord record) {
    _records.addLast(record);
    while (_records.length > capacity) {
      _records.removeFirst();
    }
  }

  void clear() => _records.clear();
}
