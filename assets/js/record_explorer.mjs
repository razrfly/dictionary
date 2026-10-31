// Filters the existing permitted DOM only. No API requests, storage, or payload cache.
export const fold = value => String(value ?? "").normalize("NFKD")
  .replace(/\p{M}/gu, "").toLocaleLowerCase().replace(/\s+/g, " ").trim()

export function filterURL(href, filters) {
  const url = new URL(href)
  url.searchParams.delete("view")
  for (const name of ["q", "type", "source"]) {
    if (filters[name]) url.searchParams.set(name, filters[name])
    else url.searchParams.delete(name)
  }
  return url.pathname + url.search + url.hash
}
export function matchesRecord(record, filters) {
  return (!filters.type || record.type === filters.type) &&
    (!filters.source || record.sources.some(source => source.id === filters.source)) &&
    (!fold(filters.q) || fold(filters.q).split(" ").every(term => fold(record.text).includes(term)))
}
function sources(node) {
  try { return JSON.parse(node.dataset.recordSources || "[]") }
  catch { return [] }
}
export function recordText(node) {
  return [...node.childNodes].map(child => {
    if (child.nodeType === 3) return child.textContent
    if (child.nodeType !== 1 || child.hasAttribute("data-record-kind")) return ""
    return recordText(child)
  }).join(" ")
}
export function records(inventory) {
  const native = [...inventory.querySelectorAll("[data-record-kind]")]
    .filter(node => !node.hasAttribute("data-record-browser"))
    .map(node => ({node, type: node.dataset.recordKind, sources: sources(node), text: recordText(node)}))
  const browser = [...inventory.querySelectorAll("[data-record-browser]")].flatMap(shelf =>
    [...shelf.querySelectorAll("[data-results] > li")].map(node => ({
      node, type: shelf.dataset.recordKind, sources: sources(shelf), text: node.textContent
    })))
  return [...native, ...browser]
}
// Filtering never hides or edits the complete source records.
export function applyFilters(rows, filters) {
  return rows.filter(row => matchesRecord(row, filters))
}
export function openRecordTarget(inventory, target) {
  if (!target || !inventory.contains(target)) return false
  for (let node = target; node; node = node === inventory ? null : node.parentElement) {
    if (node.tagName === "DETAILS") node.open = true
  }
  return true
}
// A late target is retried until it exists, then never steals scroll again.
export function revealRecordFragment(state, inventory, hash, dom = document) {
  if (state.revealedHash === hash) return
  let id
  try { id = decodeURIComponent(hash.slice(1)) } catch {
    state.pendingFragment = null
    return
  }
  const target = id && dom.getElementById(id)
  state.pendingFragment = id && !target ? id : null
  if (target && openRecordTarget(inventory, target)) target.scrollIntoView({block: "start"})
  if (!state.pendingFragment) state.revealedHash = hash
}
const categories = [
  ["", "All materials"], ["definition", "Definitions"], ["example", "Examples & claims"],
  ["quote", "Quotations"], ["artwork", "Artworks"], ["image", "Images"],
  ["film", "Films"], ["text", "Texts"], ["news", "News"], ["music", "Music"],
  ["gif", "GIFs"], ["entity", "Entities"], ["word", "Word information"], ["related", "Related"]
]
export function categoryCounts(rows, filters) {
  const eligible = rows.filter(row => matchesRecord(row, {...filters, type: ""}))
  return Object.fromEntries(categories.map(([type]) => [type, type ? eligible.filter(row => row.type === type).length : eligible.length]))
}
// Interleave categories without inventing an editorial relevance ranking.
export function interleave(rows) {
  const buckets = new Map()
  for (const row of rows) {
    if (!buckets.has(row.type)) buckets.set(row.type, [])
    buckets.get(row.type).push(row)
  }
  const ordered = [...categories.map(([type]) => buckets.get(type)).filter(Boolean), ...[...buckets].filter(([type]) => !categories.some(([kind]) => kind === type)).map(([, rows]) => rows)]
  const result = []
  while (ordered.some(bucket => bucket.length)) {
    for (const bucket of ordered) if (bucket.length) result.push(bucket.shift())
  }
  return result
}
function element(tag, text, className) {
  const node = document.createElement(tag)
  if (text) node.textContent = text
  if (className) node.className = className
  return node
}
export function excerpt(text, query, length = 360) {
  const match = fold(query) ? fold(text).indexOf(fold(query).split(" ")[0]) : -1
  const start = match > 100 ? match - 100 : 0
  return (start ? "…" : "") + text.slice(start, start + length) + (text.length > start + length ? "…" : "")
}
function cleanClone(original) {
  const copy = original.cloneNode(true)
  for (const node of [copy, ...copy.querySelectorAll("*")]) {
    for (const attr of [...node.attributes]) if (attr.name === "id" || attr.name.startsWith("phx-") || attr.name.startsWith("data-phx-") || attr.name.startsWith("on")) node.removeAttribute(attr.name)
  }
  return copy
}
let nextTargetId = 0
export function recordTargetId(node, dom) {
  if (node.id) return node.id
  let id
  do { id = "material-record-" + (++nextTargetId) } while (dom.getElementById(id))
  node.id = id
  return id
}
function material(row, inventory, query) {
  const article = element("article", null, "material-result")
  article.dataset.materialKind = row.type
  const image = ["artwork", "image", "film", "text", "news", "music", "gif"].includes(row.type) ? row.node.querySelector("img") : null
  if (image) {
    const copy = image.cloneNode(false)
    copy.removeAttribute("id"); copy.removeAttribute("phx-hook")
    copy.loading = "lazy"; copy.className = "material-thumbnail"
    article.append(copy)
  }
  const body = element("div", null, "material-body")
  const heading = row.node.querySelector("h2,h3,h4,[id^=culture-entry-title]")
  const title = fold(heading?.textContent) ? heading.textContent.trim() : row.text.trim().slice(0, 110)
  body.append(element("p", (categories.find(([kind]) => kind === row.type)?.[1] || row.type) + " · " + row.sources.map(source => source.label).join(" · "), "material-source"))
  const targetId = recordTargetId(row.node, document)
  article.dataset.materialTarget = targetId
  const titleLink = element("a", title || "Source record")
  titleLink.href = "#" + encodeURIComponent(targetId)
  const titleHeading = element("h3", null, "material-title")
  titleHeading.append(titleLink)
  body.append(titleHeading)
  const text = row.text.replace(/\s+/g, " ").trim()
  body.append(element("p", excerpt(text, query, 150), "material-description"))
  // Required creator/licence credits remain visible and unclamped in both modes.
  for (const credit of row.node.querySelectorAll("[id^=culture-attribution-]")) {
    const copy = cleanClone(credit)
    copy.className = "material-credit"
    body.append(copy)
  }
  const links = element("div", null, "material-links")
  // Preserve original, already-vetted source/evidence destinations and their labels.
  const seen = new Set()
  for (const anchor of row.node.querySelectorAll("a[href]")) {
    const href = anchor.getAttribute("href")
    const identity = href + "|" + anchor.textContent.trim()
    if (!href || seen.has(identity) || !/^(https?:|\/|#)/i.test(href)) continue
    const copy = cleanClone(anchor)
    // Thumbnails already appear once above; keep source marks and text links.
    if (copy.querySelector("img") && !copy.textContent.trim()) continue
    seen.add(identity)
    links.append(copy)
  }
  // Use a stable local target without changing any source identity.
  const inspect = element("a", "Complete record ↗")
  inspect.href = "#" + encodeURIComponent(targetId)
  links.append(inspect)
  // Full source wording and all original destinations remain one disclosure away.
  const details = element("details", null, "material-details")
  details.append(element("summary", "Details & source links"))
  details.append(element("p", text, "material-full-text"))
  if (row.node.dataset.recordObserved) details.append(element("p", "Shelf fetched " + row.node.dataset.recordObserved, "material-source"))
  details.append(links)
  body.append(details)
  if (row.type === "music") {
    const listen = row.node.querySelector("a[title='Listen on Spotify']")
    if (listen) body.append(cleanClone(listen))
  }
  // Provider marks belong alongside the result, never only inside a disclosure.
  for (const source of row.sources) {
    const mark = inventory.querySelector("#culture-mark-" + CSS.escape(source.id))
    if (mark) body.append(cleanClone(mark))
  }
  article.append(body)
  return article
}
// Rebuild from the current eligible projection, preserving interaction state only.
// Never retain an old payload node after a source withdraws or changes it.
export function replaceResults(container, nodes, fallback) {
  const active = container.ownerDocument.activeElement
  const focused = active && container.contains(active) ? active : null
  const target = focused?.closest(".material-result")?.dataset.materialTarget
  const open = new Set([...container.querySelectorAll(".material-result")]
    .filter(row => row.querySelector("details")?.open).map(row => row.dataset.materialTarget))
  const key = focused && {tag: focused.tagName, href: focused.getAttribute("href"), text: focused.textContent}
  container.replaceChildren(...nodes)
  for (const row of nodes) {
    const details = row.querySelector("details")
    if (details && open.has(row.dataset.materialTarget)) details.open = true
  }
  if (focused) {
    const row = nodes.find(row => row.dataset.materialTarget === target)
    const replacement = row && [...row.querySelectorAll("a[href],button,summary")]
      .find(node => node.tagName === key.tag && node.getAttribute("href") === key.href && node.textContent === key.text)
    ;(replacement || fallback)?.focus({preventScroll: true})
  }
}
export function updateCategoryButtons(container, buttons, counts, selected, create = element) {
  for (const [type, label] of categories) {
    let button = buttons.get(type)
    if (!button) {
      button = create("button", null, "material-category")
      button.type = "button"
      button.dataset.recordCategory = type
      buttons.set(type, button)
      container.append(button)
    }
    button.textContent = label + " " + counts[type]
    button.setAttribute("aria-pressed", String(type === selected))
  }
  return buttons
}
export function defaultLayout(type) {
  return ["artwork", "image", "film", "gif"].includes(type) ? "grid" : "list"
}
export function selectedLayout(type, choices = new Map()) {
  return choices.get(type) || defaultLayout(type)
}
export function adoptExplorerState(current, early) {
  if (!early || current.el !== early.el) return
  for (const key of ["revealedHash", "categoryButtons", "layoutChoices", "limit"]) current[key] = early[key]
}
let earlyExplorer = null
const RecordExplorer = {
  mounted() {
    if (earlyExplorer) {
      adoptExplorerState(this, earlyExplorer)
      RecordExplorer.destroyed.call(earlyExplorer)
      earlyExplorer = null
    }
    this.q = this.el.querySelector("[name=q]")
    this.type = this.el.querySelector("[name=type]")
    this.source = this.el.querySelector("[name=source]")
    this.status = this.el.querySelector("[data-record-status]")
    this.results = this.el.querySelector("[data-record-results]")
    this.categories = this.el.querySelector("[data-record-categories]")
    this.more = this.el.querySelector("[data-record-more]")
    this.limit ??= 30
    this.layoutChoices ??= new Map()
    this.updateFilters = () => {
      this.limit = 30
      this.apply()
      const path = filterURL(window.location.href, {q: this.q.value, type: this.type.value, source: this.source.value})
      window.history.replaceState(window.history.state, "", path)
    }
    this.clear = event => {
      event.preventDefault()
      this.q.value = ""; this.type.value = ""; this.source.value = ""
      this.updateFilters()
    }
    this.click = event => {
      const category = event.target.closest("[data-record-category]")
      if (category) { this.type.value = category.dataset.recordCategory; this.updateFilters() }
      const layout = event.target.closest("[data-record-layout]")
      if (layout) {
        this.layoutChoices.set(this.type.value, layout.dataset.recordLayout)
        this.applyLayout()
      }
      if (event.target.closest("[data-record-more]")) { this.limit += 30; this.apply() }
    }
    this.submit = event => { event.preventDefault(); this.updateFilters() }
    this.el.querySelector("#record-search").addEventListener("submit", this.submit)
    this.el.addEventListener("input", this.updateFilters)
    this.el.addEventListener("change", this.updateFilters)
    this.el.addEventListener("click", this.click)
    this.el.querySelector("#record-clear").addEventListener("click", this.clear)
    this.inventory = document.getElementById("record-inventory")
    if (!this.inventory) return
    this.observer = new MutationObserver(() => {
      if (this.frame) return
      this.frame = requestAnimationFrame(() => {
        this.frame = null
        this.apply()
        if (this.pendingFragment) this.revealFragment()
      })
    })
    this.observer.observe(this.inventory, {
      subtree: true, childList: true, characterData: true, attributes: true,
      attributeFilter: ["hidden", "data-record-kind", "data-record-sources"]
    })
    this.revealFragment = () => revealRecordFragment(this, this.inventory, window.location.hash)
    window.addEventListener("hashchange", this.revealFragment)
    this.apply()
    this.revealFragment()
  },
  applyLayout() {
    const layout = selectedLayout(this.type.value, this.layoutChoices)
    this.results.dataset.layout = layout
    for (const button of this.el.querySelectorAll("[data-record-layout]")) button.setAttribute("aria-pressed", String(button.dataset.recordLayout === layout))
  },
  apply() {
    if (!this.inventory?.isConnected) return
    const rows = records(this.inventory)
    const options = new Set([...this.source.options].map(option => option.value))
    for (const row of rows) for (const source of row.sources) {
      if (!options.has(source.id)) { this.source.add(new Option(source.label, source.id)); options.add(source.id) }
    }
    const filters = {q: this.q.value, type: this.type.value, source: this.source.value}
    const label = categories.find(([kind]) => kind === filters.type)?.[1] || "All materials"
    this.el.querySelector("label[for=record-query] > span").textContent = "Search " + label.toLocaleLowerCase()
    this.q.placeholder = filters.type ? "Search " + label.toLocaleLowerCase() + "…" : "Titles, creators, words…"
    this.applyLayout()
    const counts = categoryCounts(rows, filters)
    this.categoryButtons = updateCategoryButtons(this.categories, this.categoryButtons || new Map(), counts, filters.type)
    const matches = interleave(applyFilters(rows, filters))
    replaceResults(this.results, matches.slice(0, this.limit).map((row) => material(row, this.inventory, filters.q)), this.q)
    this.more.hidden = matches.length <= this.limit
    const message = matches.length ? `${matches.length} ${filters.type ? label.toLocaleLowerCase() : "materials"}${filters.q || filters.source ? " matching" : ""} · ${Math.min(this.limit, matches.length)} shown` : "No matching materials. Clear filters or inspect provider status below."
    if (this.status.textContent !== message) this.status.textContent = message
  },
  destroyed() {
    this.observer?.disconnect()
    window.removeEventListener("hashchange", this.revealFragment)
    if (this.frame) cancelAnimationFrame(this.frame)
    this.el.querySelector("#record-search")?.removeEventListener("submit", this.submit)
    this.el.removeEventListener("input", this.updateFilters)
    this.el.removeEventListener("change", this.updateFilters)
    this.el.removeEventListener("click", this.click)
    this.el.querySelector("#record-clear")?.removeEventListener("click", this.clear)
  }
}
// Make the saved inventory usable before the live transport connects. The
// LiveView hook takes over and removes these listeners once it mounts.
export function bootRecordExplorer(dom = document) {
  const el = dom.querySelector('[phx-hook="RecordExplorer"]')
  // Old preview bookmarks used a generic jump into the toolbar. Entry URLs
  // now open at the top; exact source-record fragments still work normally.
  if (el && window.location.hash === "#record-search") {
    window.history.replaceState(window.history.state, "", window.location.pathname + window.location.search)
    window.scrollTo(0, 0)
  }
  if (!el || earlyExplorer) return
  const instance = Object.create(RecordExplorer)
  instance.el = el
  instance.mounted()
  earlyExplorer = instance
}
export default RecordExplorer
