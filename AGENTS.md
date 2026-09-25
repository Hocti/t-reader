# AGENTS.md

Android-first EPUB reader named T Reader. Application id `riverine.studio.epub`. Flutter UI, chapter HTML in a WebView. Cloud TTS, lookup of Chinese words, and Android watch control are not in the current build. English lookup, search, tags, system TTS, and Google Drive sync of per-book reading data are. Cloud TTS is shown and cannot be selected.

## Source of truth

`docs/features.html` is the feature spec, written in Traditional Chinese for the user to edit. The MVP follows that file. If the user edits the HTML, follow the HTML, then update this file in the same session.

If this file and `docs/features.html` disagree, follow the HTML, then update this file in the same session.

## Current phase

Bookshelf, settings, and the full-screen reader. The reader pages one chapter at a time. It has layout, a table of contents, highlights, tags, whole-book search, one temporary bookmark, an English lookup sheet, and system TTS. Speech can be Cantonese (default), Mandarin, or English. Cloud TTS is on the menu and cannot be selected. The top bar's 放書籤 button moves the one temporary bookmark to the current page. On the page that holds it, the button reads 抽起書籤 and removes it. No bookstore and no remote backend of our own. Sync uses only the user's Google Drive. `book_server.dart` only serves the open book to the WebView on this device.

Accepted and implemented:

- Three screens: bookshelf, reader, settings. No tab bar. A folder picker is an extra page opened from settings. The table of contents is a panel inside the reader.
- Settings opens only from one top-right icon on the bookshelf.
- Settings includes multiple local book directories, theme, interface language, lookup speech, keep the screen on while reading (default off), open the last book at start (default on), the reading data folder, Google Drive, hidden books, and the current version. Hidden books show only as a count. The count opens a page that lists each one with its own restore button.
- Interface copy lives in `assets/i18n/strings.csv` (`key`, `zh-Hant`, `en`). Default language is Traditional Chinese. Add a column to add a language.
- Themes: white e-ink (default, pure black and white), black e-ink, slightly colored light, slightly colored dark. No follow-system. The app is not only for e-ink.
- Books are `.epub` files or an unzipped folder that contains a `mimetype` file. The folder is one book. First directory level only. An epub and an unzipped copy are two books.
- An `.epub` opened from another app (`ACTION_VIEW`, `application/epub+zip` or a `.epub` file path) opens in the reader and is kept in `openedFiles` in `library_v1`, outside the book folders. `MainActivity` answers `epub_reader/open` `initial` and pushes `open` for later intents. It uses the real path when this app can read it, otherwise it copies the book to the app's `files/opened/`. A missing opened file is left off the shelf.
- The bookshelf's search icon opens a filter row: title or file name, case and spaces ignored, not saved. List view has a 48 × 72 cover on the left, filled and cropped.
- The system back button closes the top layer first: lookup, panel, speech menu, selection, seek bar, then the shelf search. Partial panels (contents, layout, lookup) close on a tap outside them.
- The reader loads one spine item at a time. Do not render the whole book. Pages are the laid-out pages of that chapter. A single image fits one screen until the user zooms.
- More than one bookmark and watch controls are not in scope yet. Tags are the long-lived places.
- A long press on an English word opens the lookup sheet on the bottom half. Its top row never scrolls: the word, Traditional Chinese (up to three lines), a speak button, and close. The rest scrolls: full Chinese, Chinese Wikipedia, English senses, English Wikipedia.
- Chinese comes first from `assets/dict/word.csv` (copied from `quick-read`, columns `word`, `lemmas`, `cefr`, `tc`). Inflections map to the headword through `lemmas` and common endings. When the list has no Chinese, the Chinese Wikipedia summary fills in, found through the English article's language link and asked for as `zh-hk`. English senses come from the Wiktionary REST API. `dictionaryapi.dev` was too slow (about 19 s, sometimes 522). These are public APIs, not our backend. Offline, only the built-in list shows.
- The speak button uses the system voice in British English (`en-GB`) and pauses book speech first. The setting 點查時讀出字音 is with headphones (default), always, or never. Headphones come from the `epub_reader/audio` method channel in `MainActivity`. Bluetooth audio counts as headphones.
- No bookstore, ever. No remote backend.
- Archive and hide follow section 4 of the spec. They appear on a long-press menu, not as buttons on every book. Archive and hide stay on this device and do not sync. Default sort is last-read time, newest first. Modified date sorts by the file or folder mtime, newest first.
- The bookshelf's top is one row: icon groups for view and sort, a filter selector button, then the search and settings icons. No title row.
- The filter selector shows the current filter and opens a menu: 書櫃 (default, not archived), 閱讀中, 未開始 (never opened), 已完結 (progress 100%), 封存, 全部. The status filters leave out archived books. Hidden books never show. Saved as `filter` in `library_v1`; the old `showArchived` maps to 封存.
- Progress is a percent. The first open measures characters and images per chapter, footnotes excluded (one image counts as 300 characters). The position inside a chapter is the text before the first sentence on the page. Books never measured fall back to chapter start over chapter count.
- Title, chapter count, a cover thumbnail (max 360 px wide), and chapter weights are cached per book until its mtime or size changes. Thumbnails live in the app support folder under `covers/`.
- Reopening a book returns to the saved chapter and sentence.
- Each book's position (chapter, sentence, page, percent, last read, speech place), highlights, and tags are one JSON file named after the book title (`bookDataFileName`), all in one folder: app support `book-data/` by default, or a folder picked in settings (files are moved and merged). `library_v1` still keeps a per-path copy of the position; the file wins when its `lastRead` is later. Highlights and tags once kept in `reader_v1` move into the file the first time the book opens.
- Google Drive sync (`drive_sync.dart`) uses `google_sign_in` 6.x and the Drive v3 REST API with the `drive.file` scope, in a Drive folder named `EPUB Reader`. It runs at app start, resume, pause, 8 s after a local change, and on 立即同步. Merge: later `lastRead` wins the position; highlights and tags are a union by key; removals are kept in `removed` so they do not come back; the newer tag name wins. It needs an Android OAuth client in Google Cloud for package `riverine.studio.epub` and the signing SHA-1; without it sign-in fails with status 10 (`drive.not_set_up`). The Drive folder name stays `EPUB Reader`.
- `readingNow` in `library_v1` is the book on screen. The reader clears it when it closes, so it is set only when the app was closed from the reader. With 開 app 時打開上次正在讀的書 on, `main.dart` opens it. A book from another app wins.
- Every theme forces its own text color and a transparent background over the book's CSS. Selection and the sentence being read use the theme's fill color with a selector that beats that rule.
- Tapping a note number or any in-book link jumps to its target before page-turn zones are checked.
- One temporary bookmark, icon only, in a 24 px blank band above the text. Later jumps keep the first bookmark. Going back through it leaves no new bookmark and removes it. A jump from the highlights list always leaves one. Only the top bar's bookmark button replaces it.
- Swiping left is the next page, right the previous (reversed in vertical writing). Edge taps still turn pages when speech is off.
- The bottom-left corner shows the whole-book percent, clear of the Android home bar. The bottom centre shows this chapter's page and page count (`12 / 40`). A tap opens a seek bar that stays until a tap on the text. A tap or drag on the bar goes to that spot. Holding the percent and sliding also works. The first move leaves the temporary bookmark, then each spot previews at once. While a finger is on the bar, the chapter name shows above it. Within 10 px of a chapter start, the spot snaps to that chapter's first page. Above the bar are 最頭, 上章, 下章 buttons; they go to the first page of the book or of that chapter, leave the temporary bookmark like the first move, and keep the bar open.
- Selection handles move by character, down to one character. Highlights store sentence ids plus character offsets and a `created` time. Old highlights without offsets cover whole sentences; old ones without a time show no date. One passage is never highlighted twice: when the selection shares a character with a highlight (`marksOverlapping`), 劃線 becomes 移除劃線. The selection bar is copy, highlight, search, close. Search then offers Google, Wikipedia (Chinese text goes to `zh.wikipedia.org/zh-hk/`), and in-book search. Links open in the external browser through `url_launcher`.
- 加標籤 sits left of 放書籤. It opens a rename box. The default name is the selected text, then a highlight on this page, then the chapter label. The contents drawer has four tabs: 目錄, 劃線, 標籤, 圖片. Highlights list newest first with date and time, chapter, and a delete button. Tags show their date and time; a long press renames or deletes one. 圖片 lists every distinct image with a thumbnail, found from the prepared chapter HTML (`imageSources`), and jumps to the first place it appears (`reader.goImage(n)`, the n-th `img`/`image` in the chapter). Every jump from these tabs leaves the temporary bookmark.
- Top and bottom bars have a colored edge in every theme. Light and dark use a see-through paper; the e-ink themes stay solid. Bottom bar order: contents, layout, brightness (icon), orientation (icon), speech.
- Brightness opens a draggable bar above the bottom bar that sets the window brightness at once (`epub_reader/screen` `brightness`), saved in `reader_v1` on release. 跟隨系統 gives it back to the system. Only while a book is open.
- Orientation offers auto-rotate (default), portrait, landscape, and landscape flipped through `SystemChrome.setPreferredOrientations`. It is app-wide, saved as `screenTurn` in `library_v1`, and applied at start.
- Keep screen on uses `epub_reader/screen` `keepOn` while a book is open.
- Layout covers only the bottom half. A tap on the top half closes it. No close button. Margins are two settings: left/right (12, 24, 40 px) and top/bottom (0, 12, 32 px added to the fixed 24 px top band and 12 px bottom band; default 12). On screens wider than 800 px the layout panel adds 欄數: one or two columns. Two columns apply only to horizontal paged mode: each column is half a page wide (`columnWidth` in `reader_bridge.dart`), so paging math stays one screen per page. Narrower screens fall back to one column.
- Vertical page mode does not use a fixed page width. `paginateVertical` in `reader_bridge.dart` measures every line and starts a page at the first line that would cross the left margin, so no line is cut. Masks at both edges hide the neighbouring pages' lines. Horizontal pages find a sentence's page by rounding its left edge down, not to the nearest page.
- In scroll mode the selection handles are placed again on every scroll.
- While speech plays, the word being spoken gets a second color inside the sentence (`reader.word`, from the `flutter_tts` progress handler): amber in light, light blue in dark, the sentence inverted in the e-ink themes. When that word is on the next page, the page turns at once; in scroll mode it scrolls into view.
- The contents panel follows the book's nav document (`properties="nav"`), nested as in the book, then `toc.ncx`. Only with neither does it list spine files with their `h3`/`h4`. Spine files missing from the contents take the previous entry's label for search results.
- A selection has two round handles at its ends: the start handle above the first character (top-left), the end handle below the last (bottom-right). Dragging one moves that end; the other stays.
- While the speech bar is open, a tap on a sentence reads it at once, a tap on blank space opens the bars, and only swipes turn pages. A direct hit on a link still follows it.
- Pause then play resumes at the word it stopped on (Android 8+ word progress from `flutter_tts`); otherwise from the sentence start. The speech bar has small previous/next sentence buttons.
- Speech remembers its chapter and sentence after stopping. It resumes there only when that sentence is on the current page. `audio_service` gives it an Android media session: system controls and headset play/pause work in the background, and previous/next move one sentence. While speech plays, `MainActivity` loops a silent `AudioTrack` (`epub_reader/audio` `silence`), because Android gives headset buttons to the app that is playing audio and the system voice plays from the TTS engine's process.
- Speech marks bold and italic. Bold (`b`, `strong`, class with `bold`, inline weight 600+) reads at 0.8 times the pace and pitch 0.9. Italic (`i`, `em`, class with `italic`, inline italic) uses a second speaker of the same locale and pitch 1.15. Heading boldness does not count.
- Bookshelf cards and covers have no border. Grid covers share one height (fit to height, cropped at the sides). Titles are at most two lines, and grid titles always reserve two. No percent text, only the bar.
- Selected choices use a filled style. Do not append 「使用中」.
- No animation anywhere, including route transitions, ripples, and progress fills.
- Android signing is ready for a temporary self-signed cert. When `android/key.properties` exists, debug and release use that keystore. The keystore and the password file are gitignored. Replace them later.
- `scripts/build-android.sh` with no flags builds the debug APK and installs it on the connected device. Debug stays at `build/app/outputs/flutter-apk/app-debug.apk`. `--release` also builds the release APK. `--dl` builds the release APK and copies it to `/mnt/nas4/web/subdomains/dl/epub-reader-release.apk`, which is [https://dl.sitepreview.cc/epub-reader-release.apk](https://dl.sitepreview.cc/epub-reader-release.apk). When the user asks for a download link, run the script with `--dl` and give this URL. Do not invent a different download location.

## End of every session

Do this before the final reply:

1. If `progress.md` already describes an earlier session, move that whole body into `changelog.md`. Put the moved entry at the top, under a heading with the date. Do not summarize it away.
2. Replace `progress.md` so it contains only this session: what was done, and what to do next. Next may be empty. No history, no copied changelog.
3. Update this file if a decision, constraint, file map, or next step changed.

`changelog.md` is the history. `progress.md` is not.

## File map

| Path | Role |
| --- | --- |
| `docs/features.html` | Feature spec the user reviews |
| `docs/plan-2-settings.md` | Draft prompt for settings not in the MVP. Not merged until the user says so |
| `docs/plan-read-view.md` | Draft prompt for the reader. Not merged until the user says so |
| `progress.md` | This session only |
| `changelog.md` | Old progress entries |
| `assets/i18n/strings.csv` | UI languages. Columns: `key`, `zh-Hant`, `en` |
| `lib/src/i18n.dart` | Loads that CSV. `tr(context, key)` |
| `lib/main.dart` | App entry |
| `lib/src/` | Bookshelf, reader, settings, EPUB parsing |
| `lib/src/book_text.dart` | Chapter weights, progress estimate and its reverse for the seek bar, search |
| `lib/src/parse_epub.dart` | OPF, spine, cover, and the nested contents from nav or NCX |
| `lib/src/reader_bridge.dart` | CSS and script injected into each chapter: paging, taps, swipes, character-level selection and highlight painting |
| `lib/src/reader_store.dart` | Layout, speech settings, brightness; the highlight and tag types; old highlights and tags waiting to move |
| `lib/src/book_data.dart` | One JSON file per book title: position, highlights, tags, removals. Merge rules and the folder store |
| `lib/src/drive_sync.dart` | Google sign-in and Drive v3 sync of the per-book files |
| `lib/src/screen.dart` | Brightness, keep screen on, and screen orientation |
| `lib/src/cover_thumb.dart` | Cover thumbnails |
| `lib/src/lookup.dart` | Built-in word list, word matching, Wiktionary and Wikipedia requests, headphone check |
| `lib/src/lookup_sheet.dart` | The lookup sheet with its fixed top row |
| `lib/src/pages/hidden_books_page.dart` | Hidden books, one restore button each |
| `assets/dict/word.csv` | English to Traditional Chinese word list, frequency order |
| `lib/src/speech_media.dart` | Android media session for speech |
| `lib/src/open_with.dart` | `epub_reader/open` channel: books opened from another app |
| `android/` | Android project. `MainActivity` extends `AudioServiceActivity` and answers `epub_reader/audio` `headphones` and `silence`, `epub_reader/open` `initial`, and `epub_reader/screen` `brightness`, `systemBrightness`, and `keepOn`. Signing files in `android/signing/` are gitignored |
| `scripts/build-android.sh` | Installs the debug APK on the connected device. `--release` builds release. `--dl` builds release and copies it to the download site. Points Gradle at the Samsung SSD first |
| `scripts/push-github.sh` | Commits the working tree and pushes to `origin`. `--release` also builds the release APK and uploads it to a GitHub release |
| `scripts/sandbox-cache-on-ssd.sh` | Makes `/tmp/cursor-sandbox-cache` a symlink to the Samsung SSD so the sandbox Gradle cache is not stored in RAM |
| `pubspec.yaml` | Package `epub_reader` |
| `demo/` | Ignored local books. Do not commit or treat as source |

## Working rules

- Reply to the user in English at B2–C1. Add a short Traditional Chinese gloss for difficult words when it helps.
- Do not add animations to satisfy a Flutter default.
- Do not add a bookstore or a remote backend.
- `demo/` is gitignored. Leave it out of commits.
- `/tmp` on this machine is tmpfs. Before any Flutter or Gradle build, run `scripts/sandbox-cache-on-ssd.sh` outside the sandbox. The cache belongs on `/run/media/hocti/92C4A6B3C4A698CD/cursor-sandbox-cache`. If that disk is not mounted, do not start an Android build.
