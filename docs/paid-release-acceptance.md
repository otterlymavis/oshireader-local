# OshiReader Local paid release acceptance

Use this checklist before enabling `PUSH_SUBSCRIPTION_PRODUCT_IDS` for a release candidate. Automated simulator tests prove client logic and API compatibility; they do not prove StoreKit, a deployed entitlement, APNs delivery, or iOS background execution.

## Evidence record

Record one dated acceptance reference containing:

- TestFlight build number and tested commit;
- deployed backend URL and commit;
- device model, iOS version, and resolved APNs environment;
- sandbox subscription product and lifecycle scenario;
- result and evidence location for every section below.

Do not record App Store credentials, APNs tokens, device secrets, keywords, feed contents, or authenticated response bodies.

Start from [the paid release evidence template](paid-release-evidence-template.md). The approved initial catalog is exactly:

- `com.otterpia.oshireader.hosted.monthly`
- `com.otterpia.oshireader.hosted.yearly`

Both products use a backend limit of 10 guaranteed-push terms. Keep the repository default catalog empty until the completed evidence passes this gate.
The machine-readable source of truth is [`ios-swift/config/paid-catalog.json`](../ios-swift/config/paid-catalog.json); release tooling reads product IDs from it instead of maintaining another copy.

`fastlane ios paid_acceptance_beta` reads the latest TestFlight build for the current marketing version and archives the next number. For an archive-only candidate, set an unused number explicitly, for example `PAID_ACCEPTANCE_BUILD_NUMBER=10 fastlane ios paid_acceptance_archive`.

After the seven-day soak, calculate the minimum gross price with:

```bash
python3 scripts/paid_catalog_cost_gate.py \
  --compute 0 --database 0 --egress 0 \
  --proxy 0 --apns 0 --diagnostics 0
```

Replace the zeroes with incremental EUR costs for the representative account. Use `--monthly-price` to make the command fail when a proposed Apple price is below the gate.

## Free and local-first behavior

- With the paid catalog disabled, confirm purchase and hosted controls are absent and ordinary refresh makes no paid-backend requests.
- Confirm on-device ingestion, local storage, manual refresh, background refresh, and best-effort local alerts still work.
- With an active subscription, confirm local ingestion still runs and hosted results merge without replacing or duplicating Local items.
- With the device offline or the backend unavailable, confirm Local refresh and Local feed access continue.

## Purchase and hosted client matrix

- Purchase and restore each configured product, then confirm the backend reports the correct active entitlement and push-term limit.
- Confirm active Local-profile terms are copied to the hosted service without importing unrelated backend terms into the profile.
- Confirm hosted feed continuation completes, source status loads on demand, hiding a hosted item remains hidden locally and is muted remotely, and pending “Notify Now”/“Clear Notification” actions behave as labelled.
- Confirm free, inactive, unconfigured, and opted-out states do not call paid-only feed, status, mute, notification-control, or diagnostic endpoints.

## Notification ownership and recovery

- Verify APNs registration uses the environment in the signed provisioning profile and that the backend marks the registration verified.
- With active delivery and a backend-bound term, confirm one server alert is delivered and no Local duplicate is scheduled.
- Remove or invalidate registration and confirm Local alerts immediately resume ownership.
- Exercise the device-credential recovery paths for an authenticated 401 and a background-poll 404; confirm successful re-registration retries once within the original deadline.
- Confirm token rotation or a stale cleanup completion cannot clear a newer token, and that active entitlement repairs registration after overlapping cleanup.
- Test a terminated-app silent/visible push, preview merge, Open, Save, and notification-service receipt reporting.

## Entitlement lifecycle

- Verify purchase and restore for each configured product, monthly/yearly switching, renewal, expiration, and refund/revocation.
- Confirm an authoritative inactive response enables Local notifications before APNs cleanup begins.
- Confirm successful 204/404 cleanup clears only the matching registration; failed cleanup retains it for a later retry.
- Renew after cleanup and confirm APNs registration, hosted polling, and server notification ownership resume without rebuilding Local terms or feed data.

## Optional hosted diagnostics

- Confirm diagnostics consent is off on a fresh install, appears only for an active paid entitlement, survives entitlement expiry, and returns after renewal.
- While opted out, trigger an eligible hosted-feed or scheduled term-sync failure and confirm no diagnostic request is sent.
- While opted in, confirm an eligible failure submits only bounded app/build, APNs environment, counts, platform IDs, operation, and sanitized category fields.
- Confirm the report excludes keywords, aliases, URLs, item data, custom feeds, credentials, device identifiers, raw bodies, and localized error text.
- Confirm successful uploads are throttled per profile for six hours, failed uploads remain retryable, and reporting never changes feed results or Local diagnostics.

## Release-gate mapping

For an enabled catalog, dispatch `OshiReader Local paid-backend release gate` with:

- `physical_push_test=passed` after the physical push and ownership checks;
- `receipt_reporting_test=passed` after notification-service receipt proof;
- `sandbox_billing_matrix=passed` after all configured purchase lifecycle cases;
- `paid_client_matrix=passed` after hosted features, recovery, lifecycle, and diagnostic checks;
- `acceptance_evidence` set to the dated TestFlight/device record.

Keep the catalog disabled if any required result is pending. For a free-only candidate, leave product IDs and evidence empty and mark every paid acceptance input `not-required`.
