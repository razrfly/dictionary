// The `PageHead` hook (#237 C4): keeps the document's head in step with the
// page on live navigation. The root layout renders the head of the initial
// response; a `push_navigate` or `push_patch` replaces the LiveView, not the
// `<head>`, so `DevilsDictionaryWeb.Head.hook/1` carries the same facts as
// data on a hidden element, and this hook applies them when it mounts and
// whenever they change: the title, the canonical, the robots and description
// metas, and the JSON-LD. A page that sets no head is noindex with no
// canonical, as its initial response is.

const JSON_LD_ID = "json-ld"

const setLink = (rel, href) => {
  let link = document.head.querySelector(`link[rel="${rel}"]`)
  if (!href) {
    if (link) link.remove()
    return
  }
  if (!link) {
    link = document.createElement("link")
    link.setAttribute("rel", rel)
    document.head.appendChild(link)
  }
  link.setAttribute("href", href)
}

const setMeta = (name, content) => {
  let meta = document.head.querySelector(`meta[name="${name}"]`)
  if (!content) {
    if (meta) meta.remove()
    return
  }
  if (!meta) {
    meta = document.createElement("meta")
    meta.setAttribute("name", name)
    document.head.appendChild(meta)
  }
  meta.setAttribute("content", content)
}

const setJsonLd = (json) => {
  let script = document.getElementById(JSON_LD_ID)
  if (!json) {
    if (script) script.remove()
    return
  }
  if (!script) {
    script = document.createElement("script")
    script.id = JSON_LD_ID
    script.type = "application/ld+json"
    document.head.appendChild(script)
  }
  script.textContent = json
}

const PageHead = {
  mounted() {
    this.sync()
  },
  updated() {
    this.sync()
  },
  sync() {
    const data = this.el.dataset
    if (data.title) document.title = data.title
    setLink("canonical", data.canonical)
    setMeta("robots", data.robots)
    setMeta("description", data.description)
    setJsonLd(data.jsonLd)
  },
}

export default PageHead
