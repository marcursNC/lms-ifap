import test from 'node:test'
import assert from 'node:assert/strict'
import { enrollmentActions, isCourseOwnerAdmin, ENROLLMENT_LABELS, isActiveEnrollment, isCompleted } from '../lib/enrollment-rules.mjs'

const none = { validate: false, needsReason: false, revoke: false, cancel: false, reactivate: false }
const row = (status, extra = {}) => ({ status, attestation_id: null, revoked_at: null, ...extra })

test('à valider : validation sans motif, annulation', () => {
  assert.deepEqual(enrollmentActions(row('awaiting_validation')), { ...none, validate: true, cancel: true })
})
test('en cours : validation avec motif, annulation', () => {
  assert.deepEqual(enrollmentActions(row('in_progress')), { ...none, validate: true, needsReason: true, cancel: true })
})
test('attestée : seule la révocation', () => {
  assert.deepEqual(enrollmentActions(row('completed', { attestation_id: 'a' })), { ...none, revoke: true })
})
test('révoquée : nouvelle délivrance avec motif', () => {
  assert.deepEqual(enrollmentActions(row('completed', { attestation_id: 'a', revoked_at: '2027-01-01' })), { ...none, validate: true, needsReason: true })
})
test('annulée : réactivation seule ; en attente : accepter ou annuler', () => {
  assert.deepEqual(enrollmentActions(row('cancelled')), { ...none, reactivate: true })
  assert.deepEqual(enrollmentActions(row('pending')), { ...none, cancel: true, reactivate: true })
})
test('propriétaire : administrateur seulement', () => {
  const course = { owner_organization_id: 'ifap' }
  assert.equal(isCourseOwnerAdmin(course, [{ organization_id: 'ifap', role: 'org_admin' }]), true)
  assert.equal(isCourseOwnerAdmin(course, [{ organization_id: 'x', role: 'platform_admin' }]), true)
  assert.equal(isCourseOwnerAdmin(course, [{ organization_id: 'ifap', role: 'trainer' }]), false)
  assert.equal(isCourseOwnerAdmin(course, [{ organization_id: 'colA', role: 'org_admin' }]), false)
  assert.equal(isCourseOwnerAdmin(null, []), false)
})
test('progression à 100 % en attente de validation : pas terminée', () => {
  assert.equal(isCompleted({ status: 'awaiting_validation', progress: 100 }), false)
  assert.equal(isCompleted({ status: 'completed', progress: 100 }), true)
  assert.equal(isActiveEnrollment({ status: 'cancelled' }), false)
  assert.equal(isActiveEnrollment({ status: 'awaiting_validation' }), true)
  assert.equal(ENROLLMENT_LABELS.awaiting_validation, 'À valider')
})
