# OshiReader (Otterpia)

OshiReader is a native SwiftUI iOS app that tracks favorite creators, idols, and topics across supported Japanese media sources and presents matched items in a feed.

The core app is local-only: ingestion runs on-device in `ios-swift/OshiReader/IngestionService.swift`, and feed data is stored locally. Best-effort alerts and background refresh are free and run on the device; iOS controls when background work runs.

Optional paid products add hosted polling, backend feed refresh, and guaranteed push. They never replace on-device ingestion or local storage: every refresh still runs the free local collectors and safely merges any paid backend results. When `PUSH_SUBSCRIPTION_PRODUCT_IDS` is empty, purchase controls and every backend synchronization path stay disabled.

The Local catalog offers monthly and yearly subscriptions for up to 10 watch words, plus a non-consumable one-time plan for 1 watch word. A release is not ready until App Store Connect contains all three products and the hosted backend maps each product ID to the same watch-word limit; lifetime purchase, restore, subscription coexistence, and fallback after subscription expiry must be verified together.

Paid release candidates must pass the automated contract gate and the separate TestFlight/device checklist in [Paid release acceptance](docs/paid-release-acceptance.md). Simulator and build results do not substitute for sandbox purchase, entitled backend, physical-device APNs, or real background-execution proof.

## Project Structure

```text
oshireader/
└── ios-swift/          # Native iOS SwiftUI application
```

## Native iOS App

The SwiftUI app lives in `ios-swift/` and targets iOS 17+.

### Setup

```bash
cd ios-swift
xcodegen generate
open OshiReader.xcodeproj
```

Select a simulator or device in Xcode and run the `OshiReader` scheme.

The app is a universal iPhone and iPad build. The schemes select build configurations only:

| Scheme | Configuration |
|---|---|
| `OshiReader Local` | `Debug` |
| `OshiReader Staging` | `Staging` |
| `OshiReader Production` | `Release` |

## Supported Sources

On-device ingestion currently reads these sources:

| Platform | Source |
|---|---|
| YouTube | Search scrape fallback |
| NicoNico | NicoNico snapshot search API |
| TVer | TVer keyword search APIs |
| Note | Public tag RSS feeds |
| Ameblo | User-configured official RSS feeds, with Google News fallback when none are configured |
| AERA dot. | Dedicated official RSS feed |
| Hochi | Dedicated official RSS feed |
| Real Sound | Dedicated official Atom feed |
| CinemaCafe | Dedicated official RSS feed |
| Billboard Japan | Dedicated official RSS feed |
| Sponichi | Google News site-filtered fallback; official RSS endpoint deferred |
| Natalie | Dedicated music and TV RSS feeds |
| BARKS | Dedicated official RSS feed |
| 5channel | Direct HTTPS 2ch.sc subject/DAT scans with a rotating local subject index; Google News is the empty-result fallback |
| Girls Channel | Google News site-filtered results |
| ModelPress | ModelPress article search |
| YahooNews | Yahoo News article search through a text mirror for EEA-safe access |
| News/RSS | Curated Japanese entertainment RSS feeds |

Watch terms support aliases. Ingestion searches the primary keyword and each alias while storing matches against the original watch term.

## Paid parity boundary

OshiReader Local includes the ordinary paid-user backend functions from OshiReader+: StoreKit entitlement verification, hosted term copies and feed continuation, hosted source status, guaranteed push, pending notification controls, hosted item muting, APNs credential recovery and cleanup, and opt-in bounded client diagnostics. Local profiles, feed data, ingestion, and fallback alerts remain authoritative on the device.

The app intentionally does not expose server-global source credentials, admin polling and maintenance, APNs administration, or automatic backend-to-Local term importing. Those are administrative/server-ownership surfaces rather than paid end-user features.
