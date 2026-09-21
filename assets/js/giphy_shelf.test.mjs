import test from 'node:test'
import assert from 'node:assert/strict'
import Hook, {searchURL, parsePage, retryDelay} from './giphy_shelf.mjs'
const item = id => ({id, title: id, url: `https://giphy.com/gifs/${id}`, images: {fixed_width_still: {url: `https://media.giphy.com/media/${id}/200_s.gif?x=1`}, fixed_width: {url: `https://media.giphy.com/media/${id}/200.gif`}}})
const page = (data, offset = 0) => ({data, pagination: {offset, count: data.length, total_count: 100}})
test('preserves exact query with fixed safe rating and bounded page size', () => {
  const url = new URL(searchURL('a & b', 'en', 'public-test-key', 8))
  assert.equal(url.searchParams.get('q'), 'a & b')
  assert.equal(url.searchParams.get('rating'), 'g')
  assert.equal(url.searchParams.get('limit'), '8')
  assert.equal(url.searchParams.get('offset'), '8')
  assert.throws(() => searchURL('x'.repeat(51), 'en', 'test', 0))
})
test('preserves order and full media URL and caps pagination', () => {
  const result = parsePage(page([item('b'), item('a')]), 0)
  assert.deepEqual(result.items.map(i => i.id), ['b','a'])
  assert.ok(result.items[0].still.endsWith('?x=1'))
  assert.equal(parsePage(page([item('a')],16),16).more, false)
  assert.deepEqual(parsePage(page([]),0), {items: [], more:false})
})
test('rejects unsafe URLs, wrong pagination and malformed payloads', () => {
  const bad = item('a'); bad.url = 'javascript:alert(1)'
  assert.throws(() => parsePage(page([bad]),0))
  assert.throws(() => parsePage(page([item('a')],8),0))
  assert.throws(() => parsePage({},0))
})
test('parses Retry-After seconds and dates conservatively', () => {
  assert.equal(retryDelay('120'),120000)
  assert.equal(retryDelay(null),60000)
  assert.equal(retryDelay('Thu, 01 Jan 1970 00:01:00 GMT',0),60000)
})
test('duplicate in-flight calls do not fetch', async () => {
  await Hook.load.call({busy:true, alive:true})
})
test('destroy cancels requests and clears transient results', () => {
  let aborted=false, cleared=false
  const ctx={alive:true,controller:{abort(){aborted=true}},more:{removeEventListener(){}},motion:{removeEventListener(){}},list:{replaceChildren(){cleared=true}}}
  Hook.destroyed.call(ctx)
  assert.equal(ctx.alive,false); assert.ok(aborted); assert.ok(cleared)
})
function context() {
  return {alive:true,busy:false,offset:0,pagesLoaded:0,el:{dataset:{query:'mountain',language:'en',apiKey:'test'}},status:{textContent:''},more:{hidden:true},addItem(){throw new Error('Unexpected item')}}
}
test('network failure is nonblocking and does not automatically retry', async () => {
  const old=globalThis.fetch; let calls=0
  globalThis.fetch=async () => {calls++;throw new TypeError('network')}
  try { const ctx=context();await Hook.load.call(ctx);assert.equal(calls,1);assert.equal(ctx.busy,false);assert.match(ctx.status.textContent,/unavailable/)} finally {globalThis.fetch=old}
})
test('response arriving after navigation cannot append stale GIFs', async () => {
  const old=globalThis.fetch; let release
  globalThis.fetch=() => new Promise(resolve => {release=resolve})
  try {
    const ctx=context();const pending=Hook.load.call(ctx)
    ctx.alive=false
    release({ok:true,status:200,json:async()=>page([item('a')])})
    await pending;assert.equal(ctx.offset,0)
  } finally {globalThis.fetch=old}
})
test('three partial pages stop pagination before a fourth request', async () => {
  const old=globalThis.fetch;let calls=0
  globalThis.fetch=async url=>{
    const offset=Number(new URL(url).searchParams.get('offset'))
    calls++
    return {ok:true,status:200,json:async()=>page([item(`partial-${calls}`)],offset)}
  }
  try {
    const ctx=context();ctx.addItem=()=>{}
    await Hook.load.call(ctx);await Hook.load.call(ctx);await Hook.load.call(ctx);await Hook.load.call(ctx)
    assert.equal(calls,3);assert.equal(ctx.offset,3);assert.equal(ctx.pagesLoaded,3);assert.equal(ctx.more.hidden,true)
  } finally {globalThis.fetch=old}
})
test('rate limit pauses subsequent visits without further fetches', async () => {
  const old=globalThis.fetch;let calls=0
  globalThis.fetch=async()=>{calls++;return {status:429,headers:{get:()=> '60'}}}
  try {
    const ctx=context();await Hook.load.call(ctx);await Hook.load.call(context())
    assert.equal(calls,1);assert.match(ctx.status.textContent,/paused/)
  } finally {globalThis.fetch=old}
})

// A frame, wired the way addItem wires it, against a stub DOM: enough of
// document/li/img/button for the listeners, and a motion query we control.
function frame(reduced = false) {
  const nodes = []
  const make = tag => {
    const listeners = {}
    const attrs = {}
    const node = {tag, dataset: {}, className: '', textContent: '', children: nodes,
      addEventListener(type, fn) { (listeners[type] ||= []).push(fn) },
      fire(type, event) { for (const fn of listeners[type] || []) fn(event) },
      contains(node) { return nodes.includes(node) },
      setAttribute(k, v) { attrs[k] = v }, getAttribute(k) { return attrs[k] ?? null },
      append(...kids) { nodes.push(...kids) }, prepend() {}, querySelector() { return null }}
    return node
  }
  const old = globalThis.document
  globalThis.document = {createElement: make}
  const list = {items: [], append(li) { this.items.push(li) }, querySelectorAll(sel) {
    const [li] = this.items
    if (sel === '[aria-pressed="true"]') return li && li.play.getAttribute('aria-pressed') === 'true' ? [li.play] : []
    if (sel === 'img[data-still]') return li ? [li.image] : []
    return []
  }}
  const ctx = {list, motion: {matches: reduced}}
  try { Hook.addItem.call(ctx, {id: 'g', title: 'g', still: 'S', animated: 'A', url: 'https://giphy.com/gifs/g'}) } finally { globalThis.document = old }
  const li = list.items[0]
  const [image, play] = nodes.filter(n => n.tag === 'img' || n.tag === 'button')
  li.image = image; li.play = play
  return {li, image, play, ctx, onMotion: () => {
    for (const button of list.querySelectorAll('[aria-pressed="true"]')) button.fire('click')
    if (ctx.motion.matches) for (const img of list.querySelectorAll('img[data-still]')) img.src = img.dataset.still
  }}
}
test('hover and focus play a frame; leaving it stops it', () => {
  const {li, image} = frame()
  assert.equal(image.src, 'S')
  li.fire('mouseenter'); assert.equal(image.src, 'A')
  li.fire('mouseleave'); assert.equal(image.src, 'S')
  li.fire('focusin'); assert.equal(image.src, 'A')
  li.fire('focusout'); assert.equal(image.src, 'S')
})
test('pointer and focus are separate intents: the frame plays while either holds it', () => {
  const {li, image} = frame()
  li.fire('mouseenter'); li.fire('focusin'); assert.equal(image.src, 'A')
  li.fire('mouseleave'); assert.equal(image.src, 'A', 'focus still holds the frame')
  li.fire('focusout'); assert.equal(image.src, 'S')
  li.fire('focusin'); li.fire('mouseenter'); assert.equal(image.src, 'A')
  li.fire('focusout'); assert.equal(image.src, 'A', 'the pointer still holds the frame')
  li.fire('mouseleave'); assert.equal(image.src, 'S')
})
test('focus moving between the frame\'s own controls does not stop it', () => {
  const {li, image, play} = frame()
  li.fire('focusin'); assert.equal(image.src, 'A')
  li.fire('focusout', {relatedTarget: play}); assert.equal(image.src, 'A')
  li.fire('focusout', {relatedTarget: null}); assert.equal(image.src, 'S')
})
test('a pressed frame keeps playing when the pointer leaves, and hover never unpresses it', () => {
  const {li, image, play} = frame()
  play.fire('click'); assert.equal(image.src, 'A'); assert.equal(play.getAttribute('aria-pressed'), 'true')
  li.fire('mouseenter'); li.fire('mouseleave'); assert.equal(image.src, 'A')
  assert.equal(play.getAttribute('aria-pressed'), 'true')
  play.fire('click'); assert.equal(image.src, 'S')
})
test('under reduced motion hover never swaps the still, and Play still works', () => {
  const {li, image, play} = frame(true)
  li.fire('mouseenter'); assert.equal(image.src, 'S')
  li.fire('focusin'); assert.equal(image.src, 'S')
  play.fire('click'); assert.equal(image.src, 'A')
  play.fire('click'); assert.equal(image.src, 'S')
})
test('reduced motion switching on mid-hover puts a hovered frame back to its still', () => {
  const {li, image, ctx, onMotion} = frame(false)
  li.fire('mouseenter'); assert.equal(image.src, 'A')
  ctx.motion.matches = true; onMotion(); assert.equal(image.src, 'S')
})
