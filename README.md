# OshiReader (Otterpia)

OshiReader is a native SwiftUI iOS app that tracks favorite creators, idols, and topics across supported Japanese media sources and presents matched items in a feed.

The app is local-only: ingestion runs on-device in `ios-swift/OshiReader/IngestionService.swift`, and feed data is stored locally. There is no backend service or scheduled GitHub poll in this repository.

## Project Structure

```text
oshireader/
├── ios-swift/          # Native iOS SwiftUI application
└── mobile/             # Mobile scraper/package experiments
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
| 5channel | Google News site-filtered results |
| Girls Channel | Google News site-filtered results |
| Togetter | Curation page scraping |
| ModelPress | ModelPress article search |
| YahooNews | Yahoo News article search through a text mirror for EEA-safe access |
| News/RSS | Curated Japanese entertainment RSS feeds |

Watch terms support aliases. Ingestion searches the primary keyword and each alias while storing matches against the original watch term.
