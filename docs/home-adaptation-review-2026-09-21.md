# Homepage compatibility review — 2026-09-21

Scope: homepage changes since `db8bcbc1eae711eea8a2a076128c40276c75e953`, plus the fixes from this review. Requirements: show content from more configured providers, preserve source identity, and keep category/year/region browsing working. Platforms: shared iOS/macOS code; execution verified on macOS.

## Standards

No hard repository-standard violations were identified. Three behavior/design findings were confirmed and fixed:

1. Display limits also limited provider availability checks. Homepage display still starts with four categories, but an empty result now checks remaining categories; recovery also checks all categories.
2. Popular sorting was treated as mandatory. Empty/failed popular queries now retry default order while retaining year/region filters. The section reflects the actual order used.
3. Source keys alone were used for request/cache identity. Full source values now distinguish changed endpoints/extensions; recovery cannot return to a provider from an old configuration.

Follow-up review found no new severe regression. Loading state now covers the additional category scan.

## Spec

Four original requirement gaps were confirmed and fixed:

1. Later populated categories were skipped, incorrectly treating a selected source as unavailable.
2. Providers without working popular sorting lost their recommendation content.
3. Type 4 homepage supplementation omitted `extend`, although the initial request and category request included it. The same resolved extension is now reused.
4. CatVod A→B→A switching on one route skipped A initialization. Initialization now tracks the active configuration per route.

Follow-up review found one further edge case, also fixed: failed B initialization may already mutate route state. The previous initialization record is invalidated before attempting B, so returning to A reinitializes it.

No scope creep was identified by the requirements reviewer.

## Additional compatibility fixes

- XML homepage/list parsing uses XMLParser rather than field-order-dependent regular expressions. It reads homepage videos, CDATA, escaped text, nonnumeric IDs, year/region, and entries without poster/remarks. External entity resolution is disabled. XML detail/playback parsing is outside this change.
- JSON CMS `videolist` failures/empty results retry `detail`, retaining category, page and filters.
- Legacy CatVod initialization supplies an empty guest Bilibili cookie; no user credentials are sent to third-party scripts.

## Verification

- macOS regression suite: 45 tests passed. Tests cover source recovery, category grouping, browsing filters, protocol parsing, extension propagation, source identity and sorting fallback.
- Gateway suite: 54 tests passed, including guest initialization, A→B→A, and failed initialization recovery.
- Live probes covered 29 CatVod providers and 15 JSON/XML CMS providers. These are point-in-time network observations, not guarantees of continuing availability.
- CatVod baseline: five providers returned category content (Huya, Douban, new 6V, 360, movie harbor). After fixing guest initialization, Bilibili returned 40 categories and 20 category videos; previously it threw while accessing an undefined cookie.
- Eleven of fifteen CMS providers returned video data in at least one action. Some rejected `videolist` while supporting `detail`.
- Application-level live checks passed for Sony XML (61 categories/20 videos), Jisu (42/20), Jianan (19/20), and Baidu (54/20). Counts can change remotely.
- Permanent fixtures use synthetic data. Temporary live tests and supplied configuration files are not included in the repository.

## Remaining limits

Some providers still return empty data, time out, or return a suspension page instead of JSON (observed for CNTV). This review does not establish whether each empty result is an upstream outage or a defect inside its third-party script. Android-only JAR providers still require a compatible worker; these fixes do not turn them into native macOS providers. No iOS device/simulator execution was performed.

Summary: Standards — 3 findings fixed (most consequential: truncated availability checks); Spec — 4 original findings and 1 follow-up edge case fixed (most consequential: lost provider initialization state).
