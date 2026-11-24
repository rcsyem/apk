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

/// Two-screen MVP: this is the settings screen. Intentionally no Top-K / Top-P /
/// Repeat Penalty / GPU options (spec section 11).
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
      _snack('تعذّر استيراد الملف.');
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
        sha256: e.sha256!.toLowerCase(),
        source: ModelSource.catalog,
        catalogId: e.id,
        createdAt: DateTime.now(),
      );
      await repo.insert(m);
      await models.register(m);
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
      body: ListView(children: [
        const ListTile(title: Text(S.installedModels)),
        if (models.installed.isEmpty) const ListTile(title: Text(S.noInstalledModels)),
        for (final m in models.installed)
          RadioListTile<String>(
            value: m.id,
            groupValue: settings.activeModelId,
            onChanged: (v) {
              if (v != null) models.select(v);
            },
            title: Text(m.name, overflow: TextOverflow.ellipsis),
            subtitle: Text(_mb(m.sizeBytes)),
            secondary: IconButton(
              tooltip: S.delete,
              icon: const Icon(Icons.delete_outline),
              onPressed: () => _confirmDelete(m),
            ),
          ),
        ListTile(
          leading: const Icon(Icons.folder_open_outlined),
          title: const Text(S.importGguf),
          subtitle: _importing ? const Text(S.importing) : null,
          enabled: !_importing,
          onTap: _importing ? null : _import,
        ),
        const Divider(),
        const ListTile(title: Text(S.downloadModel)),
        if (_catalog != null)
          for (final e in _catalog!.entries)
            ListTile(
              title: Text(e.name),
              subtitle: e.downloadable
                  ? Text(pr.messageAr ?? '${_mb(e.sizeBytes!)}')
                  : const Text(S.downloadUnavailable),
              trailing: e.downloadable
                  ? Row(mainAxisSize: MainAxisSize.min, children: [
                      if (pr.state == DownloadState.downloading)
                        IconButton(
                            tooltip: S.pause,
                            icon: const Icon(Icons.pause),
                            onPressed: dm.pause),
                      if (pr.state == DownloadState.paused || pr.state == DownloadState.failed)
                        IconButton(
                            tooltip: S.resume,
                            icon: const Icon(Icons.play_arrow),
                            onPressed: () => _download(e)),
                      if (pr.state == DownloadState.idle ||
                          pr.state == DownloadState.cancelled ||
                          pr.state == DownloadState.completed)
                        IconButton(
                            tooltip: S.downloadModel,
                            icon: const Icon(Icons.download),
                            onPressed: () => _download(e)),
                      if (dm.active || pr.state == DownloadState.paused)
                        IconButton(
                            tooltip: S.cancel,
                            icon: const Icon(Icons.close),
                            onPressed: dm.cancel),
                    ])
                  : null,
            ),
        if (pr.state == DownloadState.downloading || pr.state == DownloadState.verifying)
          Padding(
            padding: const EdgeInsets.symmetric(horizontal: 16),
            child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
              LinearProgressIndicator(value: pr.fraction),
              Text(
                  '${pr.fraction == null ? '' : '${(pr.fraction! * 100).toStringAsFixed(1)}% • '}'
                  '${pr.remainingBytes == null ? '' : 'المتبقي ${_mb(pr.remainingBytes!)} • '}'
                  '${(pr.bytesPerSecond / (1024 * 1024)).toStringAsFixed(1)} MB/s'),
            ]),
          ),
        const Divider(),
        FutureBuilder<List<int>>(
          future: models.allowedContexts(),
          builder: (context, snap) {
            final allowed = snap.data ?? const <int>[];
            final options = {...allowed, settings.contextLength}.toList()..sort();
            return ListTile(
              title: const Text(S.contextLength),
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
      ]),
    );
  }
}
