// Règles d'affichage du déploiement. La base reste seule juge (RLS et déclencheurs) :
// ces fonctions évitent seulement de proposer une action qui serait refusée.
// memberships : lignes { organization_id, role, organizations: { name, kind } } de l'utilisateur connecté.

const hasRole = (memberships, organizationId, roles) =>
  memberships.some(m => m.organization_id === organizationId && roles.includes(m.role))
const isPlatformAdmin = memberships => memberships.some(m => m.role === 'platform_admin')
const isExternalPrivate = (course, targetId) =>
  targetId !== course.owner_organization_id && course.visibility !== 'ifap_catalog'

export function deployTargets(course, memberships, clients) {
  if (!course || course.status !== 'published') return []
  const owner = course.owner_organization_id
  const targets = new Map()
  const add = o => targets.set(o.id, o)
  const ownerAdmin = hasRole(memberships, owner, ['org_admin']) && course.organizations?.kind === 'ifap'

  if (ownerAdmin) add({ id: owner, name: course.organizations.name, kind: 'ifap' })
  if (ownerAdmin || isPlatformAdmin(memberships)) clients.forEach(add)
  for (const m of memberships) {
    if (m.role !== 'org_admin') continue
    if (m.organization_id === owner || course.visibility === 'ifap_catalog') {
      add({ id: m.organization_id, name: m.organizations?.name || 'Mon organisation', kind: m.organizations?.kind })
    }
  }
  return [...targets.values()]
}

// Le mode « lien » reste masqué tant qu'il ne fonctionne pas.
export function enrollmentModes(course, targetId) {
  const modes = ['manager', 'prescribed', 'employer']
  if (course && !isExternalPrivate(course, targetId)) modes.push('self_service')
  return modes
}

export const canManageDeployment = (deployment, memberships) =>
  isPlatformAdmin(memberships) || hasRole(memberships, deployment.initiated_by_organization_id, ['org_admin'])

export const canEnroll = (deployment, memberships) =>
  isPlatformAdmin(memberships) || hasRole(memberships, deployment.target_organization_id, ['org_admin', 'trainer'])

export const canEditCourse = (course, memberships) =>
  isPlatformAdmin(memberships) || hasRole(memberships, course.owner_organization_id, ['org_admin', 'trainer'])

export const STATUS_LABELS = { available: 'Ouvert', closed: 'Clos', archived: 'Archivé' }
export const MODE_LABELS = {
  manager: 'Inscription gestionnaire',
  prescribed: 'Prescription',
  employer: 'Inscription employeur',
  self_service: 'Auto-inscription',
  link: 'Lien d’inscription'
}

export const NOT_ALLOWED = 'Vous n’avez pas le droit d’effectuer cette action.'

export function frenchError(error) {
  if (error?.code === '42501') return NOT_ALLOWED
  if (error?.code === '23505') return 'Cet enregistrement existe déjà. Un déploiement archivé se réactive.'
  if (error?.code === 'P0001') return error.message // message rédigé par la base
  return `L’opération a échoué : ${error?.message || 'erreur inconnue'}`
}
