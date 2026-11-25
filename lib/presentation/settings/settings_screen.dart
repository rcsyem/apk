import 'package:file_picker/file_picker.dart';
import 'package:flutter/material.dart';
import 'package:provider/provider.dart';
import '../../application/app_settings.dart';
import '../../data/model_repository.dart';
import '../../models/download_manager.dart';
import '../../models/model_catalog.dart';
import '../../models/model_importer.dart';
import '../../models/model_manager.dart';
import '../strings_ar.dart';

class SettingsScreen extends StatefulWidget {
  const SettingsScreen({super.key});
  @override
  State<SettingsScreen> createState() => _SettingsScreenState();
}

class _SettingsScreenState extends State<SettingsScreen> {
  ModelCatalog? _catalog;
  bool _importing = false;

  @override
  void initState() {
    super.initState();
    ModelCatalog.loadFromAssets().then((c) {
      if (mounted) setState(() => _catalog = c);
    });
  }

  String _mb(int bytes) => '${(bytes / (1024 * 1024)).toStringAsFixed(0)} MB';
  String _gb(int bytes) => '${(bytes / (1024 * 1024 * 1024)).toStringAsFixed(2)} GB';

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
        content: const Text(S.confirmDeleteModel),
        actions: [
          TextButton(onPressed: () => Navigator.pop(ctx, false), child: const Text(S.no)),
          TextButton(onPressed: () => Navigator.pop(ctx, true), child: const Text(S.yes)),
        ],
      ),
    );
    if (ok == true) await models.delete(m.id);
  }

  @override
  Widget build(BuildContext context) {
    final models = context.watch<ModelManager>();
    final settings = context.watch<AppSettings>();
    final dm = context.watch<DownloadManager>();
    final pr = dm.progress;

    return Scaffold(
      appBar: AppBar(title: const Text(S.settings)),
      body: ListView(
        padding: const EdgeInsets.symmetric(vertical: 8),
        children: [
          // Section 1: Installed Models
          const ListTile(
            title: Text(S.installedModels, style: TextStyle(fontWeight: FontWeight.bold)),
          ),
          if (models.installed.isEmpty)
            const Padding(
              padding: EdgeInsets.symmetric(horizontal: 16, vertical: 4),
              child: Text(S.noInstalledModels, style: TextStyle(color: Colors.grey)),
            ),
          for (final m in models.installed)
            RadioListTile<String>(
              value: m.id,
              groupValue: settings.activeModelId,
              onChanged: (v) {
                if (v != null) models.select(v);
              },
              title: Text(m.name, overflow: TextOverflow.ellipsis),
              subtitle: Text(m.sizeBytes > 1024 * 1024 * 1024 ? _gb(m.sizeBytes) : _mb(m.sizeBytes)),
              secondary: IconButton(
                tooltip: S.delete,
                icon: const Icon(Icons.delete_outline),
                onPressed: () => _confirmDelete(m),
              ),
            ),
          ListTile(
            leading: const Icon(Icons.folder_open_outlined),
            title: const Text(S.importGguf),
            subtitle: _importing ? const Text(S.importing) : const Text('اختر ملف GGUF تم تنزيله يدوياً على هاتفك'),
            enabled: !_importing,
            onTap: _importing ? null : _import,
          ),
          const Divider(),

          // Section 2: Approved Model Catalog
          const ListTile(
            title: Text(S.modelCatalogTitle, style: TextStyle(fontWeight: FontWeight.bold)),
            subtitle: Text('النماذج الخمسة المعتمدة رسمياً للإصدار الأول'),
          ),
          if (_catalog != null)
            for (final e in _catalog!.entries)
              Card(
                margin: const EdgeInsets.symmetric(horizontal: 12, vertical: 6),
                child: Padding(
                  padding: const EdgeInsets.all(12),
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      Row(
                        children: [
                          Expanded(
                            child: Text(
                              e.name,
                              style: const TextStyle(fontWeight: FontWeight.bold, fontSize: 15),
                            ),
                          ),
                          Chip(
                            label: Text(e.quantization, style: const TextStyle(fontSize: 11)),
                            visualDensity: VisualDensity.compact,
                          ),
                        ],
                      ),
                      const SizedBox(height: 4),
                      Text(e.description, style: const TextStyle(fontSize: 13, color: Colors.black87)),
                      const SizedBox(height: 6),
                      Text(
                        e.ramRequirementSummary,
                        style: TextStyle(fontSize: 12, color: Colors.blueGrey.shade700),
                      ),
                      const SizedBox(height: 8),
                      if (e.isGated)
                        Container(
                          padding: const EdgeInsets.all(8),
                          decoration: BoxDecoration(
                            color: Colors.amber.shade50,
                            borderRadius: BorderRadius.circular(6),
                            border: Border.all(color: Colors.amber.shade300),
                          ),
                          child: const Text(
                            S.gatedNotice,
                            style: TextStyle(fontSize: 12, color: Colors.black87),
                          ),
                        )
                      else if (e.downloadable)
                        Row(
                          mainAxisAlignment: MainAxisAlignment.spaceBetween,
                          children: [
                            Text(
                              e.sizeBytes! > 1024 * 1024 * 1024 ? _gb(e.sizeBytes!) : _mb(e.sizeBytes!),
                              style: const TextStyle(fontWeight: FontWeight.w600),
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
                                if (pr.state == DownloadState.paused || pr.state == DownloadState.failed)
                                  IconButton(
                                    tooltip: S.resume,
                                    icon: const Icon(Icons.play_arrow),
                                    onPressed: () => _download(e),
                                  ),
                                if (pr.state == DownloadState.idle ||
                                    pr.state == DownloadState.cancelled ||
                                    pr.state == DownloadState.completed)
                                  ElevatedButton.icon(
                                    icon: const Icon(Icons.download, size: 18),
                                    label: const Text(S.downloadModel),
                                    onPressed: () => _download(e),
                                  ),
                                if (dm.active || pr.state == DownloadState.paused)
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

          // Download Progress
          if (pr.state == DownloadState.downloading || pr.state == DownloadState.verifying)
            Padding(
              padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 8),
              child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
                LinearProgressIndicator(value: pr.fraction),
                const SizedBox(height: 4),
                Text(
                  '${pr.fraction == null ? '' : '${(pr.fraction! * 100).toStringAsFixed(1)}% • '}'
                  '${pr.remainingBytes == null ? '' : 'المتبقي ${_mb(pr.remainingBytes!)} • '}'
                  '${(pr.bytesPerSecond / (1024 * 1024)).toStringAsFixed(1)} MB/s',
                  style: const TextStyle(fontSize: 12),
                ),
              ]),
            ),
          const Divider(),

          // Section 3: Model Parameters & Settings
          const ListTile(
            title: Text('إعدادات التوليد والذاكرة', style: TextStyle(fontWeight: FontWeight.bold)),
          ),
          FutureBuilder<List<int>>(
            future: models.allowedContexts(),
            builder: (context, snap) {
              final allowed = snap.data ?? const <int>[];
              final options = {...allowed, settings.contextLength, 2048, 4096}.toList()..sort();
              return ListTile(
                title: const Text(S.contextLength),
                subtitle: const Text('طول نافذة السياق بالرموز (Tokens)'),
                trailing: DropdownButton<int>(
                  value: settings.contextLength,
                  items: [for (final v in options) DropdownMenuItem(value: v, child: Text('$v'))],
                  onChanged: (v) {
                    if (v != null) settings.setContextLength(v);
                  },
                ),
              );
            },
          ),
          ListTile(
            title: Text('${S.temperature}: ${settings.temperature.toStringAsFixed(1)}'),
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
    );
  }
}
