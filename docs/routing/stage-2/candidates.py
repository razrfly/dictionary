r"""Stage 2 candidate population, derived read-only from a routing audit
manifest. Reproducible: same inputs, same output.

    python3 docs/routing/stage-2/candidates.py OUT.json \
        [--audit DIR] [--input FILE] [--boundaries FILE] [--stratified FILE]

The defaults are the 26 September audit's archives. For a fresh audit, pass
the `mix dd.routing.audit --output` directory as --audit and the export it
read as --input (plain or gzipped JSONL both work).

The inputs are bound to the audit before anything is derived:

* the export's SHA-256, over its uncompressed bytes, must equal the audit
  summary's `input_sha256` (so descriptions cannot come from another
  snapshot than the classifications);
* the audit summary's entity count and policy version must match the
  assignments;
* no object id may appear twice among the assignments or the exported
  entities.

The digests are recorded in the output. The boundary and stratified files
name registry object ids, which a fresh export of the same database keeps; a
selected id missing from the audit is reported, not dropped silently.

Slugs follow `Routing.Policy.slug/1` exactly (NFC, letters, marks and numbers,
the same punctuation words, at most 120 bytes); `slug-parity.json` holds both
implementations to the same cases.

Tests: python3 -m unittest discover -s docs/routing/stage-2 -p 'test_candidates.py'
"""
import argparse
import collections
import gzip
import hashlib
import json
import os
import re
import sys
import unicodedata

KINDS = ['studio album', 'album', 'film', 'documentary', 'novel', 'tv series', 'series', 'song',
         'poem', 'painting', 'anthology', 'book', 'play', 'single', 'video game', 'dictionary']

# Named ADR edge cases, found by exact (case-insensitive) label in the snapshot.
NAMES = ['c++', 'c+', 'c', 'polish', 'mercury', 'apple', 'voltaire', 'putin', 'vladimir putin',
         'poutine', 'love', 'ambrose bierce', "the devil's dictionary", 'earthquake', 'human']


class InputError(SystemExit):
    """An input that cannot be trusted: reported, nothing written."""

    def __init__(self, message):
        super().__init__(f'candidates.py: {message}')


# ── slugs and words, as the application defines them ──────────────────────

def _letter_mark_or_number(ch):
    return unicodedata.category(ch)[0] in 'LMN'


def slug(text):
    """`Routing.Policy.slug/1`, step for step: NFC; lowercase (per character,
    as Elixir's default mode does: a final sigma stays σ); `+ # & .` spelled
    out; apostrophes removed; every run of anything but letters, marks and
    numbers becomes one hyphen; trimmed; NFC again; at most 120 bytes."""
    t = unicodedata.normalize('NFC', text)
    t = ''.join(ch.lower() for ch in t)
    for a, b in (('+', '-plus-'), ('#', '-sharp-'), ('&', '-and-'), ('.', '-dot-')):
        t = t.replace(a, b)
    t = t.replace("'", '').replace('’', '')
    t = ''.join(ch if _letter_mark_or_number(ch) else '-' for ch in t)
    t = re.sub('-+', '-', t).strip('-')
    t = unicodedata.normalize('NFC', t)
    return t if t and len(t.encode()) <= 120 else None


def words(text):
    """Word-like runs: Python's `\\w` (letters, numbers, underscore) plus
    combining marks, which `\\w` would split a word on, and apostrophes and
    hyphens."""
    def word_char(ch):
        return ch.isalnum() or ch in "_'’-" or unicodedata.category(ch)[0] == 'M'

    out, current = [], []
    for ch in text:
        if word_char(ch):
            current.append(ch)
        elif current:
            out.append(''.join(current))
            current = []
    if current:
        out.append(''.join(current))
    return out


def nfc(path):
    return unicodedata.normalize('NFC', path) if path else path


# ── inputs, bound to the audit ────────────────────────────────────────────

def read_bytes(path):
    """A file's uncompressed bytes, gzipped or not; `path` may name either
    form. Returns the bytes and the file actually read."""
    for candidate in [path, path + '.gz', path[:-3] if path.endswith('.gz') else None]:
        if candidate and os.path.exists(candidate):
            opener = gzip.open if candidate.endswith('.gz') else open
            with opener(candidate, 'rb') as f:
                return f.read(), candidate
    raise InputError(f'no such file: {path}[.gz]')


def jsonl(data):
    return [json.loads(line) for line in data.decode('utf-8').splitlines() if line.strip()]


def sha256(data):
    return hashlib.sha256(data).hexdigest()


def unique_by_id(records, what):
    """Records keyed by object id; an id twice is refused, not overwritten."""
    counts = collections.Counter(r['object_id'] for r in records)
    twice = sorted(oid for oid, n in counts.items() if n > 1)
    if twice:
        raise InputError(f'{len(twice)} object ids appear more than once in {what} '
                         f'(first: {twice[:5]}); each identity must appear exactly once')
    return {r['object_id']: r for r in records}


def load(opts):
    audit = opts.audit
    summary_path = os.path.join(audit, 'summary.json')
    if not os.path.exists(summary_path):
        raise InputError(f'no audit summary at {summary_path}; the export cannot be checked')
    with open(summary_path) as f:
        audit_summary = json.load(f)
    expected = audit_summary.get('input_sha256')
    if not expected:
        raise InputError(f'{summary_path} records no input_sha256')

    assignment_bytes, assignments_file = read_bytes(os.path.join(audit, 'assignments.jsonl'))
    input_bytes, input_file = read_bytes(opts.input or os.path.join(audit, 'input.jsonl'))

    actual = sha256(input_bytes)
    if actual != expected:
        raise InputError(
            f"the export {input_file} (SHA-256 {actual}) is not the one this audit read "
            f"(input_sha256 {expected}); descriptions and classifications would come from "
            f"different snapshots. Pass the export the audit read as --input")

    rows = unique_by_id(jsonl(assignment_bytes), assignments_file)
    inp = unique_by_id([r for r in jsonl(input_bytes) if r.get('record_type') == 'entity'],
                       f'the entities of {input_file}')

    if audit_summary.get('entities') != len(rows):
        raise InputError(f"{summary_path} counts {audit_summary.get('entities')} entities, "
                         f'but {assignments_file} has {len(rows)}')
    versions = sorted({r['policy_version'] for r in rows.values()})
    if versions != [audit_summary.get('policy_version')]:
        raise InputError(f"{summary_path} is policy {audit_summary.get('policy_version')}, "
                         f'but the assignments are policy {", ".join(versions)}')

    # Belt and braces: an entity missing from the export would look
    # undescribed and silently turn its group into a duplicate-identity review.
    unexported = sorted(set(rows) - set(inp))
    if unexported:
        raise InputError(f'{len(unexported)} audited entities are missing from the export '
                         f'(first: {unexported[:5]}); pass the export this audit read as --input')

    provenance = {
        'audit_summary': summary_path,
        'assignments': assignments_file,
        'assignments_sha256': sha256(assignment_bytes),
        'input': input_file,
        'input_sha256': actual,
        'policy_version': audit_summary.get('policy_version'),
        'policy_sha256': audit_summary.get('policy_sha256'),
    }
    return rows, inp, provenance


# ── derivation ────────────────────────────────────────────────────────────

def qualifier(e, r):
    """A readable, evidence-backed qualifier by family (ADR §5): a work's year,
    kind and creator; a person's occupation and dates; a place's location; an
    organization's origin and type. Only from the record's own description or
    typed details — never invented."""
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
        ws = [w for w in words(occ) if w.lower() not in {'and', 'of', 'the'}]
        base = ' '.join(ws[-2:]) if ws else None
        return base, (years.group(1) if years else ' '.join(ws[:1]) or None), f'description "{desc[:90]}"'
    if fam == 'places':
        m = re.search(r'\bin (?:the )?([^,]+)', desc)
        return (m.group(1).strip() if m else None), None, f'description "{desc[:90]}"'
    ws = [w for w in words(desc) if w.lower() not in {'a', 'an', 'the', 'of'}]
    base = f'{ws[0]} {ws[-1]}' if len(ws) > 1 else (ws[0] if ws else None)
    return base, None, f'description "{desc[:90]}"'


def generate(opts):
    rows, inp, provenance = load(opts)

    with open(opts.boundaries) as f:
        selected_boundary = [json.loads(line)['object_id'] for line in f if line.strip()]
    with open(opts.stratified) as f:
        selected_stratified = [r['object_id'] for r in json.load(f)['records']]
    selection_missing = sorted({o for o in selected_boundary + selected_stratified if o not in rows})
    boundary = [o for o in selected_boundary if o in rows]
    stratified = [o for o in selected_stratified if o in rows]

    by_label = collections.defaultdict(list)
    for oid, r in rows.items():
        by_label[(r['label'] or '').lower()].append(oid)
    named = sorted({oid for n in NAMES for oid in by_label.get(n, [])})

    reasons = collections.defaultdict(set)
    for oid in boundary:
        reasons[oid].add('boundary_example')
    for oid in stratified:
        reasons[oid].add('stratified_sample')
    for oid in named:
        reasons[oid].add('named_edge_case')
    seed = set(reasons)

    # Collision closure: a group is decided together (ADR §5), so every member
    # of a group touching the seed joins, with its own disposition.
    paths = collections.defaultdict(list)
    for oid, r in rows.items():
        if r.get('candidate_path'):
            paths[nfc(r['candidate_path'])].append(oid)
    groups = {p: sorted(m) for p, m in paths.items() if len(m) > 1}
    touched = {p: m for p, m in groups.items() if any(o in seed for o in m)}
    for members in touched.values():
        for oid in members:
            reasons[oid].add('collision_group_member')

    records = []
    for oid in sorted(reasons):
        r = rows[oid]
        e = inp.get(oid, {})
        status, addr = r['status'], r['address_status']
        rec = {
            'object_id': oid, 'label': r['label'], 'stored_kind': r['stored_kind'],
            'description': (e.get('description') or '')[:120], 'status': status,
            'candidate_families': r['candidate_families'],
            'family': r['family'] if status == 'mapped' else None,
            'candidate_path': r.get('candidate_path'), 'address_status': addr,
            'selected_because': sorted(reasons[oid]),
        }
        if status == 'excluded_source_page':
            rec['disposition'] = 'excluded: source page; never a subject address (can inform a future choice/collection page, whose namespace is undefined)'
        elif status == 'identity_review':
            rec['disposition'] = 'deferred: identity lifecycle review first (split/merged registry identity)'
        elif addr == 'collision_review':
            base, extra, why = qualifier(e, r)
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

    # Collision groups, decided together. A group where some member has no
    # description may be one subject twice: duplicate-identity review comes
    # before any qualifier (ADR §5).
    by_id = {r['object_id']: r for r in records}
    all_candidate_paths = set(paths)

    def path_for(r, extra):
        text = ' '.join(x for x in [r['label'], r['_base'], r['_extra'] if extra else None] if x)
        s = slug(text) if r['_base'] else None
        return f"/{r['_fam']}/{s}" if s and r['_fam'] else None

    for members in touched.values():
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

    # Addresses are one domain: a proposal must also be unique across groups,
    # and must not be any record's candidate path, compared as normalized.
    proposed = collections.Counter(nfc(r.get('proposed_path')) for r in records if r.get('proposed_path'))
    for r in records:
        pp = nfc(r.get('proposed_path'))
        if pp and (proposed[pp] > 1 or pp in all_candidate_paths) and not r.get('proposed_path_conflict'):
            r['disposition'] = 'collision review: qualifier still collides; hold for a human-chosen qualifier'
            r['proposed_path_conflict'] = True

    for r in records:
        for k in ('_base', '_extra', '_fam'):
            r.pop(k, None)

    summary = {
        'source': f"{provenance['assignments']} (policy {provenance['policy_version']}, {len(rows):,} entities, read-only)",
        'inputs': provenance,
        'global_proposal_conflicts': sum(1 for r in records if r.get('proposed_path_conflict')),
        'selection': f'policy boundary examples ({len(boundary)}) + stratified mapped sample ({len(stratified)}) + named ADR edge cases present in the snapshot + every member of each candidate-path collision group touching those',
        'selection_missing_from_audit': selection_missing,
        'records': len(records),
        'by_reason': dict(collections.Counter(x for r in records for x in r['selected_because'])),
        'by_status': dict(collections.Counter(r['status'] for r in records)),
        'by_family_mapped': dict(collections.Counter(r['family'] for r in records if r['family'])),
        'by_disposition': dict(collections.Counter(r['disposition'].split(':')[0] for r in records)),
        'collision_groups_touched': len(touched),
        'collision_group_sizes': dict(collections.Counter(len(m) for m in touched.values())),
        'named_found': sorted({rows[o]['label'] for o in named}),
        'named_missing': sorted(n for n in NAMES if n not in by_label),
        'deferred_outside_population': len(rows) - len(records),
    }
    summary['sha256_of_records'] = hashlib.sha256(
        json.dumps(records, sort_keys=True, ensure_ascii=False).encode()).hexdigest()
    return {'summary': summary, 'groups': {p: m for p, m in sorted(touched.items())}, 'records': records}


def main(argv=None):
    parser = argparse.ArgumentParser(description=__doc__.split('\n')[0])
    parser.add_argument('out', help='where to write the candidates JSON')
    parser.add_argument('--audit', default='data/audits/2026-09-26-issue194',
                        help='directory holding summary.json and assignments.jsonl[.gz] from mix dd.routing.audit')
    parser.add_argument('--input', help='the export the audit read (default: DIR/input.jsonl[.gz])')
    parser.add_argument('--boundaries', default='docs/audits/2026-09-26-issue194/policy-boundaries.jsonl')
    parser.add_argument('--stratified', default='docs/audits/2026-09-26-issue194/stratified-review.json')
    opts = parser.parse_args(argv)

    out = generate(opts)
    with open(opts.out, 'w') as f:
        json.dump(out, f, ensure_ascii=False, indent=1, sort_keys=True)
    print(json.dumps(out['summary'], indent=1, ensure_ascii=False))


if __name__ == '__main__':
    sys.exit(main())
