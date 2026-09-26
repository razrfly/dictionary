"""Stage 2 candidate population, derived read-only from the 26 September
routing audit manifest. Reproducible: same inputs, same output."""
import gzip, json, collections, hashlib, re, sys

AUD = 'data/audits/2026-09-26-issue194'
rows = {r['object_id']: r for r in map(json.loads, gzip.open(f'{AUD}/assignments.jsonl.gz', 'rt'))}
inp = {}
for line in gzip.open(f'{AUD}/input.jsonl.gz', 'rt'):
    r = json.loads(line)
    if r.get('record_type') == 'entity':
        inp[r['object_id']] = r

boundary = [json.loads(l)['object_id'] for l in open('docs/audits/2026-09-26-issue194/policy-boundaries.jsonl')]
stratified = [r['object_id'] for r in json.load(open('docs/audits/2026-09-26-issue194/stratified-review.json'))['records']]

# Named ADR edge cases, found by exact (case-insensitive) label in the snapshot.
names = ['c++', 'c+', 'c', 'polish', 'mercury', 'apple', 'voltaire', 'putin', 'vladimir putin',
         'poutine', 'love', 'ambrose bierce', "the devil's dictionary", 'earthquake', 'human']
by_label = collections.defaultdict(list)
for oid, r in rows.items():
    by_label[(r['label'] or '').lower()].append(oid)
named = sorted({oid for n in names for oid in by_label.get(n, [])})

reasons = collections.defaultdict(set)
for oid in boundary: reasons[oid].add('boundary_example')
for oid in stratified: reasons[oid].add('stratified_sample')
for oid in named: reasons[oid].add('named_edge_case')
seed = set(reasons)

# Collision closure: a group is decided together (ADR §5), so every member of
# a group touching the seed joins, with its own disposition.
paths = collections.defaultdict(list)
for oid, r in rows.items():
    if r.get('candidate_path'):
        paths[r['candidate_path']].append(oid)
groups = {p: sorted(m) for p, m in paths.items() if len(m) > 1}
touched = {p: m for p, m in groups.items() if any(o in seed for o in m)}
for p, members in touched.items():
    for oid in members:
        reasons[oid].add('collision_group_member')

KINDS = ['studio album', 'album', 'film', 'documentary', 'novel', 'tv series', 'series', 'song',
         'poem', 'painting', 'anthology', 'book', 'play', 'single', 'video game', 'dictionary']

def qualifier(oid):
    """A readable, evidence-backed qualifier by family (ADR §5): a work's year,
    kind and creator; a person's occupation and dates; a place's location; an
    organization's origin and type. Only from the record's own description or
    typed details — never invented."""
    e = inp.get(oid, {}); r = rows[oid]
    desc = (e.get('description') or '').strip()
    fam = r['family'] or (r['candidate_families'][0] if len(r['candidate_families']) == 1 else None)
    low = desc.lower()
    if not desc:
        return None, None, 'no description to qualify from'
    if fam == 'works':
        year = (re.search(r'\b(1[0-9]{3}|20[0-9]{2})\b', desc) or [None])[0]
        kind = next((k for k in KINDS if k in low), e.get('work_kind'))
        kind = 'album' if kind == 'studio album' else kind
        creator = re.search(r'\bby ([^,;(]+)', desc)
        base = ' '.join(x for x in [year, kind] if x)
        extra = creator.group(1).strip() if creator else None
        return (base or None), extra, f'description "{desc[:90]}"'
    if fam == 'people':
        years = re.search(r'\((\d{4})[-–]', desc)
        occ = re.sub(r'\(.*?\)', '', desc).strip()
        words = [w for w in re.findall(r"[\w'’-]+", occ) if w.lower() not in {'and', 'of', 'the'}]
        base = ' '.join(words[-2:]) if words else None
        return base, (years.group(1) if years else ' '.join(words[:1]) or None), f'description "{desc[:90]}"'
    if fam == 'places':
        m = re.search(r'\bin (?:the )?([^,]+)', desc)
        return (m.group(1).strip() if m else None), None, f'description "{desc[:90]}"'
    words = [w for w in re.findall(r"[\w'’-]+", desc) if w.lower() not in {'a', 'an', 'the', 'of'}]
    base = f'{words[0]} {words[-1]}' if len(words) > 1 else (words[0] if words else None)
    return base, None, f'description "{desc[:90]}"'

def slug(text):
    t = text.lower()
    for a, b in [('+', '-plus-'), ('#', '-sharp-'), ('&', '-and-'), ('.', '-dot-')]:
        t = t.replace(a, b)
    t = re.sub(r"['’]", '', t)
    t = re.sub(r'[^\w]+', '-', t, flags=re.U).replace('_', '-')
    t = re.sub(r'-+', '-', t).strip('-')
    return t if t and len(t.encode()) <= 120 else None

records = []
for oid in sorted(reasons):
    r = rows[oid]; e = inp.get(oid, {})
    status, addr = r['status'], r['address_status']
    rec = {
        'object_id': oid, 'label': r['label'], 'stored_kind': r['stored_kind'],
        'description': (e.get('description') or '')[:120], 'status': status,
        'candidate_families': r['candidate_families'], 'family': r['family'] if status == 'mapped' else None,
        'candidate_path': r.get('candidate_path'), 'address_status': addr,
        'selected_because': sorted(reasons[oid]),
    }
    if status == 'excluded_source_page':
        rec['disposition'] = 'excluded: source page; never a subject address (can inform a future choice/collection page, whose namespace is undefined)'
    elif status == 'identity_review':
        rec['disposition'] = 'deferred: identity lifecycle review first (split/merged registry identity)'
    elif addr == 'collision_review':
        base, extra, why = qualifier(oid)
        fam = r['family'] or (r['candidate_families'][0] if len(r['candidate_families']) == 1 else None)
        rec['qualifier_evidence'] = why
        rec['_base'], rec['_extra'], rec['_fam'] = base, extra, fam
        rec['disposition'] = 'pending'
    elif addr == 'candidate':
        rec['disposition'] = 'allocation candidate after classification review confirms the mapping'
    elif addr == 'classification_review':
        rec['disposition'] = 'classification review: sole candidate family needs a human decision'
    else:
        rec['disposition'] = 'deferred: no family evidence; stays unaddressed and visible'
    records.append(rec)

# Collision groups, decided together. A group where members of one family
# share a label and some member has no description may be one subject twice:
# duplicate-identity review comes before any qualifier (ADR §5).
by_id = {r['object_id']: r for r in records}
all_candidate_paths = set(paths)
for p, members in touched.items():
    recs = [by_id[o] for o in members]
    mapped = [r for r in recs if r['status'] == 'mapped']
    if any(not r['description'] for r in recs):
        for r in recs:
            r['disposition'] = 'duplicate-identity review first: same name, too little evidence to tell apart'
            r['proposed_path'] = None
        continue
    for r in recs:
        if r['status'] != 'mapped':
            r['disposition'] = 'collision review blocked: classification review first'
            r['proposed_path'] = None
    # Base qualifier first; add the extra (creator, dates) only where needed.
    def path_for(r, extra):
        text = ' '.join(x for x in [r['label'], r['_base'], r['_extra'] if extra else None] if x)
        s_ = slug(text) if r['_base'] else None
        return f"/{r['_fam']}/{s_}" if s_ and r['_fam'] else None
    first = {r['object_id']: path_for(r, False) for r in mapped}
    counts = collections.Counter(first.values())
    for r in mapped:
        p1 = first[r['object_id']]
        r['proposed_path'] = p1 if p1 and counts[p1] == 1 else path_for(r, True)
    final = collections.Counter(r['proposed_path'] for r in mapped)
    for r in mapped:
        pp = r['proposed_path']
        if pp is None:
            r['disposition'] = 'collision review: no evidence for a readable qualifier; hold'
        elif final[pp] > 1 or pp in all_candidate_paths:
            r['disposition'] = 'collision review: qualifier still collides; hold for a human-chosen qualifier'
            r['proposed_path_conflict'] = True
        else:
            r['disposition'] = 'collision review: proposed readable qualifier, needs human approval'
for r in records:
    for k in ('_base', '_extra', '_fam'):
        r.pop(k, None)

summary = {
    'source': 'data/audits/2026-09-26-issue194/assignments.jsonl.gz (policy 1.0.0, 100,723 entities, read-only)',
    'selection': 'policy boundary examples (54) + stratified mapped sample (46) + named ADR edge cases present in the snapshot + every member of each candidate-path collision group touching those',
    'records': len(records),
    'by_reason': dict(collections.Counter(x for r in records for x in r['selected_because'])),
    'by_status': dict(collections.Counter(r['status'] for r in records)),
    'by_family_mapped': dict(collections.Counter(r['family'] for r in records if r['family'])),
    'by_disposition': dict(collections.Counter(r['disposition'].split(':')[0] for r in records)),
    'collision_groups_touched': len(touched),
    'collision_group_sizes': dict(collections.Counter(len(m) for m in touched.values())),
    'named_found': sorted({rows[o]['label'] for o in named}),
    'named_missing': sorted(n for n in names if n not in by_label),
    'deferred_outside_population': len(rows) - len(records),
}
out = {'summary': summary, 'groups': {p: m for p, m in sorted(touched.items())}, 'records': records}
blob = json.dumps(out, ensure_ascii=False, indent=1, sort_keys=True)
out['summary']['sha256_of_records'] = hashlib.sha256(json.dumps(records, sort_keys=True, ensure_ascii=False).encode()).hexdigest()
json.dump(out, open(sys.argv[1], 'w'), ensure_ascii=False, indent=1, sort_keys=True)
print(json.dumps(summary, indent=1, ensure_ascii=False))
