# Tree layout

[tree_layout.dart](../../lib/tree/tree_layout.dart) computes a deterministic, Flutter-independent ranked
layout from the current [tree model](tree-model.md). It arranges every person once, including distant
and disconnected context. Selection and trunk mode change focus and ancestry presentation, not the genealogy.

Related: [UI](ui.md), [history and storage](history-and-storage.md),
[rooms and identity](rooms-and-identity.md).

## Input and output contract

`TreeLayout.build` takes a `TreeDocument`, an existing `selectedId`, a `TreeTrunkMode` (`father`, `mother`,
`both`), `nodeExtent` (default 96), and `gap` (default 24). The current UI supplies a 108 px node extent.
Node extent must be finite and positive; gap must be finite and nonnegative. The optional
`previousLayout` parameter remains accepted for API compatibility but is **never consulted**.
The same current document, selection, mode, and metrics produce the same complete output regardless
of prior selections, prior layouts, document insertion order, or screen orientation.

The builder performs no Flutter measurement, scrolling, persistence, or I/O. Output collections are immutable:

| Output | Meaning |
| --- | --- |
| `levels` / `TreeGeneration` | Absolute rank, sibling blocks in cross-coordinate order, `minCross` and `maxCross`. |
| `TreeSiblingBlock` | Indivisible ordered people, father/mother IDs, signed start and extent, trunk/emphasis/branch metadata. |
| `positions` / `TreeNodePosition` | One entry per person: block ID, rank, signed `crossCenter`, and individual metadata. |
| `trunkIds` | Selected person plus ancestors belonging to the chosen immediate parental branch(es). |
| `links` / `TreeLink` | Actual parent/child IDs and the child's block ID, not routed screen geometry. |

Coordinates use a **generation axis** (integer rank) and a **cross axis** (signed logical distance around
zero). They are not fixed screen `x`/`y`. `TreeGeneration.crossExtent` is `maxCross - minCross`; viewport
padding, pixel rectangles, and the transformation from these coordinates belong to the [UI](ui.md).

## Absolute generation ranks

The builder sorts person IDs, builds parent/child adjacency, and deduplicates identical parent IDs
within one person's references. It rejects missing parents and defensively checks for directed cycles.
The document normally prevents these through its [acyclic projection](tree-model.md#parent-graph-and-actor-bindings).

Model-projected sibling groups first form rigid generation components: computed full siblings and
active explicit sibling components with incomplete parents. The model guarantees coherent accepted
father/mother roles and an acyclic ancestry quotient for every group; layout does not repair sibling
claims or reinterpret them as parents. Partner pairs combine actual co-parents with the endpoints of
all projected `TreeDocument.marriages`, including childless and completed historical marriages. Multiple
episodes of one pair count once. Pairs are deduplicated and sorted by canonical person IDs, then merge
their current components only when neither component can reach the other in the quotient parent DAG.
A merge that would collapse ancestry or create a directed cycle is skipped. Marriage is a soft rank-equality
request, never a parent edge, ancestry shortcut, sibling claim, or sex/parent-role constraint.
Kahn's topological traversal first computes each component's earliest feasible rank from its longest
parent path. The resulting quotient DAG then minimizes **total edge slack**:
`sum(rank(child) - rank(parent) - 1)` over distinct quotient edges, subject to every real parent edge
strictly descending and the already established sibling/partner equalities. Duplicate full-sibling
links do not weight one cohort more heavily. No source or terminal is frozen at its first feasible rank.

The compactor uses iterative minimum-weight closure, solved by an integer residual minimum cut. Raising
a set of cohorts changes total slack by the sum of their `indegree - outdegree`; a tight outgoing edge
requires raising its child as well. The best improving closed set moves together until another outgoing
edge becomes tight. This moves free parents **and their shallow collateral children** toward a deeper
co-parent cohort instead of letting a new terminal pull those parents back to the top. Residual source
reachability selects the inclusion-minimal optimal closure, with canonical ID traversal and no zero-cost
moves. Every accepted move strictly reduces nonnegative integer slack; no recursion, permutations, or
ancestry paths are involved. Each weak component is finally translated to its own minimum rank zero,
never to the height of an unrelated tree or a document-wide deepest leaf.

If all quotient edges can span exactly one generation, this objective achieves zero slack on all of them.
Incompatible ancestry can force long links; minimizing the sum is not a promise that every particular
edge is shortest in every conflicting graph. Equal-cost alternatives retain the deterministic earliest-
rank/strict-improvement solution rather than a separate leaf-depth or selection preference. For `V`
quotient cohorts, `E` edges and initial integer slack `S <= E*(V-1)`, at most `S` improving iterations
occur; each uses an iterative Edmonds–Karp cut (`O(V*E^2)` worst case), with `O(V+E)` working space.
Capacities are bounded by `E+1`, not unbounded numeric sentinels.

This keeps ordinary co-parents on the same level when adding ancestry to either partner. For example,
adding a father to Lydia moves both Lydia and Gennady below that ancestor instead of leaving Gennady
in the ancestor's generation. If Natalia and Oleg share Olga, Natalia's deeper pedigree aligns Oleg
with Natalia; Oleg's newly created, undated parents then sit together immediately above Oleg rather
than remaining at rank zero. Adding their one-parent child Shrek keeps both free parents there and
places Shrek alongside Oleg; subsequently supplying Shrek's second parent, adding more shallow children,
or adding a child below Shrek does not re-anchor that cohort. Full siblings remain on one rank even when
a sibling's partner has a deeper pedigree. The algorithm aligns a deterministic maximal compatible set of couples, not
necessarily the maximum-size set: genuinely conflicting intergeneration unions retain long edges.

Ranks depend on graph structure, **not** selection, dates, insertion order, or trunk mode. All actual
parent edges survive, including those skipping bands. Shared ancestors and cousin unions do not
create duplicate nodes or imply a directed cycle.

## Ancestry, branch, and emphasis

An ancestry traversal starts with bit 1 at the selected person's mother and bit 2 at their father,
propagating each bit through both parents of every ancestor. Each bit visits a person at most once;
a shared ancestor receives mask 3 rather than expanding into all possible ancestry paths.

- `father` trunk includes the selection and **all ancestry of its father**, not just an all-father line.
- `mother` does the analogous traversal from its mother; `both` includes both immediate-parent branches.
- A shared ancestor is one person with `TreeBranch.both`. Branch membership is separate from trunk mode:
  the unchosen parental branch still exists, and its ancestors retain normal emphasis.

Context branch masks spread from the selection (neutral mask) and all ancestors via a multi-source
shortest-path traversal over undirected parent/child adjacency. The nearest seeds determine a person's
mask; equal-distance seeds combine masks. Unreached people are neutral. Block masks combine their
members' masks, so a block's branch can differ from an individual member's branch.

`TreeEmphasis` is contextual, not an edit permission or a genealogical completeness judgment:

- `normal`: selection, all ancestors, all descendants, and anyone sharing a known parent or the model's
  sibling group with selection (including explicit parentless siblings and half siblings).
- `cousin`: full/half siblings of every direct ancestor (aunts/uncles and their equivalents at higher
  ancestral generations), children of the selected person's immediate aunts/uncles, nephews/nieces
  (children of full or half siblings), and partners of either direct parent other than the selected
  person's actual parents (stepparents). Both co-parent and explicit-marriage pairs qualify, including
  childless marriages; hiding an implied co-parent marriage does not remove that relationship.
  Actual ancestors and other normal membership take precedence. A stepparent's own ancestors,
  siblings, or other partners do not gain emphasis through this exception.
- `distant`: everyone else, including cousins' children, further collateral descendants without another
  qualifying relationship, and unrelated people. Missing parents alone never establish sibling relationships;
  an explicit sibling component can establish them without inventing an unknown parent.

A block takes its most prominent member's blood-relative emphasis. Stepparent-only cousin styling
applies to the individual card, not the block: an otherwise unrelated block stays `distant`/grey.
Normal membership or a genuine cousin-style relative in the same block still promotes that block.
These labels do not remove nodes or links from layout output; the [UI](ui.md) decides how strongly to draw context and which connections to paint.
The UI also gives the selected person's partners normal color on their individual cards only, using
`TreeDocument.partnersOf`: both co-parents and explicit marriage partners, of any sex. This keeps the existing
full-color photo, name, and avatar treatment; it does not change model emphasis, sibling-block wash, palette,
or legend. The layout uses the same combined pairs for proximity in **every mode**: the selected person's
partners first, then their full/half/explicit siblings' partners. This ordering preference does not promote
sibling partners' color or emphasis. Removing a childless marriage removes its equality/proximity and
card-color exception; detached people remain present as ordinary neutral context. Removing a marriage
from co-parents' history (`noMarriage`) does not remove the existing shared-child partner policy.

A previously disconnected childless spouse therefore joins the selected partner's feasible generation
and neighboring whole-block cluster without becoming a descendant, blood relative, or trunk ancestor.
Actual ancestry and stricter structural invariants still win when equality or literal adjacency is
impossible. Marriage endpoints do not enter branch-mask propagation or blood-relative connection filtering.

## Sibling blocks and canonical family backbone

The builder reads the model's immutable `siblingGroupIds` snapshot once. It contains every visible
person ID and is the sole sibling-block identity source:

- With both parents known, the normal computed group is the ordered father/mother pair, retaining the
  existing `treeSurnameFamilyKey` identity. Swapped roles and half siblings remain separate blocks.
- While a parent is missing, an active explicit sibling component has a `siblings:…` identity based on its
  canonical member ID. Its direct links are transitive grouping claims, not ancestry edges. All projected
  members have the same accepted known/missing parent roles.
- Missing parents without an explicit component never group people. Unlinking a direct claim may split
  that component while retaining known parents, leaving separate half-sibling blocks. Filling the second
  parent retires the direct claims in the model and returns to normal computed full-sibling blocks.

The layout consumes this projection without writing, copying parents, retiring claims, or creating
sibling curves. Actual links remain parent→child only. Block identity is no longer synonymous with the
[historical family-surname fallback](tree-model.md#canonical-surnames): that legacy key and individual
surname inheritance are unchanged. A surname edit never merges/splits a block or copies a surname.

Computed and explicit sibling groups share a rank and retain one contiguous block/background. Their strict
canonical order uses the model's shared `compareTreePeopleByBirth`: **unknown birth dates are considered
older and come first**, then known dates ascend by calendar year/month/day. Missing or equal dates
compare the trimmed given name, case-insensitively with `ё` treated as `е`, then person ID as the final
strict tie-break. Combined `fullName`, rendered surnames, sex, and insertion order do not supply ordering ties.
This member order is preserved in every mode except to expose an **actual mother→father card seam in
`both` mode** for the selected person's parents or an ancestral couple at any depth. Structural roles,
including opposite branches of a common descendant or sibling co-parents in single modes, never reorder
members. Selected/co-parent proximity also moves only whole blocks. None of these presentation changes
alter the document, block identity, membership, dimensions, or surname configurations.

Each rank establishes a structural backbone before considering focus:

1. Blocks compare by their first member's birth ordering, then block ID.
2. Blocks sharing one **priority parent** form chronological role groups. In `father`/`mother` mode the
   priority parent is the corresponding known parent, falling back to the other. In `both` mode it is
   the older parent by that same unknown-date-first/date/name/ID comparator. Parentless blocks retain
   individual groups. Selecting a member no longer exempts its block from this grouping.
3. Co-parent and explicit marriage pairs join these groups into contiguous partner components on that rank.
   Cross-generation unions do not introduce a horizontal constraint across different ranks.
4. Within each component, deterministic insertion and improving whole-group relocations minimize
   the number of people separating partners. Only actual co-parents contribute maternal-before-paternal
   orientation ties; childless marriages have no directional preference. Remaining ties use
   the canonical birth/name/ID order. No random seed, previous geometry, child ID, graph distance from the
   selection, or emphasis priority supplies an ordering tie-break.

This backbone is computed from canonical birth order **before** any focus-specific member reorder.
It keeps half-sibling context grouped without claiming it is one full-sibling block, and prevents an
unrelated block from entering a partner component merely because one partner becomes context. The
arrangement is a deterministic structural heuristic, not a global minimum-crossing or minimum-edge-length solver.
Some partner networks cannot make every couple simultaneously adjacent. This initial priority-parent
backbone is a tie-break, **not** permission to split the children of their other known parent. Final
structural parent cohorts below supersede incompatible context-partner/focus preferences.

## Structural common-parent cohorts in every mode

Every actual father **and** mother contributes the set of their child **blocks on that rank**. Each set
with two or more blocks requests one contiguous interval, regardless of selection, emphasis, mode's
priority parent, parent birth/name/sex, or which links the UI paints. Missing parents contribute nothing;
identical father/mother IDs are deduplicated. Real long-edge children participate only on their own rank.
Full-sibling blocks remain indivisible and retain their accepted member permutations; half siblings with
different second parents keep their distinct block IDs/backgrounds.

The family-only structure admits a specialized exact construction rather than permutation search:

- Treat a child block as an edge between its distinct parent IDs. A one-parent block gets a private
  dummy leaf; parentless blocks are free context. Parallel unordered parent sets form temporary edge
  bundles only, never a new sibling block or shared background.
- A connected simple component can satisfy all its incident-parent intervals exactly when it is a
  **caterpillar tree**: it is acyclic, and deleting leaves leaves a path or at most one vertex.
- Walk that path, placing each vertex's pendant bundles before the next path edge. Try both path
  directions; pendant/bundle ties use the incoming canonical backbone. Each feasible component is
  solved independently, even beside a cyclic/non-caterpillar component. Without higher ancestor locks,
  every family-only feasible component therefore receives all its parent intervals.

For actual ancestor locks, candidate component runs are checked at each row insertion gap. The final
cohort repair preserves already accepted actual mother→father card seams, genuine ancestor role sides,
and the `both` ancestor corridor's complete ancestor order and exclusive maternal-left/paternal-right
sides where there are multiple ancestor blocks. Neutral/shared exterior stability is only a movement
tie-break, not a reason to veto a family cohort around a sole ancestor. A candidate that
would violate these is not used. Cyclic/non-caterpillar or hard-constrained components then use bounded
stable cohort extraction/insertion and intruder-eviction candidates. Father/mother modes try their own
parent role first, then canonical parent ID; `both` uses canonical parent ID. Dates, names, sex, and focus
do not choose which incompatible parent interval is attempted first. Each accepted interval is locked
against later repairs. These bounded candidates are deterministic best effort with hard locks, not a
claim that candidate exhaustion proves global infeasibility or finds a maximum compatible subset.

Overlapping intervals are not merged into one indivisible clan: `AB` and `BC` can coexist as `ABC`.
A parent triangle, or the four child families of two fathers and two mothers, cannot satisfy every
parent simultaneously. Additional compatible intervals can reverse the order of **whole half-sibling
blocks** when necessary; chronology inside each full-sibling block never changes. Context role sides
and partner proximity are soft tie-breaks and cannot veto an otherwise compatible parent interval.
The selected-descendant convenience corridor is attempted last and must preserve all accepted parent
intervals. No downstream focus/corridor operation can split them again.

Thus Natalia's separate-father children Anastasia and Olga remain neighboring blocks when Natalia,
Nikita, Veronika, Roman, Olga, or Anastasia is selected, in every mode unless a genuine stronger ancestor
constraint conflicts. A cousin/nephew is not allowed between them merely because their different fathers
are older, unnamed, or preferred by the initial mode-specific backbone.

## Structural block-level role sides in every mode

After the mode-specific backbone, related same-generation people in **different sibling blocks** use their
**nearest common descendant below them**: the common descendant with the smallest absolute generation
rank, not the closest graph ancestor above them and not necessarily the current selection. An ancestry
bit-mask traversal from each descendant labels entry through its mother as 1 and father as 2. An exclusive
maternal ancestor's block precedes an exclusive paternal ancestor's block when compatible, regardless of
either person's sex, birth date, intermediate parent roles, selection, or trunk mode. Each bit visits each
ancestor once; pedigree collapse does not enumerate paths. Real long parent edges participate in this
traversal without changing their generation ranks. Within one block, birth/name/ID chronology takes precedence
over inferred or direct role sides; merely sharing an ancestor above the siblings supplies no role side.

For each same-rank pair, only the first common-descendant rank supplies inferred direction. All common
descendants at that rank contribute; opposed directions cancel rather than arbitrarily choosing a child
ID. Mask 3 (both branches), equal-side masks, or a missing common descendant do not assign a side. A
later, deeper descendant does not reverse the earlier relationship. Actual distinct, same-rank co-parents
also supply mother-before-father direction directly; inconsistent reversed direct roles cancel each other.

The row accepts direct-role inequalities first in canonical parent-ID-pair order, then inferred inequalities
by common-descendant rank and canonical ancestor IDs. Constraints apply only to whole blocks. A same-block
preference is ignored, not stored as a member constraint that could reorder siblings or veto an allowed
ancestral seam. An edge that would cycle the block precedence DAG is skipped. Stable topological ordering
permutes constrained block slots while retaining the canonical backbone as its tie-break and leaving
unconstrained slots alone. Thus contradictory partner networks receive a deterministic compatible best
effort, not a factorial search or a promise that every requested side can coexist with indivisible siblings.

This rule does **not** make whole rows mode-independent: the initial priority-parent backbone, unconstrained
chronology, centering, and `both` focus refinements still differ. Parent/partner repairs preserve accepted
role inequalities until the final structural cohort stage. Genuine ancestor role directions remain hard;
**context** role preferences are soft during common-parent grouping in every mode and cannot by themselves
veto a family interval. The `both` ancestor corridor additionally overrides incompatible context edges.
Full-sibling identity and contiguity never yield.

For example, Valentina is Roman's mother; Lydia/Gennady are the parents of full sisters Natalia/Veronika;
Roman and Veronika have Nikita. Lydia and Gennady enter Nikita's maternal branch, Valentina his paternal
branch. Every mode and selection therefore puts `Lydia < Gennady < Valentina`, even if Valentina is older
and Gennady is male. Oleg/Natalia's Olga and Nekto/Natalia's Anastasia likewise put Natalia before either
father. Their relationship is not inferred from the sex of the cards or from context branch colors.

## Compatible parent adjacency and focus refinements

In `both` mode, actual parent couples along the selection's ancestry are attempted at **every ancestral
level**, even when the selection is not their direct child or has only one known parent. The mother
**card** is immediately before the father card whenever they occupy the same rank, are distinct people,
and that seam is compatible with block-level structural role sides and earlier accepted seams. No sibling
or unrelated card intervenes in an accepted seam. Only this parent-pair operation may override sibling
birth/name/ID order; it takes priority over context proximity, not just the order of the couple's blocks:

- In different blocks, move the mother to the end of her block and the father to the beginning of his.
  Other siblings retain their relative order; both backgrounds stay whole and keep their identities.
- In one full-sibling block, place the adjacent mother/father pair at the earlier of their previous
  member slots. Other members retain their relative order. Sibling unions do not duplicate people.
- First try joining different parent blocks by exchanging the father's block with the mother's current
  right-hand neighbor. This preserves the historical father-slot behavior when compatible. If this swap
  violates a structural role side or an earlier seam, also try relocating the father after the mother,
  then relocating the mother before the father. These are fixed local candidates, not permutation search.
  If the mother is the final block, relocate the father after her to create the missing right-hand slot.

A focus-independent normalization supplies a canonical partner slot for a shared maternal block. In
each partner component, pairs sort by mother ID then father ID; the first maternal block participating
in multiple pairs has that canonical father's block placed directly after it. Subsequent focus
constraints exchange partner slots on this same backbone. After role-side ordering, normalization is
attempted again and retained only if it preserves every accepted inequality: a side repair may have moved
the mother past her original partner slot. This keeps the mother block anchored for compatible half-sibling
father-slot exchanges, without consulting an earlier layout.

After the selected parents, actual ancestral couples are attempted nearest-first by the depth of their
child from the selection, with child ID resolving ties. Duplicate pairs are processed once. A later
repair is accepted only if every structural role inequality and all earlier accepted maternal-before-paternal
card adjacencies survive; otherwise both its block move and member reorder are discarded. This is a
deterministic compatible priority heuristic, not a promise that conflicting partner networks can all be
adjacent. For example, a shared grandmother preceding both grandfathers plus maternal-grandfather-before-
paternal-grandfather can make one ancestral seam impossible; the compatible seam is still attempted.
Genuine cross-generation couples retain their real ranks and long links instead of a same-row constraint.
There is no additional maternal/shared/paternal sorting of the ancestor blocks themselves: shared ancestry
is not arbitrarily assigned between sides. Context branch masks are used only by the final corridor
operation below, not to globally reorder whole rows.

Partner refinement runs in **father, mother, and both modes**. The original `both` parent-seam pass remains
an initial backbone refinement; a final guarded call runs after structural parent/descendant cohorts so
that later grouping cannot accidentally undo partner priority or vice versa:

- Co-parents are inferred only from actual children naming both distinct parents. Explicit marriage
  episodes additionally supply undirected partner pairs, including when there are no shared children.
  Neither source creates a painted horizontal edge across or within ranks.
- The selected person's partners take priority. The objective first compacts their whole blocks,
  minimizes selected-pair card separation, then prefers maternal-before-paternal orientation only for
  actual co-parents. Childless pairs never supply parental-role directions or canonical mother/father slots.
- Next come the partners of the selection's siblings, using the same full/half/explicit-group scope as
  sibling emphasis. Their aggregate card separation and block compactness improve only without worsening
  the selected person's objective. This also works when selection has no partner at all.
- Every accepted structural parent interval, accepted descendant interval, actual ancestral card seam,
  ancestor corridor, and currently satisfied accepted role inequality is locked. A partner preference
  cannot reverse an accepted maternal/paternal side or split a stronger family cohort.
- Deterministic improving relocations move whole focused blocks or whole accepted cohort runs only.
  Every member permutation is preserved exactly as received from parent-pair ordering (canonical chronology
  or an actual `both` ancestor seam). A selected person, sibling, or partner cannot move to a member boundary
  just for proximity. Intervening siblings can make literal card adjacency impossible even when blocks touch.
- When a direct parent has an additional partner, the parents and their partners additionally request
  a compact whole-block cluster after own/sibling partner objectives. Unrelated blocks cannot occupy
  a compatible gap between the selected person's parents and stepparents. This adds no literal
  stepparent-card adjacency, member reorder, ancestry edge, or rank constraint; stronger structural
  locks still win. Without a stepparent, this extra focus objective is absent.
- Remaining ties avoid increasing other context-couple gaps, then retain the incoming canonical block
  order. Child IDs and prior layouts do not break ties. Strict improvement prevents oscillation; no
  sibling-member permutations or factorial searches are performed.
- Own and sibling partner clusters are best effort under the stronger invariants. Already optimal own
  partners do not suppress sibling refinement, but a sibling's partner can never displace an own partner
  merely to expose its own seam. No emphasis or highlighting changes accompany these block moves.

The priority is indivisible full-sibling blocks and genuine ancestor role sides, then accepted actual
parent seams and the ancestor corridor in `both` mode. Structural **common-parent child cohorts in every
mode** come next; the selected-descendant convenience corridor must respect those accepted intervals.
After those structural stages, own-partner proximity precedes sibling-partner proximity and then the
parent/stepparent cluster in every mode, while preserving the accepted role sides still satisfied by
the structural result. Other context-partner
preferences and minimal movement are lower-priority tie-breaks. Only the actual
ancestral parent-seam operation may change sibling members; structural cohorts move whole blocks only.
Four partners in the same opposite parent role and separate blocks must all remain on one side of the
selection, so only one can touch; proximity cannot buy a reversal or a sibling reorder. Focus refinement
does not replace shared-mother normalization or globally optimize every context couple.

For example, the widget fixture uses the Russian given names `Вероника` and `Наталья`. With missing
or equal dates their canonical sibling order is **Veronika before Natalia**, regardless of their IDs.
Olga is Oleg/Natalia's daughter, Anastasia is Nekto/Natalia's daughter, and Nikita is Roman/Veronika's son.
For this name-sorted fixture, cold `both` builds put the parents' row in these orders:

- Olga: `[Veronika, Natalia] – Oleg – Nekto – Roman`.
- Anastasia: `[Veronika, Natalia] – Nekto – Oleg – Roman`.

The additional father is cousin-style stepparent context. The parent/stepparent cluster keeps Roman's
unrelated block outside rather than between the two father blocks.

Roman/Veronika focus also retains `[Veronika, Natalia]` and puts Roman's whole block immediately after
it: Natalia remains between the actual partner cards. Proximity cannot reverse the sisters. Selecting
Nikita instead permits `[Natalia, Veronika] – Roman`, because this exposes his actual mother/father seam.
The same exception applies to grandparent and higher couples, not merely direct parents. Natalia/Nekto
focus alone cannot change the canonical member order either; compatible whole partner blocks compact
without promising pairwise card adjacency.

Olga/Anastasia exchange only the equal-width Oleg/Nekto slots. The sister block has exactly the same
identity, order, start, and member coordinates; Roman also stays put. Natalia already occupies the required
right boundary in this name order. Other names or birth dates can change canonical context slots and may
require the allowed ancestral seam override, but switching Olga/Anastasia still keeps the shared block
anchored wherever these seams are compatible. Latin test names (`natalia`/`veronika`) have a different
canonical name order and therefore need not produce the Russian fixture's context slots. Returning to any
selection reproduces its exact cold layout, regardless of navigation history. Ranks, links, metrics, and
the underlying document are unchanged.

## BOTH ancestor corridors

After all role, actual-parent seam, and selected-partner ordering, each `both` generation containing
actual ancestors keeps those ancestor **blocks** in one contiguous corridor. A complete sibling block
counts as an ancestor block if any member is an actual selected ancestor: collateral siblings remain
inside their indivisible background, with the same accepted member order. Shared/both-path ancestors
are included once and are not assigned to an artificial maternal or paternal side.

Only nonancestor blocks **between the first and last ancestor blocks** are displaced. They use the
existing nearest-path context branch masks, not sex, names, emphasis, or a new genealogy traversal:

- Exclusive maternal path (mask 1): move to the left immediately outside the ancestor corridor.
- Exclusive paternal path (mask 2): move to the right immediately outside the corridor.
- Shared/ambiguous path (mask 3) or disconnected/neutral context (mask 0): choose the nearer original
  corridor edge by block slots, with the left edge winning an equal-distance tie.

This is one stable partition: existing exterior prefix, left-moving intruders, ancestor blocks,
right-moving intruders, existing exterior suffix. Within each part the incoming order is unchanged.
Within this corridor pass, already-exterior context keeps its side/order, even if its mask would choose
the other side for an intruder. Final stronger structural family grouping may subsequently move neutral
or shared exterior blocks, but must preserve the ancestor interval/order and genuine exclusive branch
sides. Rows with fewer than two ancestor blocks or no intruders are unchanged by corridor sorting. The
selected generation has no ancestor blocks and receives no ancestor-corridor sorting; neither do single modes.

Every ancestor block's relative order, every sibling-member permutation, and every accepted actual
mother→father card seam survives exactly. Incompatible role or partner edges involving an **evicted
context intruder** may yield; the corridor is not abandoned to keep a filler between ancestors. No new
role precedence edges are added, so this cannot create a constraint cycle. The pass is linear in row
size and consults neither prior layouts nor screen geometry. Ranks, block identities, links, and stored
data do not change. Packing subsequently recomputes positions for the new whole-block order.

For example, when Nikita is selected, Lydia/Gennady belong to his maternal ancestry and Valentina to
his paternal ancestry. Oleg's parents can lie between those blocks in the ordinary partner backbone,
but their nearest path goes through Olga/Natalia toward Veronika's maternal branch. In `both` mode
those intervening blocks move to the left of Lydia/Gennady rather than separating them from Valentina.
The same rule applies independently on grandparent and higher ancestor generations. Existing compatible
Olga/Anastasia father-slot exchanges remain unchanged when their ancestor corridor has no intruders.

## BOTH descendant corridors

After structural parent cohorts are accepted, the same solver attempts an additional whole-block
corridor on every generation **below** selection in `both` mode. Its cohort is all transitive descendants
reached through real child edges, not only children sharing one co-parent. A shared descendant is included
once; a niece/nephew who is also an actual descendant belongs to this cohort rather than collateral context.
This convenience interval cannot split any already accepted structural parent interval, actual ancestor
seam, or ancestor corridor. Thus it is best effort when genuinely overlapping family groups conflict.

The preferred candidate evicts only non-descendant blocks between the first and last descendant blocks,
keeping exterior context and descendant block order. Bounded whole-cohort insertion candidates are also
available when that partition conflicts with stronger intervals. All sibling-member orders stay intact;
the only member-order exception remains **actual ancestral parent seams**. This extra preference is not
applied in single modes or on the selected row, but their structural common-parent cohorts still apply.
Generation ranks, links, and stored data are unchanged.

Exclusive existing context masks still choose the corresponding left/right edge. For ambiguous/neutral
masks, lower rows additionally consult the actual **blood-relative side on the selected generation**:

1. Traverse child edges from selection and actual ancestors, expanding model sibling-group membership
   as a lateral blood-relative relation. This includes rootless explicit siblings and their descendants,
   but never follows their parents upward or treats a spouse as blood-related merely through shared children.
2. After the selected row's final block/partner ordering, seed its blood relatives with their actual card
   side relative to selection. A full sibling on the right seeds right; a sibling on the left seeds left.
3. Propagate these bits only downward along real child edges, excluding the selection's own descendants.
   Each bit visits a person once. Exclusive left/right bits choose that outside corridor edge; context
   reached from both sides, or from neither, falls back to the nearer original edge with a left tie.

These bounded traversals run once per build. They supply a private layout preference, not a changed
`TreeBranch` value, spouse relation, or link target. The solver prefers that side placement where compatible
with structural family intervals; context-role/partner preferences cannot veto those intervals.

For example, Natalia's daughters Anastasia and Olga have different fathers, and sister Veronika's son
Nikita can appear between them in the ordinary `both` backbone. With Natalia older and Veronika to her
right, selecting Natalia produces `[Anastasia, Olga] – Nikita`; if Veronika's canonical card is on the
left, it produces `Nikita – [Anastasia, Olga]`. Both daughters keep their incoming order and block IDs.
The same preference groups grandchildren and deeper descendants without changing a full-sibling
permutation. Crucially, changing selection to Nikita does not remove Natalia's structural child cohort:
Anastasia and Olga still stay together in every mode, even though neither is Nikita's descendant.

## Signed packing and centering

Each generation packs its ordered blocks in one linear pass. For `n` siblings, block extent is
`n * nodeExtent + (n - 1) * gap`; neighboring blocks are separated by `2 * gap`.
A member's center is `block.start + nodeExtent / 2 + index * (nodeExtent + gap)`.

The whole row is then translated, never rebalanced around the focus's shorter side:

- On the selected rank, the selected **person** is at cross-coordinate zero, not the average of its block.
- Single-parent modes build a centering chain: at every ancestor choose the preferred father or mother,
  using the other only if the preferred parent is unknown. Each chain person's rank centers that
  person, even inside a sibling block. The UI aligns this same repeated preferred-parent chain, not
  an average of all `trunkIds`: trunk membership still describes the chosen immediate parent's **whole
  ancestral branch**, so it is intentionally broader than the center line. Fallback does not redefine
  that trunk set. Ranks without a chain member center their first canonical person.
- In `both` mode, the selected parents' rank centers their card midpoint, including parents sharing
  one sibling block. Elsewhere a combined-ancestry block centers its first actual ancestor by the same
  unknown-date-first/date/name/ID comparator;
  otherwise maternal and paternal spans determine their central seam. A reversed seam is used if
  constraints require reversed spans; interleaved spans use their combined span centers. One-sided
  ancestry leaves a gap between its band and the origin.
- A context-only rank centers its first canonical person. Bounds always include the origin, including
  the empty side of a one-sided trunk.

Nearby full-sibling, half-sibling, and cousin selections thus usually translate their rows without
changing relative order or spacing, even for entirely cold builds. Necessary ancestry-side changes
can change ordering, and document/date/name/parent edits recompute it from current data. Missing/equal-date
siblings still use their strict given-name/ID order independently of selection; only an actual `both`
ancestral parent seam may override it. None of these operations inherit old equal-date runs or obsolete
spacing from a prior layout.

“Left” and “right” mean negative/positive **cross axis**, not permanent horizontal screen directions.
The [UI](ui.md) owns screen-position compensation, viewport alignment, zoom, and per-generation scroll offsets;
these are separate from the model's canonical structural order and are not shared document operations.

## Relation links and the UI boundary

`TreeLink` records every real parent-child relation, with the child's block ID for shared sibling
connection handling. Marriage episodes never create a `TreeLink`, marital curve, or extra parent curve;
connection identities, filtering, geometry, and the painter's sex colors remain unchanged. Layout does
not substitute the priority parent for the real pair, discard long edges, select avatar endpoints,
or calculate connection paths.

[tree_editor.dart](../../lib/ui/tree_editor.dart) owns connection filtering, relevant-person avatar-edge
or descendant-block-center endpoints, curves, clipping, and scroll-offset projection. It also owns
orientation: portrait uses generation columns (horizontal main axis, vertical cross axis), while
landscape uses generation rows (vertical main axis, horizontal cross axis). Negative maternal cross
coordinates therefore need not appear to the screen's left.

The UI paints surname footers below the block background without changing its dimensions. This does
not alter the layout's node extent, block packing, ranks, or link coordinates. Full-band hover and the
single outer scrollbar are also presentation concerns; generation controllers remain independent.
Scrolling only reprojects connection geometry and does not rebuild `TreeLayout`.

## Tradeoffs and executable examples

A rebuild considers the whole projected document. Keeping all context, complete sibling blocks,
chronological role groups, and partner components can produce wide generations and long edges;
the UI handles navigation. Canonical structural stability does not mean that all selected people can
occupy coordinate zero without translating their rows, or that all partner networks admit an adjacent
arrangement under their sibling constraints.

[tree_layout_test.dart](../../test/tree_layout_test.dart) exercises immutable output, compatible co-parent
ranks, dynamic Oleg parent/grandparent addition beside deeper Lydia ancestry and disconnected context,
Shrek's create-then-link route with one/two parents, repeated shallow collateral branches and descendants,
parent additions before/after those children, unlink/delete projection and reversed-event reloads,
fixed-seed zero-slack graph fixtures, a bounded exhaustive tiny-quotient optimum oracle, a 160-generation
branched pedigree, canonical unknown-date-first/date/name/ID ordering, differing trimmed given names and
exact duplicate-name ID ties across selections/modes/insertion orders, current name/date edits,
maternal/paternal signs, literal selected-parent card adjacency across
all sibling birth-date permutations, same-block parent pairs, shared ancestors, role-specific grouping,
cold sibling/cousin row stability, exhaustive prior-focus/mode comparisons, random prior documents and
metrics, the Nikita–Olga–Nikita and anchored Olga/Anastasia father-slot fixtures, Roman/Veronika
focus across unknown/equal/dated siblings and insertion orders without member reorders, selected co-parent
whole-block moves, single-mode sibling co-parent chronology, Valentina/Lydia/Gennady block-level role sides
for every selection and mode, common-descendant roles within chronological sibling blocks, nearest-descendant
precedence, multilevel and real long-edge branch paths, opposite-descendant cancellation, pedigree collapse,
deterministic cyclic constraints with rigid siblings and disconnected context, multi-partner clusters,
child-ID-independent focus ties, compatible independent/ancestral seams, both same-block and boundary parent
seams at multiple ancestral depths when the selection is not their direct child, multilevel ancestor
corridors with maternal/paternal intruders, neutral nearest-edge/left-tie and shared/both-path fallbacks,
unchanged exterior context and single-mode order, shared-ancestor sibling blocks, explicit conflicting
context-role priority, Natalia's separate-father child corridor outside nephew context, left/right full-sister
side propagation, deeper descendant and shared-descendant cohorts with rigid siblings, all-focus/all-mode
shared-mother and swapped-shared-father cohorts under adverse names/DOB/sex/insertion order, a bounded
tiny-permutation family-feasibility oracle (paths, pendant stars, parallel role sets, duplicate parents,
cycles and non-caterpillar trees), disconnected feasible/impossible parent components, a sole ancestor
that must not veto neutral exterior siblings, explicit zero/one-parent transitive sibling blocks,
canonical member sorting, completion-to-computed identity transitions, unlink-to-half-sibling splits,
parentless sibling/cousin emphasis and collateral side propagation without ancestry shortcuts, rejected
malformed within-group parent cycles, all-mode own-before-sibling partner conflicts, sibling-only partner
refinement for full/half/explicit siblings, two rigid sibling blocks under unknown/equal/reversed DOB,
unchanged emphasis/ranks/links/history, document edits, and metrics without overlap.
Explicit-marriage fixtures additionally cover detached childless partners of every sex, neutral
orientation, duplicate/reversed episodes, cold/reloaded rank determinism, conflicting spouse chains,
rigid sibling blocks, own-before-sibling partner priority, and removal with/without shared children.
[tree_editor_test.dart](../../test/tree_editor_test.dart) covers the separate UI contract, including
orientation, scrolling, alignment, zoom, screen-position stability, and real parent connections;
childless spouses retain existing light/dark full-color node treatment, neutral block washes, parent-only
curves, live removal/noMarriage behavior, and independently scrolled cached painter geometry.
