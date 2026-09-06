import 'package:file_picker/file_picker.dart';
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:go_router/go_router.dart';
import 'package:open_filex/open_filex.dart';
import 'package:path/path.dart' as p;
import 'package:path_provider/path_provider.dart';
import 'package:share_plus/share_plus.dart';

import '../../core/network/api_exception.dart';
import '../../core/utils/format.dart';
import '../../data/models/file_entry.dart';
import '../../routing/router.dart';
import '../../state/api_providers.dart';
import '../../state/session_controller.dart';
import '../../widgets/status_views.dart';
import 'file_thumbnail.dart';
import 'upload_progress_dialog.dart';

typedef ListArgs = ({String drive, String path, bool hidden});

/// Directory listing for a drive+path, re-fetched when the admin view scope
/// changes so admins see the right space.
final fileListProvider =
    FutureProvider.autoDispose.family<List<FileEntry>, ListArgs>((ref, args) {
  ref.watch(sessionControllerProvider.select((s) => s.effectiveViewMode));
  return ref
      .watch(filesRepositoryProvider)
      .list(args.drive, args.path, hidden: args.hidden);
});

enum _SortKey { name, size, modified }

class FileBrowserScreen extends ConsumerStatefulWidget {
  const FileBrowserScreen({
    super.key,
    required this.drive,
    required this.path,
    this.driveLabel,
  });

  final String drive;
  final String path;
  final String? driveLabel;

  @override
  ConsumerState<FileBrowserScreen> createState() => _FileBrowserScreenState();
}

class _FileBrowserScreenState extends ConsumerState<FileBrowserScreen> {
  late String _path = widget.path;
  bool _hidden = false;
  bool _grid = false;
  _SortKey _sortKey = _SortKey.name;
  bool _sortAsc = true;
  final Set<String> _selected = {};

  ListArgs get _args => (drive: widget.drive, path: _path, hidden: _hidden);

  bool get _selecting => _selected.isNotEmpty;

  void _refresh() => ref.invalidate(fileListProvider(_args));

  void _enter(FileEntry dir) => setState(() {
        _selected.clear();
        _path = dir.path;
      });

  void _goTo(String path) => setState(() {
        _selected.clear();
        _path = path;
      });

  List<FileEntry> _sorted(List<FileEntry> entries) {
    final list = [...entries];
    int cmp(FileEntry a, FileEntry b) {
      if (a.isDir != b.isDir) return a.isDir ? -1 : 1;
      final int r;
      switch (_sortKey) {
        case _SortKey.name:
          r = a.name.toLowerCase().compareTo(b.name.toLowerCase());
        case _SortKey.size:
          r = a.size.compareTo(b.size);
        case _SortKey.modified:
          r = a.mtimeMs.compareTo(b.mtimeMs);
      }
      return _sortAsc ? r : -r;
    }

    list.sort(cmp);
    return list;
  }

  // ---- Mutations -----------------------------------------------------------
  Future<void> _runGuarded(Future<void> Function() action) async {
    try {
      await action();
      _refresh();
    } on ApiException catch (e) {
      if (mounted) _snack(e.message);
    }
  }

  void _snack(String msg) {
    if (!mounted) return;
    ScaffoldMessenger.of(context)
      ..hideCurrentSnackBar()
      ..showSnackBar(SnackBar(content: Text(msg)));
  }

  Future<void> _newFolder() async {
    final name = await _promptText(
      title: 'New folder',
      hint: 'Folder name',
      action: 'Create',
    );
    if (name == null || name.trim().isEmpty) return;
    await _runGuarded(() => ref
        .read(filesRepositoryProvider)
        .mkdir(widget.drive, _path, name.trim()));
  }

  Future<void> _rename(FileEntry e) async {
    final name = await _promptText(
      title: 'Rename',
      hint: 'New name',
      initial: e.name,
      action: 'Rename',
    );
    if (name == null || name.trim().isEmpty || name.trim() == e.name) return;
    await _runGuarded(() => ref
        .read(filesRepositoryProvider)
        .rename(widget.drive, e.path, name.trim()));
  }

  Future<void> _deleteEntries(List<String> paths) async {
    final confirmed = await _confirm(
      title: 'Delete ${paths.length} item${paths.length == 1 ? '' : 's'}?',
      message: 'This cannot be undone.',
      action: 'Delete',
      destructive: true,
    );
    if (confirmed != true) return;
    setState(_selected.clear);
    await _runGuarded(
        () => ref.read(filesRepositoryProvider).delete(widget.drive, paths));
  }

  Future<void> _moveOrCopy(List<String> sources, {required bool copy}) async {
    final dest = await showModalBottomSheet<String>(
      context: context,
      isScrollControlled: true,
      showDragHandle: true,
      builder: (_) => _DestinationPicker(
        drive: widget.drive,
        driveLabel: widget.driveLabel,
        title: copy ? 'Copy to' : 'Move to',
      ),
    );
    if (dest == null) return;
    setState(_selected.clear);
    await _runGuarded(() {
      final repo = ref.read(filesRepositoryProvider);
      return copy
          ? repo.copy(widget.drive, sources, dest)
          : repo.move(widget.drive, sources, dest);
    });
  }

  Future<void> _download(FileEntry e) async {
    final messenger = ScaffoldMessenger.of(context);
    messenger.showSnackBar(SnackBar(content: Text('Downloading ${e.name}…')));
    try {
      final dir = await getTemporaryDirectory();
      final savePath = p.join(dir.path, e.name);
      await ref
          .read(filesRepositoryProvider)
          .downloadToFile(widget.drive, e.path, savePath);
      messenger.hideCurrentSnackBar();
      if (!mounted) return;
      await showModalBottomSheet<void>(
        context: context,
        showDragHandle: true,
        builder: (_) => _DownloadedSheet(name: e.name, path: savePath),
      );
    } on ApiException catch (err) {
      messenger.hideCurrentSnackBar();
      _snack(err.message);
    }
  }

  Future<void> _open(FileEntry e) async {
    if (e.isImage || e.isVideo) {
      final repo = ref.read(filesRepositoryProvider);
      final headers = ref.read(authHeadersProvider);
      if (!mounted) return;
      Navigator.of(context).push(MaterialPageRoute(
        builder: (_) => _PreviewScreen(
          title: e.name,
          url: repo.rawUrl(widget.drive, e.path).toString(),
          headers: headers,
          isVideo: e.isVideo,
        ),
      ));
      return;
    }
    await _download(e);
  }

  Future<void> _upload() async {
    final picked = await FilePicker.pickFiles();
    final files = picked
        .where((f) => f.path != null)
        .map((f) => XFile(f.path!, name: f.name))
        .toList();
    if (files.isEmpty || !mounted) return;
    await showDialog<void>(
      context: context,
      barrierDismissible: false,
      builder: (_) => UploadProgressDialog(
        files: files,
        drive: widget.drive,
        destPath: _path,
      ),
    );
    _refresh();
  }

  void _showActions() {
    showModalBottomSheet<void>(
      context: context,
      showDragHandle: true,
      builder: (_) => SafeArea(
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            ListTile(
              leading: const Icon(Icons.upload_file),
              title: const Text('Upload files'),
              onTap: () {
                Navigator.pop(context);
                _upload();
              },
            ),
            ListTile(
              leading: const Icon(Icons.create_new_folder_outlined),
              title: const Text('New folder'),
              onTap: () {
                Navigator.pop(context);
                _newFolder();
              },
            ),
          ],
        ),
      ),
    );
  }

  void _itemMenu(FileEntry e) {
    showModalBottomSheet<void>(
      context: context,
      showDragHandle: true,
      builder: (_) => SafeArea(
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            ListTile(
              leading: Icon(e.isDir ? Icons.folder_open : Icons.open_in_new),
              title: Text(e.isDir ? 'Open' : 'Open / preview'),
              onTap: () {
                Navigator.pop(context);
                e.isDir ? _enter(e) : _open(e);
              },
            ),
            if (!e.isDir)
              ListTile(
                leading: const Icon(Icons.download_outlined),
                title: const Text('Download'),
                onTap: () {
                  Navigator.pop(context);
                  _download(e);
                },
              ),
            ListTile(
              leading: const Icon(Icons.drive_file_rename_outline),
              title: const Text('Rename'),
              onTap: () {
                Navigator.pop(context);
                _rename(e);
              },
            ),
            ListTile(
              leading: const Icon(Icons.drive_file_move_outline),
              title: const Text('Move'),
              onTap: () {
                Navigator.pop(context);
                _moveOrCopy([e.path], copy: false);
              },
            ),
            ListTile(
              leading: const Icon(Icons.copy_outlined),
              title: const Text('Copy'),
              onTap: () {
                Navigator.pop(context);
                _moveOrCopy([e.path], copy: true);
              },
            ),
            ListTile(
              leading: Icon(Icons.delete_outline,
                  color: Theme.of(context).colorScheme.error),
              title: Text('Delete',
                  style:
                      TextStyle(color: Theme.of(context).colorScheme.error)),
              onTap: () {
                Navigator.pop(context);
                _deleteEntries([e.path]);
              },
            ),
          ],
        ),
      ),
    );
  }

  void _toggleSelect(FileEntry e) => setState(() {
        if (!_selected.remove(e.path)) _selected.add(e.path);
      });

  @override
  Widget build(BuildContext context) {
    final async = ref.watch(fileListProvider(_args));
    final atRoot = _path.isEmpty || _path == '/';

    return PopScope(
      canPop: atRoot && !_selecting,
      onPopInvokedWithResult: (didPop, _) {
        if (didPop) return;
        if (_selecting) {
          setState(_selected.clear);
        } else if (!atRoot) {
          _goTo(p.dirname(_path) == '.' ? '' : _dirUp(_path));
        }
      },
      child: Scaffold(
        appBar: _selecting ? _selectionAppBar() : _browseAppBar(),
        body: Column(
          children: [
            _Breadcrumb(
              driveLabel: widget.driveLabel ?? widget.drive,
              path: _path,
              onTapRoot: () => _goTo(''),
              onTapSegment: _goTo,
            ),
            const Divider(height: 1),
            Expanded(
              child: async.when(
                loading: () => const LoadingView(label: 'Loading…'),
                error: (e, _) => ErrorView(
                  message: e is ApiException ? e.message : e.toString(),
                  onRetry: _refresh,
                ),
                data: (entries) {
                  final sorted = _sorted(entries);
                  if (sorted.isEmpty) {
                    return _EmptyFolder(onUpload: _upload, onNewFolder: _newFolder);
                  }
                  return RefreshIndicator(
                    onRefresh: () async => _refresh(),
                    child: _grid
                        ? _FileGrid(
                            entries: sorted,
                            drive: widget.drive,
                            selected: _selected,
                            selecting: _selecting,
                            onTap: _onTap,
                            onLongPress: _toggleSelect,
                            onMenu: _itemMenu,
                          )
                        : _FileList(
                            entries: sorted,
                            drive: widget.drive,
                            selected: _selected,
                            selecting: _selecting,
                            onTap: _onTap,
                            onLongPress: _toggleSelect,
                            onMenu: _itemMenu,
                          ),
                  );
                },
              ),
            ),
          ],
        ),
        floatingActionButton: _selecting
            ? null
            : FloatingActionButton(
                onPressed: _showActions,
                child: const Icon(Icons.add),
              ),
      ),
    );
  }

  void _onTap(FileEntry e) {
    if (_selecting) {
      _toggleSelect(e);
    } else if (e.isDir) {
      _enter(e);
    } else {
      _open(e);
    }
  }

  String _dirUp(String path) {
    final parent = p.dirname(path);
    return parent == '.' || parent == '/' ? '' : parent;
  }

  AppBar _browseAppBar() {
    return AppBar(
      title: Text(widget.driveLabel ?? widget.drive,
          overflow: TextOverflow.ellipsis),
      actions: [
        IconButton(
          tooltip: 'Search this drive',
          icon: const Icon(Icons.search),
          onPressed: () => context.push(
            Uri(path: Routes.search, queryParameters: {
              'drive': widget.drive,
              'label': widget.driveLabel ?? '',
            }).toString(),
          ),
        ),
        IconButton(
          tooltip: _grid ? 'List view' : 'Grid view',
          icon: Icon(_grid ? Icons.view_list : Icons.grid_view),
          onPressed: () => setState(() => _grid = !_grid),
        ),
        PopupMenuButton<String>(
          onSelected: _onMenuSelect,
          itemBuilder: (_) => [
            CheckedPopupMenuItem(
              value: 'hidden',
              checked: _hidden,
              child: const Text('Show hidden'),
            ),
            const PopupMenuDivider(),
            _sortItem('sort_name', 'Name', _SortKey.name),
            _sortItem('sort_size', 'Size', _SortKey.size),
            _sortItem('sort_modified', 'Modified', _SortKey.modified),
            const PopupMenuDivider(),
            PopupMenuItem(
              value: 'order',
              child: Text(_sortAsc ? 'Descending' : 'Ascending'),
            ),
          ],
        ),
      ],
    );
  }

  PopupMenuItem<String> _sortItem(String value, String label, _SortKey key) =>
      CheckedPopupMenuItem(
        value: value,
        checked: _sortKey == key,
        child: Text(label),
      );

  void _onMenuSelect(String value) {
    setState(() {
      switch (value) {
        case 'hidden':
          _hidden = !_hidden;
        case 'order':
          _sortAsc = !_sortAsc;
        case 'sort_name':
          _sortKey = _SortKey.name;
        case 'sort_size':
          _sortKey = _SortKey.size;
        case 'sort_modified':
          _sortKey = _SortKey.modified;
      }
    });
  }

  AppBar _selectionAppBar() {
    return AppBar(
      leading: IconButton(
        icon: const Icon(Icons.close),
        onPressed: () => setState(_selected.clear),
      ),
      title: Text('${_selected.length} selected'),
      actions: [
        IconButton(
          tooltip: 'Move',
          icon: const Icon(Icons.drive_file_move_outline),
          onPressed: () => _moveOrCopy(_selected.toList(), copy: false),
        ),
        IconButton(
          tooltip: 'Copy',
          icon: const Icon(Icons.copy_outlined),
          onPressed: () => _moveOrCopy(_selected.toList(), copy: true),
        ),
        IconButton(
          tooltip: 'Delete',
          icon: const Icon(Icons.delete_outline),
          onPressed: () => _deleteEntries(_selected.toList()),
        ),
      ],
    );
  }

  // ---- Small dialogs -------------------------------------------------------
  Future<String?> _promptText({
    required String title,
    required String hint,
    String? initial,
    required String action,
  }) {
    final controller = TextEditingController(text: initial);
    return showDialog<String>(
      context: context,
      builder: (ctx) => AlertDialog(
        title: Text(title),
        content: TextField(
          controller: controller,
          autofocus: true,
          decoration: InputDecoration(hintText: hint),
          onSubmitted: (v) => Navigator.pop(ctx, v),
        ),
        actions: [
          TextButton(
              onPressed: () => Navigator.pop(ctx), child: const Text('Cancel')),
          FilledButton(
            onPressed: () => Navigator.pop(ctx, controller.text),
            child: Text(action),
          ),
        ],
      ),
    );
  }

  Future<bool?> _confirm({
    required String title,
    required String message,
    required String action,
    bool destructive = false,
  }) {
    return showDialog<bool>(
      context: context,
      builder: (ctx) => AlertDialog(
        title: Text(title),
        content: Text(message),
        actions: [
          TextButton(
              onPressed: () => Navigator.pop(ctx, false),
              child: const Text('Cancel')),
          FilledButton(
            style: destructive
                ? FilledButton.styleFrom(
                    backgroundColor: Theme.of(ctx).colorScheme.error)
                : null,
            onPressed: () => Navigator.pop(ctx, true),
            child: Text(action),
          ),
        ],
      ),
    );
  }
}

// ---- List / grid ----------------------------------------------------------
class _FileList extends StatelessWidget {
  const _FileList({
    required this.entries,
    required this.drive,
    required this.selected,
    required this.selecting,
    required this.onTap,
    required this.onLongPress,
    required this.onMenu,
  });

  final List<FileEntry> entries;
  final String drive;
  final Set<String> selected;
  final bool selecting;
  final ValueChanged<FileEntry> onTap;
  final ValueChanged<FileEntry> onLongPress;
  final ValueChanged<FileEntry> onMenu;

  @override
  Widget build(BuildContext context) {
    return ListView.builder(
      padding: const EdgeInsets.symmetric(vertical: 8),
      itemCount: entries.length,
      itemBuilder: (_, i) {
        final e = entries[i];
        final isSel = selected.contains(e.path);
        return ListTile(
          selected: isSel,
          leading: selecting
              ? Icon(isSel
                  ? Icons.check_circle
                  : Icons.radio_button_unchecked)
              : FileThumbnail(drive: drive, entry: e, size: 40),
          title: Text(e.name, maxLines: 1, overflow: TextOverflow.ellipsis),
          subtitle: Text(
            e.isDir
                ? formatRelative(e.modified)
                : '${formatBytes(e.size)} · ${formatRelative(e.modified)}',
          ),
          trailing: selecting
              ? null
              : IconButton(
                  icon: const Icon(Icons.more_vert),
                  onPressed: () => onMenu(e),
                ),
          onTap: () => onTap(e),
          onLongPress: () => onLongPress(e),
        );
      },
    );
  }
}

class _FileGrid extends StatelessWidget {
  const _FileGrid({
    required this.entries,
    required this.drive,
    required this.selected,
    required this.selecting,
    required this.onTap,
    required this.onLongPress,
    required this.onMenu,
  });

  final List<FileEntry> entries;
  final String drive;
  final Set<String> selected;
  final bool selecting;
  final ValueChanged<FileEntry> onTap;
  final ValueChanged<FileEntry> onLongPress;
  final ValueChanged<FileEntry> onMenu;

  @override
  Widget build(BuildContext context) {
    return GridView.builder(
      padding: const EdgeInsets.all(12),
      gridDelegate: const SliverGridDelegateWithMaxCrossAxisExtent(
        maxCrossAxisExtent: 140,
        childAspectRatio: 0.82,
        crossAxisSpacing: 12,
        mainAxisSpacing: 12,
      ),
      itemCount: entries.length,
      itemBuilder: (_, i) {
        final e = entries[i];
        final isSel = selected.contains(e.path);
        return InkWell(
          onTap: () => onTap(e),
          onLongPress: () => onLongPress(e),
          borderRadius: BorderRadius.circular(12),
          child: Stack(
            children: [
              Column(
                crossAxisAlignment: CrossAxisAlignment.stretch,
                children: [
                  Expanded(
                    child: ClipRRect(
                      borderRadius: BorderRadius.circular(12),
                      child: FileThumbnail(
                          drive: drive, entry: e, size: 140, fill: true),
                    ),
                  ),
                  const SizedBox(height: 6),
                  Text(e.name,
                      maxLines: 2,
                      overflow: TextOverflow.ellipsis,
                      textAlign: TextAlign.center,
                      style: Theme.of(context).textTheme.bodySmall),
                ],
              ),
              if (selecting)
                Positioned(
                  top: 4,
                  right: 4,
                  child: Icon(
                    isSel ? Icons.check_circle : Icons.radio_button_unchecked,
                    color: Theme.of(context).colorScheme.primary,
                  ),
                ),
            ],
          ),
        );
      },
    );
  }
}

// ---- Breadcrumb -----------------------------------------------------------
class _Breadcrumb extends StatelessWidget {
  const _Breadcrumb({
    required this.driveLabel,
    required this.path,
    required this.onTapRoot,
    required this.onTapSegment,
  });

  final String driveLabel;
  final String path;
  final VoidCallback onTapRoot;
  final ValueChanged<String> onTapSegment;

  @override
  Widget build(BuildContext context) {
    final segments = path.split('/').where((s) => s.isNotEmpty).toList();
    final style = Theme.of(context).textTheme.bodyMedium;
    final children = <Widget>[
      TextButton(
        onPressed: onTapRoot,
        style: TextButton.styleFrom(
            padding: const EdgeInsets.symmetric(horizontal: 8)),
        child: Row(mainAxisSize: MainAxisSize.min, children: [
          const Icon(Icons.storage, size: 16),
          const SizedBox(width: 4),
          Text(driveLabel),
        ]),
      ),
    ];
    var acc = '';
    for (final seg in segments) {
      acc = '$acc/$seg';
      final target = acc;
      children
        ..add(Icon(Icons.chevron_right,
            size: 16, color: Theme.of(context).colorScheme.outline))
        ..add(TextButton(
          onPressed: () => onTapSegment(target),
          style: TextButton.styleFrom(
              padding: const EdgeInsets.symmetric(horizontal: 8)),
          child: Text(seg, style: style),
        ));
    }
    return SizedBox(
      height: 44,
      child: ListView(
        scrollDirection: Axis.horizontal,
        padding: const EdgeInsets.symmetric(horizontal: 4),
        children: [Row(children: children)],
      ),
    );
  }
}

class _EmptyFolder extends StatelessWidget {
  const _EmptyFolder({required this.onUpload, required this.onNewFolder});
  final VoidCallback onUpload;
  final VoidCallback onNewFolder;

  @override
  Widget build(BuildContext context) {
    return ListView(
      children: [
        const SizedBox(height: 80),
        EmptyView(
          icon: Icons.folder_open,
          message: 'This folder is empty.',
          action: Wrap(
            spacing: 12,
            children: [
              FilledButton.tonalIcon(
                onPressed: onUpload,
                icon: const Icon(Icons.upload_file),
                label: const Text('Upload'),
              ),
              OutlinedButton.icon(
                onPressed: onNewFolder,
                icon: const Icon(Icons.create_new_folder_outlined),
                label: const Text('New folder'),
              ),
            ],
          ),
        ),
      ],
    );
  }
}

// ---- Destination picker (move/copy) ---------------------------------------
class _DestinationPicker extends ConsumerStatefulWidget {
  const _DestinationPicker({
    required this.drive,
    required this.title,
    this.driveLabel,
  });

  final String drive;
  final String title;
  final String? driveLabel;

  @override
  ConsumerState<_DestinationPicker> createState() => _DestinationPickerState();
}

class _DestinationPickerState extends ConsumerState<_DestinationPicker> {
  String _path = '';

  @override
  Widget build(BuildContext context) {
    final async =
        ref.watch(fileListProvider((drive: widget.drive, path: _path, hidden: false)));
    return DraggableScrollableSheet(
      expand: false,
      initialChildSize: 0.7,
      maxChildSize: 0.9,
      builder: (context, scrollController) => Column(
        children: [
          Padding(
            padding: const EdgeInsets.fromLTRB(16, 4, 8, 4),
            child: Row(
              children: [
                Expanded(
                  child: Text(widget.title,
                      style: Theme.of(context).textTheme.titleLarge),
                ),
                FilledButton(
                  onPressed: () => Navigator.pop(context, _path),
                  child: const Text('Here'),
                ),
              ],
            ),
          ),
          _Breadcrumb(
            driveLabel: widget.driveLabel ?? widget.drive,
            path: _path,
            onTapRoot: () => setState(() => _path = ''),
            onTapSegment: (p) => setState(() => _path = p),
          ),
          const Divider(height: 1),
          Expanded(
            child: async.when(
              loading: () => const LoadingView(),
              error: (e, _) => ErrorView(
                  message: e is ApiException ? e.message : e.toString()),
              data: (entries) {
                final dirs = entries.where((e) => e.isDir).toList()
                  ..sort((a, b) =>
                      a.name.toLowerCase().compareTo(b.name.toLowerCase()));
                if (dirs.isEmpty) {
                  return const Center(child: Text('No sub-folders here'));
                }
                return ListView.builder(
                  controller: scrollController,
                  itemCount: dirs.length,
                  itemBuilder: (_, i) => ListTile(
                    leading: const Icon(Icons.folder),
                    title: Text(dirs[i].name),
                    trailing: const Icon(Icons.chevron_right),
                    onTap: () => setState(() => _path = dirs[i].path),
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

// ---- Downloaded actions ---------------------------------------------------
class _DownloadedSheet extends StatelessWidget {
  const _DownloadedSheet({required this.name, required this.path});
  final String name;
  final String path;

  @override
  Widget build(BuildContext context) {
    return SafeArea(
      child: Column(
        mainAxisSize: MainAxisSize.min,
        children: [
          ListTile(
            leading: const Icon(Icons.check_circle, color: Colors.green),
            title: Text(name),
            subtitle: const Text('Downloaded'),
          ),
          ListTile(
            leading: const Icon(Icons.open_in_new),
            title: const Text('Open'),
            onTap: () {
              Navigator.pop(context);
              OpenFilex.open(path);
            },
          ),
          ListTile(
            leading: const Icon(Icons.share_outlined),
            title: const Text('Share'),
            onTap: () {
              Navigator.pop(context);
              SharePlus.instance.share(ShareParams(files: [XFile(path)]));
            },
          ),
        ],
      ),
    );
  }
}

// ---- Image / video preview ------------------------------------------------
class _PreviewScreen extends StatelessWidget {
  const _PreviewScreen({
    required this.title,
    required this.url,
    required this.headers,
    required this.isVideo,
  });

  final String title;
  final String url;
  final Map<String, String> headers;
  final bool isVideo;

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      backgroundColor: Colors.black,
      appBar: AppBar(
        backgroundColor: Colors.black,
        foregroundColor: Colors.white,
        title: Text(title, overflow: TextOverflow.ellipsis),
      ),
      body: Center(
        child: isVideo
            ? Column(
                mainAxisSize: MainAxisSize.min,
                children: [
                  const Icon(Icons.movie, color: Colors.white54, size: 72),
                  const SizedBox(height: 12),
                  const Text('Video preview opens in an external player',
                      style: TextStyle(color: Colors.white70)),
                  const SizedBox(height: 16),
                  FilledButton.icon(
                    onPressed: () => OpenFilex.open(url),
                    icon: const Icon(Icons.play_arrow),
                    label: const Text('Open'),
                  ),
                ],
              )
            : InteractiveViewer(
                child: Image.network(
                  url,
                  headers: headers,
                  fit: BoxFit.contain,
                  loadingBuilder: (context, child, progress) =>
                      progress == null
                          ? child
                          : const CircularProgressIndicator(),
                  errorBuilder: (_, _, _) => const Icon(Icons.broken_image,
                      color: Colors.white54, size: 72),
                ),
              ),
      ),
    );
  }
}
