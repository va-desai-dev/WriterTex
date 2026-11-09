//
//  content.js
//  CiteTex
//
//  Scrapes citation metadata from the current page and returns it to the popup.
//  It reads the tags scholarly sites already publish for Google Scholar and
//  Zotero — Highwire `citation_*`, Dublin Core, OpenGraph — and falls back to
//  JSON-LD. The popup turns this into CSL-JSON (enriching by DOI when it can).
//

browser.runtime.onMessage.addListener((request) => {
    if (request && request.action === "scrape") {
        return Promise.resolve(scrape());
    }
});

function metaContent(names) {
    for (const name of names) {
        const el = document.querySelector(`meta[name="${name}" i]`)
                || document.querySelector(`meta[property="${name}" i]`);
        if (el && el.content && el.content.trim()) return el.content.trim();
    }
    return null;
}

function metaAll(name) {
    return Array.from(document.querySelectorAll(`meta[name="${name}" i]`))
        .map((e) => e.content && e.content.trim())
        .filter(Boolean);
}

function scrape() {
    // One source of names, never several joined: Atypon sites (Taylor &
    // Francis, physiology.org) publish the same authors as both citation_author
    // and dc.Creator. metaAll ignores case, so "dc.creator" covers DC.Creator.
    const authors = unique(
        [metaAll("citation_author"), metaAll("dc.creator")].find((list) => list.length) || []);

    const data = {
        title: metaContent(["citation_title", "dc.title", "DC.title", "og:title"])
            || (document.title || null),
        doi: cleanDOI(metaContent(["citation_doi", "prism.doi"]))
            || metaAll("dc.identifier").map(cleanDOI).find(Boolean)
            || doiFromURL(),
        containerTitle: metaContent([
            "citation_journal_title", "citation_conference_title",
            "citation_inbook_title", "prism.publicationName", "og:site_name"
        ]),
        publisher: metaContent(["citation_publisher", "dc.publisher", "DC.publisher"]),
        volume: metaContent(["citation_volume", "prism.volume"]),
        issue: metaContent(["citation_issue", "prism.number"]),
        date: metaContent([
            "citation_publication_date", "citation_date", "citation_online_date",
            "dc.date", "DC.date", "prism.publicationDate", "article:published_time"
        ]),
        url: metaContent(["og:url"]) || location.href,
        authors: authors.length ? authors : null,
        type: guessType()
    };

    const first = metaContent(["citation_firstpage"]);
    const last = metaContent(["citation_lastpage"]);
    if (first) data.page = last ? `${first}-${last}` : first;

    // JSON-LD fills anything the meta tags did not carry.
    const ld = readJSONLD();
    if (ld) {
        data.title = data.title || ld.title;
        data.doi = data.doi || cleanDOI(ld.doi);
        data.containerTitle = data.containerTitle || ld.containerTitle;
        data.publisher = data.publisher || ld.publisher;
        data.date = data.date || ld.date;
        data.type = data.type || ld.type;
        if ((!data.authors || !data.authors.length) && ld.authors) data.authors = ld.authors;
    }

    return data;
}

function unique(list) {
    const seen = new Set();
    return list.filter((item) => {
        const key = item.toLowerCase().replace(/\s+/g, " ");
        if (seen.has(key)) return false;
        seen.add(key);
        return true;
    });
}

// Atypon pages often carry the DOI only in their address:
// tandfonline.com/doi/abs/10.1076/brhm.34.2.177.14493
function doiFromURL() {
    const m = decodeURIComponent(location.pathname).match(/\/doi\/(?:abs\/|full\/|pdf\/|epdf\/|epub\/|book\/)?(10\.\d{4,9}\/.+)$/);
    return m ? cleanDOI(m[1]) : null;
}

function cleanDOI(raw) {
    if (!raw) return null;
    const m = String(raw).match(/10\.\d{4,9}\/[^\s"'<>]+/);
    return m ? m[0] : null;
}

function guessType() {
    if (metaContent(["citation_journal_title"])) return "article-journal";
    if (metaContent(["citation_conference_title"])) return "paper-conference";
    if (metaContent(["citation_inbook_title"])) return "chapter";
    if (metaContent(["citation_isbn"])) return "book";
    if (metaContent(["citation_dissertation_institution"])) return "thesis";
    return null;
}

function readJSONLD() {
    const nodes = document.querySelectorAll('script[type="application/ld+json"]');
    for (const n of nodes) {
        let parsed;
        try {
            parsed = JSON.parse(n.textContent);
        } catch {
            continue; // ignore malformed JSON-LD
        }
        const list = Array.isArray(parsed) ? parsed : (parsed["@graph"] || [parsed]);
        for (const obj of list) {
            if (!obj || typeof obj !== "object") continue;
            const types = [].concat(obj["@type"] || []);
            if (!types.some((t) => /Article|Book|Report|Thesis|Chapter/i.test(t || ""))) continue;
            return {
                title: obj.name || obj.headline || null,
                doi: (obj.sameAs && [].concat(obj.sameAs).join(" ")) || obj["@id"] || null,
                containerTitle: (obj.isPartOf && obj.isPartOf.name)
                    || (obj.publisher && obj.publisher.name) || null,
                publisher: (obj.publisher && obj.publisher.name) || null,
                date: obj.datePublished || obj.dateCreated || null,
                authors: normalizeLDAuthors(obj.author),
                type: mapLDType(types)
            };
        }
    }
    return null;
}

function normalizeLDAuthors(author) {
    if (!author) return null;
    const names = [].concat(author)
        .map((x) => (typeof x === "string" ? x : x && x.name))
        .filter(Boolean);
    return names.length ? names : null;
}

function mapLDType(types) {
    const s = types.join(" ");
    if (/ScholarlyArticle|Article/i.test(s)) return "article-journal";
    if (/Chapter/i.test(s)) return "chapter";
    if (/Book/i.test(s)) return "book";
    if (/Report/i.test(s)) return "report";
    if (/Thesis/i.test(s)) return "thesis";
    return null;
}
