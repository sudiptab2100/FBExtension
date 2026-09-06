import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:go_router/go_router.dart';
import 'package:path/path.dart' as p;

import '../../core/network/api_exception.dart';
import '../../core/utils/format.dart';
import '../../data/models/file_entry.dart';
import '../../routing/router.dart';
import '../../state/api_providers.dart';
import '../../state/session_controller.dart';
import '../../widgets/status_views.dart';
import 'file_thumbnail.dart';

typedef SearchArgs = ({String q, String? drive});

final searchResultsProvider =
    FutureProvider.autoDispose.family<List<SearchHit>, SearchArgs>((ref, args) {
  final q = args.q.trim();
  if (q.length < 2) return Future.value(const <SearchHit>[]);
  ref.watch(sessionControllerProvider.select((s) => s.effectiveViewMode));
  return ref.watch(filesRepositoryProvider).search(q, drive: args.drive);
});

class SearchScreen extends ConsumerStatefulWidget {
  const SearchScreen({super.key, this.initialDrive, this.driveLabel});

  final String? initialDrive;
  final String? driveLabel;

  @override
  ConsumerState<SearchScreen> createState() => _SearchScreenState();
}

class _SearchScreenState extends ConsumerState<SearchScreen> {
  final _controller = TextEditingController();
  Timer? _debounce;
  String _query = '';

  @override
  void dispose() {
    _debounce?.cancel();
    _controller.dispose();
    super.dispose();
  }

  void _onChanged(String value) {
    _debounce?.cancel();
    _debounce = Timer(const Duration(milliseconds: 350), () {
      if (mounted) setState(() => _query = value);
    });
  }

  void _openHit(SearchHit hit) {
    final label = widget.driveLabel?.isNotEmpty == true
        ? widget.driveLabel!
        : hit.drive;
    final targetPath = hit.isDir ? hit.path : p.dirname(hit.path);
    context.push(
      Uri(path: Routes.files, queryParameters: {
        'drive': hit.drive,
        'path': targetPath == '.' ? '' : targetPath,
        'label': label,
      }).toString(),
    );
  }

  @override
  Widget build(BuildContext context) {
    final scoped = widget.initialDrive != null;
    final results = ref.watch(
        searchResultsProvider((q: _query, drive: widget.initialDrive)));

    return Scaffold(
      appBar: AppBar(
        titleSpacing: 0,
        title: TextField(
          controller: _controller,
          autofocus: true,
          textInputAction: TextInputAction.search,
          onChanged: _onChanged,
          decoration: InputDecoration(
            border: InputBorder.none,
            hintText: scoped
                ? 'Search ${widget.driveLabel ?? 'this drive'}…'
                : 'Search all drives…',
          ),
        ),
        actions: [
          if (_controller.text.isNotEmpty)
            IconButton(
              icon: const Icon(Icons.clear),
              onPressed: () {
                _controller.clear();
                setState(() => _query = '');
              },
            ),
        ],
      ),
      body: _query.trim().length < 2
          ? const EmptyView(
              icon: Icons.search,
              message: 'Type at least 2 characters to search.',
            )
          : results.when(
              loading: () => const LoadingView(label: 'Searching…'),
              error: (e, _) => ErrorView(
                message: e is ApiException ? e.message : e.toString(),
                onRetry: () => ref.invalidate(searchResultsProvider),
              ),
              data: (hits) {
                if (hits.isEmpty) {
                  return const EmptyView(
                    icon: Icons.search_off,
                    message: 'No matches found.',
                  );
                }
                return ListView.builder(
                  itemCount: hits.length,
                  itemBuilder: (_, i) {
                    final hit = hits[i];
                    return ListTile(
                      leading:
                          FileThumbnail(drive: hit.drive, entry: hit, size: 40),
                      title: Text(hit.name,
                          maxLines: 1, overflow: TextOverflow.ellipsis),
                      subtitle: Text(
                        '${hit.drive} · ${hit.path}',
                        maxLines: 1,
                        overflow: TextOverflow.ellipsis,
                      ),
                      trailing: hit.isDir
                          ? const Icon(Icons.chevron_right)
                          : Text(formatBytes(hit.size),
                              style: Theme.of(context).textTheme.bodySmall),
                      onTap: () => _openHit(hit),
                    );
                  },
                );
              },
            ),
    );
  }
}
