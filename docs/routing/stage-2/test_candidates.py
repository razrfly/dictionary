"""Regressions for the Stage 2 proposal generator.

Run with: python3 -m unittest discover -s docs/routing/stage-2 -p 'test_candidates.py'
"""
import gzip
import hashlib
import importlib.util
import json
import subprocess
import sys
import tempfile
import unicodedata
import unittest
from pathlib import Path

HERE = Path(__file__).parent
SCRIPT = HERE / 'candidates.py'

spec = importlib.util.spec_from_file_location('candidates', SCRIPT)
candidates = importlib.util.module_from_spec(spec)
spec.loader.exec_module(candidates)


def assignment(oid, label, path, status='mapped', family='works', address='collision_review'):
    return {'object_id': oid, 'label': label, 'stored_kind': 'work', 'status': status,
            'candidate_families': [family], 'family': family if status == 'mapped' else None,
            'candidate_path': path, 'address_status': address, 'policy_version': '1.0.0'}


def entity(oid, description):
    return {'record_type': 'entity', 'object_id': oid, 'description': description}


# Two collision groups whose proposals meet only once normalized: object 1's
# label is decomposed (NFD), object 3's composed.
ASSIGNMENTS = [
    assignment(1, 'Café', '/works/café'),
    assignment(2, 'Café', '/works/café'),
    assignment(3, 'Café 2019', '/works/café-2019'),
    assignment(4, 'Café 2019', '/works/café-2019'),
    assignment(5, 'Solo', '/works/solo', address='candidate'),
]
ENTITIES = [
    entity(1, '2019 film by Ann Lee'),
    entity(2, '2021 novel by Bo Chen'),
    entity(3, 'film'),
    entity(4, 'album'),
    entity(5, '1999 song'),
]


def lines(records):
    return ''.join(json.dumps(r, ensure_ascii=False) + '\n' for r in records).encode()


class Audit:
    """A synthetic audit directory, shaped like `mix dd.routing.audit` output."""

    def __init__(self, directory, assignments=ASSIGNMENTS, entities=ENTITIES, gzip_input=False,
                 summary=None):
        self.dir = Path(directory)
        (self.dir / 'assignments.jsonl').write_bytes(lines(assignments))
        export = lines([{'record_type': 'snapshot'}] + entities)
        self.input = self.dir / ('input.jsonl.gz' if gzip_input else 'input.jsonl')
        if gzip_input:
            with gzip.open(self.input, 'wb') as f:
                f.write(export)
        else:
            self.input.write_bytes(export)
        base = {'input_sha256': hashlib.sha256(export).hexdigest(), 'entities': len(assignments),
                'policy_version': '1.0.0', 'policy_sha256': 'policy-digest'}
        base.update(summary or {})
        (self.dir / 'summary.json').write_text(json.dumps({k: v for k, v in base.items() if v is not None}))
        (self.dir / 'boundaries.jsonl').write_text('{"object_id": 1}\n{"object_id": 3}\n')
        (self.dir / 'stratified.json').write_text('{"records": [{"object_id": 5}]}')
        self.out = self.dir / 'out.json'

    def run(self, input_path=None):
        return subprocess.run(
            [sys.executable, str(SCRIPT), str(self.out), '--audit', str(self.dir),
             '--input', str(input_path or self.input),
             '--boundaries', str(self.dir / 'boundaries.jsonl'),
             '--stratified', str(self.dir / 'stratified.json')],
            capture_output=True, text=True, check=False)

    def output(self):
        return json.loads(self.out.read_text())


class SlugParityTest(unittest.TestCase):
    """The same file `test/devils_dictionary/routing/slug_parity_test.exs`
    holds `Routing.Policy.slug/1` to."""

    def test_every_parity_case(self):
        cases = json.loads((HERE / 'slug-parity.json').read_text())['cases']
        self.assertGreater(len(cases), 20)
        for case in cases:
            with self.subTest(case=case['case']):
                self.assertEqual(candidates.slug(case['input']), case['slug'])

    def test_canonically_equivalent_text_gives_one_slug(self):
        self.assertEqual(candidates.slug('Café 2020 film'), candidates.slug('Café 2020 film'))

    def test_words_keep_combining_marks(self):
        self.assertEqual(candidates.words('हिन्दी film, 2020'), ['हिन्दी', 'film', '2020'])
        self.assertEqual(candidates.words("Devil’s co-op"), ["Devil’s", 'co-op'])


class InputBindingTest(unittest.TestCase):
    def test_matching_inputs_derive_candidates_and_record_their_digests(self):
        for gzip_input in (False, True):
            with self.subTest(gzip_input=gzip_input), tempfile.TemporaryDirectory() as d:
                audit = Audit(d, gzip_input=gzip_input)
                result = audit.run()
                self.assertEqual(result.returncode, 0, result.stderr)
                inputs = audit.output()['summary']['inputs']
                summary = json.loads((audit.dir / 'summary.json').read_text())
                self.assertEqual(inputs['input_sha256'], summary['input_sha256'])
                self.assertEqual(inputs['policy_sha256'], 'policy-digest')
                self.assertEqual(inputs['assignments_sha256'], hashlib.sha256(
                    (audit.dir / 'assignments.jsonl').read_bytes()).hexdigest())

    def test_same_ids_with_changed_evidence_are_refused(self):
        with tempfile.TemporaryDirectory() as d:
            audit = Audit(d)
            changed = [entity(1, '2026 documentary by Audit Probe')] + ENTITIES[1:]
            other = audit.dir / 'changed.jsonl'
            other.write_bytes(lines([{'record_type': 'snapshot'}] + changed))
            result = audit.run(other)
            self.assertNotEqual(result.returncode, 0)
            self.assertIn('is not the one this audit read', result.stderr)
            self.assertFalse(audit.out.exists())

    def test_an_audit_without_an_input_digest_is_refused(self):
        with tempfile.TemporaryDirectory() as d:
            audit = Audit(d, summary={'input_sha256': None})
            result = audit.run()
            self.assertNotEqual(result.returncode, 0)
            self.assertIn('records no input_sha256', result.stderr)
            (audit.dir / 'summary.json').unlink()
            result = audit.run()
            self.assertIn('no audit summary', result.stderr)
            self.assertFalse(audit.out.exists())

    def test_a_summary_for_other_assignments_is_refused(self):
        with tempfile.TemporaryDirectory() as d:
            result = Audit(d, summary={'entities': 6}).run()
            self.assertNotEqual(result.returncode, 0)
            self.assertIn('counts 6 entities', result.stderr)
        with tempfile.TemporaryDirectory() as d:
            result = Audit(d, summary={'policy_version': '2.0.0'}).run()
            self.assertNotEqual(result.returncode, 0)
            self.assertIn('policy 2.0.0', result.stderr)

    def test_duplicate_identities_are_refused_not_overwritten(self):
        with tempfile.TemporaryDirectory() as d:
            twice = ASSIGNMENTS + [assignment(2, 'Café again', '/works/café')]
            audit = Audit(d, assignments=twice, summary={'entities': len(twice)})
            result = audit.run()
            self.assertNotEqual(result.returncode, 0)
            self.assertIn('appear more than once', result.stderr)
            self.assertIn('[2]', result.stderr)
        with tempfile.TemporaryDirectory() as d:
            audit = Audit(d, entities=ENTITIES + [entity(3, '2026 documentary')])
            result = audit.run()
            self.assertNotEqual(result.returncode, 0)
            self.assertIn('appear more than once', result.stderr)
            self.assertFalse(audit.out.exists())

    def test_an_export_missing_an_audited_entity_is_refused(self):
        with tempfile.TemporaryDirectory() as d:
            result = Audit(d, entities=ENTITIES[:-1]).run()
            self.assertNotEqual(result.returncode, 0)
            self.assertIn('missing from the export', result.stderr)


class NormalizedCollisionTest(unittest.TestCase):
    def test_proposals_are_normalized_and_collide_across_groups(self):
        with tempfile.TemporaryDirectory() as d:
            audit = Audit(d)
            result = audit.run()
            self.assertEqual(result.returncode, 0, result.stderr)
            records = {r['object_id']: r for r in audit.output()['records']}

            # The decomposed label proposes the same, composed address as the
            # composed one would: the application's slug, not a damaged one.
            self.assertEqual(records[1]['proposed_path'], '/works/café-2019-film')
            self.assertTrue(unicodedata.is_normalized('NFC', records[1]['proposed_path']))
            self.assertEqual(records[2]['proposed_path'], '/works/café-2021-novel')

            # Group /works/café-2019 proposes the same address for object 3,
            # so both are held for a human-chosen qualifier.
            self.assertEqual(records[3]['proposed_path'], '/works/café-2019-film')
            self.assertTrue(records[1].get('proposed_path_conflict'))
            self.assertTrue(records[3].get('proposed_path_conflict'))
            self.assertFalse(records[2].get('proposed_path_conflict'))
            self.assertFalse(records[4].get('proposed_path_conflict'))
            self.assertEqual(audit.output()['summary']['global_proposal_conflicts'], 2)


if __name__ == '__main__':
    unittest.main()
