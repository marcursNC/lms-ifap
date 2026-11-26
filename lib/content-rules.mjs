// Règles d'écran des contenus. La base reste seule juge (RLS, contraintes et déclencheurs).
export const MAX_PDF_BYTES = 20971520

export function linkError(url) {
  const value = (url || '').trim()
  const message = 'Saisissez une adresse complète commençant par https://'
  if (!value.startsWith('https://')) return message
  try { return new URL(value).hostname ? null : message } catch { return message }
}

export function pdfError(file) {
  if (!file || file.type !== 'application/pdf') return 'Choisissez un fichier PDF.'
  if (!file.size) return 'Ce fichier est vide.'
  if (file.size > MAX_PDF_BYTES) return 'Le fichier dépasse la limite de 20 Mo.'
  return null
}

export const pdfPath = (courseId, uuid) => `${courseId}/${uuid}.pdf`

export function move(ids, index, delta) {
  const target = index + delta
  if (target < 0 || target >= ids.length) return ids
  const next = [...ids]
  next.splice(target, 0, ...next.splice(index, 1))
  return next
}

const byPosition = (a, b) => (a.position || 0) - (b.position || 0)

// Modules et contenus visibles, dans l'ordre ; les contenus sans module forment un dernier groupe.
export function orderedTree(modules, resources) {
  const live = resources.filter(r => !r.retired_at).sort(byPosition)
  const tree = modules.filter(m => !m.retired_at).sort(byPosition)
    .map(m => ({ ...m, resources: live.filter(r => r.module_id === m.id) }))
  const loose = live.filter(r => !r.module_id)
  if (loose.length) tree.push({ id: null, title: 'Hors module', resources: loose })
  return tree
}

export function publishError(course, resources) {
  if (course?.status === 'published' || resources.some(r => !r.retired_at)) return null
  return 'La publication demande au moins un contenu.'
}
