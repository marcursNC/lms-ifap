'use client'

import Link from 'next/link'
import { useEffect, useState } from 'react'
import { useParams } from 'next/navigation'
import Shell from '../../../components/Shell'
import { createClient } from '../../../lib/supabase-browser'
import {
  deployTargets, enrollmentModes, canManageDeployment, canEditCourse,
  frenchError, NOT_ALLOWED, STATUS_LABELS, MODE_LABELS
} from '../../../lib/deployment-rules.mjs'

// Actions proposées selon le statut : [statut visé, bouton, confirmation]
const ACTIONS = {
  available: [['closed', 'Clore', 'Confirmer la clôture'], ['archived', 'Archiver', 'Confirmer l’archivage']],
  closed: [['available', 'Rouvrir', 'Confirmer la réouverture'], ['archived', 'Archiver', 'Confirmer l’archivage']],
  archived: [['available', 'Réactiver', 'Confirmer la réactivation']]
}

export default function Course() {
  const { id } = useParams()
  const [course, setCourse] = useState(null)
  const [modules, setModules] = useState([])
  const [deployments, setDeployments] = useState([])
  const [memberships, setMemberships] = useState([])
  const [clients, setClients] = useState([])
  const [targetOrg, setTargetOrg] = useState('')
  const [enrollmentMode, setEnrollmentMode] = useState('manager')
  const [showDeploy, setShowDeploy] = useState(false)
  const [pending, setPending] = useState(null)
  const [loading, setLoading] = useState(true)
  const [busy, setBusy] = useState(false)
  const [error, setError] = useState('')
  const [message, setMessage] = useState('')

  async function load() {
    const s = createClient()
    const { data: { user } } = await s.auth.getUser()
    if (!user) { location.href = '/login'; return }
    const [c, m, d, me, cl] = await Promise.all([
      s.from('courses').select('id,title,description,objectives,target_audience,duration_minutes,modality,prerequisites,visibility,status,owner_organization_id,organizations(name,kind)').eq('id', id).maybeSingle(),
      s.from('course_modules').select('id,title,description,position,is_required').eq('course_id', id).order('position'),
      s.from('deployments').select('id,status,enrollment_mode,published_at,available_from,available_until,capacity,target_organization_id,initiated_by_organization_id,organizations:target_organization_id(name)').eq('course_id', id).order('published_at'),
      s.from('organization_members').select('organization_id,role,organizations(name,kind)').eq('user_id', user.id),
      s.rpc('list_deployable_organizations')
    ])
    const failed = [c, m, d, me, cl].find(r => r.error)
    if (failed) setError(frenchError(failed.error))
    setCourse(c.data)
    setModules(m.data || [])
    setDeployments(d.data || [])
    setMemberships(me.data || [])
    setClients(cl.data || [])
    setLoading(false)
  }

  useEffect(() => { if (id) load() }, [id])

  const targets = deployTargets(course, memberships, clients)
  const freeTargets = targets.filter(o => !deployments.some(d => d.target_organization_id === o.id))
  const selectedTarget = freeTargets.some(o => o.id === targetOrg) ? targetOrg : (freeTargets.length === 1 ? freeTargets[0].id : '')
  const modes = enrollmentModes(course, selectedTarget)
  const selectedMode = modes.includes(enrollmentMode) ? enrollmentMode : 'manager'
  const editable = course ? canEditCourse(course, memberships) : false
  const targetName = d => d.organizations?.name || clients.find(o => o.id === d.target_organization_id)?.name || 'Organisation'

  async function run(action, success) {
    setBusy(true)
    setError('')
    setMessage('')
    const { data, error: failure } = await action(createClient())
    // Une mise à jour refusée par la base ne renvoie pas d'erreur, seulement aucune ligne.
    if (failure) setError(frenchError(failure))
    else if (!data?.length) setError(NOT_ALLOWED)
    else { setMessage(success); await load() }
    setBusy(false)
    return !failure && Boolean(data?.length)
  }

  const publish = () => run(s => s.from('courses').update({ status: 'published' }).eq('id', id).select('id'), 'Formation publiée.')
  const publishCatalog = () => run(s => s.from('courses').update({ status: 'published', visibility: 'ifap_catalog' }).eq('id', id).select('id'), 'Formation publiée au catalogue IFAP.')

  async function deploy(e) {
    e.preventDefault()
    if (!selectedTarget) return
    const ok = await run(s => s.from('deployments').insert({ course_id: id, target_organization_id: selectedTarget, status: 'available', enrollment_mode: selectedMode }).select('id'), 'Déploiement créé.')
    if (ok) { setShowDeploy(false); setTargetOrg('') }
  }

  async function changeStatus(deployment, status) {
    await run(s => s.from('deployments').update({ status }).eq('id', deployment.id).select('id'), `Déploiement : ${STATUS_LABELS[status].toLowerCase()}.`)
    setPending(null)
  }

  return (
    <Shell active="courses">
      <div className="top">
        <div>
          <div className="eyebrow">FORMATION</div>
          <h1>{loading ? 'Chargement…' : course?.title || 'Formation introuvable'}</h1>
          <div className="muted">{course?.organizations?.name || '—'} · {course?.status || ''}</div>
        </div>
        <div className="actions">
          <Link className="btn secondary" href="/courses">Retour</Link>
          {editable && course.status === 'draft' && <button className="btn" onClick={publish} disabled={busy}>Publier</button>}
          {editable && course.visibility !== 'ifap_catalog' && course.organizations?.kind === 'ifap' && <button className="btn" onClick={publishCatalog} disabled={busy}>Publier au catalogue IFAP</button>}
          {freeTargets.length > 0 && <button className="btn" onClick={() => setShowDeploy(v => !v)}>+ Déployer</button>}
        </div>
      </div>

      {message && <div className="success" role="status">{message}</div>}
      {error && <div className="error" role="alert">{error}</div>}

      {showDeploy && freeTargets.length > 0 && (
        <form className="card form-inline" onSubmit={deploy}>
          <div><b>Nouveau déploiement</b><div className="muted small">Choisissez l’organisation destinataire.</div></div>
          <select aria-label="Organisation destinataire" value={selectedTarget} onChange={e => setTargetOrg(e.target.value)} required>
            <option value="">Organisation…</option>
            {freeTargets.map(o => <option key={o.id} value={o.id}>{o.name}</option>)}
          </select>
          <select aria-label="Mode d’inscription" value={selectedMode} onChange={e => setEnrollmentMode(e.target.value)}>
            {modes.map(m => <option key={m} value={m}>{MODE_LABELS[m]}</option>)}
          </select>
          <button className="btn" disabled={busy || !selectedTarget}>Créer</button>
        </form>
      )}

      {course && (
        <>
          <div className="hero">
            <div className="badge">{course.visibility === 'ifap_catalog' ? 'Catalogue IFAP' : 'Formation privée'}</div>
            <p>{course.description || 'Aucune description.'}</p>
            <div className="grid" style={{ marginTop: 16 }}>
              <K label="Durée" value={course.duration_minutes ? `${course.duration_minutes} min` : '—'} />
              <K label="Modalité" value={course.modality || '—'} />
              <K label="Public" value={course.target_audience || '—'} />
              <K label="Déploiements" value={deployments.length} />
            </div>
          </div>
          <div className="grid2">
            <div className="card">
              <h2>Parcours</h2>
              {modules.length === 0 ? <div className="empty">Aucun module pour le moment.</div> : modules.map((m, i) => (
                <div key={m.id} className="course-row">
                  <div className="course-icon">{i + 1}</div>
                  <div><b>{m.title}</b><div className="muted small">{m.description || 'Module'} · {m.is_required ? 'Obligatoire' : 'Optionnel'}</div></div>
                </div>
              ))}
            </div>
            <div className="card">
              <h2>Déploiements</h2>
              {deployments.length === 0 ? <div className="empty">Aucun déploiement.</div> : deployments.map(d => (
                <div key={d.id} className="course-row" style={{ flexWrap: 'wrap' }}>
                  <div>
                    <b>{targetName(d)}</b>
                    <div className="muted small">
                      {STATUS_LABELS[d.status] || d.status} · {MODE_LABELS[d.enrollment_mode] || d.enrollment_mode} · {d.capacity || 'sans capacité'}
                      {d.available_from ? ` · à partir du ${new Date(d.available_from).toLocaleDateString('fr-FR')}` : ''}
                    </div>
                  </div>
                  <div className="actions">
                    <Link className="btn secondary" href={`/deployments/${d.id}`}>Inscriptions</Link>
                    <Link className="btn secondary" href={`/sessions?deployment=${d.id}`}>Sessions</Link>
                    {canManageDeployment(d, memberships) && (pending?.id === d.id ? (
                      <>
                        <button className="btn" disabled={busy} onClick={() => changeStatus(d, pending.status)}>{pending.confirm}</button>
                        <button className="btn secondary" disabled={busy} onClick={() => setPending(null)}>Annuler</button>
                      </>
                    ) : (ACTIONS[d.status] || []).map(([status, label, confirm]) => (
                      <button key={status} className="btn secondary" disabled={busy} onClick={() => setPending({ id: d.id, status, confirm })}>{label}</button>
                    )))}
                  </div>
                </div>
              ))}
            </div>
          </div>
        </>
      )}
    </Shell>
  )
}

function K({ label, value }) {
  return <div className="card"><div className="muted small">{label}</div><b>{value}</b></div>
}
