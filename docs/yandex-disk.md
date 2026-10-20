# Optional Yandex Disk Copy

[Project overview](../README.md) · [Contributor architecture](architecture/yandex-disk.md)

MyTree can keep an additional copy on the owner's Yandex Disk. Editors can exchange saved changes even when they are not online together. Optional Disk-enabled invitations also allow a first visit without another participant online: editors receive shared access, and guests receive a public read link only after explicit folder publication. Local saving and live WebRTC exchange continue independently of Disk availability.

## Connect

1. Use the owner's Yandex account and obtain an OAuth token **outside MyTree**, with the application-folder permission `cloud_api:disk.app_folder`. There is no configured OAuth client ID or built-in Yandex login/token-issuance flow in this repository. A suitable OAuth application/grant must be arranged separately; MyTree cannot generate the token for you. Do not substitute an unnecessarily broad full-Disk token.
2. As a room editor, press the unconnected cloud icon immediately left of participants (or open the room-title menu → **Настройки комнаты**), then **Подключить Яндекс Диск**.
3. Paste the token into **OAuth-токен**, press **Подключить**, and confirm that application-folder access will be shared with the room's editors, not guests.
4. Keep the room open until the cloud icon immediately left of the participants shows a **green check**. Neutral arrows mean synchronization is pending/in progress or access is awaited; a red cross means an error. Hover the cloud (or long-press on touch) for the full status/error; press it to request another exchange without opening settings. The settings' **Синхронизировать** action remains available. Local saving or an online-participant count alone does not confirm a cloud copy.

Only an editor can connect an unbound room. Other editors receive access over an eligible editor-to-editor WebRTC connection or an explicitly shared editor invitation; their devices retain the credential for later asynchronous exchange. If access is awaited, obtain it from an editor who has the matching credential. Guests see the same cloud icon as read-only status (long-press for details), but cannot enter an editor token, upload/manual-sync, or unlink Disk; a guest with a public invitation can receive read-only updates automatically.

## Invite without an online participant

This still requires Internet access to Yandex Disk. It removes the need for another participant to be online at the same time, not the need to read and validate a saved cloud history.

1. Confirm that the intended room is connected to Disk and its saved copy is available. Open **Пригласить участников** and select **Редактор** or **Гость**.
2. Choose **Скопировать URL**, **Скопировать код**, or **Показать QR**. For an editor, confirm **Передать доступ редактору?**: the invitation contains the application's Disk-folder key and must go only to a trusted editor.
3. For a guest, MyTree reuses an existing public link when possible. First publication asks **Разрешить гостям доступ к Диску?**. It shares only this room's active binding folder, not other trees, but exposes its **full saved history, including deleted records and historical photos**. Confirm only if that is acceptable. MyTree confirms the current saved copy before publishing; a guest cannot publish a folder or receive the editor token.
4. Send the complete resulting URL/code/QR through a trusted channel. On the web, the additional access is in the URL fragment, not the application server's query. Native QR/copy-code data includes the same access in JSON. Copying just the displayed room ID does **not** carry Disk access and still enters as a guest through an online participant.

The recipient validates the room, active binding, history, and binding owner's explicit editor role, then saves history/profile/access before accepting membership. Invalid or unavailable Disk data is not silently converted into successful entry or an empty tree. Retry, or use ordinary online admission. Long invitations may exceed QR capacity; use URL or code copying instead. An explicit editor invitation can promote an already accepted guest; the editor role must be saved before its matching editor token is retained. An unaccepted profile left by a failed admission keeps its original role until accepted.

After Disk entry, the status distinguishes **История загружена с Диска · онлайн-сверка продолжается** from completed live peer verification. The app continues looking for peers. This is the validated copy available on Disk, **not a guarantee of the newest global version**: another offline editor may still have changes. A saved editor/public-link guest can recheck Disk on reopening. Guests poll read-only updates without uploading their local alias/metadata; those can still travel through ordinary room synchronization.

Plain IDs, old links, and invitations without Disk access remain supported, but a first-time participant using them still needs an online room participant. A saved member can choose its accepted local copy when verification is unavailable; that choice is not a successful sync.

## Obtain a scoped token

Follow Yandex's [Disk API access guide](https://yandex.ru/dev/disk-api/doc/ru/concepts/quickstart) and [browser token instructions](https://yandex.ru/dev/id/doc/ru/tokens/debug-token). Register an OAuth application, select only **access to the application folder** (`cloud_api:disk.app_folder`), and obtain its token while signed in to the intended Disk account. The documented verification redirect is `https://oauth.yandex.ru/verification_code`; the browser-token authorization URL uses `https://oauth.yandex.ru/authorize?response_type=token&client_id=YOUR_APPLICATION_ID`.

Keep the resulting token private. Share access only deliberately with trusted editors through the confirmed invitation/room flow; do not post the token or its invitation in public chat, commit it, or put it in the application build. MyTree needs the token, not the OAuth application's client secret. Registration and authorization remain actions performed by the account owner, not by this implementation or its tests.

## Privacy

- Trust every invited editor. The token is shared access, not a per-editor password or cryptographically enforced room permission. An editor can copy or pass it on. An editor invitation/QR/code contains that token; base64 encoding is not encryption.
- Application-folder access covers the issuing OAuth application's folder, **not just one tree**. Other rooms under that same application folder may be accessible with the same editor token. Guest publication is narrower: only the selected binding folder is shared, after confirmation.
- Editor credentials and guest public links are stored separately from history and each other, but in **plaintext** browser storage/native files. Protect the browser profile/device and the complete invitation. Keep access-bearing URLs/QR/code out of public screenshots, logs, source control, and builds. The address fragment is removed at app startup, but already copied links are not revoked.
- A public link can be forwarded and exposes saved immutable history, including deleted records; it is not a redacted view of only the current tree. Deleting a person/photo does not remove the historical bytes. Do not enable guest publication if that disclosure is unacceptable.
- Guests have no editor Disk token, cloud upload rights, or **Это я** person-binding action. With retained public access they receive read-only Disk updates; ordinary WebRTC remains available.

## Unlink or revoke

The editor who connected Disk can choose **Отвязать Яндекс Диск**. Another editor linked with **Это я** to the same durable tree person can also act as that owner. Other editors retain status/manual-sync access but no unlink action.

The confirmation says **Файлы на Диске сохранятся.** Unlinking saves a room-history change; files remain on Disk. If offline, MyTree retains the matching credential to retry sending that final detach after reconnection/reopening. A locally saved detach is not yet confirmation that every other device or Disk has received it.

Once the room has no active Disk binding, an editor can connect a replacement even if the old detach is still pending or its token is no longer valid. Old retries/errors remain separate: a successful new connection does not confirm or erase them. Later edits for the new connection are not sent to the old one as part of that final delivery.

**Unlinking is not OAuth revocation or removal of public sharing.** To invalidate editor-token access already copied to other devices, revoke the application's grant/token manually in Yandex account access settings; revoking also interrupts their synchronization. A previously published guest folder remains public until you remove its sharing in Yandex Disk separately. Revoking the editor token or deleting a local public-link pointer does not itself revoke that public link, and neither action recalls history someone already downloaded.

## Limits and troubleshooting

- Local-save errors and Disk errors are different. Retry a local saving failure before leaving; keep unsent local data when Disk is unavailable. Do not rely on closing a tab to save or upload it.
- The existing 8 MiB history limit and photo limits still apply. Photos remain part of history; deleting one does not reclaim its historical storage. Disk is not an unlimited archive or a separate media library.
- If a token is rejected or lacks application-folder access, check its grant externally. MyTree has no built-in reauthorization screen. Browser/provider failures and quotas can also prevent confirmation; a file may already be on Disk while its verification download fails, so an attempted upload is not a confirmed copy. The client suppresses the application referrer for Disk requests and follows anonymous download redirects; updating/reloading the app is necessary to use this browser fix.
- This guide describes the implemented integration, not a claim that a live Yandex account/upload, token issuance, or every browser's CORS behavior has been verified. See [verification records](verification.md) for dated evidence and limitations.
