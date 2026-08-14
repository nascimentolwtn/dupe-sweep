import 'package:flutter/material.dart';
import 'package:provider/provider.dart';
import '../main.dart';
import '../theme/app_theme.dart';
import '../widgets/photo_group_card.dart';
import '../widgets/summary_bar.dart';

class DuplicateReviewScreen extends StatefulWidget {
  const DuplicateReviewScreen({super.key});

  @override
  State<DuplicateReviewScreen> createState() => _DuplicateReviewScreenState();
}

class _DuplicateReviewScreenState extends State<DuplicateReviewScreen> {
  final ScrollController _scrollController = ScrollController();

  @override
  void dispose() {
    _scrollController.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: AppBar(
        title: const Text('Review Duplicates'),
      ),
      body: Consumer<AppStateProvider>(
        builder: (context, provider, _) {
          if (provider.photoGroups.isEmpty) {
            return const Center(
              child: Column(
                mainAxisAlignment: MainAxisAlignment.center,
                children: [
                  Icon(
                    Icons.check_circle,
                    size: 64,
                    color: AppColors.accentBest,
                  ),
                  SizedBox(height: 16),
                  Text(
                    'No duplicates found',
                    style: TextStyle(
                      fontSize: 18,
                      color: AppColors.textPrimary,
                    ),
                  ),
                  SizedBox(height: 8),
                  Text(
                    'Your photos look unique!',
                    style: TextStyle(color: AppColors.textSecondary),
                  ),
                ],
              ),
            );
          }

          return Stack(
            children: [
              Scrollbar(
                controller: _scrollController,
                thumbVisibility: true,
                trackVisibility: true,
                interactive: true,
                child: ListView.builder(
                  controller: _scrollController,
                  padding: const EdgeInsets.only(bottom: 100),
                  itemCount: provider.photoGroups.length,
                  itemBuilder: (context, index) {
                    final group = provider.photoGroups[index];
                    final shouldForceExpand =
                        group.id == provider.pendingExpandGroupId;
                    if (shouldForceExpand) {
                      debugPrint(
                          '[ReviewScreen] itemBuilder: forceExpand=true for '
                          'group ${group.id} at index $index');
                    }
                    // Ties this card's State (expanded/collapsed) to the
                    // group's identity rather than its position in the
                    // list -- without this, deleting photos out of a
                    // group earlier in the list can make a later group
                    // inherit the deleted one's expanded state when it
                    // shifts into the vacated index.
                    return PhotoGroupCard(
                      key: ValueKey(group.id),
                      group: group,
                      forceExpand: shouldForceExpand,
                    );
                  },
                ),
              ),
              Positioned(
                bottom: 0,
                left: 0,
                right: 0,
                child: SummaryBar(
                  groups: provider.photoGroups,
                ),
              ),
            ],
          );
        },
      ),
    );
  }
}
