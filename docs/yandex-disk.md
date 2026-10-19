# Optional Yandex Disk Copy

[Project overview](../README.md) · [Contributor architecture](architecture/yandex-disk.md)

MyTree can keep an additional private copy on the owner's Yandex Disk. Editors who have already joined can exchange saved changes through it even when they are not online together. Local saving and live WebRTC exchange continue independently of Disk availability.

## Connect

1. Use the owner's Yandex account and obtain an OAuth token **outside MyTree**, with the application-folder permission `cloud_api:disk.app_folder`. There is no configured OAuth client ID or built-in Yandex login/token-issuance flow in this repository. A suitable OAuth application/grant must be arranged separately; MyTree cannot generate the token for you. Do not substitute an unnecessarily broad full-Disk token.
2. As a room editor, press the unconnected cloud icon immediately left of participants (or open the room-title menu → **Настройки комнаты**), then **Подключить Яндекс Диск**.
3. Paste the token into **OAuth-токен**, press **Подключить**, and confirm that application-folder access will be shared with the room's editors, not guests.
4. Keep the room open until the cloud icon immediately left of the participants shows a **green check**. Neutral arrows mean synchronization is pending/in progress or access is awaited; a red cross means an error. Hover the cloud (or long-press on touch) for the full status/error; press it to request another exchange without opening settings. The settings' **Синхронизировать** action remains available. Local saving or an online-participant count alone does not confirm a cloud copy.

Only an editor can connect an unbound room. Other editors receive access over an eligible editor-to-editor WebRTC connection; after that, their devices retain the credential for later asynchronous exchange. If the status says access is awaited, an editor with the credential must be online to pass it on. Guests can see connection status but cannot enter a token, synchronize with Disk, or unlink it.

A first-time participant still joins through an online room participant. The room link/QR does not contain the token, and Disk does not provide a public guest folder or replace admission. A saved editor can open its accepted local copy and synchronize with Disk without another peer when a valid credential is already stored.

## Obtain a scoped token

Follow Yandex's [Disk API access guide](https://yandex.ru/dev/disk-api/doc/ru/concepts/quickstart) and [browser token instructions](https://yandex.ru/dev/id/doc/ru/tokens/debug-token). Register an OAuth application, select only **access to the application folder** (`cloud_api:disk.app_folder`), and obtain its token while signed in to the intended Disk account. The documented verification redirect is `https://oauth.yandex.ru/verification_code`; the browser-token authorization URL uses `https://oauth.yandex.ru/authorize?response_type=token&client_id=YOUR_APPLICATION_ID`.

Keep the resulting token private. Do not send it in chat, commit it, or put it in the application build. MyTree needs the token, not the OAuth application's client secret. Registration and authorization remain actions performed by the account owner, not by this implementation or its tests.

## Privacy

- Trust every invited editor. The token is shared access, not a per-editor password or cryptographically enforced room permission. An editor can copy or pass it on.
- Application-folder access covers the issuing OAuth application's folder, **not just one tree**. Other rooms stored under that same application folder may be accessible with the same token. No folder is published by MyTree.
- The token is stored separately from room history, but in **plaintext** browser storage or native credential files. Protect the browser profile/device. Do not put a token in invitations, QR codes, screenshots, logs, source control, or public builds.
- Guests have no Disk token and no **Это я** person-binding action. They receive the tree through ordinary room synchronization.

## Unlink or revoke

The editor who connected Disk can choose **Отвязать Яндекс Диск**. Another editor linked with **Это я** to the same durable tree person can also act as that owner. Other editors retain status/manual-sync access but no unlink action.

The confirmation says **Файлы на Диске сохранятся.** Unlinking saves a room-history change; files remain on Disk. If offline, MyTree retains the matching credential to retry sending that final detach after reconnection/reopening. A locally saved detach is not yet confirmation that every other device or Disk has received it.

Once the room has no active Disk binding, an editor can connect a replacement even if the old detach is still pending or its token is no longer valid. Old retries/errors remain separate: a successful new connection does not confirm or erase them. Later edits for the new connection are not sent to the old one as part of that final delivery.

**Unlinking is not OAuth revocation.** To invalidate access already copied to other devices, revoke the application's grant/token manually in Yandex account access settings. Existing editor copies may continue to work until that revocation; revoking also interrupts their synchronization.

## Limits and troubleshooting

- Local-save errors and Disk errors are different. Retry a local saving failure before leaving; keep unsent local data when Disk is unavailable. Do not rely on closing a tab to save or upload it.
- The existing 8 MiB history limit and photo limits still apply. Photos remain part of history; deleting one does not reclaim its historical storage. Disk is not an unlimited archive or a separate media library.
- If a token is rejected or lacks application-folder access, check its grant externally. MyTree has no built-in reauthorization screen. Browser/provider failures and quotas can also prevent confirmation; a file may already be on Disk while its verification download fails, so an attempted upload is not a confirmed copy. The client suppresses the application referrer for Disk requests and follows anonymous download redirects; updating/reloading the app is necessary to use this browser fix.
- This guide describes the implemented integration, not a claim that a live Yandex account/upload, token issuance, or every browser's CORS behavior has been verified. See [verification records](verification.md) for dated evidence and limitations.
