import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:photo_manager/photo_manager.dart';

import '../../data/services/media_service.dart';
import '../files/upload_progress_dialog.dart';
import 'destination_picker.dart';

/// Full-screen picker for on-device photos & videos with multi-select, album
/// switching, paged loading, and upload to a chosen drive/folder.
class PhotoGridScreen extends ConsumerStatefulWidget {
  const PhotoGridScreen({super.key});

  @override
  ConsumerState<PhotoGridScreen> createState() => _PhotoGridScreenState();
}

class _PhotoGridScreenState extends ConsumerState<PhotoGridScreen> {
  static const _pageSize = 60;

  final _scroll = ScrollController();
  final Map<String, AssetEntity> _selected = {};

  bool _loading = true;
  bool _denied = false;
  bool _loadingMore = false;
  bool _hasMore = true;
  int _page = 0;

  List<AssetPathEntity> _albums = const [];
  AssetPathEntity? _album;
  final List<AssetEntity> _assets = [];

  @override
  void initState() {
    super.initState();
    _scroll.addListener(_onScroll);
    _bootstrap();
  }

  @override
  void dispose() {
    _scroll.dispose();
    super.dispose();
  }

  Future<void> _bootstrap() async {
    final media = ref.read(mediaServiceProvider);
    final ok = await media.requestGalleryAccess();
    if (!ok) {
      if (mounted) {
        setState(() {
          _denied = true;
          _loading = false;
        });
      }
      return;
    }
    final albums = await media.albums();
    if (!mounted) return;
    if (albums.isEmpty) {
      setState(() {
        _albums = albums;
        _loading = false;
      });
      return;
    }
    setState(() {
      _albums = albums;
      _album = albums.first;
    });
    await _loadPage(reset: true);
  }

  Future<void> _switchAlbum(AssetPathEntity album) async {
    setState(() {
      _album = album;
      _assets.clear();
      _page = 0;
      _hasMore = true;
      _loading = true;
    });
    await _loadPage(reset: true);
  }

  Future<void> _loadPage({bool reset = false}) async {
    final album = _album;
    if (album == null) return;
    final media = ref.read(mediaServiceProvider);
    final batch =
        await media.assets(album, page: _page, pageSize: _pageSize);
    if (!mounted) return;
    setState(() {
      if (reset) _assets.clear();
      _assets.addAll(batch);
      _page += 1;
      _hasMore = batch.length == _pageSize;
      _loading = false;
      _loadingMore = false;
    });
  }

  void _onScroll() {
    if (_loadingMore || !_hasMore || _loading) return;
    if (_scroll.position.pixels >=
        _scroll.position.maxScrollExtent - 600) {
      _loadingMore = true;
      _loadPage();
    }
  }

  void _toggle(AssetEntity a) => setState(() {
        if (_selected.remove(a.id) == null) _selected[a.id] = a;
      });

  Future<void> _uploadSelected() async {
    if (_selected.isEmpty) return;
    final dest = await showDestinationPicker(context);
    if (dest == null || !mounted) return;

    final media = ref.read(mediaServiceProvider);
    final files = await media.filesFor(_selected.values);
    if (!mounted) return;
    if (files.isEmpty) {
      ScaffoldMessenger.of(context).showSnackBar(
        const SnackBar(content: Text('Could not read the selected items.')),
      );
      return;
    }
    await showDialog<void>(
      context: context,
      barrierDismissible: false,
      builder: (_) => UploadProgressDialog(
        files: files,
        drive: dest.drive,
        destPath: dest.path,
      ),
    );
    if (mounted) setState(() => _selected.clear());
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: AppBar(
        title: _albums.length > 1 && _album != null
            ? _AlbumDropdown(
                albums: _albums,
                current: _album!,
                onChanged: _switchAlbum,
              )
            : const Text('Photos & videos'),
        actions: [
          if (_selected.isNotEmpty)
            TextButton(
              onPressed: () => setState(_selected.clear),
              child: Text('Clear (${_selected.length})'),
            ),
        ],
      ),
      floatingActionButton: _selected.isEmpty
          ? null
          : FloatingActionButton.extended(
              onPressed: _uploadSelected,
              icon: const Icon(Icons.cloud_upload_outlined),
              label: Text('Upload ${_selected.length}'),
            ),
      body: _body(),
    );
  }

  Widget _body() {
    if (_loading) {
      return const Center(child: CircularProgressIndicator());
    }
    if (_denied) {
      return _Info(
        icon: Icons.no_photography_outlined,
        title: 'Photo access needed',
        message: 'Allow photo & video access in Settings to pick media for '
            'upload.',
        action: FilledButton(
          onPressed: () => PhotoManager.openSetting(),
          child: const Text('Open settings'),
        ),
      );
    }
    if (_assets.isEmpty) {
      return const _Info(
        icon: Icons.photo_library_outlined,
        title: 'No media found',
        message: 'This device has no photos or videos to show.',
      );
    }
    return GridView.builder(
      controller: _scroll,
      padding: const EdgeInsets.all(2),
      gridDelegate: const SliverGridDelegateWithFixedCrossAxisCount(
        crossAxisCount: 3,
        crossAxisSpacing: 2,
        mainAxisSpacing: 2,
      ),
      itemCount: _assets.length + (_hasMore ? 1 : 0),
      itemBuilder: (_, i) {
        if (i >= _assets.length) {
          return const Center(
            child: Padding(
              padding: EdgeInsets.all(8),
              child: SizedBox(
                width: 22,
                height: 22,
                child: CircularProgressIndicator(strokeWidth: 2),
              ),
            ),
          );
        }
        final a = _assets[i];
        return _AssetTile(
          asset: a,
          selected: _selected.containsKey(a.id),
          onTap: () => _toggle(a),
        );
      },
    );
  }
}

class _AlbumDropdown extends StatelessWidget {
  const _AlbumDropdown({
    required this.albums,
    required this.current,
    required this.onChanged,
  });

  final List<AssetPathEntity> albums;
  final AssetPathEntity current;
  final ValueChanged<AssetPathEntity> onChanged;

  @override
  Widget build(BuildContext context) {
    return DropdownButtonHideUnderline(
      child: DropdownButton<AssetPathEntity>(
        value: current,
        isDense: true,
        borderRadius: BorderRadius.circular(12),
        items: [
          for (final a in albums)
            DropdownMenuItem(
              value: a,
              child: Text(a.name.isEmpty ? 'Album' : a.name,
                  overflow: TextOverflow.ellipsis),
            ),
        ],
        onChanged: (a) {
          if (a != null && a != current) onChanged(a);
        },
      ),
    );
  }
}

class _AssetTile extends StatelessWidget {
  const _AssetTile({
    required this.asset,
    required this.selected,
    required this.onTap,
  });

  final AssetEntity asset;
  final bool selected;
  final VoidCallback onTap;

  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    return GestureDetector(
      onTap: onTap,
      child: Stack(
        fit: StackFit.expand,
        children: [
          FutureBuilder(
            future: asset.thumbnailDataWithSize(const ThumbnailSize.square(220)),
            builder: (_, snap) {
              final data = snap.data;
              if (data == null) {
                return Container(color: scheme.surfaceContainerHighest);
              }
              return Image.memory(data, fit: BoxFit.cover, gaplessPlayback: true);
            },
          ),
          if (asset.type == AssetType.video)
            const Positioned(
              right: 4,
              bottom: 4,
              child: Icon(Icons.videocam, color: Colors.white, size: 18),
            ),
          if (selected)
            Container(color: scheme.primary.withValues(alpha: 0.35)),
          Positioned(
            top: 4,
            left: 4,
            child: Icon(
              selected ? Icons.check_circle : Icons.circle_outlined,
              color: selected ? scheme.primary : Colors.white,
              size: 22,
            ),
          ),
        ],
      ),
    );
  }
}

class _Info extends StatelessWidget {
  const _Info({
    required this.icon,
    required this.title,
    required this.message,
    this.action,
  });

  final IconData icon;
  final String title;
  final String message;
  final Widget? action;

  @override
  Widget build(BuildContext context) {
    return Center(
      child: Padding(
        padding: const EdgeInsets.all(32),
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            Icon(icon, size: 56, color: Theme.of(context).colorScheme.outline),
            const SizedBox(height: 16),
            Text(title, style: Theme.of(context).textTheme.titleMedium),
            const SizedBox(height: 8),
            Text(message, textAlign: TextAlign.center),
            if (action != null) ...[
              const SizedBox(height: 16),
              action!,
            ],
          ],
        ),
      ),
    );
  }
}
