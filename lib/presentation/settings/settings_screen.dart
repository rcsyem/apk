import 'package:file_picker/file_picker.dart';
import 'package:flutter/material.dart';
import 'package:provider/provider.dart';
import '../../application/app_settings.dart';
import '../../data/model_repository.dart';
import '../../models/download_manager.dart';
import '../../models/model_catalog.dart';
import '../../models/model_importer.dart';
import '../../models/model_manager.dart';
import '../../native/native_info.dart';
import '../strings_ar.dart';

class SettingsScreen extends StatefulWidget {
  const SettingsScreen({super.key});
  @override
  State<SettingsScreen> createState() => _SettingsScreenState();
}

class _SettingsScreenState extends State<SettingsScreen> {
  ModelCatalog? _catalog;
  bool _importing = false;
  MemorySnapshot? _memSnapshot;

  @override
  void initState() {
    super.initState();
    ModelCatalog.loadFromAssets().then((c) {
      if (mounted) setState(() => _catalog = c);
    });
    _loadMemoryInfo();
  }

  Future<void> _loadMemoryInfo() async {
    try {
      final native = context.read<NativeInfo>();
      final snap = await native.memorySnapshot();
      if (mounted) setState(() => _memSnapshot = snap);
    } catch (_) {}
  }

  String _mb(int bytes) => '${(bytes / (1024 * 1024)).toStringAsFixed(0)} ميغابايت';
  String _gb(int bytes) => '${(bytes / (1024 * 1024 * 1024)).toStringAsFixed(2)} جيجابايت';

  void _snack(String m) {
    if (!mounted) return;
    ScaffoldMessenger.of(context).showSnackBar(SnackBar(content: Text(m)));
  }

  Future<void> _import() async {
    final models = context.read<ModelManager>();
    final importer = context.read<ModelImporter>();
    final res = await FilePicker.platform.pickFiles(type: FileType.any);
    final path = res?.files.single.path;
    if (path == null) return;
    setState(() => _importing = true);
    try {
      final m = await importer.importFile(path, moveSource: true);
      await models.register(m);
      _snack(S.imported);
    } on ImportException catch (e) {
      _snack(e.messageAr);
    } catch (_) {
      _snack('تعذّر استيراد الملف، تأكد من سلامة ملف GGUF ومساحة التخزين.');
    } finally {
      if (mounted) setState(() => _importing = false);
    }
  }

  Future<void> _download(CatalogEntry e) async {
    final dm = context.read<DownloadManager>();
    final models = context.read<ModelManager>();
    final repo = context.read<ModelRepository>();
    final file = await dm.start(e);
    if (file != null) {
      final m = InstalledModel(
        id: e.id,
        name: e.name,
        fileName: e.fileName,
        sizeBytes: await file.length(),
        sha256: e.sha256?.toLowerCase() ?? '',
        source: ModelSource.catalog,
        catalogId: e.id,
        createdAt: DateTime.now(),
      );
      await repo.insert(m);
      await models.register(m);
      _snack('اكتمل تنزيل وتثبيت النموذج بنجاح.');
    }
  }

  Future<void> _confirmDelete(InstalledModel m) async {
    final models = context.read<ModelManager>();
    final ok = await showDialog<bool>(
      context: context,
      builder: (ctx) => AlertDialog(
        title: const Text('تأكيد حذف النموذج'),
        content: Text('هل تريد بالتأكيد إزالة النموذج "${m.name}" من ذاكرة الجهاز؟'),
        actions: [
          TextButton(onPressed: () => Navigator.pop(ctx, false), child: const Text(S.no)),
          FilledButton(
            style: FilledButton.styleFrom(backgroundColor: Theme.of(ctx).colorScheme.error),
            onPressed: () => Navigator.pop(ctx, true),
            child: const Text(S.yes),
          ),
        ],
      ),
    );
    if (ok == true) await models.delete(m.id);
  }

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final cs = theme.colorScheme;
    final models = context.watch<ModelManager>();
    final settings = context.watch<AppSettings>();
    final dm = context.watch<DownloadManager>();
    final pr = dm.progress;

    return Scaffold(
      appBar: AppBar(
        title: const Text(S.settings),
      ),
      body: SafeArea(
        child: ListView(
          padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 12),
          children: [
            // Section 1: Installed Models
            _SectionHeader(
              title: S.installedModels,
              icon: Icons.check_circle_outline,
            ),
            if (models.installed.isEmpty)
              Card(
                elevation: 0,
                color: cs.surfaceContainerLowest,
                shape: RoundedRectangleBorder(
                  borderRadius: BorderRadius.circular(12),
                  side: BorderSide(color: cs.outlineVariant),
                ),
                child: const Padding(
                  padding: EdgeInsets.all(16),
                  child: Text(
                    S.noInstalledModels,
                    style: TextStyle(color: Colors.grey),
                  ),
                ),
              )
            else
              Card(
                elevation: 0,
                color: cs.surfaceContainerLow,
                shape: RoundedRectangleBorder(
                  borderRadius: BorderRadius.circular(12),
                  side: BorderSide(color: cs.outlineVariant),
                ),
                child: Column(
                  children: [
                    for (final m in models.installed)
                      RadioListTile<String>(
                        value: m.id,
                        groupValue: settings.activeModelId,
                        onChanged: (v) {
                          if (v != null) models.select(v);
                        },
                        title: Text(
                          m.name,
                          overflow: TextOverflow.ellipsis,
                          style: const TextStyle(fontWeight: FontWeight.w600),
                        ),
                        subtitle: Text(
                          m.sizeBytes > 1024 * 1024 * 1024
                              ? _gb(m.sizeBytes)
                              : _mb(m.sizeBytes),
                        ),
                        secondary: IconButton(
                          tooltip: S.delete,
                          icon: const Icon(Icons.delete_outline, size: 20),
                          onPressed: () => _confirmDelete(m),
                        ),
                      ),
                  ],
                ),
              ),

            const SizedBox(height: 8),

            // Import Button
            FilledButton.tonalIcon(
              icon: _importing
                  ? const SizedBox(
                      width: 18,
                      height: 18,
                      child: CircularProgressIndicator(strokeWidth: 2),
                    )
                  : const Icon(Icons.file_open_outlined),
              label: Text(_importing ? S.importing : S.importGguf),
              onPressed: _importing ? null : _import,
            ),

            const SizedBox(height: 24),

            // Section 2: Approved Model Catalog (The 5 Models)
            _SectionHeader(
              title: S.modelCatalogTitle,
              icon: Icons.auto_awesome_motion_outlined,
              subtitle: 'النماذج الخمسة المعتمدة رسمياً للإصدار الأول',
            ),

            // Download Progress Bar
            if (pr.state == DownloadState.downloading ||
                pr.state == DownloadState.verifying) ...[
              Card(
                color: cs.secondaryContainer.withOpacity(0.4),
                child: Padding(
                  padding: const EdgeInsets.all(12),
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      Row(
                        mainAxisAlignment: MainAxisAlignment.spaceBetween,
                        children: [
                          Text(
                            pr.state == DownloadState.verifying
                                ? S.statusVerifying
                                : S.statusDownloading,
                            style: const TextStyle(fontWeight: FontWeight.bold),
                          ),
                          Text(
                            '${((pr.fraction ?? 0) * 100).toStringAsFixed(1)}%',
                            style: const TextStyle(fontWeight: FontWeight.bold),
                          ),
                        ],
                      ),
                      const SizedBox(height: 8),
                      LinearProgressIndicator(value: pr.fraction),
                      const SizedBox(height: 6),
                      Text(
                        '${pr.remainingBytes == null ? '' : 'المتبقي ${_mb(pr.remainingBytes!)} • '}'
                        '${(pr.bytesPerSecond / (1024 * 1024)).toStringAsFixed(1)} MB/s',
                        style: const TextStyle(fontSize: 12),
                      ),
                    ],
                  ),
                ),
              ),
              const SizedBox(height: 8),
            ],

            if (_catalog != null)
              for (final e in _catalog!.entries)
                Card(
                  elevation: 0,
                  margin: const EdgeInsets.only(bottom: 10),
                  color: cs.surfaceContainerLow,
                  shape: RoundedRectangleBorder(
                    borderRadius: BorderRadius.circular(14),
                    side: BorderSide(color: cs.outlineVariant, width: 0.8),
                  ),
                  child: Padding(
                    padding: const EdgeInsets.all(14),
                    child: Column(
                      crossAxisAlignment: CrossAxisAlignment.start,
                      children: [
                        Row(
                          children: [
                            Expanded(
                              child: Text(
                                e.name,
                                style: const TextStyle(
                                  fontWeight: FontWeight.bold,
                                  fontSize: 15,
                                ),
                              ),
                            ),
                            Container(
                              padding: const EdgeInsets.symmetric(
                                  horizontal: 8, vertical: 2),
                              decoration: BoxDecoration(
                                color: cs.primaryContainer,
                                borderRadius: BorderRadius.circular(8),
                              ),
                              child: Text(
                                e.quantization,
                                style: TextStyle(
                                  fontSize: 11,
                                  fontWeight: FontWeight.bold,
                                  color: cs.onPrimaryContainer,
                                ),
                              ),
                            ),
                          ],
                        ),
                        const SizedBox(height: 6),
                        Text(
                          e.description,
                          style: theme.textTheme.bodySmall?.copyWith(
                            color: cs.onSurfaceVariant,
                            height: 1.4,
                          ),
                        ),
                        const SizedBox(height: 8),
                        Row(
                          children: [
                            Icon(Icons.memory, size: 16, color: cs.primary),
                            const SizedBox(width: 4),
                            Expanded(
                              child: Text(
                                e.ramRequirementSummary,
                                style: TextStyle(
                                  fontSize: 12,
                                  color: cs.primary,
                                  fontWeight: FontWeight.w500,
                                ),
                              ),
                            ),
                          ],
                        ),
                        const SizedBox(height: 10),
                        if (e.isGated)
                          Container(
                            padding: const EdgeInsets.all(10),
                            decoration: BoxDecoration(
                              color: Colors.amber.shade50,
                              borderRadius: BorderRadius.circular(8),
                              border: Border.all(color: Colors.amber.shade300),
                            ),
                            child: Row(
                              children: [
                                Icon(Icons.lock_outline,
                                    size: 18, color: Colors.amber.shade900),
                                const SizedBox(width: 8),
                                const Expanded(
                                  child: Text(
                                    S.gatedNotice,
                                    style: TextStyle(
                                      fontSize: 12,
                                      color: Colors.black87,
                                    ),
                                  ),
                                ),
                              ],
                            ),
                          )
                        else if (e.downloadable)
                          Row(
                            mainAxisAlignment: MainAxisAlignment.spaceBetween,
                            children: [
                              Text(
                                e.sizeBytes! > 1024 * 1024 * 1024
                                    ? _gb(e.sizeBytes!)
                                    : _mb(e.sizeBytes!),
                                style: const TextStyle(
                                    fontWeight: FontWeight.bold),
                              ),
                              Row(
                                mainAxisSize: MainAxisSize.min,
                                children: [
                                  if (pr.state == DownloadState.downloading)
                                    IconButton(
                                      tooltip: S.pause,
                                      icon: const Icon(Icons.pause),
                                      onPressed: dm.pause,
                                    ),
                                  if (pr.state == DownloadState.paused ||
                                      pr.state == DownloadState.failed)
                                    IconButton(
                                      tooltip: S.resume,
                                      icon: const Icon(Icons.play_arrow),
                                      onPressed: () => _download(e),
                                    ),
                                  if (pr.state == DownloadState.idle ||
                                      pr.state == DownloadState.cancelled ||
                                      pr.state == DownloadState.completed)
                                    FilledButton.icon(
                                      icon: const Icon(Icons.download, size: 16),
                                      label: const Text(S.downloadModel),
                                      style: FilledButton.styleFrom(
                                        visualDensity: VisualDensity.compact,
                                      ),
                                      onPressed: () => _download(e),
                                    ),
                                  if (dm.active ||
                                      pr.state == DownloadState.paused)
                                    IconButton(
                                      tooltip: S.cancel,
                                      icon: const Icon(Icons.close),
                                      onPressed: dm.cancel,
                                    ),
                                ],
                              ),
                            ],
                          ),
                      ],
                    ),
                  ),
                ),

            const SizedBox(height: 24),

            // Section 3: Generation & Memory Parameters
            _SectionHeader(
              title: 'إعدادات التوليد والذاكرة',
              icon: Icons.tune,
            ),
            Card(
              elevation: 0,
              color: cs.surfaceContainerLow,
              shape: RoundedRectangleBorder(
                borderRadius: BorderRadius.circular(12),
                side: BorderSide(color: cs.outlineVariant),
              ),
              child: Padding(
                padding: const EdgeInsets.symmetric(vertical: 8),
                child: Column(
                  children: [
                    FutureBuilder<List<int>>(
                      future: models.allowedContexts(),
                      builder: (context, snap) {
                        final allowed = snap.data ?? const <int>[];
                        final options = {
                          ...allowed,
                          settings.contextLength,
                          2048,
                          4096
                        }.toList()
                          ..sort();
                        return ListTile(
                          title: const Text(S.contextLength),
                          subtitle: const Text('طول نافذة السياق بالرموز (Tokens)'),
                          trailing: DropdownButton<int>(
                            value: settings.contextLength,
                            underline: const SizedBox(),
                            items: [
                              for (final v in options)
                                DropdownMenuItem(value: v, child: Text('$v'))
                            ],
                            onChanged: (v) {
                              if (v != null) settings.setContextLength(v);
                            },
                          ),
                        );
                      },
                    ),
                    const Divider(height: 1),
                    ListTile(
                      title: Text(
                          '${S.temperature}: ${settings.temperature.toStringAsFixed(1)}'),
                      subtitle: Slider(
                        value: settings.temperature,
                        min: AppSettings.minTemperature,
                        max: AppSettings.maxTemperature,
                        divisions: 15,
                        onChanged: settings.setTemperature,
                      ),
                    ),
                  ],
                ),
              ),
            ),

            const SizedBox(height: 24),

            // Section 4: Device & System Diagnostics
            const _SectionHeader(
              title: S.memoryStatus,
              icon: Icons.speed_outlined,
            ),
            Card(
              elevation: 0,
              color: cs.surfaceContainerLow,
              shape: RoundedRectangleBorder(
                borderRadius: BorderRadius.circular(12),
                side: BorderSide(color: cs.outlineVariant),
              ),
              child: Padding(
                padding: const EdgeInsets.all(14),
                child: Column(
                  children: [
                    const _InfoRow(
                      label: S.inferenceEngine,
                      value: 'v3 FFI Bridge (llama.cpp)',
                    ),
                    const Divider(height: 16),
                    _InfoRow(
                      label: S.deviceTotalRam,
                      value: _memSnapshot != null
                          ? _gb(_memSnapshot!.totalBytes)
                          : 'غير محدد',
                    ),
                    const Divider(height: 16),
                    _InfoRow(
                      label: S.deviceAvailRam,
                      value: _memSnapshot != null
                          ? _gb(_memSnapshot!.availableBytes)
                          : 'غير محدد',
                    ),
                    const Divider(height: 16),
                    const _InfoRow(
                      label: S.systemSafetyReserve,
                      value: '≥ 512 ميغابايت (محجوز تلقائياً للنظام)',
                    ),
                  ],
                ),
              ),
            ),

            const SizedBox(height: 24),

            // Section 5: About App & Developer
            const _SectionHeader(
              title: S.aboutSectionTitle,
              icon: Icons.info_outline,
            ),
            Card(
              elevation: 0,
              color: cs.surfaceContainerLow,
              shape: RoundedRectangleBorder(
                borderRadius: BorderRadius.circular(12),
                side: BorderSide(color: cs.outlineVariant),
              ),
              child: Padding(
                padding: const EdgeInsets.all(16),
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Row(
                      children: [
                        Container(
                          padding: const EdgeInsets.all(8),
                          decoration: BoxDecoration(
                            color: cs.primaryContainer,
                            borderRadius: BorderRadius.circular(10),
                          ),
                          child: Icon(
                            Icons.auto_awesome,
                            color: cs.onPrimaryContainer,
                            size: 24,
                          ),
                        ),
                        const SizedBox(width: 12),
                        Expanded(
                          child: Column(
                            crossAxisAlignment: CrossAxisAlignment.start,
                            children: [
                              Text(
                                S.appName,
                                style: theme.textTheme.titleMedium?.copyWith(
                                  fontWeight: FontWeight.bold,
                                ),
                              ),
                              Text(
                                S.appVersionName,
                                style: theme.textTheme.bodySmall?.copyWith(
                                  color: cs.onSurfaceVariant,
                                ),
                              ),
                            ],
                          ),
                        ),
                      ],
                    ),
                    const SizedBox(height: 14),
                    const Divider(height: 1),
                    const SizedBox(height: 14),
                    Text(
                      S.aboutAppDescription,
                      style: theme.textTheme.bodyMedium?.copyWith(
                        height: 1.6,
                        color: cs.onSurface,
                      ),
                    ),
                  ],
                ),
              ),
            ),
            const SizedBox(height: 20),
          ],
        ),
      ),
    );
  }
}

class _SectionHeader extends StatelessWidget {
  const _SectionHeader({
    required this.title,
    required this.icon,
    this.subtitle,
  });

  final String title;
  final IconData icon;
  final String? subtitle;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final cs = theme.colorScheme;
    return Padding(
      padding: const EdgeInsets.only(bottom: 10),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Row(
            children: [
              Icon(icon, size: 20, color: cs.primary),
              const SizedBox(width: 8),
              Text(
                title,
                style: theme.textTheme.titleMedium?.copyWith(
                  fontWeight: FontWeight.bold,
                ),
              ),
            ],
          ),
          if (subtitle != null) ...[
            const SizedBox(height: 2),
            Text(
              subtitle!,
              style: theme.textTheme.bodySmall?.copyWith(
                color: cs.onSurfaceVariant,
              ),
            ),
          ],
        ],
      ),
    );
  }
}

class _InfoRow extends StatelessWidget {
  const _InfoRow({required this.label, required this.value});
  final String label;
  final String value;

  @override
  Widget build(BuildContext context) {
    return Row(
      mainAxisAlignment: MainAxisAlignment.spaceBetween,
      children: [
        Text(label, style: const TextStyle(fontSize: 13, color: Colors.grey)),
        Text(value, style: const TextStyle(fontSize: 13, fontWeight: FontWeight.w600)),
      ],
    );
  }
}
