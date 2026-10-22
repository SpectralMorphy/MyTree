# Tree model and merge semantics

The current domain model is [tree_document.dart](../../lib/tree/tree_document.dart), with pure immutable
surname/marriage/history values in [family_history.dart](../../lib/tree/family_history.dart).
Neither module depends on Flutter, storage, or transport. `TreeDocument` owns a mutable set of immutable
operations and rebuilds immutable people, relationship/history, binding, and room patronymic projections.

Related: [tree layout](tree-layout.md), [UI](ui.md),
[history and storage](history-and-storage.md), [rooms and identity](rooms-and-identity.md).

## Domain and virtual root

- `TreePerson` contains an ID, name, biography, `TreeSex`, optional birth/death dates, an optional explicit `alive` mark, independent
  `fatherId`/`motherId` references, ordered facts/photos, an optional `avatarPhotoId`, and explicit and
  effective surname configurations with an optional immediate-father inheritance source. Its read-only
  `patronymic` is derived from the accepted father's name and the child's sex; it is not editable person data.
- `TreeFact` has a stable ID, text, and color. `TreePhoto` has a stable ID, immutable image data URL,
  and editable caption. Person collections and the document's public maps are unmodifiable.
- `TreeSex` is `unknown`, `male`, or `female`; `TreeTextField` identifies name, biography, fact text,
  or photo caption. Item text is addressed by person ID, field, and item ID, not a list index.
- Every document starts with `rootTreePersonId == 'root'`: an unnamed person with unknown sex and
  empty collections. This virtual root needs no creation event, persistence write, or actor binding.
  It is an editable person, not a hidden graph super-node. Empty names display as “Unnamed” (translated here from the Russian UI).
- Other people are introduced by `createPerson` or atomic `createSibling`. `deletePerson` permanently hides an identity, including
  the initial root. An empty visible document is valid after deleting the last person; the UI offers
  editors an explicit new-person action rather than silently recreating a deleted root.

## Person display order

`compareTreePeopleByBirth` is the shared pure person comparator for relatives, layout, search, and
person pickers. Missing birth dates count as **older** than every known date and come first; known
dates sort ascending. Equal or missing dates compare the stored given-name text with
`name.trim().toLowerCase().replaceAll('ё', 'е')`, then the immutable person ID as the final strict tie.
Rendered/inherited surnames, death dates, insertion order, and selection do not affect that order.
`childrenOf` and `siblingsOf` return unmodifiable lists in this order without changing stored names,
creating operations, or saving a migration. This presentation order does not change event replay stamps
or the identity-keyed public `people` map.

## Operations and event-set replay

`TreeOperation` is a validated, deeply frozen JSON payload. The schema rejects unknown operation
names, extra/missing keys, wrong field types, malformed Unicode, and invalid IDs. Its `fieldKey` and
`description` support history presentation; neither changes merge behavior. Person operations retain
all their existing required keys and nonempty `personId`. Room-scoped `setPatronymicOverride` has no
serialized `personId`; its compatibility getter returns `''` and `isRoomScoped` returns `true`.

`StampedTreeOperation` adds immutable `id`, `author`, logical `clock`, and `createdAt`. Tree ordering
is lexicographic **(clock, author, id)**; wall time is display metadata, never a conflict tie-breaker.
The clock must be a nonnegative integer at most `9007199254740991`, safe on Dart VM and JavaScript.

Commands such as `setValue`, `editText`, and `moveFact` return payloads without changing the document.
The caller must stamp and optimistically merge each command before producing the next local command.
[RoomSession](../../lib/room_session.dart) stores payload JSON in `RoomEditKind.tree` journal entries
and adapts those entries into stamps. The room envelope's `authorSequence`, `authorPrevious`, and
`authorBase` prove journal-prefix order only; they are **not** tree stamps and do not change LWW,
text-anchor, list-placement, parent-cycle, or binding-claim/release rules. Optimistic IDs/payloads/clock/time are
fixed before persistence, so assigning a canonical author proof cannot restamp text atoms or replay a
different command. `createdAt` remains the actual UTC epoch creation instant, even after a clock rollback.
Durable and optimistic projections, complete-prefix validation, and unchanged legacy replay are integration
concerns; see [history and storage](history-and-storage.md).

`merge` deduplicates immutable event IDs. Equivalent redelivery is a no-op; reusing an ID with different
content or stamp throws before any event in that batch is accepted. A changed event set causes a full
sorted rebuild, not mutation in arrival order:

1. Create the virtual root and gather person identities (including atomic new marriage partners), then fact/photo identities.
2. Seed new identities from the earliest create/add in total order; later duplicate creations do not
   replace them. Gathering identities first lets an edit/removal be replayed before its add arrives.
3. Replay text edits, scalar registers, room patronymic overrides, removals, placements, and actor claims
   using their own rules. Room registers are handled independently of person lookup or visibility.
4. Collect permanent person tombstones, drop references to deleted people, resolve parent cycles,
   derive birth surnames/patronymics from accepted father edges, and project family histories/current
   surnames using the accepted live graph and independent marriage/suppression records. Order lists
   and publish immutable visible snapshots.

Events targeting identities not yet present stay in the event set; a later rebuild can apply them.
Equal event sets therefore converge independently of delivery order or duplicate delivery.

## Person deletion and relationship removal

`deletePerson` has exactly `type` and `personId` fields. Deletion is remove-wins and permanent for that
identity, independent of stamp or delivery order. Concurrent/later edits, photos, facts, or duplicate
creation records cannot resurrect it. Local creation also rejects previously used/deleted IDs.
The projection excludes parent references to deleted people; relatives and unrelated people remain.
All original events, text anchors, image payloads, and actor binding claims stay in the immutable journal.
Deleting a bound person does not automatically clear its actor claims. An actor can explicitly release
its active claim even when the person is deleted, then select another existing person.

Removing a parent relationship uses a nullable `fatherId`/`motherId` register update, not a person
tombstone. Inside an active direct-sibling component, that role clear propagates to every member.
Computed full siblings share both known parents in the same roles and have no independently removable
sibling edge. Explicit sibling claims are different: removing a claim preserves already assigned parents,
so former direct siblings with one common parent remain half siblings.

## Atomic new siblings and direct components

`createSibling(sourceId, newId, {name, sex, DateTime? birthDate})` produces one immutable payload with
exactly `{type: createSibling, personId: newId, siblingId: sourceId, name, sex, birthDate}`. The source must
be visible and the new identity unused locally. `birthDate` is a required nullable strict `yyyy-MM-dd`
wire field. The winning earliest creation seeds anchored name text, sex, and DOB; later edits use normal
field operations. Duplicate creations cannot create another relationship for the same identity.

This one journal event creates the new person and copies the source's currently accepted canonical
father/mother references. If both are known, the result is ordinary computed full siblings and no direct
claim. Otherwise the creation event ID identifies an undirected direct-sibling claim. There is no general
command to link two existing people. Parentless people do not become related just because dates or
parents are missing.

Relationship events replay in total tree-stamp order. Active undirected claims form components whose
father and mother role registers agree, including explicit null clears. Linking selects the newest
per-role register and materializes it to members. An ordinary parent `setValue` to any member sets or
clears that role for the entire current direct component with the same original event stamp. This is
domain replay, not UI-only fanout or a batch of independently saved commands. When an edge is removed,
the last materialized per-person registers remain; later edits propagate only in the remaining components.

`unlinkSibling(personId, siblingId)` freezes the active claim into the exact payload
`{type: unlinkSibling, personId, siblingId, linkId}`. Replay removes only that claim with matching
undirected endpoints; stale/wrong-target removals cannot cancel another claim. A removal arriving before
its claim is retained, and unknown-source creation records remain in history for later replay. The local
session requires the exact claim still active and forbids unlinking computed-only full siblings.

After a relationship transition, an active component with **both accepted live parent roles** retires all
its direct claims deterministically. This writes no synthetic unlink events or migration: the original
creation/parent operations already encode the transition. Claims are retired at that replay step, not
merely hidden while the final pair is complete, so later parent clears/deletions cannot resurrect them.
Deleting a member cuts its incident claims and cannot bridge survivors through a tombstone. Historical
completion uses deletion state at that transition, not future deletion events. Final visibility is still
permanent remove-wins. Original journals without sibling operations keep their original replay fast path.

Active-component parent roles are accepted/rejected atomically on the component quotient DAG, rather
than filtering individual members into inconsistent families. Local parent commands check cycles against
every direct-component member; remote conflicting edges are projected deterministically. A rejected raw
reference does not count as a known second parent and cannot retire claims. Accepted father edges remain
the only source of surname inheritance; sibling claims never synchronize personal surnames.

The immutable `directSiblingLinks` list contains `TreeSiblingLink(id, personId, siblingId)` descriptors
of active claims. Immutable `siblingGroupIds` covers every visible person: active components use
`siblings:<minimum member ID UTF-16 length>:<minimum member ID>`, and others use the existing computed
parent-pair/singleton `treeSurnameFamilyKey`. Layout consumes the projected group map, while historical
surname fallback continues using the unchanged surname key. `siblingsOf(includeHalf: false)` includes
explicit component peers and computed full siblings; the default additionally includes shared-parent
half siblings. Groups and lists are rebuilt with the person projection, never saved on opening.

Creation, parent propagation, and unlink each need only one normal optimistic/durable room edit. Failed
saves retain the same event/core for retry and are never broadcast as durable success. The separate
`explicitSiblings` capability is required before history/admission because older clients reject the new
payloads and do not propagate ordinary parent operations inside components.

## Field-specific semantics

| Data | Current rule |
| --- | --- |
| Name, biography, fact text, photo caption | Independent anchored text sequences, not whole-string LWW. |
| Birth surname, legacy family/maiden surnames | Atomic nullable per-person LWW `(text, decline)` configuration. Historical family-keyed registers remain read-only fallback until any personal register exists; maiden stays independent and non-rendered. |
| Marriage episode | Stable room-global ID and immutable undirected endpoints; shared period is atomic LWW, surname choice/snapshot is independent LWW per endpoint; deletion is remove-wins. |
| Pair `noMarriage` | Endpoint/root-independent LWW suppression of common-child marriage fallback; valid fresh episode add clears, remove sets. |
| Independent surname change | Person-scoped stable ID; atomic LWW `(canonical surname, date, reason)` record; deletion is remove-wins. |
| Current surname | Projection from chronological changes, falling back to birth. Never inherited by children. |
| Room patronymic dictionary | Per-normalized-name LWW nullable `(male, female)` pair; null resets to the built-in dictionary/algorithm. Independent of any person. |
| Person patronymic | Projection only, from the accepted father's given-name text, room overrides, and child's sex; unknown sex gives an empty string. |
| Sex | Atomic last-writer-wins (LWW) register; clearing means `unknown`, not `null`. |
| Birth/death date | Independent nullable LWW registers; strict valid `yyyy-MM-dd` calendar dates, exposed as UTC dates. Nullable bool `alive` is a separate register: `true` is living (`н.в.`), `false` is an unknown death (`?`). Absent `alive` keeps the legacy display: `н.в.` only when a birth date exists and death does not; both missing stays `?–?`. A death date wins over `alive`. |
| Father/mother | Independent nullable role registers; parent writes materialize across active direct-sibling components, followed by atomic quotient-DAG cycle projection. |
| Avatar | Nullable LWW photo-ID register; exposed as `null` if that photo is not visible. |
| Fact color | Independent LWW `#RRGGBB` register; the supplied palette is not a validation restriction. |
| Photo bytes | Set by the first add for that item ID; replacing an image requires a new photo item. |

LWW chooses the greatest tree stamp, not the last received operation. Different fields do not overwrite
one another. Text is not accepted through `setValue`; list ordering is not an atomic whole-list value.

## Canonical surnames

The original surname registers describe a person's **surname at birth**. Later marriage and independent
surname changes are separate history records; they never rewrite those birth registers or feed paternal
inheritance. Legacy `family` and `maiden` operations remain valid immutable journal data; opening a tree
does not migrate them, parse historical names, rewrite history, or save synthesized personal values.
Historical maiden values remain independent compatibility data.

`TreeSurname` is an immutable canonical base `text` plus `decline`. The model constructor retains its
historical **false** default; commands serialize the explicit flag. The new UI input defaults to **true**
when no value or inherited setting exists, without changing saved false values. With the flag
on, `formForSex` appends the literal Cyrillic `а` for female sex; male/unknown keep the base unchanged.
`plural` appends the literal Cyrillic `ы`. With the flag off, all forms are the original text. This is
suffix concatenation, **not Russian morphology**: there is no suffix detection, spelling correction,
or name parser. Rendered female/plural forms never become inherited bases.

### Personal commands and historical family identity

`setIndividualSurname(personId, text:, decline:)` creates one person-scoped `setSurname` operation.
The deprecated `setFamilySurname` helper is a compatibility alias to that command: it never emits a
shared write. The session rejects newly submitted raw `scope: family` commands; history decoding,
replay, and already queued immutable retries are not subject to that local command guard.
`setMaidenSurname` remains a compatibility API, not a user-facing edit mode.

The unchanged operation schema is exactly `{type, personId, scope, familyKey, text, decline}`:

- `scope` is `individual`, historical `family`, or legacy `maiden`. New personal commands always have
  `scope: individual, familyKey: null`; maiden also requires a null key.
- The complete `(text, decline)` pair is one LWW value, ordered by **(clock, author, id)**, independently
  for each person. Editing one sibling never writes a family register or copies values to relatives.
- Command helpers trim text and convert null/empty/whitespace-only input to `text: null, decline: false`.
  A clear is still an individual-register write, not deletion of that register. The decoder requires
  null or already-trimmed, nonempty, well-formed text of at most **200 runes**, without control characters.
  A null value must have `decline: false`; extra/missing keys are rejected.
- Local commands require an existing visible person. A personal command remains addressed to the same
  person after a parent change; its identity does not depend on the sibling block.

`treeSurnameFamilyKey` remains the layout's full-sibling block identity and the identity used to read
historical family registers. Both accepted parents must be known, in the same **father/mother roles**.
Its key is `parents:<father UTF-16 length>:<father ID>:<mother UTF-16 length>:<mother ID>`; otherwise it is
`person:<ID UTF-16 length>:<ID>`. Missing parents do not group unrelated people or half siblings, and
swapping parental roles changes the key. Length prefixes make IDs containing colons unambiguous.

Historical family operations retain their original shared-key LWW register. Their serialized key is
frozen; `personId` is only the old editing representative/journal context. A representative may be
unknown, moved, or deleted without discarding/retargeting its record. No new commands modify these
registers, but complete old history, including losing values and null clears, still round-trips.

### Effective value and inheritance

1. If an individual register exists, use its non-null configuration; null goes directly to father inheritance.
2. Only if no individual register has ever existed, use the current historical family's non-null fallback.
3. Otherwise use the accepted father's effective **canonical** configuration, or no surname if absent.

Individual-register **presence**, including a null clear, suppresses historical family fallback regardless
of the family operation's stamp or delivery order. A delayed or later old family operation cannot resurrect
that person's shared surname. `TreePerson.familySurname` exposes only the eligible untouched legacy fallback
and is null after any personal edit; `individualSurname` exposes the personal value. The UI can read
`individualSurname ?? familySurname` for an explicit setting and `effectiveSurname` for the resolved result.
No stored fields, operation scopes, or IDs are renamed, deleted, or automatically migrated.

The retained legacy maiden register never overrides the birth surname or participates in inheritance.
The father's personal or eligible legacy configuration can be inherited because inheritance uses his
effective value. Resolution runs after person deletion and concurrent-cycle projection, following only
the accepted father DAG. An iterative parent-first walk with memoization avoids recursive stack growth
and repeated expansion of shared ancestry. `surnameInheritedFrom` names the immediate father only when
a non-null effective value is actually inherited from him. Rendered female forms never become bases.

A personal clear returns to father inheritance; there is **no explicit blank that blocks inheritance**.
A personal edit affects that person and descendants inheriting through accepted father edges, not siblings.
For untouched legacy people, parent changes can select another historical keyed fallback without copying
values; a personal register bypasses every such key. Deleting a representative cannot resurrect it, and
deleting a parent removes that edge before resolving the surname. Because old surname-capable clients
interpret null clears differently, sessions negotiate the separate `personalSurnames` capability before
admission/history exchange; see [capability compatibility](synchronization.md#capability-compatibility).

`TreePerson.currentSurname` is the latest chronological history configuration, falling back to birth
`effectiveSurname`. `surname` renders **currentSurname** for sex. `fullName` puts the existing trimmed
name first and appends that surname, using the unnamed fallback if needed. Existing name text may contain
given name and patronymic; it is neither split nor migrated. This compatibility property remains
name-first without appending the derived patronymic; `nameForMode` supplies the alternate order described
below. Stored name fields and old operation payloads are unchanged. `surnameForBlock` deliberately uses
**birth effective configurations**, including its singleton sex-specific form: empty for no members/all
missing, plural for several equal non-null configurations, and `разные фамилии` (“different surnames”)
for mixed configurations, including a missing value among non-missing ones. Equality includes `decline`,
not merely displayed text. A father's later surname change therefore changes his full name, but not his
children's inherited birth surnames or the family's birth-surname block footer.

## Marriages and surname history

### Values and read projections

`TreeMarriage` identifies an undirected **episode**, not an ancestry edge. It contains immutable `id`,
`personId`, `partnerId`, nullable `startDate`/`endDate`, `TreeMarriageEndMode` (`unknown`, `lifelong`,
`date`), `isImplied`, `orderingDate`, and an unmodifiable per-person `surnameChoices` map.
`otherPersonId(id)` returns the other endpoint, or null for a nonmember. Episodes with the same pair may
coexist; their IDs and endpoints never change. No monogamy, sex, generation, or kinship restriction is
imposed. The only invalid pair is a self pair. Marriage cannot introduce an ancestry cycle.

`TreeMarriageSurnameChoice` contains `changeSurname`, nullable canonical `adoptedSurname`, and
`isExplicit` (the person has an explicit choice rather than an inferred/default one).
`TreeSurnameChange` contains `id`, `personId`, canonical `surname`, nullable actual `date`, `reason`,
optional `marriageId`/`partnerId`, `isImplied`, `orderingDate`, and projection-only `changesSurname`.
Actual change compares the preceding and new **rendered forms for that person's current sex**. A
canonical `decline`-only adjustment can therefore update the saved configuration without repeating an
identical visible surname. A generic reason record remains editable in that case with `changesSurname`
false; a marriage with no actual change has no surname-change row at all. The raw canonical configuration
still becomes the current surname and is not discarded merely because its rendered text is unchanged.

All document lookups return unmodifiable snapshots; unknown/deleted person lookups return empty lists:

- `marriages` contains all undeleted episodes whose **two endpoints are visible**, including ended
  marriages. It is suitable for layout adjacency, not for ancestry.
- `marriagesOf(personId)` is that person's historical episodes. Explicit episodes remain editable for
  a surviving person even after the partner is deleted; their immutable partner ID is retained. No
  person is resurrected. Implied episodes disappear when a partner/accepted common child disappears.
- `partnersOf(personId)` returns visible people in `compareTreePeopleByBirth` order, deduplicating both
  marriage endpoints and accepted live co-parents. Pair suppression removes a marital assertion, not
  the fact of shared parenthood or co-parent navigation/layout adjacency.
- `surnameChangesOf(personId)` contains chronological surname records: generic records (even no-op
  reason records) and only actual marriage changes. `historyOf(personId)` contains sorted
  `TreeFamilyHistoryEntry(id, marriage?, surnameChange?)` rows. A marriage row optionally contains its
  actual surname change; there is no duplicate independent surname row for that marriage.

Neither surname computation nor relationship inference appends events or saves a migration.

### Commands and exact operation payloads

Commands create operations, never mutate the document. Every new operation is **person-scoped**;
`isRoomScoped` remains limited to patronymic dictionary operations. The caller stamps/merges each
operation using the existing event-set workflow.

- `addMarriage(personId, partnerId, {id, startDate, endDate, endMode = unknown, changeSurname,
  adoptedSurname, newPartner})` creates an episode; omitted ID gets a fresh generated identity. Omitted
  surname choice defaults to adoption for women and keeping for male/unknown sex. `changeSurname`
  and `adoptedSurname` control only the initiating endpoint; they do not overwrite the other's choice.
- Optional `TreeNewMarriagePartner(name = '', sex = unknown, birthDate, birthSurname)` creates the
  supplied fresh `partnerId`, DOB and canonical birth surname in the **same** operation. Earliest
  creation gathering includes these identities, so delayed edits/creations behave like other person
  identities. A deleted/used partner ID cannot be reused locally. Existing partners require null
  `newPartner`; no separate create-person/DOB/marriage writes are needed.
- `updateMarriage(personId, marriageId, {required startDate, required endDate, endMode = unknown})`
  updates the atomic shared period only. `setMarriageSurname(personId, marriageId,
  {required changeSurname, adoptedSurname})` updates only that endpoint's atomic choice/snapshot.
  Both commands materialize an implied episode under its existing deterministic ID.
- `removeMarriage(personId, marriageId)` permanently removes the observed episode and writes pair
  `noMarriage = true`. It does not alter parenthood, children, another episode's ID, or a person's birth
  surname. Update/remove require a visible initiating person and an observed episode, but not a
  still-visible partner. A fresh add for the same pair clears suppression without reviving old IDs.
- `addSurnameChange(personId, {id, required surname, date, reason = ''})`,
  `updateSurnameChange(personId, id, {required surname, date, reason = ''})`, and
  `removeSurnameChange(personId, id)` manage an independent person-scoped history identity. An update
  atomically replaces that record's surname/date/reason, not another record or the entire history.
  Removing a marriage-derived change uses `setMarriageSurname(... changeSurname: false)` or removes
  the marriage itself; generic history commands cannot edit a derived marriage row.

Every wire key below is required, including nullable values; extra/missing keys are rejected.
`Surname` means exact `{text: String, decline: bool}` and `Choice` means exact
`{changeSurname: bool, surname: Surname?}`:

| Type | Exact keys beyond `type` |
| --- | --- |
| `addMarriage` | `personId, partnerId, itemId, startDate, endDate, endMode, surnameChoices, newPartner` |
| `setMarriageDates` | `personId, partnerId, itemId, startDate, endDate, endMode` |
| `setMarriageSurname` | `personId, partnerId, itemId, changeSurname, surname` |
| `removeMarriage` | `personId, partnerId, itemId` |
| `addSurnameChange`, `setSurnameChange` | `personId, itemId, surname, date, reason` |
| `removeSurnameChange` | `personId, itemId` |

`addMarriage.surnameChoices` has exactly the two endpoint IDs as keys and `Choice` values.
The initial other-endpoint default is a frozen snapshot, not a later whole-pair editable register;
subsequent updates from either endpoint preserve the other's register. `newPartner` is null or exact
`{name, sex, birthDate, birthSurname}`. Independent surname IDs are person-scoped; episode IDs are
room-global. Explicit IDs have the normal 256-UTF-16-unit bound. Reserved implied IDs are
`implied:<canonical pair key>`, where the two IDs sort lexically and are length-prefixed with UTF-16
lengths; that namespace allows up to 550 units. Endpoints containing colons/astral Unicode remain
unambiguous. A reserved ID for a different pair is rejected.

Dates are nullable strict valid `yyyy-MM-dd` calendar strings. `endMode: date` requires an end date;
other end modes forbid one. The start/end/mode triple is one LWW register, so concurrent changes
cannot assemble an invalid range. A known start later than a known end is rejected both locally and
on wire decode. End-only periods do not supply an ordering start. `unknown` is the default, not
lifelong. For `lifelong`, `lifelongEndDate(personDeath, partnerDeath)` returns the earliest known death;
with no death the UI distinguishes living/current from unknown using the existing `alive` fields.
`hasExplicitDates` is false if both actual dates are absent, even when a child supplies an ordering hint.

New history strings must be well-formed Unicode without C0/C1 controls, except that reason text allows
interior LF/CR line breaks. Surnames are trimmed, nonempty, at most 200 runes; reasons are trimmed, may
be empty or multiline, and are at most 1,000 runes (`maxTreeSurnameReasonLength`). Atomic new-partner
names are trimmed, may be empty, and are bounded
at 200 runes. Helpers trim reasons/new-partner names; wire decoding requires canonical text. Keeping
a surname requires a null adopted snapshot. Adoption may have a null snapshot when the partner has
no surname: that does **not** clear the person's existing surname.

### Inference, snapshots, ordering and deletion

A pair of distinct accepted live parents of a visible child implies one stable marriage only when no
explicit episode exists and the pair is not suppressed. Inference follows the final cycle-filtered,
sibling-propagated live parent graph, not raw/rejected parent registers. It uses the oldest **known
common child's** DOB as an ordering hint only: no inferred date is displayed or persisted as a marriage
start/surname-change date. Other children, deleted children and unknown dates do not supply a false
boundary. Either partner may explicitly uncheck adoption; materializing that choice prevents later
children, renames, or unrelated date edits from restoring the female default.

Explicit adopted surnames are canonical configuration snapshots. Default implied transfers use the
partner's latest **concrete** configuration: birth plus generic changes and persisted explicit-episode
snapshots, excluding every inferred/default-derived transfer. This two-stage calculation never follows
spouses' current surnames recursively; female/female unions and marriage loops cannot cycle. A partner
rename, changed birth surname, death, or deletion does not rewrite an already persisted snapshot.
Divorce/death does not roll back a surname; a later explicit change can restore any canonical value.

Surname chronology sorts undated records before dated records; date means actual change/marriage
start, or the common-child ordering hint for a startless marriage. Ties compare canonical surname text,
marriage-before-generic kind, stable ID and person ID. Projection walks that deterministic order from
the birth surname to find actual changes and the latest current value. For history presentation,
undated marriages with no actual surname change and no ordering date come first, sorted by the partner's
birth/name/ID seniority; other undated records sort by surname, then dated entries ascend. These two
passes avoid a cyclic dependency between sorting and whether a surname really changed. End dates
alone never act as start dates. Missing partner display names are a UI fallback, not stored text.

Episode and independent-record deletion are remove-wins, even when a tombstone arrives before its
creation or an edit has a later stamp. Pair suppression is a separate **(clock, author, id)** LWW
register independent of endpoint/root visibility. Removal writes true; a valid **fresh**, non-tombstoned
add writes false. A delayed/later duplicate add of a tombstoned episode cannot clear suppression.
Wrong-endpoint edits/removals cannot retarget an existing episode. Local commands reject used IDs,
including deleted IDs; concurrent materializations of an implied episode keep its one deterministic ID
and independent endpoint choices. All original events and tombstones stay in history.

## Derived patronymics and name modes

The pure [patronymic.dart](../../lib/tree/patronymic.dart) module is imported and re-exported by
`tree_document.dart`. Its public API includes immutable `TreePatronymicForms(male:, female:)`,
`normalizePatronymicName`, `basePatronymicDictionary`, and nullable `generatePatronymicForms`.
Normalization trims, lowercases, and equates `ё` with `е`. Room overrides take precedence over built-in
exceptions and algorithmic generation; unsupported names return no forms unless explicitly overridden.
The fallback handles single Cyrillic names: hard consonants take `-ович/-овна`, sibilants/`ц` take
`-евич/-евна`, final `й/ь` is replaced with `-евич/-евна`, and `-ий` normally becomes `-ьевич/-ьевна`
(but after `г/к/х`, `-иевич/-иевна`). Final `а/я` uses the corresponding stem with `-ович/-овна` or
`-евич/-евна`; irregular common names use the built-in dictionary. Hyphenated names derive each part,
omitting deliberately blank room forms without leaving dangling separators. Original `ё` is retained
in generated stems. This is a bounded fallback plus exceptions, not universal morphology for every language.

`TreePerson.patronymic` selects the male/female generated form using the **child's** sex. Unknown sex,
a missing/deleted father, a cycle-rejected father edge, or an unsupported/empty father name gives `''`.
Only the final accepted `fatherId` is used: not the mother, an older rejected register, the person's own
name, or a more distant ancestor. The father's sex does not constrain the relationship. Projection uses
the father's complete current name text without parsing historical full names. Renaming/relinking or
deleting a father, changing the child's sex, and editing the dictionary update the projection without
synthetic person operations, name migration, or changes to text atom identities. The forms supplied to
`TreePerson` construction are projection input, not a persisted/editable patronymic field.

`TreeNameMode` has `givenSurname` and `surnameGivenPatronymic`:

- `person.nameForMode(givenSurname)` returns the existing `fullName`: trimmed name, then rendered surname.
- `person.nameForMode(surnameGivenPatronymic)` returns rendered surname, trimmed name, then derived
  patronymic (ФИО). `fullNameWithPatronymic` is an alias to this mode for search and other consumers.
- Missing surname/patronymic components are omitted. A blank given name uses the existing `displayName`
  fallback (`Без имени`). Internal spacing and historical name contents are preserved; no deduplication,
  splitting, or migration of an already recorded patronymic occurs.

### Room dictionary operations

`TreeDocument.patronymicOverrides` is an unmodifiable snapshot map keyed by normalized father names;
values are immutable `TreePatronymicForms`. It exposes only active room overrides, not built-in entries
or reset tombstones. Previously published snapshots remain unchanged after another merge.

`setPatronymicOverride(String name, {required String? male, required String? female})` returns exactly
`{type: 'setPatronymicOverride', name: <normalized>, male: <String?>, female: <String?>}` without changing
the document. It requires no person/root and works after deleting every person. There is no fake person
ID in this payload. The history key is `patronymic:<normalized name>` and its description identifies
both the dictionary name and whether the operation sets or resets it.

- Both strings form one atomic override; either or both may be empty to intentionally omit a form.
- Both null values reset that name to built-in/algorithmic behavior. Mixed null/string pairs are invalid.
- Commands normalize the name and trim forms. The decoder requires canonical normalized nonempty names
  and already-trimmed forms. Names and each form have a **200-rune** limit (`maxTreePatronymicLength`),
  must be well-formed Unicode, and cannot contain C0/C1 control characters. Extra/missing keys and
  `personId` in the room payload are rejected.
- Each normalized name is an independent LWW register, choosing the greatest **(clock, author, id)**
  stamp for the whole pair, including reset. Sorted rebuild retains every event, so a reset received
  first still suppresses an older override delivered later; newer explicit overrides can replace it.
  Person deletion, missing identities, or a completely empty tree never discard dictionary events.

Old operations retain their exact schemas and encoded bytes. Opening/merging old journals does not
append dictionary operations, rewrite stored name text, or manufacture person patronymic fields.
Transport capability negotiation and local role guards are separate integration responsibilities.

## Anchored Unicode text

Text uses an RGA-style left-anchor forest with right-neighbor precedence. Each atom has a stable ID,
one Unicode scalar (Dart rune), `left` and `right` atom IDs, and its operation stamp. A run chains its
new atoms through left anchors. These are scalar identities, not UTF-16 code-unit or grapheme identities:
a supplementary character is one atom, while combining marks and joined emoji can occupy several.

`TreeTextSnapshot` captures visible text, atom IDs, and UTF-16 boundaries, including `0` and `text.length`.
For example, `A😀B` has three atoms and boundaries `[0, 1, 3, 4]`, matching Flutter selection offsets.
Snapshots remain usable after merges and deletions.

`editText` diffs a supplied base snapshot (or the current snapshot) against the requested string:

- A bounded Myers diff works on runes, retaining unchanged identities across multiple changed spans.
  After 512 edit-distance steps or a million work units, it falls back to replacing the changed middle;
  common prefix/suffix identities are still retained. An unchanged value returns no operation.
- Insertions encode **both neighbors** from the editing base. Deletions name only atoms observed in
  that base, so editing a stale widget value does not delete remote insertions absent from that value.
- Deletions union into permanent tombstones, including deletions received before their insertion.
  Tombstoned atoms remain structural anchors and are traversed, but are not rendered.
- Projection traverses the left-anchor forest iteratively. Right anchors order sibling subtrees before
  the subtree containing their successor, even when that successor lies below a tombstoned ancestor.
  Remaining sibling ties use reverse stamp order, then atom ID; concurrent runs stay intact subtrees.
- Missing anchors defer visibility rather than turning an insertion into an unrelated append.

`mapOffsetTo` maps a cursor between snapshots of the same field with right affinity: stay before the
next surviving original atom; if none survives ahead, use the previous surviving atom's end, or zero.
An end cursor remains at the new end. Offsets are clamped, and offsets inside a surrogate pair round down.

## Stable-ID fact and photo lists

Facts and photos share item-local placement replay; content/caption/color is independent of ordering.
Local adds append after the last visible item. IDs cannot be reused locally, including after removal.
A move validates visible anchors after excluding the moving item, fills in the other neighbor when only
one is supplied, and encodes both `afterId` and `beforeId`. No supplied anchors means move to the front.

Ordering replays **every add and move placement**, sorted by stamp and then item ID:

1. Remove the placed item from its current position.
2. Insert immediately after `afterId` if present in the replayed list; otherwise before `beforeId`.
3. If neither anchor is present, insert at the front for a move, or at the end for an add.

Keeping placement history, rather than only each item's latest anchors, preserves the exact relative
order of all other items during sequential moves. Concurrent moves receive a deterministic replay
order; this does not promise that incompatible placement intentions can both be satisfied. Concurrent
adds and content edits are not lost through a whole-list replacement.

Removed items remain ordering anchors until the final visible filter. Removal is permanent for that
identity: later moves/edits cannot resurrect it. Moving an item preserves its text atom IDs and snapshots.
Removing the chosen avatar photo makes the projected avatar `null` without another register write.

## Parent graph and actor bindings

Local parent commands require an existing person and parent. `wouldCreateCycle` follows parent links;
self-parenting and indirect directed cycles are rejected. Shared ancestry and unions between relatives
are allowed: kinship alone is not a directed cycle, and there is no partner or sex-based constraint here.

Concurrent valid local commands can still form a cycle. Rebuild takes only the newest register for each
parent field, ignores references to missing people, and sorts candidate edges by descending tree stamp
(with child/group representative ID and field as deterministic final ties). An active explicit-sibling
component supplies one atomic candidate per role on the quotient graph; otherwise the historical
per-person rule applies. It accepts an edge only if the accepted graph cannot already reach that
child/component from the parent/component. Rejected edges project as `null`; older register values
are not fallback candidates, and no event is deleted. A later graph change can make an edge visible again.

`bindActor` associates an actor ID with a person. Replay accepts the **earliest claim in total tree
order** while that actor has no active claim, not the first delivered claim or earliest wall timestamp.
A later bind alone cannot replace an active claim. Multiple actors may select the same person.

`unbindActor` has exactly `{type, personId, actorId, bindingId}`. `bindingId` is the immutable stamped
ID of the claim being released, not the person ID. Replay clears a claim only when that ID, person,
and actor match the active claim and the release's stamped author equals the actor. A stale,
wrong-target, or other-actor release has no projection effect; it cannot clear a later rebind, even
to the same person. After release, the next bind in tree order can become active. Binds ignored
before that release do not become replacement claims retroactively.

`bindActor()` requires an existing visible person. `unbindActor()` requires an active claim but not
a still-visible person, so deleting a bound person does not trap the actor. Old claim-only histories
retain their original earliest-claim projection until an explicit matching release is appended;
no claims or history records are rewritten. Delayed delivery triggers the same sorted replay.
The domain retains legacy bind author/subject semantics; it does not authenticate clients or impose
room roles. Editor-only, own-actor command guards and pending/durable checks belong to
[rooms and identity](rooms-and-identity.md).

## Limits and executable examples

Text input and edit payloads are bounded at 100,000 UTF-16 units/associated edit limits, not a global cap
on merged text. Images are inline canonical base64 JPEG, PNG, or WebP data URLs, at most 700 KiB decoded;
validation checks MIME and file signatures, not complete image decoding. There is no event/tombstone
compaction in this model: full replay favors simple deterministic behavior over incremental scalability.
Convergence does not decide which genealogy assertion is factually correct or surface semantic conflicts.

[tree_document_test.dart](../../test/tree_document_test.dart) covers immutable operations and batch
collisions, shuffled/duplicate replay, Unicode and stale snapshots, concurrent list edits, permanent
removal, scalar ordering, per-person surname edits/clears, preserved legacy registers/frozen targets and long paternal
inheritance, derived patronymics/name modes without name migration, room dictionary validation and atomic
LWW overrides/resets (including empty-tree replay), local/concurrent cycles, legacy first claims,
exact-claim releases/rebinding, and image validation.
[family_history_test.dart](../../test/family_history_test.dart) additionally covers atomic new partners,
shared episode dates and independent surname choices, implied/materialized marriages, chronological
current surnames without inheritance changes, actual/no-op rows, strict new schemas and bounded Unicode,
remove-wins identities, pair suppression/reset/re-add, survivor history, immutable snapshots, and
shuffled/duplicate/late/concurrent replay. [family_history_search_test.dart](../../test/family_history_search_test.dart)
covers the current-name/search projection with preserved patronymics and birth-surname block titles.
