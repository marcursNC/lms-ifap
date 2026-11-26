'use client'

import { useEffect, useState } from 'react'
import { useParams } from 'next/navigation'
import Link from 'next/link'
import Shell from '../../../components/Shell'
import { createClient } from '../../../lib/supabase-browser'
import { canEnroll, frenchError, STATUS_LABELS, MODE_LABELS } from '../../../lib/deployment-rules.mjs'
import { ENROLLMENT_LABELS, enrollmentActions, isActiveEnrollment } from '../../../lib/enrollment-rules.mjs'

const MANAGER_MODES = ['prescribed', 'employer', 'manager']

export default function DeploymentPage() {
  const { id } = useParams()
  const [dep, setDep] = useState(null)
  const [learners, setLearners] = useState([])
  const [enrolled, setEnrolled] = useState(new Map())
  const [pending, setPending] = useState(null)
  const [selected, setSelected] = useState([])
  const [allowed, setAllowed] = useState(false)
  const [mode, setMode] = useState('prescribed')
  const [loading, setLoading] = useState(true)
  const [busy, setBusy] = useState(false)
  const [error, setError] = useState('')
  const [message, setMessage] = useState('')

  async function load() {
    const s = createClient()
    const { data: { user } } = await s.auth.getUser()
    if (!user) { location.href = '/login'; return }
    const [d, me] = await Promise.all([
      s.from('deployments').select('id,status,enrollment_mode,enrollment_requires_approval,capacity,available_from,available_until,course_id,courses(title),target_organization_id,organizations:target_organization_id(name)').eq('id', id).maybeSingle(),
      s.from('organization_members').select('organization_id,role').eq('user_id', user.id)
    ])
    if (d.error || me.error || !d.data) {
      setError(d.error || me.error ? frenchError(d.error || me.error) : 'Déploiement introuvable.')
      setLoading(false)
      return
    }
    // L'IFAP ne lit pas la fiche d'une organisation cliente : son nom vient de la liste des destinataires.
    if (!d.data.organizations) {
      const { data: clients } = await s.rpc('list_deployable_organizations')
      d.data.organizations = clients?.find(o => o.id === d.data.target_organization_id) || null
    }
    setDep(d.data)
    setMode(MANAGER_MODES.includes(d.data.enrollment_mode) ? d.data.enrollment_mode : 'prescribed')
    const manager = canEnroll(d.data, me.data || [])
    setAllowed(manager)
    if (manager) {
      const [l, e] = await Promise.all([
        s.from('learners').select('id,first_name,last_name,email,job_title,department,is_active').eq('organization_id', d.data.target_organization_id).order('last_name'),
        s.from('enrollments').select('id,learner_id,status,progress').eq('deployment_id', id)
      ])
      if (l.error || e.error) setError(frenchError(l.error || e.error))
      else {
        setLearners((l.data || []).filter(x => x.is_active))
        setEnrolled(new Map((e.data || []).map(x => [x.learner_id, x])))
      }
    }
    setLoading(false)
  }

  useEffect(() => {
    if (id) load()
  }, [id])

  function toggle(learnerId) {
    setSelected(value =>
      value.includes(learnerId)
        ? value.filter(x => x !== learnerId)
        : [...value, learnerId]
    )
  }

  async function change(call) {
    setBusy(true)
    setError('')
    setMessage('')
    const { error: failure } = await createClient().rpc(call, { p_enrollment: pending.id })
    if (failure) setError(frenchError(failure))
    else setMessage(call === 'cancel_enrollment' ? 'Inscription annulée.' : 'Inscription active.')
    setPending(null)
    await load()
    setBusy(false)
  }

  async function enroll() {
    if (!selected.length) return
    setBusy(true)
    setError('')
    const s = createClient()
    const payload = selected
      .filter(learnerId => !enrolled.has(learnerId))
      .map(learnerId => ({
        deployment_id: id,
        learner_id: learnerId,
        enrollment_mode: mode,
        status: 'enrolled',
        enrollment_source: 'manager'
      }))

    if (payload.length) {
      const { error: insertError } = await s.from('enrollments').insert(payload)
      if (insertError) {
        setError(frenchError(insertError))
      } else {
        setMessage(payload.length + ' apprenant(s) inscrit(s).')
        setSelected([])
        await load()
      }
    }
    setBusy(false)
  }

  if (loading) {
    return <Shell active="courses"><div className="card">Chargement…</div></Shell>
  }

  return (
    <Shell active="courses">
      <div className="top">
        <div>
          <div className="eyebrow">DÉPLOIEMENT</div>
          <h1>{dep?.courses?.title || 'Déploiement'}</h1>
          <div className="muted">{dep?.organizations?.name || '—'} · Inscription des apprenants</div>
        </div>
        <Link className="btn secondary" href={`/courses/${dep?.course_id}`}>← Formation</Link>
      </div>

      {message && <div className="success">{message}</div>}
      {error && <div className="error">{error}</div>}

      <div className="grid">
        <div className="card"><div className="muted small">ORGANISATION</div><div className="kpi">{dep?.organizations?.name || '—'}</div></div>
        <div className="card"><div className="muted small">INSCRITS</div><div className="kpi">{allowed ? [...enrolled.values()].filter(isActiveEnrollment).length : '—'}</div></div>
        <div className="card"><div className="muted small">CAPACITÉ</div><div className="kpi">{dep?.capacity || '∞'}</div></div>
        <div className="card"><div className="muted small">STATUT</div><div className="kpi">{STATUS_LABELS[dep?.status] || '—'}</div></div>
        <div className="card"><div className="muted small">MODE</div><div className="kpi">{MODE_LABELS[dep?.enrollment_mode] || '—'}</div></div>
      </div>

      {dep && (allowed ? (
        <div className="card" style={{ marginTop: 18 }}>
          <div className="section-head">
            <div>
              <h2>Ajouter des apprenants</h2>
              <div className="muted">{dep?.status === 'available' ? 'Inscription gérée par l’organisation.' : 'Ce déploiement n’accepte plus de nouvelle inscription.'}</div>
            </div>
            <div>
              <select value={mode} onChange={e => setMode(e.target.value)}>
                {MANAGER_MODES.map(m => <option key={m} value={m}>{MODE_LABELS[m]}</option>)}
              </select>
              {' '}
              <button className="btn" disabled={busy || !selected.length || dep?.status !== 'available'} onClick={enroll}>
                {busy ? 'Inscription…' : 'Inscrire ' + (selected.length || '')}
              </button>
            </div>
          </div>

          <div style={{ marginTop: 16 }}>
            {learners.length === 0 ? (
              <div className="empty">Aucun apprenant actif dans cette organisation.</div>
            ) : (
              <table className="table">
                <thead>
                  <tr><th></th><th>Apprenant</th><th>Fonction</th><th>Service</th><th>Statut</th><th>Actions</th></tr>
                </thead>
                <tbody>
                  {learners.map(learner => {
                    const enrollment = enrolled.get(learner.id)
                    const isIn = Boolean(enrollment)
                    const can = enrollment ? enrollmentActions(enrollment) : {}
                    return (
                      <tr key={learner.id}>
                        <td><input type="checkbox" checked={selected.includes(learner.id) || isIn} disabled={isIn} onChange={() => toggle(learner.id)} /></td>
                        <td><b>{learner.first_name} {learner.last_name}</b><div className="muted small">{learner.email || '—'}</div></td>
                        <td>{learner.job_title || '—'}</td>
                        <td>{learner.department || '—'}</td>
                        <td><span className="badge">{isIn ? ENROLLMENT_LABELS[enrollment.status] || enrollment.status : 'Disponible'}</span></td>
                        <td>
                          <div className="actions">
                            {pending?.id === enrollment?.id && pending ? (
                              <>
                                <button className="btn small-btn" disabled={busy} onClick={() => change(pending.call)}>Confirmer</button>
                                <button className="btn secondary small-btn" disabled={busy} onClick={() => setPending(null)}>Fermer</button>
                              </>
                            ) : (
                              <>
                                {can.reactivate && <button className="btn secondary small-btn" disabled={busy} onClick={() => setPending({ id: enrollment.id, call: 'reactivate_enrollment' })}>{enrollment.status === 'pending' ? 'Accepter' : 'Réactiver'}</button>}
                                {can.cancel && <button className="btn secondary small-btn" disabled={busy} onClick={() => setPending({ id: enrollment.id, call: 'cancel_enrollment' })}>Annuler</button>}
                              </>
                            )}
                          </div>
                        </td>
                      </tr>
                    )
                  })}
                </tbody>
              </table>
            )}
          </div>
        </div>
      ) : (
        <div className="card" style={{ marginTop: 18 }}>
          <div className="empty">Les inscriptions sont gérées par l’organisation destinataire. Ses apprenants ne sont visibles que par ses gestionnaires.</div>
        </div>
      ))}
    </Shell>
  )
}
