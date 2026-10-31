// Filters the existing permitted DOM only. No API requests, storage, or payload cache.
export const fold = value => String(value ?? "").normalize("NFKD")
  .replace(/\p{M}/gu, "").toLocaleLowerCase().replace(/\s+/g, " ").trim()

export function matchesRecord(record, filters) {
  return (!filters.type || record.type === filters.type) &&
    (!filters.source || record.sources.some(source => source.id === filters.source)) &&
    (!fold(filters.q) || fold(record.text).includes(fold(filters.q)))
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
// Same routine for native, asynchronous discovery and browser-only rows.
export function applyFilters(rows, filters) {
  const matches = rows.filter(row => matchesRecord(row, filters))
  const kept = new Set(matches.map(row => row.node))
  for (const row of rows) {
    const show = kept.has(row.node) || matches.some(match => row.node.contains(match.node))
    if (row.node.hidden === show) row.node.hidden = !show
  }
  return matches
}
export function openRecordTarget(inventory, target) {
  if (!target || !inventory.contains(target)) return false
  for (let node = target; node && node !== inventory; node = node.parentElement) {
    if (node.tagName === "DETAILS") node.open = true
  }
  return true
}
const RecordExplorer = {
  mounted() {
    this.q = this.el.querySelector("[name=q]")
    this.type = this.el.querySelector("[name=type]")
    this.source = this.el.querySelector("[name=source]")
    this.status = this.el.querySelector("[data-record-status]")
    this.opened = new Map()
    this.updateFilters = () => this.apply()
    this.clear = () => {
      this.q.value = ""; this.type.value = ""; this.source.value = ""
      this.apply()
    }
    this.el.addEventListener("input", this.updateFilters)
    this.el.addEventListener("change", this.updateFilters)
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
      if (!target || !this.inventory.contains(target)) return
      // A dictionary-index link remains usable even after local filtering.
      if (target.closest("[hidden]")) this.clear()
      if (openRecordTarget(this.inventory, target)) target.scrollIntoView({block: "start"})
    }
    window.addEventListener("hashchange", this.revealFragment)
    this.apply()
    this.revealFragment()
  },
  apply() {
    if (!this.inventory?.isConnected) return
    const rows = records(this.inventory)
    const options = new Map([...this.source.options].map(option => [option.value, option.textContent]))
    for (const row of rows) for (const source of row.sources) {
      if (!options.has(source.id)) {
        this.source.add(new Option(source.label, source.id))
        options.set(source.id, source.label)
      }
    }
    const filters = {q: this.q.value, type: this.type.value, source: this.source.value}
    const active = Boolean(fold(filters.q) || filters.type || filters.source)
    const matches = applyFilters(rows, filters)
    // Reveal matching nested text; clearing restores prior disclosure states.
    if (!active) {
      for (const [node, open] of this.opened) if (node.isConnected) node.open = open
      this.opened.clear()
    } else {
      const reveal = node => {
        if (!this.opened.has(node)) this.opened.set(node, node.open)
        node.open = true
      }
      for (const row of matches) {
        for (let node = row.node; node && node !== this.inventory; node = node.parentElement) {
          if (node.tagName === "DETAILS") reveal(node)
        }
        if (fold(filters.q)) for (const detail of row.node.querySelectorAll("details")) {
          if (fold(detail.textContent).includes(fold(filters.q))) reveal(detail)
        }
      }
    }
    const message = active
      ? (matches.length ? matches.length + " matching records" : "No matching records. Clear filters to see the full record.")
      : rows.length + " available records · more may arrive"
    if (this.status.textContent !== message) this.status.textContent = message
  },
  destroyed() {
    this.observer?.disconnect()
    window.removeEventListener("hashchange", this.revealFragment)
    if (this.frame) cancelAnimationFrame(this.frame)
    this.el.removeEventListener("input", this.updateFilters)
    this.el.removeEventListener("change", this.updateFilters)
    this.el.querySelector("#record-clear")?.removeEventListener("click", this.clear)
    for (const [node, open] of this.opened || []) if (node.isConnected) node.open = open
    this.opened?.clear()
  }
}
export default RecordExplorer
