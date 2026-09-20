// Only request accounting survives LiveView navigation. GIF results never do.
const attempts = []
let retryAt = 0
export function retryDelay(value, now = Date.now()) {
  if (value && /^\d+$/.test(value)) return Number(value) * 1000
  const date = Date.parse(value)
  return Number.isFinite(date) ? Math.max(0, date - now) : 60_000
}
export function searchURL(query, language, key, offset) {
  if (!query || [...query].length > 50) throw new Error('This term is too long for GIF search.')
  const url = new URL('https://api.giphy.com/v1/gifs/search')
  url.search = new URLSearchParams({api_key: key, q: query, lang: language || 'en', rating: 'g', limit: '8', offset: String(offset)})
  return url.href
}
function safeURL(value, media = false) {
  try {
    const u = new URL(value)
    return u.protocol === 'https:' && !u.username && !u.password &&
      (u.hostname === 'giphy.com' || u.hostname.endsWith('.giphy.com')) &&
      (!media || u.hostname !== 'giphy.com') ? u.href : null
  } catch { return null }
}
export function parsePage(body, offset) {
  if (!body || !Array.isArray(body.data) || body.data.length > 8 ||
      !body.pagination || body.pagination.offset !== offset ||
      body.pagination.count !== body.data.length || !Number.isInteger(body.pagination.total_count)) {
    throw new Error('GIF search returned an invalid response.')
  }
  const items = body.data.map(item => {
    const still = safeURL(item.images?.fixed_width_still?.url, true)
    const animated = safeURL(item.images?.fixed_width?.url, true)
    const url = safeURL(item.url)
    if (!still || !animated || !url || typeof item.id !== 'string') throw new Error('GIF search returned an invalid response.')
    return {id: item.id, title: item.title || 'GIF', still, animated, url}
  })
  return {items, more: offset + items.length < body.pagination.total_count && items.length > 0 && offset < 16}
}
export default {
  mounted() {
    this.alive = true
    this.offset = 0
    this.pagesLoaded = 0
    this.busy = false
    this.status = this.el.querySelector('[data-status]')
    this.list = this.el.querySelector('[data-results]')
    this.more = this.el.querySelector('[data-more]')
    this.onMore = () => this.load()
    this.more.addEventListener('click', this.onMore)
    this.motion = matchMedia('(prefers-reduced-motion: reduce)')
    this.onMotion = () => {
      for (const button of this.list.querySelectorAll('[aria-pressed="true"]')) button.click()
      if (this.motion.matches) for (const image of this.list.querySelectorAll('img[data-still]')) image.src = image.dataset.still
    }
    this.motion.addEventListener('change', this.onMotion)
    this.load()
  },
  async load() {
    if (this.busy || !this.alive || this.pagesLoaded >= 3) return
    const now = Date.now()
    while (attempts.length && attempts[0] <= now - 3600_000) attempts.shift()
    if (retryAt > now || attempts.length >= 100) {
      this.status.textContent = 'GIF requests are temporarily paused. Please try again later.'
      this.more.hidden = true
      return
    }
    this.busy = true
    this.more.disabled = true
    this.controller = new AbortController()
    const timer = setTimeout(() => this.controller.abort(), 10_000)
    try {
      const {query, language, apiKey} = this.el.dataset
      const url = searchURL(query, language, apiKey, this.offset)
      attempts.push(now)
      const response = await globalThis.fetch(url, {signal: this.controller.signal, credentials: 'omit', cache: 'no-store', referrerPolicy: 'no-referrer'})
      if (response.status === 429) {
        retryAt = Date.now() + Math.max(1000, retryDelay(response.headers.get('Retry-After')))
        throw new Error('GIF requests are temporarily paused. Please try again later.')
      }
      if (response.status === 401 || response.status === 403) throw new Error('GIF search is unavailable. The API key needs checking.')
      if (!response.ok) throw new Error('GIF search is temporarily unavailable.')
      const page = parsePage(await response.json(), this.offset)
      if (!this.alive) return
      for (const item of page.items) this.addItem(item)
      this.offset += page.items.length
      this.pagesLoaded += 1
      this.status.textContent = this.offset ? '' : 'No matching GIFs for this term yet.'
      this.more.hidden = !page.more || this.pagesLoaded >= 3
    } catch (error) {
      if (this.alive) {
        this.status.textContent = error.name === 'AbortError' ? 'GIF search timed out. Try another visit later.' :
          (error instanceof TypeError ? 'GIF search is temporarily unavailable.' : error.message)
        this.more.hidden = true
      }
    } finally {
      clearTimeout(timer)
      this.busy = false
      this.more.disabled = false
    }
  },
  addItem(item) {
    const li = document.createElement('li')
    li.className = 'w-24 shrink-0 snap-start space-y-2 sm:w-28'
    const image = document.createElement('img')
    image.src = item.still
    image.dataset.still = item.still
    image.alt = item.title
    image.width = 112
    image.height = 112
    image.className = 'aspect-square w-full rounded-sm object-cover'
    image.referrerPolicy = 'no-referrer'
    const play = document.createElement('button')
    play.type = 'button'
    play.className = 'text-sm underline'
    play.textContent = 'Play'
    play.setAttribute('aria-label', `Play ${item.title}`)
    play.setAttribute('aria-pressed', 'false')
    // Motion on intent (#131, the GIF review's version B). The still is what
    // loads; the animated rendition plays while the pointer or the focus is
    // on the frame and stops when it leaves, so one frame moves at a time and
    // a rendition is fetched only for a GIF the reader reached for. Under
    // prefers-reduced-motion the frame never swaps on hover — the reader who
    // wants motion still has Play, which is deliberate and reversible. Play
    // is the sticky state: a pressed frame keeps moving when the pointer
    // leaves, and hover never unpresses it.
    const pressed = () => play.getAttribute('aria-pressed') === 'true'
    const show = playing => { image.src = playing ? item.animated : item.still }
    play.addEventListener('click', () => {
      const playing = !pressed()
      show(playing)
      play.setAttribute('aria-pressed', String(playing))
      play.setAttribute('aria-label', `${playing ? 'Pause' : 'Play'} ${item.title}`)
      play.textContent = playing ? 'Pause' : 'Play'
    })
    const enter = () => { if (!this.motion.matches && !pressed()) show(true) }
    const leave = () => { if (!pressed()) show(false) }
    li.addEventListener('mouseenter', enter)
    li.addEventListener('mouseleave', leave)
    li.addEventListener('focusin', enter)
    li.addEventListener('focusout', leave)
    image.addEventListener('error', () => {
      image.hidden = true
      play.hidden = true
      const fallback = document.createElement('div')
      fallback.className = 'aspect-square text-sm'
      fallback.textContent = 'Preview unavailable'
      if (!li.querySelector('[data-fallback]')) { fallback.dataset.fallback = ''; li.prepend(fallback) }
    })
    const link = document.createElement('a')
    link.href = item.url
    link.target = '_blank'
    link.rel = 'noreferrer noopener'
    link.textContent = item.title
    link.className = 'line-clamp-2 text-sm hover:underline'
    li.append(image, play, link)
    this.list.append(li)
  },
  destroyed() {
    this.alive = false
    this.controller?.abort()
    this.more.removeEventListener('click', this.onMore)
    this.motion.removeEventListener('change', this.onMotion)
    this.list.replaceChildren()
  }
}
