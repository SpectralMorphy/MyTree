# MyTree — Collaborative Family Tree

A Flutter application for maintaining a family tree together. Create a room, invite relatives, and edit from multiple devices without asking users to set up their own servers. An optional private Yandex Disk copy supports asynchronous exchange between editors.

## Features

- Generations with independent scrolling, full-sibling blocks, and paternal, maternal, or both-lineage views.
- Tree zoom with toolbar controls, Ctrl+wheel on a computer, and a two-finger pinch on a phone.
- A selected main person with automatic parent/descendant alignment.
- Biographies, parents and children, new brothers/sisters with explicit links when parents are incomplete, dates, colored facts, and photo albums with avatar selection.
- One personal birth-surname field with paternal inheritance; editing a person does not edit their siblings.
- Search by full birth name and life years; people without a birth date sort first, then older births, with names breaking date ties.
- Full-screen biographies on phones and a side panel on wide screens; existing relatives are chosen in the full searchable tree.
- Guest/editor invitations by URL, QR code, or room ID; editors can promote existing guests.
- Persistent rooms and change history, collaborative text editing, and offline edits in an already opened room.
- Optional private Yandex Disk copy and asynchronous editor exchange; connect an externally obtained application-folder OAuth token in room settings.
- A live participant list, optional aliases, and an editor-only **This Is Me** link that groups a person's editor devices; the link can be released and chosen again.

The interface is currently in Russian. UI labels below are English translations, not a change to the application's localization.

## Run Locally

Requires Flutter with Dart >=3.10 and Node.js for the local release server. Web scaffolding is included.

```bash
flutter pub get
flutter analyze
flutter test
flutter build web --no-web-resources-cdn
node tool/serve_web.cjs build/web 52173
```

Open `http://127.0.0.1:52173/`. For development, `flutter run -d web-server` is also available. The release server is preferable when checking loading performance over a tunnel.

Use different browser profiles or private contexts to test independent participants. Ordinary same-origin tabs in one profile share the local participant and saved room. Web editing requires a browser with Web Locks in a secure context (HTTPS or trustworthy localhost); missing support produces a visible saving error. To test a phone, serve the application at an HTTPS address the phone can reach; a localhost URL on the computer is not enough. Changing the domain, protocol, or port uses different browser storage.

These commands are developer setup, not steps required of end users.

## Getting Started

1. Choose **Create Room** and optionally enter your participant name. Leave it empty to appear as **Аноним** (Anonymous). The room starts with one unnamed tree node.
2. Open **Biography** at the bottom right, choose **Edit**, and enter the person's name and details. The name can include a patronymic; **Surname** is the separate surname-at-birth field. Full names display the name first, followed by the surname.
3. Set the person's **Surname**, or leave it empty to use the father's surname; the form shows the inherited hint and source. The field is always personal, with no separate/shared toggle or sibling synchronization. **склонять** is on for a new surname, while saved settings are preserved. Historical shared values remain readable until that person's surname is edited; clearing the field restores paternal inheritance. Later married/changed surnames are not recorded.
4. Use **Add Relative** to select an existing parent/child or create a new person. For an existing person, **Choose** opens the full tree: browse or search, focus the candidate, confirm with the floating check, then press **Add** in the dialog. Browsing or canceling does not add a relationship or disturb your main tree view. Father/mother choices are disabled when that parent is already present; Add never replaces an occupied parent slot. **Брат/сестра**, immediately before the child option, always creates a new person with selectable sex, never chooses one from the tree. If both parents are known, they are copied; otherwise a direct sibling link groups the new person with the source. Parent assignment/removal applies to everyone connected by those direct links. A direct sibling X removes only that link and keeps assigned parents; once both parents become known, the direct links retire and normal computed sibling grouping takes over. Computed full-sibling relationships still have no sibling unlink button.
5. Use the avatar to open the photo album. Upload photos, choose an avatar, and add or reorder colored facts. Facts appear before the biography text.
6. Open **Participants → Invite Participants**, choose **Guest** or **Editor**, and copy a URL or show a QR code. A phone's regular camera can open the QR link. A plain room ID admits a guest. A first-time participant needs someone already online; after successful entry, the room and participant name are remembered. The app removes the invitation from the address bar on startup and does not put the room ID back after entry. Refresh restores an already saved room without an invitation in the URL. To invite someone, use **Copy URL** or QR in the app, not the browser address. Keep invitation links private: hiding the address does not revoke links already shared.
7. Select a different person, search by full birth name/year, or change the trunk mode to explore the tree. Arrows and Enter choose a search result, Escape dismisses suggestions. The toolbar stays in one compact row in either orientation. On phones, tap the search field at the right to replace the other tools with full-width search; its back arrow restores the row. Desktop search stays fixed-width. Collapse hides the whole toolbar, and the floating settings icon reopens it. Each generation scrolls independently. Hold the middle mouse button and drag to move the whole canvas in both directions without changing the levels' relative positions. Selecting a fully visible card keeps it at its pre-click screen position even when surrounding blocks reorder. Clipped selections autoalign; **Выровнять всё** beside the mode icon also intentionally recenters visible generations. Node/block order depends only on the current person and mode, not navigation history. Trunk modes change arrangement and centering, not the displayed relationships. In every mode, related same-generation branches try to keep the maternal side before the paternal side of their nearest shared descendant, reducing avoidable crossings without forcing identical mode orders. A single-line trunk follows the chosen parent repeatedly at each ancestor level; **Both Lines** places compatible mother/father cards together on every ancestral level and keeps ancestor and direct-descendant blocks in uninterrupted groups, moving intervening collateral blocks toward their related branch outside those groups. Children sharing either parent are grouped even when another person is selected; only genuinely incompatible higher-priority structural constraints can prevent that grouping. Only ancestral parental adjacencies may override order inside a sibling block. Canonical sibling order treats people without a birth date as older, then sorts known dates ascending; equal or missing dates sort by name, with ID breaking identical-name ties. In every trunk mode, the selected person's co-parents are kept nearby first, then their siblings' co-parents, by moving whole blocks without reordering siblings or adding partner highlighting. Use Ctrl+wheel for small fixed zoom steps, a two-finger pinch, or the toolbar's minus/plus buttons to zoom between a nominal 4 mm avatar minimum (currently 26%) and 200% without changing the levels' relative alignment. The minimum uses approximate browser units, not measured physical display size; high-density/OS-scaled displays may differ from real millimeters. The zoom group is **[−] [+] [percentage]**; click the percentage to return to 100%. Keyboard shortcuts: **1** selects the paternal line, **2** the maternal line, **3** both lines, and **Space** runs Align All. Desktop toolbar tooltips show these shortcuts and Ctrl+wheel zoom gestures. Text fields keep ordinary digit/space input.
8. Editors can optionally choose **This Is Me** in their biography to group their devices in the participant list. An explicit participant alias wins; with an empty alias, an active link uses the person's name without surname, otherwise **Аноним**. The participant tooltip includes the bound person's full birth name. Use **Change My Name** to change/clear your alias or release your own link, then choose **This Is Me** again on another person. Releasing appends a change; it does not rewrite history or release the other grouped actors' links. Guests have no binding action and remain separate participants even if an older version saved a binding for them.

Tap the room name for **Room Settings**, **Change Log**, **Change My Name**, and **Exit to Menu**. Exiting does not delete the room, history, or membership. To add a private cloud copy, see [Yandex Disk setup and privacy](docs/yandex-disk.md); no built-in OAuth login or configured client ID is provided.

## Permissions and Connection States

- The creator is an editor. Editors can change the tree and room name, invite either role, and promote guests from the participant list. Guests can read, change their own participant name, and invite guests. Person binding and cross-device person grouping are editor-only.
- Opening an editor invitation again does not promote an already saved guest. Demotion, participant removal, and access revocation are not supported.
- Roles assume a small trusted family group. They are not protection against modified clients. Do not distribute invitations to outsiders.
- The loading screen waits for initial verification. An unavailable service is not treated as proof that nobody else is online.
- **Open Local Copy** is an explicit unsynchronized mode for an accepted, saved room. It is not a successful network exchange and cannot admit a first-time participant.
- Changes appear immediately while local saving can still be pending. Save failures remain visible; retry them before leaving. **Exit to Menu** and room switches wait for saving; closing a dialog or browser tab is not a save action.
- After an update, reload all open tabs on every device. Older clients without explicit sibling links, personal-surname inheritance, complete change-history, and editable participant-identity support cannot connect to the current tree editor, even in an empty room. A room that has used Disk also requires Disk-aware clients. Existing saved history remains readable without automatic rewriting.

## Limits and Privacy

- Without a connected and confirmed Yandex Disk copy or another saved device, clearing site data, private browsing, or losing a device can remove the only remaining copy. Disk is optional; its status is separate from local saving and WebRTC. Tokens are plaintext local credentials shared with trusted editors, scoped to an application folder rather than one tree. See [Disk setup and privacy](docs/yandex-disk.md).
- Surnames are limited to 200 Unicode code points. The **склонять** checkbox is on by default for a new surname, while saved settings are preserved: it literally appends `а` for a woman and `ы` for a plural block label. This is not grammatical inflection; turn it off for unchanged or already-complete spellings. Names are not automatically split into name/patronymic/surname.
- Photos support PNG/JPEG/WebP, are resized to at most 1024 px, and must fit within 700 KiB after processing. Input files are limited to 8 MiB. The current full-history limit is 8 MiB; browser storage quotas can be reached sooner. Deleting a photo does not free its historical storage.
- Public connection services provide no availability guarantee. Some networks may block them. Do not treat the current public-service setup as a hardened private family archive.
- Cold-starting the web app without internet depends on cached application files; full offline/PWA installation is not implemented.
- Native builds and physical-phone behavior are not established by the recorded browser checks. The Android SDK and full Windows desktop toolchain were unavailable in the verification environment.
- Old ephemeral text-demo rooms cannot be recovered automatically after closing. Existing saved history is retained, but old demo text is not automatically turned into a person's biography.

## Documentation

- [Architecture](docs/architecture/README.md) — contributor documentation, organized by subsystem.
- [Verification records and manual checks](docs/verification.md) — dated results, benchmarks, and limitations.
- [Tree editor guide](docs/tree-editor.md) — entry point to the tree-editor subsystem documentation.
- [Yandex Disk setup and privacy](docs/yandex-disk.md) — optional cloud copy, manual token setup, sharing, and unlink/revocation limits.
- [Future storage and synchronization](docs/future-storage-and-sync.md) — remaining agreements, distinct from the implemented Disk subset.
- [Interface palette reference](docs/future-interface.md) — colors and contrast guidance.
- [Development rules](CLAUDE.md) — project workflow and modularity requirements.
