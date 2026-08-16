import 'dart:typed_data';

import 'package:flutter/material.dart';
import 'package:photo_manager/photo_manager.dart';
import '../models/photo_item.dart';
import '../screens/photo_fullscreen_viewer.dart';
import '../services/deletion_service.dart';
import '../theme/app_theme.dart';
import '../utils/byte_formatter.dart';

/// Scrollable list of independently-flagged photos (blurry / large-file
/// results). Unlike `PhotoGroupCard`'s grid, there's no "keep the best,
/// delete the rest" comparison here -- each row stands on its own, so a
/// flat list with a per-row checkbox is the right shape instead of
/// `PhotoGroupCard`'s grouped-comparison UI.
class FlaggedPhotoList extends StatefulWidget {
  final List<PhotoItem> photos;
  final String Function(PhotoItem photo) subtitleBuilder;
  final VoidCallback onSelectionChanged;

  const FlaggedPhotoList({
    super.key,
    required this.photos,
    required this.subtitleBuilder,
    required this.onSelectionChanged,
  });

  @override
  State<FlaggedPhotoList> createState() => _FlaggedPhotoListState();
}

class _FlaggedPhotoListState extends State<FlaggedPhotoList> {
  // Explicit controller (rather than relying on ListView's implicit
  // PrimaryScrollController) so Scrollbar below can attach to it --
  // Android/iOS don't draw a scrollbar by default the way desktop/web do,
  // so without this there was no visible or grabbable scroll handle on a
  // list that can run into the hundreds of flagged photos.
  final ScrollController _scrollController = ScrollController();

  @override
  void dispose() {
    _scrollController.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    // RawScrollbar (not the plain Material Scrollbar) so minThumbLength can
    // be forced -- this list can run into the hundreds of flagged photos,
    // and the default proportional thumb shrinks to a barely-grabbable
    // sliver on a list that long. trackVisibility mirrors
    // DuplicateReviewScreen's Scrollbar, which the same complaint didn't
    // apply to.
    return RawScrollbar(
      controller: _scrollController,
      thumbVisibility: true,
      trackVisibility: true,
      interactive: true,
      thickness: 10,
      minThumbLength: 64,
      radius: const Radius.circular(6),
      thumbColor: AppColors.accentCyan,
      trackColor: AppColors.surfaceElevated,
      trackBorderColor: AppColors.border,
      child: ListView.builder(
        controller: _scrollController,
        padding: const EdgeInsets.only(bottom: 96),
        itemCount: widget.photos.length,
        itemBuilder: (context, index) {
          return _FlaggedPhotoRow(
            // Keyed by photo id, not index -- same reasoning as
            // PhotoGroupCard's thumbnail row: without this, deleting a row
            // can make Flutter reuse another row's State (and its already-
            // fetched thumbnail future) for a different photo that shifted
            // into its old index.
            key: ValueKey(widget.photos[index].id),
            photo: widget.photos[index],
            allPhotos: widget.photos,
            index: index,
            subtitle: widget.subtitleBuilder(widget.photos[index]),
            subtitleBuilder: widget.subtitleBuilder,
            onSelectionChanged: widget.onSelectionChanged,
          );
        },
      ),
    );
  }
}

class _FlaggedPhotoRow extends StatefulWidget {
  final PhotoItem photo;
  final List<PhotoItem> allPhotos;
  final int index;
  final String subtitle;
  final String Function(PhotoItem photo) subtitleBuilder;
  final VoidCallback onSelectionChanged;

  const _FlaggedPhotoRow({
    super.key,
    required this.photo,
    required this.allPhotos,
    required this.index,
    required this.subtitle,
    required this.subtitleBuilder,
    required this.onSelectionChanged,
  });

  @override
  State<_FlaggedPhotoRow> createState() => _FlaggedPhotoRowState();
}

class _FlaggedPhotoRowState extends State<_FlaggedPhotoRow> {
  // Memoized once, not rebuilt inline in FutureBuilder -- same reasoning as
  // PhotoGroupCard's _PhotoThumbnail: a rebuild (e.g. from a checkbox tap
  // elsewhere in the list) must not re-issue a fresh thumbnail fetch.
  late Future<Uint8List?> _thumbnailFuture;

  @override
  void initState() {
    super.initState();
    _thumbnailFuture = _getThumbnail(widget.photo);
  }

  Future<Uint8List?> _getThumbnail(PhotoItem photo) async {
    try {
      final asset = await AssetEntity.fromId(photo.id);
      if (asset != null) {
        return await asset.thumbnailDataWithSize(
          const ThumbnailSize(200, 200),
        );
      }
    } catch (e) {
      debugPrint('Error loading thumbnail: $e');
    }
    return null;
  }

  Future<void> _openFullscreen() async {
    await Navigator.of(context).push(
      MaterialPageRoute(
        builder: (_) => PhotoFullscreenViewer(
          photos: widget.allPhotos,
          initialIndex: widget.index,
          labelBuilder: widget.subtitleBuilder,
        ),
      ),
    );
    if (!mounted) return;
    setState(() {});
    widget.onSelectionChanged();
  }

  @override
  Widget build(BuildContext context) {
    final photo = widget.photo;
    return ListTile(
      onTap: _openFullscreen,
      leading: SizedBox(
        width: 56,
        height: 56,
        child: FutureBuilder<Uint8List?>(
          future: _thumbnailFuture,
          builder: (context, snapshot) {
            if (snapshot.connectionState != ConnectionState.done) {
              return const Center(
                child: SizedBox(
                  width: 16,
                  height: 16,
                  child: CircularProgressIndicator(strokeWidth: 2),
                ),
              );
            }
            if (snapshot.data == null) {
              return Container(
                color: AppColors.surfaceElevated,
                child: const Icon(
                  Icons.image_not_supported,
                  color: AppColors.textSecondary,
                ),
              );
            }
            return ClipRRect(
              borderRadius: BorderRadius.circular(6),
              child: Image.memory(snapshot.data!, fit: BoxFit.cover),
            );
          },
        ),
      ),
      title: Text(widget.subtitle),
      trailing: Checkbox(
        value: photo.isSelected,
        onChanged: (value) {
          setState(() => photo.isSelected = value ?? false);
          widget.onSelectionChanged();
        },
      ),
    );
  }
}

/// Bottom summary/delete bar for a flat, independently-flagged photo list
/// (blurry / large-file review screens). A separate small widget rather
/// than a forced merge into `SummaryBar`: `SummaryBar`'s selection/delete
/// logic is shaped around `PhotoGroup` (many photos being compared, one
/// marked "best" to keep), while this operates over a flat
/// `List<PhotoItem>` with no such structure. The actual delete call
/// (`DeletionService.deletePhotos`) and the confirm-dialog/partial-failure
/// handling pattern are still reused from `SummaryBar`, just not its
/// group-shaped wrapper.
class FlaggedPhotoSummaryBar extends StatelessWidget {
  final List<PhotoItem> photos;
  final VoidCallback onDeleted;
  final VoidCallback onRescan;

  const FlaggedPhotoSummaryBar({
    super.key,
    required this.photos,
    required this.onDeleted,
    required this.onRescan,
  });

  @override
  Widget build(BuildContext context) {
    final selected = photos.where((p) => p.isSelected).toList();
    final reclaimable = selected.fold<int>(0, (sum, p) => sum + p.fileSize);

    return Container(
      decoration: const BoxDecoration(
        color: AppColors.surface,
        border: Border(top: BorderSide(color: AppColors.border)),
        boxShadow: [
          BoxShadow(
            color: Colors.black54,
            blurRadius: 12,
            offset: Offset(0, -2),
          ),
        ],
      ),
      padding: EdgeInsets.fromLTRB(
        16,
        12,
        16,
        12 + MediaQuery.of(context).padding.bottom,
      ),
      child: Column(
        mainAxisSize: MainAxisSize.min,
        children: [
          if (selected.isNotEmpty) ...[
            Text(
              'Delete ${selected.length} photos? Reclaim '
              '${ByteFormatter.format(reclaimable)}',
              style: const TextStyle(
                fontSize: 14,
                color: AppColors.textPrimary,
              ),
            ),
            const SizedBox(height: 12),
          ],
          Row(
            mainAxisAlignment: MainAxisAlignment.spaceBetween,
            children: [
              ElevatedButton(
                onPressed: selected.isEmpty
                    ? null
                    : () => _showDeleteConfirmation(context, selected.length),
                style: ElevatedButton.styleFrom(
                  backgroundColor: AppColors.danger,
                  foregroundColor: Colors.white,
                ),
                child: const Text('Delete Selected'),
              ),
              ElevatedButton.icon(
                onPressed: onRescan,
                icon: const Icon(Icons.refresh),
                label: const Text('Re-scan'),
              ),
            ],
          ),
        ],
      ),
    );
  }

  void _showDeleteConfirmation(BuildContext context, int count) {
    showDialog(
      context: context,
      // Named distinctly from the outer `context` on purpose -- same
      // reasoning as SummaryBar._showDeleteConfirmation: the dialog's own
      // context becomes unmounted the instant Navigator.pop(dialogContext)
      // runs below, so the async delete must use the outer context.
      builder: (dialogContext) => AlertDialog(
        title: const Text('Confirm Delete'),
        content: Text('Delete $count photos? This cannot be undone.'),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(dialogContext),
            child: const Text('Cancel'),
          ),
          TextButton(
            onPressed: () async {
              Navigator.pop(dialogContext);
              await _performDeletion(context);
            },
            child: const Text(
              'Delete',
              style: TextStyle(color: AppColors.danger),
            ),
          ),
        ],
      ),
    );
  }

  Future<void> _performDeletion(BuildContext context) async {
    final toDelete =
        photos.where((p) => p.isSelected).map((p) => p.id).toList();
    if (toDelete.isEmpty) return;

    try {
      final deletedIds = await DeletionService.deletePhotos(toDelete);

      photos.removeWhere((p) => deletedIds.contains(p.id));

      // A photo that was requested but not confirmed deleted stays in the
      // list, but must not stay visually marked as still selected/pending
      // since nothing further is going to happen to it from this attempt.
      final notDeleted = toDelete.toSet().difference(deletedIds.toSet());
      for (final p in photos) {
        if (notDeleted.contains(p.id)) p.isSelected = false;
      }

      onDeleted();

      if (context.mounted) {
        final message = deletedIds.length == toDelete.length
            ? 'Deleted ${deletedIds.length} photos'
            : deletedIds.isEmpty
                ? 'Delete cancelled -- no photos were deleted'
                : 'Deleted ${deletedIds.length} of ${toDelete.length} '
                    'photos';
        ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(content: Text(message)),
        );
      }
    } catch (e) {
      if (context.mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(content: Text('Error: $e')),
        );
      }
    }
  }
}
