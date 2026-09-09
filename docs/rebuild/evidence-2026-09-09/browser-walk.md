# Chrome walkthrough, 9 September 2026

Local application at `http://localhost:4017`, backed by `devils_dictionary_v2`.

Verified at explicit 1280×900 and 375×812 CSS-pixel viewports:

- `/define/nepotism`: separately attributed Johnson, Bierce, WordNet and Wiktionary definitions; etymology and forms displayed. Followed the actual Bierce author link.
- `/entities/1/ambrose-bierce`: correct Wikidata Q191050, biography, authored work and definitions. No invented precise death date. Followed the work link from its works section.
- `/entities/2/the-devils-dictionary`: work identity and edition link. Followed the edition link.
- `/entities/3/project-gutenberg-972-1911-text`: edition identity and content list.

Every page had `document.documentElement.scrollWidth <= innerWidth` at both widths. Screenshots are adjacent. The temporary Chrome viewport override was reset afterward. Browser console inspection found extension-origin messaging errors; no application-origin JavaScript error was observed in the captured entries.

Authenticated login succeeded on the disposable verification database after fixing submit button types. The contribution/review browser workflow remains pending. Local acceptance fixtures were added only after the saved successful clean-database comparison.
