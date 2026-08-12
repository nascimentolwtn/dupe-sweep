import 'package:flutter/material.dart';
import '../main.dart';
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
      totalSelected += group.selectedCount;
      totalReclaimable += group.reclaimableBytes;
    }

    return Container(
      decoration: BoxDecoration(
        color: Colors.white,
        boxShadow: [
          BoxShadow(
            color: Colors.black.withAlpha(25),
            blurRadius: 4,
            offset: const Offset(0, -2),
          ),
        ],
      ),
      padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 12),
      child: Column(
        mainAxisSize: MainAxisSize.min,
        children: [
          if (totalSelected > 0) ...[
            Text(
              'Delete ${totalSelected} photos? Reclaim ${ByteFormatter.format(totalReclaimable)}',
              style: const TextStyle(fontSize: 14),
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
                  backgroundColor: Colors.red,
                  foregroundColor: Colors.white,
                ),
                child: const Text('Delete Selected'),
              ),
              ElevatedButton.icon(
                onPressed: () {},
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
            child: const Text('Delete', style: TextStyle(color: Colors.red)),
          ),
        ],
      ),
    );
  }

  Future<void> _performDeletion(BuildContext context) async {
    final photosToDelete = <String>[];

    for (final group in groups) {
      for (final photo in group.photos) {
        if (photo.isSelected && !photo.isBest) {
          photosToDelete.add(photo.id);
        }
      }
    }

    if (photosToDelete.isEmpty) return;

    try {
      final deleted = await DeletionService.deletePhotos(photosToDelete);
      if (context.mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(content: Text('Deleted $deleted photos')),
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
