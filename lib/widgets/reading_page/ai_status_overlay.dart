import 'package:flutter/material.dart';
import 'package:anx_reader/service/ai_translation_status_service.dart';
import 'package:anx_reader/config/shared_preference_provider.dart';

class AiStatusOverlay extends StatefulWidget {
  const AiStatusOverlay({super.key});

  @override
  State<AiStatusOverlay> createState() => _AiStatusOverlayState();
}

class _AiStatusOverlayState extends State<AiStatusOverlay> {
  @override
  void initState() {
    super.initState();
    AiTranslationStatusService().addListener(_onStatusChanged);
  }

  @override
  void dispose() {
    AiTranslationStatusService().removeListener(_onStatusChanged);
    super.dispose();
  }

  void _onStatusChanged() {
    if (mounted) {
      setState(() {});
    }
  }

  void _showLogsModal(BuildContext context) {
    showModalBottomSheet(
      context: context,
      isScrollControlled: true,
      backgroundColor: Colors.transparent,
      builder: (context) {
        return DraggableScrollableSheet(
          initialChildSize: 0.6,
          minChildSize: 0.4,
          maxChildSize: 0.9,
          builder: (context, scrollController) {
            return Container(
              decoration: BoxDecoration(
                color: Theme.of(context).colorScheme.surface,
                borderRadius:
                    const BorderRadius.vertical(top: Radius.circular(16)),
              ),
              child: const AiStatusLogsModal(),
            );
          },
        );
      },
    );
  }

  @override
  Widget build(BuildContext context) {
    final showStatus = Prefs().showAiTranslationStatus;
    final state = AiTranslationStatusService().state;

    if (!showStatus || state == AiTranslationState.idle) {
      return const SizedBox.shrink();
    }

    final count = AiTranslationStatusService().translatingCount;

    IconData icon;
    Color iconColor;
    String text;

    switch (state) {
      case AiTranslationState.translating:
        icon = Icons.hourglass_bottom;
        iconColor = Theme.of(context).colorScheme.primary;
        final duration = AiTranslationStatusService().translationDurationSec;
        final durationStr = duration > 0 ? ' (${duration}s)' : '';
        text = 'Translating $count items...$durationStr';
        break;
      case AiTranslationState.waitingRateLimit:
        icon = Icons.hourglass_empty;
        iconColor = Theme.of(context).colorScheme.error;
        text = 'Rate limit (429) hit. Waiting...';
        break;
      case AiTranslationState.error:
        icon = Icons.error_outline;
        iconColor = Theme.of(context).colorScheme.error;
        text = 'Error';
        break;
      default:
        icon = Icons.info_outline;
        iconColor = Theme.of(context).colorScheme.onSurface;
        text = '';
    }

    return Positioned(
      bottom: 80,
      right: 20,
      child: GestureDetector(
        onTap: () => _showLogsModal(context),
        child: Container(
          padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 8),
          decoration: BoxDecoration(
            color: Theme.of(context)
                .colorScheme
                .surfaceContainerHighest
                .withOpacity(0.9),
            borderRadius: BorderRadius.circular(20),
            boxShadow: [
              BoxShadow(
                color: Colors.black.withOpacity(0.1),
                blurRadius: 4,
                offset: const Offset(0, 2),
              ),
            ],
          ),
          child: Row(
            mainAxisSize: MainAxisSize.min,
            children: [
              Icon(icon, size: 16, color: iconColor),
              const SizedBox(width: 8),
              Text(
                text,
                style: TextStyle(
                  fontSize: 12,
                  color: Theme.of(context).colorScheme.onSurfaceVariant,
                ),
              ),
            ],
          ),
        ),
      ),
    );
  }
}

class AiStatusLogsModal extends StatefulWidget {
  const AiStatusLogsModal({super.key});

  @override
  State<AiStatusLogsModal> createState() => _AiStatusLogsModalState();
}

class _AiStatusLogsModalState extends State<AiStatusLogsModal> {
  @override
  void initState() {
    super.initState();
    AiTranslationStatusService().addListener(_onLogsChanged);
  }

  @override
  void dispose() {
    AiTranslationStatusService().removeListener(_onLogsChanged);
    super.dispose();
  }

  void _onLogsChanged() {
    if (mounted) {
      setState(() {});
    }
  }

  @override
  Widget build(BuildContext context) {
    final logs = AiTranslationStatusService().logs.reversed.toList();
    final stats = AiTranslationStatusService().requestStats.reversed.toList();

    return DefaultTabController(
      length: 2,
      child: Column(children: [
        Container(
          padding: const EdgeInsets.all(16),
          decoration: BoxDecoration(
            border: Border(
              bottom: BorderSide(color: Theme.of(context).dividerColor),
            ),
          ),
          child: Row(
            mainAxisAlignment: MainAxisAlignment.spaceBetween,
            children: [
              Text(
                'AI Translation Logs',
                style: Theme.of(context).textTheme.titleLarge,
              ),
              IconButton(
                icon: const Icon(Icons.delete_outline),
                onPressed: () {
                  AiTranslationStatusService().clearLogs();
                },
                tooltip: 'Clear Logs',
              ),
            ],
          ),
        ),
        const TabBar(
          tabs: [
            Tab(text: 'Logs'),
            Tab(text: 'Requests History'),
          ],
        ),
        Expanded(
          child: TabBarView(
            children: [
              _buildLogsTab(logs),
              _buildStatsTab(stats),
            ],
          ),
        ),
      ]),
    );
  }

  Widget _buildLogsTab(List<AiLogEntry> logs) {
    return logs.isEmpty
        ? const Center(child: Text('No logs available'))
        : ListView.separated(
            padding: const EdgeInsets.all(16),
            itemCount: logs.length,
            separatorBuilder: (context, index) => const Divider(),
            itemBuilder: (context, index) {
              final log = logs[index];
              return _buildLogItem(context, log);
            },
          );
  }

  Widget _buildStatsTab(List<AiRequestStats> stats) {
    return stats.isEmpty
        ? const Center(child: Text('No requests yet'))
        : ListView.separated(
            padding: const EdgeInsets.all(16),
            itemCount: stats.length,
            separatorBuilder: (context, index) => const Divider(),
            itemBuilder: (context, index) {
              final stat = stats[index];
              return _buildStatItem(context, stat);
            },
          );
  }

  Widget _buildStatItem(BuildContext context, AiRequestStats stat) {
    final timeStr =
        '${stat.timestamp.hour.toString().padLeft(2, '0')}:${stat.timestamp.minute.toString().padLeft(2, '0')}:${stat.timestamp.second.toString().padLeft(2, '0')}';

    return Row(
      children: [
        Text(
          timeStr,
          style: TextStyle(
            fontSize: 12,
            color: Theme.of(context).colorScheme.onSurface.withOpacity(0.5),
          ),
        ),
        const SizedBox(width: 12),
        Icon(
          stat.isError ? Icons.error_outline : Icons.check_circle_outline,
          color:
              stat.isError ? Theme.of(context).colorScheme.error : Colors.green,
          size: 16,
        ),
        const SizedBox(width: 8),
        Expanded(
          child: Text(
            '${stat.itemsCount} items${stat.durationMs > 0 ? ' in ${stat.durationMs}ms' : ''}',
            style: TextStyle(
              color: Theme.of(context).colorScheme.onSurface,
            ),
          ),
        ),
      ],
    );
  }

  Widget _buildLogItem(BuildContext context, AiLogEntry log) {
    final timeStr =
        '${log.timestamp.hour.toString().padLeft(2, '0')}:${log.timestamp.minute.toString().padLeft(2, '0')}:${log.timestamp.second.toString().padLeft(2, '0')}';

    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Row(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Text(
              timeStr,
              style: TextStyle(
                fontSize: 12,
                color: Theme.of(context).colorScheme.onSurface.withOpacity(0.5),
              ),
            ),
            const SizedBox(width: 8),
            Expanded(
              child: Text(
                log.message,
                style: TextStyle(
                  fontWeight: FontWeight.bold,
                  color: log.isError
                      ? Theme.of(context).colorScheme.error
                      : Theme.of(context).colorScheme.onSurface,
                ),
              ),
            ),
          ],
        ),
        if (log.requestPayload != null && log.requestPayload!.isNotEmpty) ...[
          const SizedBox(height: 8),
          const Text('Request:',
              style: TextStyle(fontSize: 12, fontWeight: FontWeight.bold)),
          _buildCodeBlock(context, log.requestPayload!),
        ],
        if (log.responsePayload != null && log.responsePayload!.isNotEmpty) ...[
          const SizedBox(height: 8),
          const Text('Response:',
              style: TextStyle(fontSize: 12, fontWeight: FontWeight.bold)),
          _buildCodeBlock(context, log.responsePayload!),
        ],
      ],
    );
  }

  Widget _buildCodeBlock(BuildContext context, String text) {
    return Container(
      width: double.infinity,
      margin: const EdgeInsets.only(top: 4),
      padding: const EdgeInsets.all(8),
      decoration: BoxDecoration(
        color: Theme.of(context)
            .colorScheme
            .surfaceContainerHighest
            .withOpacity(0.5),
        borderRadius: BorderRadius.circular(8),
        border:
            Border.all(color: Theme.of(context).dividerColor.withOpacity(0.2)),
      ),
      child: SelectableText(
        text,
        style: TextStyle(
          fontFamily: 'monospace',
          fontSize: 11,
          color: Theme.of(context).colorScheme.onSurfaceVariant,
        ),
      ),
    );
  }
}
