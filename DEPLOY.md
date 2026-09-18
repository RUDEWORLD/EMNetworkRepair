# EM Network Repair — release / deploy runbook

Same auto-update flow as AlphaCaps:
- App checks `https://raw.githubusercontent.com/RUDEWORLD/EMNetworkRepair/main/update.json` on
  launch (silent) and via the footer's **Check for Updates** button.
- `update.json` → `{ "version": "X.Y.Z", "url": "<GitHub release zip>" }`.
- If newer, the app asks, then downloads the zip → verifies it's signed by team
  **EGET63XBLQ** with bundle id **com.rudeworld.emnetworkrepair** at the advertised
  version → swaps itself in place → relaunches.

Repo (created on first deploy): **github.com/RUDEWORLD/EMNetworkRepair** (public).
Version string = `MARKETING_VERSION` + `.` + `CURRENT_PROJECT_VERSION`  → "1.0.0" today.

## You: cut a new version

1. **Bump the version** in Xcode ▸ target ▸ General (or Build Settings):
   - patch: `CURRENT_PROJECT_VERSION` 0 → 1  ⇒ 1.0.1
   - minor/major: `MARKETING_VERSION` 1.0 → 1.1  (and reset build to 0) ⇒ 1.1.0
   Keep every component numeric — "1.0.1", never "1.0.1b".
2. **Archive & notarize:** Product ▸ Archive ▸ Distribute App ▸ **Direct Distribution**.
   Wait for "Ready to distribute" (notarization done), then **Export** the .app.
3. **Zip it into RELEASES**, keeping the bundle as the top entry:
   ```
   ditto -c -k --keepParent "EM Network Repair.app" \
     "RELEASES/vX.Y.Z/EMNetworkRepair.zip"
   ```
   (Folder name `vX.Y.Z` matches the version — same as AlphaCaps/Releases.)
4. Tell me: **“deploy vX.Y.Z”**.

## Me: deploy

Given `RELEASES/vX.Y.Z/EMNetworkRepair.zip`, I run (first deploy also creates the repo):

```
# first time only:
gh repo create RUDEWORLD/EMNetworkRepair --public --source . --remote origin --push

# every release:
gh release create vX.Y.Z "RELEASES/vX.Y.Z/EMNetworkRepair.zip" \
  --repo RUDEWORLD/EMNetworkRepair --title "vX.Y.Z" --notes "…"
# bump update.json to X.Y.Z + the new asset URL, then:
git add update.json && git commit -m "update.json → X.Y.Z" && git push
```

Within a minute (GitHub CDN), every installed copy sees the update on next launch or
on **Check for Updates**.

## One-time note
The installed app must live somewhere the user can write (e.g. /Applications or
~/Applications) for the in-place swap to work; if it can't, the updater asks for an
admin password. The app is un-sandboxed + hardened-runtime + Developer-ID signed —
required for both the self-update and the core repair function.
