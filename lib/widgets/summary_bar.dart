import 'package:flutter/material.dart';
import 'package:provider/provider.dart';
import '../main.dart';
import '../models/photo_group.dart';
import '../screens/scan_progress_screen.dart';
import '../theme/app_theme.dart';
import '../utils/byte_formatter.dart';
import '../services/deletion_service.dart';

class SummaryBar extends StatelessWidget {
  final List<PhotoGroup> groups;

  const SummaryBar({
    Key? key,
    required this.groups,
  }) : super(key: key);

  @override
  Widget build(BuildContext context) {
    int totalSelected = 0;
    int totalReclaimable = 0;

    for (final group in groups) {
      totalSelected += group.selectedCount.toInt();
      totalReclaimable += group.reclaimableBytes.toInt();
    }

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
        // Add the system nav bar's inset so the buttons clear gesture-nav
        // pill / 3-button nav on real devices instead of sitting behind it.
        12 + MediaQuery.of(context).padding.bottom,
      ),
      child: Column(
        mainAxisSize: MainAxisSize.min,
        children: [
          if (totalSelected > 0) ...[
            Text(
              'Delete ${totalSelected} photos? Reclaim ${ByteFormatter.format(totalReclaimable)}',
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
                onPressed: totalSelected == 0
                    ? null
                    : () => _showDeleteConfirmation(context, totalSelected),
                style: ElevatedButton.styleFrom(
                  backgroundColor: AppColors.danger,
                  foregroundColor: Colors.white,
                ),
                child: const Text('Delete Selected'),
              ),
              ElevatedButton.icon(
                onPressed: () {
                  Navigator.of(context).pushReplacement(
                    MaterialPageRoute(
                      builder: (_) => const ScanProgressScreen(),
                    ),
                  );
                },
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
      builder: (context) => AlertDialog(
        title: const Text('Confirm Delete'),
        content: Text('Delete $count photos? This cannot be undone.'),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(context),
            child: const Text('Cancel'),
          ),
          TextButton(
            onPressed: () async {
              Navigator.pop(context);
              await _performDeletion(context);
            },
            child:
                const Text('Delete', style: TextStyle(color: AppColors.danger)),
          ),
        ],
      ),
    );
  }

  Future<void> _performDeletion(BuildContext context) async {
    // Deliberately no `!photo.isBest` filter here: `isBest` is only a
    // stopgap "largest file size" guess (see scan_progress_screen.dart),
    // not a guarantee -- the whole point of a manual review screen is that
    // the user can override it, including deciding no photo in a group is
    // worth keeping and deleting all of them.
    final photosToDelete = <String>[
      for (final group in groups)
        for (final photo in group.photos)
          if (photo.isSelected) photo.id,
    ];

    print('[SummaryBar] Delete requested: ${photosToDelete.length} photos');

    if (photosToDelete.isEmpty) return;

    try {
      final deletedIds = await DeletionService.deletePhotos(photosToDelete);

      if (deletedIds.isNotEmpty && context.mounted) {
        // Removes the deleted photos (and any group left with nothing to
        // compare) from the review list -- without this the screen kept
        // showing already-deleted photos until the next full re-scan.
        context
            .read<AppStateProvider>()
            .removeDeletedPhotos(deletedIds.toSet());
      }

      if (context.mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(content: Text('Deleted ${deletedIds.length} photos')),
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
