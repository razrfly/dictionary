// Filters the existing permitted DOM only. No API requests, storage, or payload cache.
export const fold = value => String(value ?? "").normalize("NFKD")
  .replace(/\p{M}/gu, "").toLocaleLowerCase().replace(/\s+/g, " ").trim()

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
  body.append(element("h3", title || "Source record", "material-title"))
  // API cards retain their full textual credits; long native texts have the exact
  // complete record immediately below, rather than duplicating entire dictionaries.
  const isDiscovery = Boolean(row.node.closest("[id^=culture-shelf-]"))
  const text = row.text.replace(/\s+/g, " ").trim()
  body.append(element("p", isDiscovery ? text : excerpt(text, query), "material-description"))
  if (row.node.dataset.recordObserved) body.append(element("p", "Shelf fetched " + row.node.dataset.recordObserved, "material-source"))
  const links = element("div", null, "material-links")
  // Preserve original, already-vetted source/evidence destinations and their labels.
  const seen = new Set()
  for (const anchor of row.node.querySelectorAll("a[href]")) {
    if (!isDiscovery && seen.size >= 3) break
    const href = anchor.getAttribute("href")
    const identity = href + "|" + anchor.textContent.trim()
    if (!href || seen.has(identity) || !/^(https?:|\/|#)/i.test(href)) continue
    const copy = cleanClone(anchor)
    // Thumbnails already appear once above; keep source marks and text links.
    if (copy.querySelector("img") && !copy.textContent.trim()) continue
    seen.add(identity)
    links.append(copy)
  }
  for (const source of row.sources) {
    const mark = inventory.querySelector("#culture-mark-" + CSS.escape(source.id))
    if (mark) links.append(cleanClone(mark))
  }
  // Use a stable local target without changing any source identity.
  const targetId = recordTargetId(row.node, document)
  const inspect = element("a", "Complete record ↗")
  inspect.href = "#" + encodeURIComponent(targetId)
  links.append(inspect)
  body.append(links)
  article.append(body)
  return article
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
const RecordExplorer = {
  mounted() {
    this.q = this.el.querySelector("[name=q]")
    this.type = this.el.querySelector("[name=type]")
    this.source = this.el.querySelector("[name=source]")
    this.status = this.el.querySelector("[data-record-status]")
    this.results = this.el.querySelector("[data-record-results]")
    this.categories = this.el.querySelector("[data-record-categories]")
    this.more = this.el.querySelector("[data-record-more]")
    this.limit = 30
    this.updateFilters = () => { this.limit = 30; this.apply() }
    this.clear = event => {
      this.q.value = ""; this.type.value = ""; this.source.value = ""
      this.updateFilters()
    }
    this.click = event => {
      const category = event.target.closest("[data-record-category]")
      if (category) { this.type.value = category.dataset.recordCategory; this.updateFilters() }
      const layout = event.target.closest("[data-record-layout]")
      if (layout) {
        this.results.dataset.layout = layout.dataset.recordLayout
        for (const button of this.el.querySelectorAll("[data-record-layout]")) button.setAttribute("aria-pressed", String(button === layout))
      }
      if (event.target.closest("[data-record-more]")) { this.limit += 30; this.apply() }
    }
    this.el.addEventListener("input", this.updateFilters)
    this.el.addEventListener("change", this.updateFilters)
    this.el.addEventListener("click", this.click)
    this.el.querySelector("#record-clear").addEventListener("click", this.clear)
    this.inventory = document.getElementById("record-inventory")
    if (!this.inventory) return
    this.observer = new MutationObserver(() => {
      if (this.frame) return
      this.frame = requestAnimationFrame(() => { this.frame = null; this.apply() })
    })
    this.observer.observe(this.inventory, {
      subtree: true, childList: true, characterData: true, attributes: true,
      attributeFilter: ["hidden", "data-record-kind", "data-record-sources"]
    })
    this.revealFragment = () => {
      let id
      try { id = decodeURIComponent(window.location.hash.slice(1)) } catch { return }
      const target = id && document.getElementById(id)
      if (openRecordTarget(this.inventory, target)) target.scrollIntoView({block: "start"})
    }
    window.addEventListener("hashchange", this.revealFragment)
    this.apply()
    this.revealFragment()
  },
  apply() {
    if (!this.inventory?.isConnected) return
    const rows = records(this.inventory)
    const options = new Set([...this.source.options].map(option => option.value))
    for (const row of rows) for (const source of row.sources) {
      if (!options.has(source.id)) { this.source.add(new Option(source.label, source.id)); options.add(source.id) }
    }
    const filters = {q: this.q.value, type: this.type.value, source: this.source.value}
    const counts = categoryCounts(rows, filters)
    this.categoryButtons = updateCategoryButtons(this.categories, this.categoryButtons || new Map(), counts, filters.type)
    const matches = interleave(applyFilters(rows, filters))
    this.results.replaceChildren(...matches.slice(0, this.limit).map((row) => material(row, this.inventory, filters.q)))
    this.more.hidden = matches.length <= this.limit
    const message = matches.length ? `${matches.length} matching materials · showing ${Math.min(this.limit, matches.length)} of ${rows.length} loaded` : "No matching materials. Clear filters or inspect provider status below."
    if (this.status.textContent !== message) this.status.textContent = message
  },
  destroyed() {
    this.observer?.disconnect()
    window.removeEventListener("hashchange", this.revealFragment)
    if (this.frame) cancelAnimationFrame(this.frame)
    this.el.removeEventListener("input", this.updateFilters)
    this.el.removeEventListener("change", this.updateFilters)
    this.el.removeEventListener("click", this.click)
    this.el.querySelector("#record-clear")?.removeEventListener("click", this.clear)
  }
}
export default RecordExplorer
