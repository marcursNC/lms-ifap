// Règles d'affichage des inscriptions. La base reste seule juge.

export const ENROLLMENT_LABELS = {
  pending: 'En attente',
  not_started: 'Non commencée',
  enrolled: 'Inscrit',
  started: 'En cours',
  in_progress: 'En cours',
  awaiting_validation: 'À valider',
  completed: 'Terminée',
  cancelled: 'Annulée'
}

export const isActiveEnrollment = enrollment => enrollment.status !== 'cancelled'
export const isCompleted = enrollment => enrollment.status === 'completed'

export const isCourseOwnerAdmin = (course, memberships) =>
  Boolean(course) && memberships.some(m =>
    m.role === 'platform_admin' || (m.organization_id === course.owner_organization_id && m.role === 'org_admin'))

// row : une ligne de list_course_enrollments, ou toute inscription { status, attestation_id?, revoked_at? }.
export function enrollmentActions(row) {
  const { status } = row
  const attested = Boolean(row.attestation_id) && !row.revoked_at
  const validate = !['cancelled', 'pending'].includes(status) && !attested
  return {
    validate,
    needsReason: validate && status !== 'awaiting_validation',
    revoke: attested,
    cancel: !['cancelled', 'completed'].includes(status),
    reactivate: ['cancelled', 'pending'].includes(status)
  }
}
