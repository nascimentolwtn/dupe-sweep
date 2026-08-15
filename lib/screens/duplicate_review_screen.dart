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

  // One GlobalKey per group id, reused across rebuilds via putIfAbsent --
  // lets _maybeScrollToPendingExpand find the on-screen (or off-screen but
  // built) RenderObject for a specific group after a delete, so it can be
  // scrolled into view. Never explicitly pruned: stale entries for
  // long-deleted groups are cheap (an unused GlobalKey) and self-correct
  // the next time that same group id would matter, which never happens.
  final Map<String, GlobalKey> _itemKeys = {};

  // Tracks the last pendingExpandGroupId this screen already reacted to,
  // so a delete's scroll only fires once per delete (pendingExpandGroupId
  // is a one-shot signal from AppStateProvider that stays set between
  // rebuilds -- without this guard every unrelated rebuild, e.g. a
  // selection toggle, would re-trigger the same scroll).
  String? _lastScrolledPendingExpandId;

  GlobalKey _keyForGroup(String groupId) =>
      _itemKeys.putIfAbsent(groupId, () => GlobalKey());

  void _maybeScrollToPendingExpand(AppStateProvider provider) {
    final pendingId = provider.pendingExpandGroupId;
    if (pendingId == null || pendingId == _lastScrolledPendingExpandId) {
      return;
    }
    _lastScrolledPendingExpandId = pendingId;

    // Deferred to after this frame builds: the target group's PhotoGroupCard
    // (now force-expanded) needs to have actually laid out at its new
    // (taller) size before Scrollable.ensureVisible can compute how far to
    // scroll.
    WidgetsBinding.instance.addPostFrameCallback((_) {
      final targetContext = _itemKeys[pendingId]?.currentContext;
      if (targetContext == null) return;
      Scrollable.ensureVisible(
        targetContext,
        duration: const Duration(milliseconds: 300),
        curve: Curves.easeOut,
      );
    });
  }

  @override
  void dispose() {
    _scrollController.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    // context.watch (not a nested Consumer) so the AppBar title -- not just
    // the body -- rebuilds when photoGroups changes (e.g. after a delete
    // removes a group): a Consumer scoped to just the body wouldn't reach
    // the title at all.
    final provider = context.watch<AppStateProvider>();
    _maybeScrollToPendingExpand(provider);

    final groupCount = provider.photoGroups.length;

    return Scaffold(
      appBar: AppBar(
        title: Text(
          groupCount == 0
              ? 'Review Dupes'
              : 'Review Dupes ($groupCount '
                  '${groupCount == 1 ? 'group' : 'groups'})',
        ),
      ),
      body: groupCount == 0
          ? const Center(
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
            )
          : Stack(
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
                      //
                      // Wrapped in a KeyedSubtree carrying a separate
                      // GlobalKey (not the ValueKey above, which only needs
                      // to be unique among siblings) so
                      // _maybeScrollToPendingExpand can look up this exact
                      // group's on-screen position via
                      // `_itemKeys[groupId].currentContext`.
                      return KeyedSubtree(
                        key: _keyForGroup(group.id),
                        child: PhotoGroupCard(
                          key: ValueKey(group.id),
                          group: group,
                          forceExpand: shouldForceExpand,
                        ),
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
            ),
    );
  }
}
