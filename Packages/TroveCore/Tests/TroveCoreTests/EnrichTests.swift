import Foundation
import Testing
@testable import TroveCore

@Suite struct URLCleanerTests {
    @Test func stripsTrackingKeepsMeaning() {
        let u = URL(string: "HTTPS://WWW.Example.com:443/a?utm_source=x&id=7&fbclid=abc#:~:text=hello")!
        #expect(URLCleaner.clean(u).absoluteString == "https://www.example.com/a?id=7")
        #expect(URLCleaner.clean(URL(string: "https://youtu.be/abc?si=XYZ&t=30")!).absoluteString == "https://youtu.be/abc?t=30")
        // `si` means something on other sites.
        #expect(URLCleaner.clean(URL(string: "https://shop.com/p?si=2")!).absoluteString == "https://shop.com/p?si=2")
        #expect(URLCleaner.dedupeKey(URL(string: "http://www.example.com/a/?utm_medium=e")!) == URLCleaner.dedupeKey(URL(string: "https://example.com/a")!))
    }
}

@Suite struct HTMLTests {
    let recipePage = """
    <html><head><title>Fallback &amp; title</title>
    <meta property="og:title" content="Best Ever Ramen">
    <meta content="Rich, quick ramen for weeknights." name="description">
    <meta property="og:image" content="/img/ramen.jpg"><meta property="og:site_name" content="Cook Daily">
    <link rel="canonical" href="https://cook.example/ramen">
    <script type="application/ld+json">
    {"@context":"https://schema.org","@graph":[{"@type":"WebSite","name":"Cook"},
     {"@type":"Recipe","name":"Best Ever Ramen","recipeIngredient":["noodles","miso","egg"],
      "recipeInstructions":[{"@type":"HowToStep","text":"Boil water."},{"@type":"HowToStep","text":"Add miso."}],
      "totalTime":"PT20M","recipeYield":"2","image":{"url":"https://cook.example/r.jpg"}}]}
    </script></head>
    <body><nav>Home | Recipes</nav><article><h1>Best Ever Ramen</h1><p>This ramen takes twenty minutes.</p>
    <script>alert(1)</script><ul><li>Fast</li><li>Cheap</li></ul></article><footer>© 2026</footer></body></html>
    """

    @Test func metadataAndReadableText() {
        let m = HTMLMetadata(html: recipePage, baseURL: URL(string: "https://cook.example/ramen?x=1"))
        #expect(m.title == "Best Ever Ramen")
        #expect(m.description == "Rich, quick ramen for weeknights.")
        #expect(m.imageURL == "https://cook.example/img/ramen.jpg")
        #expect(m.siteName == "Cook Daily")
        #expect(m.canonicalURL == "https://cook.example/ramen")
        #expect(m.readableText.contains("This ramen takes twenty minutes."))
        #expect(m.readableText.contains("• Fast"))
        #expect(!m.readableText.contains("alert"))
        #expect(!m.readableText.contains("Home | Recipes"))
        #expect(HTMLMetadata(html: "<title>A &amp; B &#8211; C &#x263A;</title>").title == "A & B – C ☺")
    }

    @Test func schemaRecipeProductEventPlace() {
        let recipe = SchemaOrg.extract(jsonLD: HTMLMetadata(html: recipePage).jsonLD).recipe
        #expect(recipe?.ingredients == ["noodles", "miso", "egg"])
        #expect(recipe?.steps == ["Boil water.", "Add miso."])
        #expect(recipe?.image == "https://cook.example/r.jpg")

        let product = SchemaOrg.extract(jsonLD: [#"{"@type":"Product","name":"Desk Lamp","brand":{"@type":"Brand","name":"Lumo"},"offers":{"@type":"Offer","price":"49.99","priceCurrency":"GBP","availability":"https://schema.org/InStock"}}"#]).product
        #expect(product == SchemaOrg.Product(name: "Desk Lamp", price: 49.99, currency: "GBP", brand: "Lumo", availability: "InStock", image: nil))

        let event = SchemaOrg.extract(jsonLD: [#"[{"@type":"MusicEvent","name":"Gig","startDate":"2026-11-01T20:00","location":{"@type":"Place","name":"O2","address":{"streetAddress":"Peninsula Sq","addressLocality":"London"}}}]"#]).event
        #expect(event?.venue == "O2")
        #expect(event?.address == "Peninsula Sq, London")

        let place = SchemaOrg.extract(jsonLD: [#"{"@type":["Restaurant","LocalBusiness"],"name":"Noodle Bar","geo":{"latitude":51.5,"longitude":"-0.12"}}"#]).place
        #expect(place?.latitude == 51.5 && place?.longitude == -0.12)
    }

    @Test func basicEnricherPicksCategoryAndFields() {
        let e = BasicEnricher.enrich(html: recipePage, url: URL(string: "https://cook.example/ramen")!)
        #expect(e.category == .recipe)
        #expect(e.title == "Best Ever Ramen")
        #expect(e.extracted["recipe"]?.object?["ingredients"]?.stringArray == ["noodles", "miso", "egg"])
        #expect(e.tags.contains("quick"))
        let fields = e.fields(existingTitle: "My title")
        #expect(fields[Field.title] == nil)
        #expect(fields[Field.category] == "recipe")

        let video = BasicEnricher.enrich(html: "<title>Talk</title>", url: URL(string: "https://www.youtube.com/watch?v=1")!)
        #expect(video.category == .video)
    }

    @Test func summariesWithoutAI() {
        let text = "Trove keeps everything. It organises itself. " + String(repeating: "More words here. ", count: 30)
        let s = BasicEnricher.firstSentences(text, maxLength: 60)!
        #expect(s.count <= 61)
        #expect(s.hasSuffix(".") || s.hasSuffix("…"))
    }
}

@Suite struct ImportTests {
    @Test func markdownFrontMatterLinksAndTags() {
        let text = "---\ntitle: \"Ramen: notes\"\ntags: [food, japan]\naliases:\n  - noodles\n---\n# Ramen\nSee [[Broth|the broth]] and [[Toppings#Eggs]]. #recipe #to-try not#this `#code`\n## Heading\n"
        let doc = Markdown.parse(text)
        #expect(doc.frontMatter["title"]?.string == "Ramen: notes")
        #expect(doc.frontMatter["tags"]?.list == ["food", "japan"])
        #expect(doc.frontMatter["aliases"]?.list == ["noodles"])
        #expect(Markdown.wikilinks(in: doc.body) == ["Broth", "Toppings"])
        #expect(Markdown.hashtags(in: doc.body) == ["recipe", "to-try"])
        let rendered = Markdown.render(frontMatter: [("title", .string("A: b")), ("tags", .list(["x"]))], body: "hi")
        #expect(Markdown.parse(rendered).frontMatter["title"]?.string == "A: b")
    }

    @Test func obsidianRoundTrip() {
        var r = Record(id: "abc123", kind: "item", createdHLC: "", updatedHLC: "")
        r.fields = [Field.title: "Best ramen", Field.tags: ["food"], Field.kind: "note", Field.category: "recipe",
                    Field.url: "https://cook.example/r", Field.createdAt: JSONValue(Date(timeIntervalSince1970: 1_700_000_000))]
        r.texts = [Field.body: "Boil water.\n#quick"]
        let item = Item(r)
        let md = ObsidianMirror.render(item)
        #expect(md.contains("trove-id: abc123"))
        let parsed = ObsidianMirror.parse(md, fileName: "Best ramen.md")
        #expect(parsed.troveId == "abc123")
        #expect(parsed.title == "Best ramen")
        #expect(parsed.body == "Boil water.\n#quick")
        #expect(Set(parsed.tags) == ["food", "quick"])
        #expect(parsed.url == "https://cook.example/r")
        #expect(ObsidianMirror.relativePath(for: item) == "Notes/Recipes/Best ramen.md")
        #expect(ObsidianMirror.relativePath(for: item, taken: ["Notes/Recipes/Best ramen.md"]) == "Notes/Recipes/Best ramen (abc123).md")
        #expect(ObsidianMirror.safeFileName("a/b:c?") == "a b c")

        let plain = ObsidianMirror.parse("Just text", fileName: "Idea.md")
        #expect(plain.troveId == nil && plain.title == "Idea" && plain.body == "Just text")
    }

    @Test func kindleClippings() {
        let text = """
        \u{FEFF}Atomic Habits (James Clear)
        - Your Highlight on page 27 | Location 410-412 | Added on Monday, 3 March 2025 10:00:00

        You do not rise to the level of your goals.
        ==========
        Atomic Habits (James Clear)
        - Your Bookmark on page 30 | Location 450 | Added on Monday, 3 March 2025 10:05:00


        ==========
        Atomic Habits (James Clear)
        - Your Highlight on page 27 | Location 410-412 | Added on Monday, 3 March 2025 10:00:00

        You do not rise to the level of your goals.
        ==========
        Dune
        - Your Note on Location 99 | Added on Tuesday, March 4, 2025 9:00:00 PM

        Spice = oil
        ==========
        """
        let items = KindleClippings.parse(text)
        #expect(items.count == 2)
        #expect(items[0].title == "Atomic Habits" && items[0].author == "James Clear")
        #expect(items[0].body.contains("p. 27, loc. 410-412"))
        #expect(items[0].createdAt != nil)
        #expect(items[1].tags.contains("note"))
        #expect(items[1].createdAt != nil)
    }

    @Test func bookmarksAndCSV() {
        let html = """
        <DL><p><DT><H3>Recipes</H3><DL><p>
        <DT><A HREF="https://cook.example/r?utm_source=x" ADD_DATE="1700000000" TAGS="food,quick">Ramen &amp; more</A>
        </DL><p><DT><A HREF="https://news.example/a">News</A></DL>
        """
        let items = NetscapeBookmarks.parse(html)
        #expect(items.count == 2)
        #expect(items[0].title == "Ramen & more" && items[0].collection == "Recipes" && items[0].tags == ["food", "quick"])
        #expect(items[1].collection == nil)

        let csv = "title,note,excerpt,url,folder,tags,created\n\"Hello, world\",\"multi\nline\",x,https://a.example/1,Reading,\"t1, t2\",2026-01-01T00:00:00Z\nbad,,,ftp://x,,,\n"
        let rows = CSVImport.importLinks(csv)
        #expect(rows.count == 1)
        #expect(rows[0].title == "Hello, world" && rows[0].body == "multi\nline" && rows[0].tags == ["t1", "t2"])
        #expect(rows[0].collection == "Reading" && rows[0].createdAt != nil)
        let pocket = CSVImport.importLinks("title,url,time_added,tags,status\nA,https://p.example,1700000000,x|y,unread\n")
        #expect(pocket[0].tags == ["x", "y"] && pocket[0].createdAt == Date(timeIntervalSince1970: 1_700_000_000))
    }

    @Test func readwiseNotionAppleNotes() throws {
        let rw = #"{"results":[{"title":"Deep Work","author":"Cal Newport","source_url":null,"highlights":[{"id":5,"text":"Focus.","note":"key","highlighted_at":"2025-02-01T10:00:00.000Z","tags":[{"name":"Work"}]}]}]}"#
        let items = try ReadwiseExport.parse(Data(rw.utf8))
        #expect(items.count == 1 && items[0].externalId == "readwise:5" && items[0].tags == ["readwise", "work"])
        #expect(items[0].body.contains("> Focus.") && items[0].createdAt != nil)

        let notion = #"{"results":[{"type":"heading_1","heading_1":{"rich_text":[{"plain_text":"Plan"}]}},{"type":"bulleted_list_item","bulleted_list_item":{"rich_text":[{"plain_text":"one","annotations":{"bold":true}}]}},{"type":"bulleted_list_item","bulleted_list_item":{"rich_text":[{"plain_text":"two","href":"https://x.example"}]}},{"type":"to_do","to_do":{"checked":true,"rich_text":[{"plain_text":"done"}]}}]}"#
        #expect(try NotionBlocks.markdown(fromBlocksJSON: Data(notion.utf8)) == "# Plan\n\n- **one**\n- [two](https://x.example)\n- [x] done")

        let notes = AppleNotesHTML.markdown("<div><h1>Shopping</h1></div><div>Get <b>milk</b> &amp; eggs</div><ul><li>bread</li></ul><div><a href=\"https://x.example\">link</a></div>")
        #expect(notes.contains("# Shopping") && notes.contains("Get **milk** & eggs") && notes.contains("- bread") && notes.contains("[link](https://x.example)"))
    }
}
