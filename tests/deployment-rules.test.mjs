import test from 'node:test'
import assert from 'node:assert/strict'
import { deployTargets, enrollmentModes, canManageDeployment, canEditCourse, canEnroll, frenchError } from '../lib/deployment-rules.mjs'

const ifap = { organization_id: 'ifap', role: 'org_admin', organizations: { name: 'IFAP', kind: 'ifap' } }
const trainer = { ...ifap, role: 'trainer' }
const col = { organization_id: 'colA', role: 'org_admin', organizations: { name: 'A', kind: 'collectivite' } }
const clients = [{ id: 'colA', name: 'A', kind: 'collectivite' }, { id: 'org', name: 'O', kind: 'organisme' }]
const priv = { owner_organization_id: 'ifap', status: 'published', visibility: 'private', organizations: { name: 'IFAP', kind: 'ifap' } }
// la collectivité ne peut pas lire la fiche de l'organisation IFAP
const cat = { owner_organization_id: 'ifap', status: 'published', visibility: 'ifap_catalog', organizations: null }
const ids = list => list.map(o => o.id).sort()

test('admin IFAP : son organisation et les clients', () => {
  assert.deepEqual(ids(deployTargets(priv, [ifap], clients)), ['colA', 'ifap', 'org'])
})
test('formateur IFAP et apprenant : aucune cible', () => {
  assert.deepEqual(deployTargets(priv, [trainer], []), [])
  assert.deepEqual(deployTargets(cat, [{ ...col, role: 'learner' }], []), [])
})
test('collectivité : catalogue pour elle seule, jamais une privée IFAP', () => {
  assert.deepEqual(ids(deployTargets(cat, [col], [])), ['colA'])
  assert.deepEqual(deployTargets(priv, [col], []), [])
})
test('collectivité : sa propre formation reste chez elle', () => {
  const own = { owner_organization_id: 'colA', status: 'published', visibility: 'private', organizations: { name: 'A', kind: 'collectivite' } }
  assert.deepEqual(ids(deployTargets(own, [col], [])), ['colA'])
})
test('brouillon : aucune cible', () => {
  assert.deepEqual(deployTargets({ ...priv, status: 'draft' }, [ifap], clients), [])
})
test('modes : ni lien, ni auto-inscription pour une privée envoyée', () => {
  assert.deepEqual(enrollmentModes(priv, 'colA'), ['manager', 'prescribed', 'employer'])
  assert.deepEqual(enrollmentModes(priv, 'ifap'), ['manager', 'prescribed', 'employer', 'self_service'])
  assert.deepEqual(enrollmentModes(cat, 'colA'), ['manager', 'prescribed', 'employer', 'self_service'])
})
test('seule l’organisation à l’origine gère le déploiement', () => {
  const dep = { initiated_by_organization_id: 'ifap', target_organization_id: 'colA' }
  assert.equal(canManageDeployment(dep, [ifap]), true)
  assert.equal(canManageDeployment(dep, [col]), false)
  assert.equal(canManageDeployment(dep, [trainer]), false)
  assert.equal(canEnroll(dep, [col]), true)
  assert.equal(canEnroll(dep, [{ ...col, role: 'trainer' }]), true)
  assert.equal(canEnroll(dep, [ifap]), false)
})
test('modification de la formation réservée au propriétaire', () => {
  assert.equal(canEditCourse(priv, [trainer]), true)
  assert.equal(canEditCourse(priv, [col]), false)
})
test('messages d’erreur en français', () => {
  assert.match(frenchError({ code: '42501', message: 'new row violates row-level security policy' }), /pas le droit/)
  assert.match(frenchError({ code: '23505', message: 'duplicate key' }), /existe déjà/)
  assert.equal(frenchError({ code: 'P0001', message: 'Seule une formation publiée peut être déployée' }), 'Seule une formation publiée peut être déployée')
  assert.match(frenchError({ message: 'Failed to fetch' }), /a échoué/)
})
