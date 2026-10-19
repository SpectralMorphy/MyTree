import 'dart:collection';
import 'dart:math' as math;

import 'tree_document.dart';

enum TreeTrunkMode { father, mother, both }

enum TreeEmphasis { normal, cousin, distant }

enum TreeBranch { neutral, maternal, paternal, both }

/// A Flutter-independent ranked layout. Cross coordinates are signed around 0;
/// the UI supplies orientation, per-generation scrolling, and viewport padding.
class TreeLayout {
  const TreeLayout._({
    required this.selectedId,
    required this.mode,
    required this.nodeExtent,
    required this.gap,
    required this.levels,
    required this.positions,
    required this.trunkIds,
    required this.links,
  });

  /// Ordering comes from the current family structure, not selection history.
  /// [previousLayout] is accepted for caller compatibility but never consulted.
  /// Mode-specific backbones respect the same structural parental-role sides.
  /// Own/sibling partner proximity applies in every mode without member moves;
  /// only actual ancestral parent seams in [TreeTrunkMode.both] may reorder them.
  factory TreeLayout.build(
    TreeDocument document, {
    required String selectedId,
    required TreeTrunkMode mode,
    double nodeExtent = 96,
    double gap = 24,
    TreeLayout? previousLayout,
  }) {
    if (!nodeExtent.isFinite || nodeExtent <= 0) {
      throw ArgumentError.value(nodeExtent, 'nodeExtent', 'Must be positive.');
    }
    if (!gap.isFinite || gap < 0) {
      throw ArgumentError.value(gap, 'gap', 'Must be nonnegative.');
    }
    final people = document.people;
    if (!people.containsKey(selectedId)) {
      throw ArgumentError.value(selectedId, 'selectedId', 'Unknown person.');
    }
    final ids = people.keys.toList()..sort();
    final parents = <String, List<String>>{};
    final children = <String, List<String>>{for (final id in ids) id: []};
    for (final id in ids) {
      final person = people[id]!;
      final known = <String>{
        if (person.fatherId case final father?) father,
        if (person.motherId case final mother?) mother,
      };
      for (final parent in known) {
        if (!people.containsKey(parent)) {
          throw StateError('Unknown parent $parent of $id.');
        }
        children[parent]!.add(id);
      }
      parents[id] = known.toList();
    }

    final siblingGroupIds = document.siblingGroupIds;
    final drafts = <String, _SiblingDraft>{};
    for (final id in ids) {
      final person = people[id]!;
      final father = person.fatherId;
      final mother = person.motherId;
      // The model owns explicit incomplete-parent sibling components and normal
      // computed full siblings. Every projected group has coherent parent roles.
      final key = siblingGroupIds[id]!;
      (drafts[key] ??= _SiblingDraft(key, father, mother)).people.add(person);
    }
    final siblingMembers = <String, List<String>>{
      for (final block in drafts.values)
        block.id: [for (final person in block.people) person.id],
    };
    Iterable<String> siblingsOf(String id) sync* {
      final seen = <String>{id};
      for (final sibling in siblingMembers[siblingGroupIds[id]]!) {
        if (seen.add(sibling)) yield sibling;
      }
      for (final parent in parents[id]!) {
        for (final sibling in children[parent]!) {
          if (seen.add(sibling)) yield sibling;
        }
      }
    }

    final ranks = _generationRanks(ids, parents, drafts.values);
    final rolePreferences = _descendantRolePreferences(
      ids,
      people,
      parents,
      ranks,
    );

    // A bit can visit an ancestor once. Shared ancestors are not duplicated and
    // pedigree collapse never expands into exponentially many ancestry paths.
    final selected = people[selectedId]!;
    final ancestry = <String, int>{};
    final ancestryQueue = Queue<(String, int)>();
    if (selected.motherId case final mother?) {
      ancestryQueue.add((mother, 1));
    }
    if (selected.fatherId case final father?) {
      ancestryQueue.add((father, 2));
    }
    while (ancestryQueue.isNotEmpty) {
      final (id, mask) = ancestryQueue.removeFirst();
      final previous = ancestry[id] ?? 0;
      if ((previous | mask) == previous) continue;
      ancestry[id] = previous | mask;
      for (final parent in parents[id]!) {
        ancestryQueue.add((parent, mask));
      }
    }
    final trunkMask = switch (mode) {
      TreeTrunkMode.father => 2,
      TreeTrunkMode.mother => 1,
      TreeTrunkMode.both => 3,
    };
    final trunkIds = <String>{
      selectedId,
      for (final entry in ancestry.entries)
        if ((entry.value & trunkMask) != 0) entry.key,
    };
    final descendants = _reachable(selectedId, children)..remove(selectedId);
    final siblings = siblingsOf(selectedId).toSet();
    final coParentPairs = <(String, String)>{
      for (final id in ids)
        if (people[id]!.motherId case final mother?)
          if (people[id]!.fatherId case final father?)
            if (mother != father) (mother, father),
    };
    final auntsAndUncles = <String>{
      for (final parent in parents[selectedId]!) ...siblingsOf(parent),
    }..removeAll(parents[selectedId]!);
    final cousins = <String>{
      for (final relative in auntsAndUncles) ...children[relative]!,
      // The same muted family context includes nieces/nephews of full or half
      // siblings. Normal ancestry/descendant emphasis below always wins.
      for (final sibling in siblings) ...children[sibling]!,
    };
    final ancestralSiblings = <String>{
      for (final ancestor in ancestry.keys) ...siblingsOf(ancestor),
    };
    final normalIds = <String>{
      selectedId,
      ...ancestry.keys,
      ...descendants,
      ...siblings,
    };
    TreeEmphasis emphasisOf(String id) => normalIds.contains(id)
        ? TreeEmphasis.normal
        : cousins.contains(id) || ancestralSiblings.contains(id)
        ? TreeEmphasis.cousin
        : TreeEmphasis.distant;

    final branches = _contextBranches(selectedId, ancestry, parents, children);
    final byLevel = <int, List<_SiblingDraft>>{};
    for (final block in drafts.values) {
      block.people.sort(compareTreePeopleByBirth);
      block.level = ranks[block.people.first.id]!;
      block.trunk = block.people.any((p) => trunkIds.contains(p.id));
      block.emphasis = block.people
          .map((p) => emphasisOf(p.id))
          .reduce((a, b) => a.index < b.index ? a : b);
      block.mask = block.people.fold(
        0,
        (mask, person) => mask | (branches[person.id] ?? 0),
      );
      block.ancestorMask = block.people.fold(
        0,
        (mask, person) => mask | (ancestry[person.id] ?? 0),
      );
      (byLevel[block.level] ??= []).add(block);
    }

    // Single-branch centering follows one person on the preferred parental
    // chain, not the average of all ancestors sharing that branch. The other
    // parent is a fallback only when the preferred parent is unknown.
    final centerIds = <int, String>{ranks[selectedId]!: selectedId};
    if (mode != TreeTrunkMode.both) {
      TreePerson? current = selected;
      while (current != null) {
        final parent = mode == TreeTrunkMode.father
            ? current.fatherId ?? current.motherId
            : current.motherId ?? current.fatherId;
        current = parent == null ? null : people[parent];
        if (current != null) centerIds[ranks[current.id]!] = current.id;
      }
    }

    final parentPairs = mode == TreeTrunkMode.both
        ? _ancestralParentPairs(selectedId, people)
        : <(String, String)>[];
    final selectedParents =
        selected.motherId != null && selected.fatherId != null
        ? (selected.motherId!, selected.fatherId!)
        : null;
    final levels = <TreeGeneration>[];
    final positions = <String, TreeNodePosition>{};
    final levelIndices = byLevel.keys.toList()..sort();
    var descendantSides = <String, int>{};
    for (final index in levelIndices) {
      var blocks = _orderedBlocks(
        byLevel[index]!,
        people,
        mode,
        parentPairs,
        selectedId,
        rolePreferences[index] ?? const [],
      );
      blocks = _orderParentCohorts(
        blocks,
        mode,
        parentPairs,
        rolePreferences[index] ?? const [],
        selectedId: selectedId,
        siblingIds: siblings,
        couples: coParentPairs,
        descendantIds: mode == TreeTrunkMode.both && index > ranks[selectedId]!
            ? descendants
            : const {},
        descendantSides: descendantSides,
      );
      if (mode == TreeTrunkMode.both && index == ranks[selectedId]) {
        descendantSides = _descendantContextSides(
          blocks,
          selectedId,
          ancestry.keys,
          descendants,
          children,
          siblingGroupIds,
          siblingMembers,
        );
      }
      final packing = _GenerationPacking(nodeExtent, gap);
      packing.place(blocks, centerIds[index], ancestry, mode, selectedParents);
      final placed = <TreeSiblingBlock>[];
      for (final block in blocks) {
        final branch = _branch(block.mask);
        placed.add(
          TreeSiblingBlock(
            id: block.id,
            people: List.unmodifiable(block.people),
            fatherId: block.fatherId,
            motherId: block.motherId,
            start: block.start,
            extent: packing.extent(block),
            trunk: block.trunk,
            emphasis: block.emphasis,
            branch: branch,
          ),
        );
        for (var i = 0; i < block.people.length; i++) {
          final id = block.people[i].id;
          positions[id] = TreeNodePosition(
            personId: id,
            blockId: block.id,
            level: index,
            crossCenter: block.start + nodeExtent / 2 + i * (nodeExtent + gap),
            trunk: trunkIds.contains(id),
            emphasis: emphasisOf(id),
            branch: _branch(branches[id] ?? 0),
          );
        }
      }
      placed.sort((a, b) => a.start.compareTo(b.start));
      levels.add(
        TreeGeneration(
          index: index,
          blocks: List.unmodifiable(placed),
          minCross: packing.minCross,
          maxCross: packing.maxCross,
        ),
      );
    }
    return TreeLayout._(
      selectedId: selectedId,
      mode: mode,
      nodeExtent: nodeExtent,
      gap: gap,
      levels: List.unmodifiable(levels),
      positions: Map.unmodifiable(positions),
      trunkIds: Set.unmodifiable(trunkIds),
      links: List.unmodifiable([
        for (final id in ids)
          for (final parent in parents[id]!)
            TreeLink(
              parentId: parent,
              childId: id,
              blockId: positions[id]!.blockId,
            ),
      ]),
    );
  }

  final String selectedId;
  final TreeTrunkMode mode;
  final double nodeExtent;
  final double gap;
  final List<TreeGeneration> levels;
  final Map<String, TreeNodePosition> positions;
  final Set<String> trunkIds;
  final List<TreeLink> links;
}

class TreeGeneration {
  const TreeGeneration({
    required this.index,
    required this.blocks,
    required this.minCross,
    required this.maxCross,
  });

  final int index;
  final List<TreeSiblingBlock> blocks;
  final double minCross;
  final double maxCross;
  double get crossExtent => maxCross - minCross;
}

class TreeSiblingBlock {
  const TreeSiblingBlock({
    required this.id,
    required this.people,
    required this.fatherId,
    required this.motherId,
    required this.start,
    required this.extent,
    required this.trunk,
    required this.emphasis,
    required this.branch,
  });

  final String id;
  final List<TreePerson> people;
  final String? fatherId;
  final String? motherId;
  final double start;
  final double extent;
  final bool trunk;
  final TreeEmphasis emphasis;
  final TreeBranch branch;
  double get center => start + extent / 2;
}

class TreeNodePosition {
  const TreeNodePosition({
    required this.personId,
    required this.blockId,
    required this.level,
    required this.crossCenter,
    required this.trunk,
    required this.emphasis,
    required this.branch,
  });

  final String personId;
  final String blockId;
  final int level;
  final double crossCenter;
  final bool trunk;
  final TreeEmphasis emphasis;
  final TreeBranch branch;
}

/// An actual parent-child edge, including edges that skip generation bands.
/// The child block ID lets the painter share buses for full siblings.
class TreeLink {
  const TreeLink({
    required this.parentId,
    required this.childId,
    required this.blockId,
  });

  final String parentId;
  final String childId;
  final String blockId;
}

/// Full siblings are rigid generation units. Co-parents share a generation
/// whenever merging their units preserves the ancestry DAG. Conflicting unions
/// use canonical parent-ID pair order, never selection, birth dates, child IDs,
/// or map iteration order. This is a maximal compatible set, not a maximum one:
/// a later incompatible union retains its real cross-generation parent links.
Map<String, int> _generationRanks(
  List<String> ids,
  Map<String, List<String>> parents,
  Iterable<_SiblingDraft> blocks,
) {
  final components = <String, String>{};
  for (final block in blocks) {
    // Members arrived in sorted ID order, before display birth-order sorting.
    final first = block.people.first.id;
    for (final person in block.people) {
      components[person.id] = first;
    }
  }
  String component(String id) {
    var root = id;
    while (components[root] != root) {
      root = components[root]!;
    }
    while (id != root) {
      final next = components[id]!;
      components[id] = root;
      id = next;
    }
    return root;
  }

  final successors = <String, Set<String>>{
    for (final id in ids)
      if (components[id] == id) id: {},
  };
  final predecessors = <String, Set<String>>{
    for (final id in successors.keys) id: {},
  };
  final couples = <(String, String)>{};
  for (final id in ids) {
    final known = parents[id]!;
    for (final parent in known) {
      successors[component(parent)]!.add(component(id));
      predecessors[component(id)]!.add(component(parent));
    }
    if (known.length == 2) {
      final a = known[0];
      final b = known[1];
      couples.add(a.compareTo(b) < 0 ? (a, b) : (b, a));
    }
  }
  final orderedCouples = couples.toList()
    ..sort((a, b) {
      final first = a.$1.compareTo(b.$1);
      return first != 0 ? first : a.$2.compareTo(b.$2);
    });
  for (final (first, second) in orderedCouples) {
    final a = component(first);
    final b = component(second);
    if (a == b) continue;
    // Check the CURRENT quotient, not just the original ancestry: two safe
    // unions separately can form a cycle together through a spouse chain.
    if (_reachable(a, successors).contains(b) ||
        _reachable(b, successors).contains(a)) {
      continue;
    }
    final keep = a.compareTo(b) < 0 ? a : b;
    final drop = keep == a ? b : a;
    for (final parent in predecessors.remove(drop)!) {
      successors[parent]!
        ..remove(drop)
        ..add(keep);
      predecessors[keep]!.add(parent);
    }
    for (final child in successors.remove(drop)!) {
      predecessors[child]!
        ..remove(drop)
        ..add(keep);
      successors[keep]!.add(child);
    }
    components[drop] = keep;
  }

  // Longest parent paths establish the earliest feasible ranks on the quotient.
  final pending = {
    for (final id in successors.keys) id: predecessors[id]!.length,
  };
  final ranks = {for (final id in successors.keys) id: 0};
  final queue = Queue<String>.of(
    successors.keys.where((id) => pending[id] == 0),
  );
  final topological = <String>[];
  while (queue.isNotEmpty) {
    final id = queue.removeFirst();
    topological.add(id);
    for (final child in successors[id]!) {
      ranks[child] = math.max(ranks[child]!, ranks[id]! + 1);
      pending[child] = pending[child]! - 1;
      if (pending[child] == 0) queue.add(child);
    }
  }
  if (topological.length != successors.length) {
    throw StateError('The parent graph contains a directed cycle.');
  }
  _compactGenerationRanks(successors, predecessors, ranks);
  return {for (final id in ids) id: ranks[component(id)]!};
}

/// Minimize total edge slack on the rigid-cohort DAG, without freezing either
/// sources or terminals. Raising a set changes this linear cost by the sum of
/// (indegree - outdegree) in that set. Tight outgoing edges require raising the
/// child too; minimum-weight closure finds the best compatible set, including
/// free collateral leaves that a one-node/backwards pass would leave behind.
void _compactGenerationRanks(
  Map<String, Set<String>> successors,
  Map<String, Set<String>> predecessors,
  Map<String, int> ranks,
) {
  final ids = successors.keys.toList()..sort();
  final indices = {for (var i = 0; i < ids.length; i++) ids[i]: i};
  final weights = [
    for (final id in ids) predecessors[id]!.length - successors[id]!.length,
  ];
  final capacity =
      1 +
      weights.where((weight) => weight < 0).fold<int>(0, (sum, w) => sum - w);
  while (true) {
    // A minimum cut solves minimum-weight closure. Infinite-capacity tight
    // edges encode implication; finite supply is at most the number of edges.
    final source = ids.length;
    final sink = source + 1;
    final residual = [for (var i = 0; i <= sink; i++) <int, int>{}];
    void edge(int from, int to, int value) {
      residual[from][to] = (residual[from][to] ?? 0) + value;
      residual[to].putIfAbsent(from, () => 0);
    }

    for (var i = 0; i < ids.length; i++) {
      final weight = weights[i];
      if (weight < 0) edge(source, i, -weight);
      if (weight > 0) edge(i, sink, weight);
      final children = successors[ids[i]]!.toList()..sort();
      for (final child in children) {
        if (ranks[child] == ranks[ids[i]]! + 1) {
          edge(i, indices[child]!, capacity);
        }
      }
    }
    List<int> reachable() {
      final previous = List<int>.filled(residual.length, -1);
      previous[source] = source;
      final queue = Queue<int>.of([source]);
      while (queue.isNotEmpty) {
        final from = queue.removeFirst();
        for (final entry in residual[from].entries) {
          if (entry.value <= 0 || previous[entry.key] != -1) continue;
          previous[entry.key] = from;
          queue.add(entry.key);
        }
      }
      return previous;
    }

    var previous = reachable();
    while (previous[sink] != -1) {
      var amount = capacity;
      for (var to = sink; to != source; to = previous[to]) {
        amount = math.min(amount, residual[previous[to]][to]!);
      }
      for (var to = sink; to != source; to = previous[to]) {
        final from = previous[to];
        residual[from][to] = residual[from][to]! - amount;
        residual[to][from] = residual[to][from]! + amount;
      }
      previous = reachable();
    }
    // The residual source side is the inclusion-minimal minimum cut: it does
    // not drag along unrelated zero-cost branches or disconnected families.
    final moving = {
      for (var i = 0; i < ids.length; i++)
        if (previous[i] != -1) ids[i],
    };
    final change = moving.fold(0, (sum, id) => sum + weights[indices[id]!]);
    if (change >= 0) break;
    final distance = [
      for (final id in moving)
        for (final child in successors[id]!)
          if (!moving.contains(child)) ranks[child]! - ranks[id]! - 1,
    ].reduce(math.min);
    for (final id in moving) {
      ranks[id] = ranks[id]! + distance;
    }
    // Every move strictly decreases nonnegative integer slack. No permutation
    // search, ancestry-path enumeration, or zero-cost iteration is involved.
  }
  // Translation is immaterial to slack. Normalize each weak component locally,
  // never to the height of another tree or a global deepest terminal.
  final remaining = ids.toSet();
  while (remaining.isNotEmpty) {
    final members = <String>[];
    final queue = Queue<String>.of([remaining.first]);
    remaining.remove(queue.first);
    while (queue.isNotEmpty) {
      final id = queue.removeFirst();
      members.add(id);
      for (final next in [...successors[id]!, ...predecessors[id]!]) {
        if (remaining.remove(next)) queue.add(next);
      }
    }
    final minimum = members.map((id) => ranks[id]!).reduce(math.min);
    for (final id in members) {
      ranks[id] = ranks[id]! - minimum;
    }
  }
}

/// For every same-rank pair, consult its first common descendant rank, not a
/// common ancestor above it or the current focus. Bits describe the parental
/// role at that descendant, regardless of the ancestor's sex or intermediate
/// roles. Each bit visits each ancestor once; no ancestry paths are enumerated.
Map<int, List<(String, String)>> _descendantRolePreferences(
  List<String> ids,
  Map<String, TreePerson> people,
  Map<String, List<String>> parents,
  Map<String, int> ranks,
) {
  final descendants = ids.toList()
    ..sort((a, b) {
      final rank = ranks[a]!.compareTo(ranks[b]!);
      return rank != 0 ? rank : a.compareTo(b);
    });
  final nearest = <(String, String), int>{};
  final directions = <(String, String), int>{};
  for (final descendant in descendants) {
    final person = people[descendant]!;
    final masks = <String, int>{};
    final queue = Queue<(String, int)>.of([
      if (person.motherId case final mother?) (mother, 1),
      if (person.fatherId case final father?) (father, 2),
    ]);
    while (queue.isNotEmpty) {
      final (id, bit) = queue.removeFirst();
      final previous = masks[id] ?? 0;
      if ((previous | bit) == previous) continue;
      masks[id] = previous | bit;
      for (final parent in parents[id]!) {
        queue.add((parent, bit));
      }
    }
    final byRank = <int, List<String>>{};
    for (final id in masks.keys) {
      (byRank[ranks[id]!] ??= []).add(id);
    }
    for (final ancestors in byRank.values) {
      ancestors.sort();
      for (var i = 0; i < ancestors.length; i++) {
        for (var j = i + 1; j < ancestors.length; j++) {
          final a = ancestors[i];
          final b = ancestors[j];
          final pair = (a, b);
          final rank = ranks[descendant]!;
          // Mark even ambiguous/same-side pairs: a lower descendant cannot
          // invent a side when their nearest common descendant supplies none.
          if ((nearest[pair] ?? rank) < rank) continue;
          nearest[pair] = rank;
          final direction = (masks[a], masks[b]) == (1, 2)
              ? 1
              : (masks[a], masks[b]) == (2, 1)
              ? 2
              : 0;
          directions[pair] = (directions[pair] ?? 0) | direction;
        }
      }
    }
  }
  final direct = <(String, String), int>{};
  for (final person in people.values) {
    final mother = person.motherId;
    final father = person.fatherId;
    if (mother == null ||
        father == null ||
        mother == father ||
        ranks[mother] != ranks[father]) {
      continue;
    }
    final pair = mother.compareTo(father) < 0
        ? (mother, father)
        : (father, mother);
    direct[pair] = (direct[pair] ?? 0) | (pair.$1 == mother ? 1 : 2);
  }
  final result = <int, List<(String, String)>>{};
  void add((String, String) pair, int? direction) {
    if (direction != 1 && direction != 2) return;
    (result[ranks[pair.$1]!] ??= []).add(
      direction == 1 ? pair : (pair.$2, pair.$1),
    );
  }

  final directPairs = direct.keys.toList()
    ..sort((a, b) {
      final first = a.$1.compareTo(b.$1);
      return first != 0 ? first : a.$2.compareTo(b.$2);
    });
  for (final pair in directPairs) {
    add(pair, direct[pair]);
  }
  final pairs = nearest.keys.toList()
    ..sort((a, b) {
      final depth = nearest[a]!.compareTo(nearest[b]!);
      if (depth != 0) return depth;
      final first = a.$1.compareTo(b.$1);
      return first != 0 ? first : a.$2.compareTo(b.$2);
    });
  for (final pair in pairs) {
    // Direct roles also apply when an earlier common descendant only supplies
    // same-side/ambiguous ancestry. Reversed direct roles cancel each other.
    if (direct.containsKey(pair)) continue;
    // Opposed descendants at the same nearest rank cancel rather than picking
    // an arbitrary child or assigning a both-mask ancestor to either side.
    add(pair, directions[pair]);
  }
  return result;
}

/// A row's accepted block-level structural inequalities. Roles never constrain
/// members of the same full-sibling block: their chronology wins unless an actual
/// ancestral parent seam is exposed in BOTH mode. Contradictory block edges are
/// skipped in canonical priority order; later repairs preserve the acyclic set.
class _RoleOrder {
  _RoleOrder(List<_SiblingDraft> blocks, List<(String, String)> preferences) {
    final blockOf = {
      for (final block in blocks)
        for (final person in block.people) person.id: block.id,
    };
    for (final (left, right) in preferences) {
      final a = blockOf[left]!;
      final b = blockOf[right]!;
      if (a == b) continue;
      blocksBefore.putIfAbsent(a, () => {});
      blocksBefore.putIfAbsent(b, () => {});
      if (_reachable(b, blocksBefore).contains(a)) continue;
      blocksBefore[a]!.add(b);
      pairs.add((left, right));
    }
  }

  final pairs = <(String, String)>[];
  final blocksBefore = <String, Set<String>>{};

  List<_SiblingDraft> order(List<_SiblingDraft> blocks) =>
      _stableRoleOrder(blocks, (b) => b.id, blocksBefore);

  bool allows(Map<String, int> indices) =>
      pairs.every((pair) => indices[pair.$1]! < indices[pair.$2]!);
}

/// Stable topological sorting only permutes constrained block slots. Unrelated
/// context keeps its slot and the canonical backbone remains the tie-break.
List<T> _stableRoleOrder<T>(
  List<T> items,
  String Function(T) idOf,
  Map<String, Set<String>> edges,
) {
  final slots = [
    for (var i = 0; i < items.length; i++)
      if (edges.containsKey(idOf(items[i]))) i,
  ];
  final pending = {for (final id in edges.keys) id: 0};
  for (final next in edges.values) {
    for (final id in next) {
      pending[id] = pending[id]! + 1;
    }
  }
  final remaining = slots.toList();
  final result = items.toList();
  for (final slot in slots) {
    final index = remaining.firstWhere((i) => pending[idOf(items[i])] == 0);
    remaining.remove(index);
    result[slot] = items[index];
    for (final next in edges[idOf(items[index])]!) {
      pending[next] = pending[next]! - 1;
    }
  }
  return result;
}

TreeBranch _branch(int mask) => switch (mask) {
  1 => TreeBranch.maternal,
  2 => TreeBranch.paternal,
  3 => TreeBranch.both,
  _ => TreeBranch.neutral,
};

Set<String> _reachable(String start, Map<String, Iterable<String>> edges) {
  final visited = <String>{start};
  final queue = Queue<String>.of([start]);
  while (queue.isNotEmpty) {
    for (final next in edges[queue.removeFirst()]!) {
      if (visited.add(next)) queue.add(next);
    }
  }
  return visited;
}

Map<String, int> _contextBranches(
  String selectedId,
  Map<String, int> ancestry,
  Map<String, List<String>> parents,
  Map<String, List<String>> children,
) {
  final masks = <String, int>{...ancestry, selectedId: 0};
  final distances = <String, int>{for (final id in masks.keys) id: 0};
  final seeds = masks.keys.toList()..sort();
  final queue = Queue<String>.of(seeds);
  while (queue.isNotEmpty) {
    final id = queue.removeFirst();
    final distance = distances[id]! + 1;
    for (final next in [...parents[id]!, ...children[id]!]) {
      final previousDistance = distances[next];
      if (previousDistance == null || distance < previousDistance) {
        distances[next] = distance;
        masks[next] = masks[id]!;
        queue.add(next);
      } else if (previousDistance == distance) {
        final combined = masks[next]! | masks[id]!;
        if (combined != masks[next]) {
          masks[next] = combined;
          queue.add(next);
        }
      }
    }
  }
  return masks;
}

/// For ambiguous lower-row context, follow blood relatives on the selected row,
/// not spouses or unrelated neighbors. Their current card side propagates only
/// through child edges outside the selected person's own descendant cohort.
/// Explicit rootless siblings are blood relatives, never parent/ancestry shortcuts.
/// Shared descendants accumulate both side bits rather than choosing a relative.
Map<String, int> _descendantContextSides(
  List<_SiblingDraft> selectedBlocks,
  String selectedId,
  Iterable<String> ancestors,
  Set<String> descendants,
  Map<String, List<String>> children,
  Map<String, String> siblingGroupIds,
  Map<String, List<String>> siblingMembers,
) {
  final relatives = <String>{selectedId, ...ancestors};
  final pending = Queue<String>.of(relatives);
  while (pending.isNotEmpty) {
    final id = pending.removeFirst();
    for (final relative in [
      ...children[id]!,
      ...siblingMembers[siblingGroupIds[id]]!,
    ]) {
      if (relatives.add(relative)) pending.add(relative);
    }
  }
  final row = [for (final block in selectedBlocks) ...block.people];
  final selected = row.indexWhere((person) => person.id == selectedId);
  final sides = <String, int>{};
  final queue = Queue<(String, int)>();
  for (var i = 0; i < row.length; i++) {
    final id = row[i].id;
    if (i == selected || !relatives.contains(id)) continue;
    queue.add((id, i < selected ? 1 : 2));
  }
  while (queue.isNotEmpty) {
    final (id, bit) = queue.removeFirst();
    if (descendants.contains(id)) continue;
    final previous = sides[id] ?? 0;
    if ((previous | bit) == previous) continue;
    sides[id] = previous | bit;
    for (final child in children[id]!) {
      queue.add((child, bit));
    }
  }
  return sides;
}

class _SiblingDraft {
  _SiblingDraft(this.id, this.fatherId, this.motherId);

  final String id;
  final String? fatherId;
  final String? motherId;
  final people = <TreePerson>[];
  late int level;
  late bool trunk;
  late TreeEmphasis emphasis;
  late int mask;
  late int ancestorMask;
  late double start;
}

int _compareBlocks(_SiblingDraft a, _SiblingDraft b) {
  final birth = compareTreePeopleByBirth(a.people.first, b.people.first);
  return birth != 0 ? birth : a.id.compareTo(b.id);
}

String? _priorityParent(
  _SiblingDraft block,
  Map<String, TreePerson> people,
  TreeTrunkMode mode,
) {
  final father = block.fatherId;
  final mother = block.motherId;
  if (father == null) return mother;
  if (mother == null) return father;
  return switch (mode) {
    TreeTrunkMode.father => father,
    TreeTrunkMode.mother => mother,
    TreeTrunkMode.both =>
      compareTreePeopleByBirth(people[father]!, people[mother]!) <= 0
          ? father
          : mother,
  };
}

/// Establish the mode-specific family backbone, then enforce structural role
/// inequalities before focus refinements. Rigid full-sibling blocks survive;
/// priority-parent groups and partner proximity yield when their sides conflict.
List<_SiblingDraft> _orderedBlocks(
  List<_SiblingDraft> blocks,
  Map<String, TreePerson> people,
  TreeTrunkMode mode,
  List<(String, String)> parentPairs,
  String selectedId,
  List<(String, String)> preferences,
) {
  blocks.sort(_compareBlocks);
  final grouped = <(bool, String), List<_SiblingDraft>>{};
  for (final block in blocks) {
    final parent = _priorityParent(block, people, mode);
    final key = parent == null ? (false, block.id) : (true, parent);
    (grouped[key] ??= []).add(block);
  }
  final families = grouped.values.toList()
    ..sort((a, b) => _compareBlocks(a.first, b.first));
  final familyOf = <String, int>{
    for (var i = 0; i < families.length; i++)
      for (final block in families[i])
        for (final person in block.people) person.id: i,
  };
  final couples = <(String, String)>{};
  final neighbors = <int, Set<int>>{
    for (var i = 0; i < families.length; i++) i: {},
  };
  for (final person in people.values) {
    final mother = person.motherId;
    final father = person.fatherId;
    final a = familyOf[mother];
    final b = familyOf[father];
    // Cross-generation unions keep their genuine long edges, not an artificial
    // horizontal constraint between different generations.
    if (a == null || b == null) continue;
    couples.add((mother!, father!));
    if (a == b) continue;
    neighbors[a]!.add(b);
    neighbors[b]!.add(a);
  }
  final remaining = neighbors.keys.toSet();
  final components = <List<_SiblingDraft>>[];
  while (remaining.isNotEmpty) {
    final members = <int>[];
    final queue = Queue<int>.of([remaining.first]);
    remaining.remove(queue.first);
    while (queue.isNotEmpty) {
      final current = queue.removeFirst();
      members.add(current);
      for (final neighbor in neighbors[current]!) {
        if (remaining.remove(neighbor)) queue.add(neighbor);
      }
    }
    members.sort();
    final ordered = _orderPartners(members, families, couples, familyOf);
    final component = [for (final member in ordered) ...families[member]];
    components.add(
      mode == TreeTrunkMode.both
          ? _canonicalParentBoundary(component, couples)
          : component,
    );
  }
  final canonical = [for (final component in components) ...component];
  final roles = _RoleOrder(canonical, preferences);
  final sided = roles.order(canonical);
  if (mode != TreeTrunkMode.both) return sided;
  // A side repair can move the shared mother block past her canonical father
  // slot. Restore that focus-independent slot when the role inequalities allow
  // it, so half-sibling selections still exchange only their fathers' slots.
  final boundary = _canonicalParentBoundary(sided, couples);
  final normalized = roles.allows(_personIndices(boundary)) ? boundary : sided;
  final adjacent = _orderParentPairs(normalized, parentPairs, roles);
  final focused = _orderSelectedPartners(
    adjacent,
    selectedId,
    couples,
    parentPairs,
    roles.allows,
  );
  return _orderBranchCorridor(focused, (block) => block.ancestorMask != 0);
}

/// Keep actual ancestor/descendant blocks contiguous in BOTH mode. Only context
/// inside their span moves: exclusive side paths choose the corresponding outside
/// edge; ambiguous/unconnected context takes the nearer edge (left on a tie).
/// Stable partitions preserve cohort order, accepted ancestor seams, every member
/// order, and already-exterior context. Conflicting context role/partner edges yield.
List<_SiblingDraft> _orderBranchCorridor(
  List<_SiblingDraft> blocks,
  bool Function(_SiblingDraft) relevant, {
  int Function(_SiblingDraft)? sideOf,
}) {
  final first = blocks.indexWhere(relevant);
  final last = blocks.lastIndexWhere(relevant);
  if (first < 0 || last <= first) return blocks;
  final left = <_SiblingDraft>[];
  final cohort = <_SiblingDraft>[];
  final right = <_SiblingDraft>[];
  for (var i = first; i <= last; i++) {
    final block = blocks[i];
    if (relevant(block)) {
      cohort.add(block);
    } else {
      final maternal = switch (sideOf?.call(block) ?? block.mask) {
        1 => true,
        2 => false,
        _ => i - first <= last - i,
      };
      (maternal ? left : right).add(block);
    }
  }
  if (left.isEmpty && right.isEmpty) return blocks;
  return [
    ...blocks.take(first),
    ...left,
    ...cohort,
    ...right,
    ...blocks.skip(last + 1),
  ];
}

/// Every known parent contributes a child-block interval, not just the selected
/// branch or the mode's priority parent. Family-only caterpillar components have
/// an exact backbone; overlapping/cyclic or hard-constrained cases use bounded,
/// deterministic repairs while keeping already accepted intervals intact.
List<_SiblingDraft> _orderParentCohorts(
  List<_SiblingDraft> blocks,
  TreeTrunkMode mode,
  List<(String, String)> parentPairs,
  List<(String, String)> preferences, {
  required String selectedId,
  required Set<String> siblingIds,
  required Set<(String, String)> couples,
  required Set<String> descendantIds,
  required Map<String, int> descendantSides,
}) {
  final groups = <String, Set<_SiblingDraft>>{};
  final blockOf = <String, _SiblingDraft>{};
  for (final block in blocks) {
    for (final parent in {block.fatherId, block.motherId}.nonNulls) {
      (groups[parent] ??= {}).add(block);
    }
    for (final person in block.people) {
      blockOf[person.id] = block;
    }
  }
  groups.removeWhere((_, members) => members.length < 2);
  final descendants = blocks
      .where((block) => block.people.any((p) => descendantIds.contains(p.id)))
      .toSet();
  int descendantSide(_SiblingDraft block) {
    if (block.mask == 1 || block.mask == 2) return block.mask;
    return block.people.fold(
      0,
      (mask, person) => mask | (descendantSides[person.id] ?? 0),
    );
  }

  final descendantFirst = blocks.indexWhere(descendants.contains);
  final descendantLast = blocks.lastIndexWhere(descendants.contains);
  final descendantEdges = <_SiblingDraft, int>{
    if (descendants.length > 1)
      for (var i = descendantFirst; i <= descendantLast; i++)
        if (!descendants.contains(blocks[i]))
          blocks[i]: switch (descendantSide(blocks[i])) {
            1 => 1,
            2 => 2,
            _ => i - descendantFirst <= descendantLast - i ? 1 : 2,
          },
  };
  final original = {for (var i = 0; i < blocks.length; i++) blocks[i]: i};
  final indices = _personIndices(blocks);
  final seams = parentPairs
      .where(
        (pair) =>
            indices.containsKey(pair.$1) &&
            indices.containsKey(pair.$2) &&
            indices[pair.$2]! - indices[pair.$1]! == 1,
      )
      .toList();
  final hardSides = preferences
      .where(
        (pair) =>
            blockOf[pair.$1]!.ancestorMask != 0 &&
            blockOf[pair.$2]!.ancestorMask != 0 &&
            indices[pair.$1]! < indices[pair.$2]!,
      )
      .toList();
  final ancestors = blocks.where((block) => block.ancestorMask != 0).toSet();
  final ancestorOrder = blocks.where(ancestors.contains).toList();
  final ancestorFirst = blocks.indexWhere(ancestors.contains);
  final ancestorLast = blocks.lastIndexWhere(ancestors.contains);
  final ancestorLeft = ancestorFirst < 0
      ? <_SiblingDraft>[]
      : blocks.take(ancestorFirst).where((b) => b.mask == 1).toList();
  final ancestorRight = ancestorLast < 0
      ? <_SiblingDraft>[]
      : blocks.skip(ancestorLast + 1).where((b) => b.mask == 2).toList();
  bool contiguous(List<_SiblingDraft> order, Set<_SiblingDraft> members) {
    if (members.length < 2) return true;
    final first = order.indexWhere(members.contains);
    final last = order.lastIndexWhere(members.contains);
    return last - first + 1 == members.length;
  }

  final exactAccepted = <Set<_SiblingDraft>>[];
  bool hardAllows(List<_SiblingDraft> order) {
    if (!exactAccepted.every((group) => contiguous(order, group))) return false;
    if (mode == TreeTrunkMode.both && ancestors.isNotEmpty) {
      if (!contiguous(order, ancestors)) return false;
      final first = order.indexWhere(ancestors.contains);
      for (var i = 0; i < ancestorOrder.length; i++) {
        if (order[first + i] != ancestorOrder[i]) return false;
      }
      if (ancestors.length > 1 &&
          (ancestorLeft.any((b) => order.indexOf(b) >= first) ||
              ancestorRight.any(
                (b) => order.indexOf(b) < first + ancestors.length,
              ))) {
        return false;
      }
    }
    final next = _personIndices(order);
    return seams.every((pair) => next[pair.$2]! - next[pair.$1]! == 1) &&
        hardSides.every((pair) => next[pair.$1]! < next[pair.$2]!);
  }

  List<int> cost(List<_SiblingDraft> order) {
    final next = _personIndices(order);
    final firstDescendant = order.indexWhere(descendants.contains);
    final lastDescendant = order.lastIndexWhere(descendants.contains);
    return [
      descendantEdges.entries
          .where(
            (entry) => entry.value == 1
                ? order.indexOf(entry.key) >= firstDescendant
                : order.indexOf(entry.key) <= lastDescendant,
          )
          .length,
      preferences.where((pair) => next[pair.$1]! >= next[pair.$2]!).length,
      [
        for (var i = 0; i < order.length; i++) (original[order[i]]! - i).abs(),
      ].fold(0, (sum, distance) => sum + distance),
      for (final block in order) original[block]!,
    ];
  }

  bool better(List<_SiblingDraft> a, List<_SiblingDraft> b) {
    final first = cost(a);
    final second = cost(b);
    for (var i = 0; i < first.length; i++) {
      if (first[i] != second[i]) return first[i] < second[i];
    }
    return false;
  }

  var order = blocks;
  for (final variants in _parentCohortBackbones(blocks)) {
    final component = variants.first.toSet();
    final local = groups.values
        .where((group) => component.contains(group.first))
        .toList();
    if (local.every((group) => contiguous(order, group))) {
      exactAccepted.addAll(local);
      continue;
    }
    List<_SiblingDraft>? best;
    final rest = order.where((block) => !component.contains(block)).toList();
    for (final run in variants) {
      for (var slot = 0; slot <= rest.length; slot++) {
        final candidate = rest.toList()..insertAll(slot, run);
        if (hardAllows(candidate) &&
            (best == null || better(candidate, best))) {
          best = candidate;
        }
      }
    }
    if (best != null) {
      order = best;
      exactAccepted.addAll(local);
    }
  }
  final accepted = <Set<_SiblingDraft>>[];
  void attempt(Set<_SiblingDraft> members, {bool descendant = false}) {
    if (members.length < 2) return;
    if (contiguous(order, members)) {
      accepted.add(members);
      return;
    }
    bool allows(List<_SiblingDraft> proposal) =>
        hardAllows(proposal) &&
        accepted.every((group) => contiguous(proposal, group));
    final partition = _orderBranchCorridor(
      order,
      members.contains,
      sideOf: descendant ? descendantSide : null,
    );
    List<_SiblingDraft>? best = allows(partition) ? partition : null;
    // Preserve the existing descendant-side preference when it is compatible
    // with all stronger structural family intervals.
    if (!descendant || best == null) {
      final run = order.where(members.contains).toList();
      final rest = order.where((block) => !members.contains(block)).toList();
      for (var slot = 0; slot <= rest.length; slot++) {
        final candidate = rest.toList()..insertAll(slot, run);
        if (allows(candidate) && (best == null || better(candidate, best))) {
          best = candidate;
        }
      }
    }
    if (best != null) {
      order = best;
      accepted.add(members);
    }
  }

  int rolePriority(String parent) => switch (mode) {
    TreeTrunkMode.father =>
      groups[parent]!.every((b) => b.fatherId == parent) ? 0 : 1,
    TreeTrunkMode.mother =>
      groups[parent]!.every((b) => b.motherId == parent) ? 0 : 1,
    TreeTrunkMode.both => 0,
  };
  final parents = groups.keys.toList()
    ..sort((a, b) {
      final role = rolePriority(a).compareTo(rolePriority(b));
      return role != 0 ? role : a.compareTo(b);
    });
  for (final parent in parents) {
    attempt(groups[parent]!);
  }
  attempt(descendants, descendant: true);
  final incoming = _personIndices(order);
  final roleLocks = _RoleOrder(
    order,
    preferences,
  ).pairs.where((pair) => incoming[pair.$1]! < incoming[pair.$2]!).toList();
  return _orderSelectedPartners(
    order,
    selectedId,
    couples,
    parentPairs,
    (indices) =>
        roleLocks.every((pair) => indices[pair.$1]! < indices[pair.$2]!),
    siblingIds: siblingIds,
    lockedCohorts: [...exactAccepted, ...accepted],
    preservesBlocks: (proposal) =>
        hardAllows(proposal) &&
        accepted.every((group) => contiguous(proposal, group)),
  );
}

/// A block is an edge between its distinct parents; a sole parent gets a private
/// leaf. Parallel parent sets are temporary bundles, never new sibling blocks.
/// All parent stars have a consecutive edge order exactly when a simple component
/// is a caterpillar tree: removing leaves leaves a path (or a single vertex).
List<List<List<_SiblingDraft>>> _parentCohortBackbones(
  List<_SiblingDraft> blocks,
) {
  final edges = <String, Map<String, List<_SiblingDraft>>>{};
  final original = {for (var i = 0; i < blocks.length; i++) blocks[i]: i};
  for (final block in blocks) {
    final parents = {block.fatherId, block.motherId}.nonNulls.toList()..sort();
    if (parents.isEmpty) continue;
    final a = 'parent:${parents.first}';
    final b = parents.length == 1
        ? 'block:${block.id}'
        : 'parent:${parents.last}';
    final bundle = (edges[a] ??= {}).putIfAbsent(b, () => []);
    bundle.add(block);
    (edges[b] ??= {})[a] = bundle;
  }
  final remaining = edges.keys.toSet();
  final result = <List<List<_SiblingDraft>>>[];
  while (remaining.isNotEmpty) {
    final vertices = <String>[];
    final queue = Queue<String>.of([remaining.first]);
    remaining.remove(queue.first);
    while (queue.isNotEmpty) {
      final vertex = queue.removeFirst();
      vertices.add(vertex);
      for (final next in edges[vertex]!.keys) {
        if (remaining.remove(next)) queue.add(next);
      }
    }
    final count = vertices.fold(0, (sum, id) => sum + edges[id]!.length);
    if (count != 2 * (vertices.length - 1)) continue;
    final core = vertices.where((id) => edges[id]!.length > 1).toSet();
    if (core.any((id) => edges[id]!.keys.where(core.contains).length > 2)) {
      continue;
    }
    if (core.isEmpty) {
      result.add([edges[vertices.first]!.values.single.toList()]);
      continue;
    }
    final ends =
        core
            .where((id) => edges[id]!.keys.where(core.contains).length <= 1)
            .toList()
          ..sort();
    final spine = <String>[];
    String? previous;
    var current = ends.first;
    while (true) {
      spine.add(current);
      final next = edges[current]!.keys
          .where((id) => core.contains(id) && id != previous)
          .firstOrNull;
      if (next == null) break;
      previous = current;
      current = next;
    }
    List<_SiblingDraft> walk(Iterable<String> path) {
      final ordered = path.toList();
      final run = <_SiblingDraft>[];
      for (var i = 0; i < ordered.length; i++) {
        final vertex = ordered[i];
        final pendants =
            edges[vertex]!.entries
                .where((e) => !core.contains(e.key))
                .map((e) => e.value)
                .toList()
              ..sort(
                (a, b) => original[a.first]!.compareTo(original[b.first]!),
              );
        for (final bundle in pendants) {
          run.addAll(bundle);
        }
        if (i + 1 < ordered.length) run.addAll(edges[vertex]![ordered[i + 1]]!);
      }
      return run;
    }

    result.add([walk(spine), if (spine.length > 1) walk(spine.reversed)]);
  }
  return result;
}

Map<String, int> _personIndices(List<_SiblingDraft> blocks) {
  var index = 0;
  return {
    for (final block in blocks)
      for (final person in block.people) person.id: index++,
  };
}

/// Direct parents first, then ancestral couples by nearest child depth and ID.
/// Each ancestor and each pair is visited once, including pedigree collapse.
List<(String, String)> _ancestralParentPairs(
  String selectedId,
  Map<String, TreePerson> people,
) {
  final depths = <String, int>{selectedId: 0};
  final queue = Queue<String>.of([selectedId]);
  while (queue.isNotEmpty) {
    final id = queue.removeFirst();
    final person = people[id]!;
    for (final parent in [person.motherId, person.fatherId]) {
      if (parent != null && !depths.containsKey(parent)) {
        depths[parent] = depths[id]! + 1;
        queue.add(parent);
      }
    }
  }
  final ids = depths.keys.toList()
    ..sort((a, b) {
      final depth = depths[a]!.compareTo(depths[b]!);
      return depth != 0 ? depth : a.compareTo(b);
    });
  return <(String, String)>{
    for (final id in ids)
      if (people[id]!.motherId case final mother?)
        if (people[id]!.fatherId case final father?)
          if (mother != father) (mother, father),
  }.toList();
}

/// Give a shared maternal block one focus-independent right-hand partner slot.
/// Normalizing once from canonical parent IDs avoids moving the mother block
/// differently for half siblings. Their selected fathers can then exchange slots.
List<_SiblingDraft> _canonicalParentBoundary(
  List<_SiblingDraft> blocks,
  Set<(String, String)> couples,
) {
  final blockOf = <String, _SiblingDraft>{
    for (final block in blocks)
      for (final person in block.people) person.id: block,
  };
  final pairs =
      couples
          .where(
            (pair) =>
                blockOf.containsKey(pair.$1) &&
                blockOf.containsKey(pair.$2) &&
                blockOf[pair.$1] != blockOf[pair.$2],
          )
          .toList()
        ..sort((a, b) {
          final mother = a.$1.compareTo(b.$1);
          return mother != 0 ? mother : a.$2.compareTo(b.$2);
        });
  final counts = <_SiblingDraft, int>{};
  for (final (mother, _) in pairs) {
    final block = blockOf[mother];
    if (block != null) counts[block] = (counts[block] ?? 0) + 1;
  }
  for (final (mother, father) in pairs) {
    final maternal = blockOf[mother];
    final paternal = blockOf[father];
    if (maternal == null || paternal == null || counts[maternal]! < 2) continue;
    final order = blocks.toList()..remove(paternal);
    order.insert(order.indexOf(maternal) + 1, paternal);
    return order;
  }
  return blocks;
}

/// The only exception to sibling birth/name/ID order: expose actual ancestral couples
/// in BOTH mode. A mother ends her block and a father begins his; same-block
/// parents become an adjacent mother/father pair. Compatible seams use nearest
/// ancestry priority and preserve block-level role sides and earlier seams.
List<_SiblingDraft> _orderParentPairs(
  List<_SiblingDraft> canonical,
  List<(String, String)> pairs,
  _RoleOrder roles,
) {
  final blockOf = <String, _SiblingDraft>{
    for (final block in canonical)
      for (final person in block.people) person.id: block,
  };
  var order = canonical;
  final accepted = <(String, String)>[];
  for (final (mother, father) in pairs) {
    final maternal = blockOf[mother];
    final paternal = blockOf[father];
    // Missing on this row includes genuine cross-generation unions.
    if (maternal == null || paternal == null) continue;
    final saved = {
      for (final block in {maternal, paternal}) block: block.people.toList(),
    };
    final mom = maternal.people.firstWhere((person) => person.id == mother);
    final dad = paternal.people.firstWhere((person) => person.id == father);
    var candidate = order;
    if (maternal == paternal) {
      final first = math.min(
        maternal.people.indexOf(mom),
        maternal.people.indexOf(dad),
      );
      maternal.people
        ..remove(mom)
        ..remove(dad)
        ..insertAll(first, [mom, dad]);
    } else {
      maternal.people
        ..remove(mom)
        ..add(mom);
      paternal.people
        ..remove(dad)
        ..insert(0, dad);
      final a = order.indexOf(maternal);
      final b = order.indexOf(paternal);
      if (b != a + 1) {
        candidate = order.toList();
        if (a + 1 < order.length) {
          candidate[b] = order[a + 1];
          candidate[a + 1] = paternal;
        } else {
          // A final mother block needs a right-hand slot before swapping is
          // possible. Keep all non-parent blocks in their relative order.
          candidate.remove(paternal);
          candidate.insert(candidate.indexOf(maternal) + 1, paternal);
        }
      }
    }
    bool compatible(List<_SiblingDraft> proposal) {
      final indices = _personIndices(proposal);
      return roles.allows(indices) &&
          accepted.every((pair) => indices[pair.$2]! - indices[pair.$1]! == 1);
    }

    if (!compatible(candidate) && maternal != paternal) {
      // Prefer the historical father-slot exchange, but an intervening role
      // edge can forbid that swap while still permitting the actual parent seam.
      final moveFather = order.toList()..remove(paternal);
      moveFather.insert(moveFather.indexOf(maternal) + 1, paternal);
      final moveMother = order.toList()..remove(maternal);
      moveMother.insert(moveMother.indexOf(paternal), maternal);
      if (compatible(moveFather)) {
        candidate = moveFather;
      } else if (compatible(moveMother)) {
        candidate = moveMother;
      }
    }
    if (compatible(candidate)) {
      accepted.add((mother, father));
      order = candidate;
    } else {
      for (final entry in saved.entries) {
        entry.key.people
          ..clear()
          ..addAll(entry.value);
      }
    }
  }
  return order;
}

/// Refine partner proximity without changing members or stronger row invariants.
/// Own co-parents take priority over siblings' co-parents in every mode. Only
/// deterministic improving whole-block relocations are considered; the final
/// caller additionally locks structural family/descendant intervals and corridors.
List<_SiblingDraft> _orderSelectedPartners(
  List<_SiblingDraft> blocks,
  String selectedId,
  Set<(String, String)> couples,
  List<(String, String)> parentPairs,
  bool Function(Map<String, int>) allowsRoles, {
  Set<String> siblingIds = const {},
  Iterable<Set<_SiblingDraft>> lockedCohorts = const [],
  bool Function(List<_SiblingDraft>)? preservesBlocks,
}) {
  final canonical = _personIndices(blocks);
  final localCouples = couples
      .where(
        (pair) =>
            canonical.containsKey(pair.$1) && canonical.containsKey(pair.$2),
      )
      .toList();
  final pairs = localCouples
      .where((pair) => pair.$1 == selectedId || pair.$2 == selectedId)
      .toList();
  final siblingPairs = localCouples
      .where(
        (pair) =>
            pair.$1 != selectedId &&
            pair.$2 != selectedId &&
            (siblingIds.contains(pair.$1) || siblingIds.contains(pair.$2)),
      )
      .toList();
  if (pairs.isEmpty && siblingPairs.isEmpty) return blocks;
  final focus = <String>{
    for (final pair in [...pairs, ...siblingPairs]) ...[pair.$1, pair.$2],
  };
  final blockOf = {
    for (var i = 0; i < blocks.length; i++)
      for (final person in blocks[i].people) person.id: i,
  };
  final focusedBlocks = {for (final id in focus) blockOf[id]!};
  final ownBlocks = {
    for (final pair in pairs) ...[blockOf[pair.$1]!, blockOf[pair.$2]!],
  };
  final siblingBlocks = {
    for (final pair in siblingPairs) ...[blockOf[pair.$1]!, blockOf[pair.$2]!],
  };
  final cohortMoves = <Set<int>>[
    for (final members in lockedCohorts)
      {
        for (var i = 0; i < blocks.length; i++)
          if (members.contains(blocks[i])) i,
      },
  ].where((members) => members.any(focusedBlocks.contains)).toList();
  final locked = parentPairs.where(
    (pair) =>
        canonical.containsKey(pair.$1) &&
        canonical.containsKey(pair.$2) &&
        canonical[pair.$2]! - canonical[pair.$1]! == 1,
  );
  var order = List<int>.generate(blocks.length, (i) => i);

  List<int>? cost(List<int> order) {
    var index = 0;
    final indices = {
      for (final block in order)
        for (final person in blocks[block].people) person.id: index++,
    };
    if (!allowsRoles(indices) ||
        locked.any((pair) => indices[pair.$2]! - indices[pair.$1]! != 1) ||
        (preservesBlocks != null &&
            !preservesBlocks([for (final block in order) blocks[block]]))) {
      return null;
    }
    int holes(Set<int> members) {
      final slots = [
        for (var i = 0; i < order.length; i++)
          if (members.contains(order[i])) i,
      ];
      return slots.isEmpty ? 0 : slots.last - slots.first + 1 - slots.length;
    }

    var separation = 0;
    var reversed = 0;
    for (final (mother, father) in pairs) {
      separation += (indices[mother]! - indices[father]!).abs() - 1;
      if (indices[mother]! > indices[father]!) reversed++;
    }
    var siblingSeparation = 0;
    var siblingReversed = 0;
    for (final (mother, father) in siblingPairs) {
      siblingSeparation += (indices[mother]! - indices[father]!).abs() - 1;
      if (indices[mother]! > indices[father]!) siblingReversed++;
    }
    var collateral = 0;
    for (final (mother, father) in localCouples) {
      // A sibling's own couple cannot veto focus proximity, but when focus
      // costs tie it must not acquire a gratuitous gap beside the cluster.
      if (focus.contains(mother) || focus.contains(father)) continue;
      collateral += math.max(
        0,
        (indices[mother]! - indices[father]!).abs() -
            (canonical[mother]! - canonical[father]!).abs(),
      );
    }
    return [
      holes(ownBlocks),
      separation,
      reversed,
      siblingSeparation,
      holes(siblingBlocks),
      siblingReversed,
      collateral,
      ...order,
    ];
  }

  bool improves(List<int> candidate, List<int> current) {
    for (var i = 0; i < candidate.length; i++) {
      if (candidate[i] != current[i]) return candidate[i] < current[i];
    }
    return false;
  }

  final initialCost = cost(order)!;
  if (initialCost.take(6).every((value) => value == 0)) return blocks;
  while (true) {
    var bestOrder = order;
    var bestCost = cost(order)!;
    void consider(List<int> candidate) {
      final next = cost(candidate);
      if (next != null && improves(next, bestCost)) {
        bestOrder = candidate;
        bestCost = next;
      }
    }

    for (final block in focusedBlocks) {
      final rest = order.toList()..remove(block);
      for (var slot = 0; slot <= rest.length; slot++) {
        consider(rest.toList()..insert(slot, block));
      }
    }
    // Move the current focused run as one unit to keep a sibling's independent
    // couple at its outside boundary, without first opening a worse focus gap.
    for (final members in [
      ownBlocks,
      siblingBlocks,
      focusedBlocks,
      ...cohortMoves,
    ]) {
      if (members.isEmpty) continue;
      final cluster = order.where(members.contains).toList();
      final rest = order.where((block) => !members.contains(block)).toList();
      for (var slot = 0; slot <= rest.length; slot++) {
        consider(rest.toList()..insertAll(slot, cluster));
      }
    }
    if (identical(bestOrder, order)) break;
    order = bestOrder;
  }
  return [for (final block in order) blocks[block]];
}

/// Use structural adjacency, not child IDs or selection priority. The cost is
/// the number of people separating real co-parents, then canonical maternal-
/// before-paternal orientation, then the birth/name/ID backbone. Whole role groups
/// move together: chronology and full-sibling indivisibility are never traded
/// for a shorter edge. Deterministic insertion plus improving relocations also
/// handles spouse chains without enumerating their permutations.
List<int> _orderPartners(
  List<int> members,
  List<List<_SiblingDraft>> families,
  Set<(String, String)> couples,
  Map<String, int> familyOf,
) {
  if (members.length < 2) return members;
  final relevant = couples
      .where((pair) => members.contains(familyOf[pair.$1]))
      .toList();
  final lengths = <int, int>{};
  final offsets = <String, int>{};
  for (final member in members) {
    var offset = 0;
    for (final block in families[member]) {
      for (final person in block.people) {
        offsets[person.id] = offset++;
      }
    }
    lengths[member] = offset;
  }
  (int, int) cost(List<int> order) {
    final starts = <int, int>{};
    var offset = 0;
    for (final member in order) {
      starts[member] = offset;
      offset += lengths[member]!;
    }
    var separation = 0;
    var reversed = 0;
    for (final (mother, father) in relevant) {
      final a = starts[familyOf[mother]];
      final b = starts[familyOf[father]];
      if (a == null || b == null) continue;
      final first = a + offsets[mother]!;
      final second = b + offsets[father]!;
      separation += (first - second).abs() - 1;
      if (first > second) reversed++;
    }
    return (separation, reversed);
  }

  int compare(List<int> a, List<int> b) {
    final first = cost(a);
    final second = cost(b);
    final separation = first.$1.compareTo(second.$1);
    if (separation != 0) return separation;
    final orientation = first.$2.compareTo(second.$2);
    if (orientation != 0) return orientation;
    for (var i = 0; i < a.length; i++) {
      final tie = a[i].compareTo(b[i]);
      if (tie != 0) return tie;
    }
    return 0;
  }

  var order = <int>[];
  for (final member in members) {
    List<int>? best;
    for (var i = 0; i <= order.length; i++) {
      final candidate = order.toList()..insert(i, member);
      if (best == null || compare(candidate, best) < 0) best = candidate;
    }
    order = best!;
  }
  // A late spouse can reveal a better endpoint for an earlier family. Accept
  // only strictly improving costs/ties, so this has no history or random seed.
  while (true) {
    var best = order;
    for (var from = 0; from < order.length; from++) {
      final rest = order.toList()..removeAt(from);
      for (var to = 0; to <= rest.length; to++) {
        final candidate = rest.toList()..insert(to, order[from]);
        if (compare(candidate, best) < 0) best = candidate;
      }
    }
    if (identical(best, order)) return order;
    order = best;
  }
}

/// Pack a canonical row once and translate to its focus or ancestry seam.
/// Never rebalance context around the shorter side of the new focus: that would
/// turn a one-node sibling selection into an unnecessary permutation of a row.
class _GenerationPacking {
  _GenerationPacking(this.nodeExtent, this.gap);

  final double nodeExtent;
  final double gap;
  double minCross = 0;
  double maxCross = 0;

  double extent(_SiblingDraft block) =>
      block.people.length * nodeExtent + (block.people.length - 1) * gap;

  void place(
    List<_SiblingDraft> blocks,
    String? centerId,
    Map<String, int> ancestry,
    TreeTrunkMode mode,
    (String, String)? selectedParents,
  ) {
    var end = 0.0;
    double? center;
    double? selectedMother;
    double? selectedFather;
    double? sharedCenter;
    TreePerson? sharedPerson;
    double? maternalStart;
    double? maternalEnd;
    double? paternalStart;
    double? paternalEnd;
    for (final block in blocks) {
      block.start = end;
      for (var i = 0; i < block.people.length; i++) {
        final id = block.people[i].id;
        final cross = end + nodeExtent / 2 + i * (nodeExtent + gap);
        if (id == centerId) center = cross;
        if (id == selectedParents?.$1) selectedMother = cross;
        if (id == selectedParents?.$2) selectedFather = cross;
        if (block.ancestorMask == 3 && ancestry.containsKey(id)) {
          final person = block.people[i];
          if (sharedPerson == null ||
              compareTreePeopleByBirth(person, sharedPerson) < 0) {
            sharedPerson = person;
            sharedCenter = cross;
          }
        }
      }
      if (block.ancestorMask == 1) maternalStart ??= end;
      if (block.ancestorMask == 2) paternalStart ??= end;
      end += extent(block);
      if (block.ancestorMask == 1) maternalEnd = end;
      if (block.ancestorMask == 2) paternalEnd = end;
      end += 2 * gap;
    }
    end -= 2 * gap;
    if (mode == TreeTrunkMode.both &&
        selectedMother != null &&
        selectedFather != null) {
      center ??= (selectedMother + selectedFather) / 2;
    }
    center ??= mode == TreeTrunkMode.both ? sharedCenter : null;
    if (center == null && mode == TreeTrunkMode.both) {
      if (maternalEnd != null && paternalStart != null) {
        if (maternalEnd <= paternalStart) {
          center = (maternalEnd + paternalStart) / 2;
        } else if (paternalEnd! <= maternalStart!) {
          // A rigid partner union can require the reverse orientation. Keep
          // its empty seam central instead of centering inside a sibling block.
          center = (paternalEnd + maternalStart) / 2;
        } else {
          center =
              (maternalStart + maternalEnd + paternalStart + paternalEnd) / 4;
        }
      } else if (maternalEnd != null) {
        center = maternalEnd + gap;
      } else if (paternalStart != null) {
        center = paternalStart - gap;
      }
    }
    center ??= nodeExtent / 2;
    for (final block in blocks) {
      block.start -= center;
    }
    // Keep the origin in the scrollable band even for a one-sided trunk.
    minCross = math.min(0, -center);
    maxCross = math.max(0, end - center);
  }
}
