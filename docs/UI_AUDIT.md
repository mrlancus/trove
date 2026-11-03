# UI audit

_From the simulator screenshots of the UI tests (`scripts/ci-app-tests.sh`, branch `ci-logs-tests`,
`shots/`), run 137 at 203fbfd on 2026-11-03: iPhone SE (3rd generation), iPhone 16 Pro Max, iPad mini
(A17 Pro), iPad Air 13-inch (M2), newest iOS on the runner, default Dynamic Type, with the generated
`small` vault (2,013 items). Simulator screenshots show layout, not speed. Pictures are in `docs/ui-audit/`._

The first run's tests looked for the generated notebook on the first screen, which is the library's
collection list on iPhone and Recent on iPad, so it only reached the first screens. The tests now open
Notes, Sketches, search and Develop. The next run's screenshots extend this audit (largest Dynamic
Type, Split View and the Mac's three window sizes still to add).

## Findings

| # | Where | What | Seen in | Fix | Status |
|---|---|---|---|---|---|
| U1 | iPad, Mac: Recent (the first screen) | A library of 2,013 items opened to "Nothing here yet. Share things to Trove…", because Recent is only the last 14 days. Anyone who hasn't saved anything for two weeks is told their library is empty. | `ipad-13-landscape-library.jpg` | The empty state says "Nothing in the last two weeks" and points to the sidebar and search when the library isn't empty. | fixed (MainView `emptyState`) |
| U2 | iPhone: Library tab | The tab opens on the list of collections (Recent, Pinned, To Read…), not on anything you saved: one more tap to see your things, on the device you use one-handed. | `iphone-se-library.jpg` | Opens on Recent, with the collections one tap back (Library ‹). | fixed (PhoneViews `libraryPath`) |
| U3 | iPhone SE: Library tab | The floating tab bar covers the "Folders" header; the last row of the first section sits right against it. | `iphone-se-library.jpg` | Not a bug: content scrolls under the floating tab bar, as iOS 26 does everywhere; the rows are reachable. | no change |
| U4 | iPhone SE: top bar | Four round buttons (Settings, ⋯, New sketch, +) float over the large title; Settings is rarely used but takes a top spot. | `iphone-se-library.jpg` | Settings into the ⋯ menu; keep + and New sketch. | proposed |
| U5 | Search, iPhone and iPad | Results for links show only the domain and age, so ten "example.com · 4 yr. ago" rows look alike. | `iphone-se-search.jpg`, `ipad-13-search.jpg` | Not a bug: rows already show the matching passage (`searchSnippets`); the generated links have no text, only titles. trove-gen links should get a summary so the next screenshots show it. | test data |
| U6 | iPad: search | With results on the left, the right side still says "Pick something / Or press ⌘N…": a hint aimed at an empty library. | `ipad-13-search.jpg` | Says "Pick a result" while searching. | fixed (MainView `columnsSplit`) |
| U7 | iPhone landscape | The landscape screenshot comes out sideways and doesn't show a usable layout: the tab bar sits along the left, the content is cut off. Unclear whether it's the simulator capture or the layout; needs a check on your iPhone. | `iphone-se-landscape.jpg` | Check on a device (TEST-RESP-001). | to check |

## Design direction

Decision 16 (A Glass, glass on floating controls only). The iOS 26 build already uses system Liquid
Glass for the tab bar and toolbars (seen in every screenshot). The restyle puts Trove's colours, type
and spacing into shared tokens (`App/Sources/Views/Theme.swift`: accent, radii, spacing, reading width) so B
or C can be switched in one place. `card`, `glass` and Develop use them now; other views move onto them
as they're touched, one screen per commit, each checked against the next run's screenshots.
