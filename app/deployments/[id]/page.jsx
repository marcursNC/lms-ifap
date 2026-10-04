'use client'

import { useEffect, useState } from 'react'
import { useParams } from 'next/navigation'
import Link from 'next/link'
import Shell from '../../../components/Shell'
import { createClient } from '../../../lib/supabase-browser'

export default function DeploymentPage() {
  const { id } = useParams()
  const [dep, setDep] = useState(null)
  const [learners, setLearners] = useState([])
  const [enrolled, setEnrolled] = useState(new Set())
  const [selected, setSelected] = useState([])
  const [mode, setMode] = useState('prescribed')
  const [loading, setLoading] = useState(true)
  const [busy, setBusy] = useState(false)
  const [error, setError] = useState('')
  const [message, setMessage] = useState('')

  async function load() {
    const s = createClient()
    const [d, l, e] = await Promise.all([
      s.from('deployments').select('id,status,enrollment_mode,enrollment_requires_approval,capacity,available_from,available_until,course_id,courses(title),target_organization_id,organizations:target_organization_id(name)').eq('id', id).maybeSingle(),
      s.from('learners').select('id,first_name,last_name,email,job_title,department,is_active').order('last_name'),
      s.from('enrollments').select('id,learner_id,status,progress').eq('deployment_id', id)
    ])
    if (d.error || l.error || e.error) {
      setError((d.error || l.error || e.error).message)
    } else {
      setDep(d.data)
      setMode(d.data?.enrollment_mode || 'manager')
      setLearners((l.data || []).filter(x => x.is_active))
      setEnrolled(new Set((e.data || []).map(x => x.learner_id)))
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
        setError(insertError.message)
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
        <div className="card"><div className="muted small">INSCRITS</div><div className="kpi">{enrolled.size}</div></div>
        <div className="card"><div className="muted small">CAPACITÉ</div><div className="kpi">{dep?.capacity || '∞'}</div></div>
        <div className="card"><div className="muted small">STATUT</div><div className="kpi">{dep?.status || '—'}</div></div>
        <div className="card"><div className="muted small">MODE</div><div className="kpi">{dep?.enrollment_mode || '—'}</div></div>
      </div>

      <div className="card" style={{ marginTop: 18 }}>
        <div className="section-head">
          <div>
            <h2>Ajouter des apprenants</h2>
            <div className="muted">Inscription gérée par l’organisation.</div>
          </div>
          <div>
            <select value={mode} onChange={e => setMode(e.target.value)}>
              <option value="prescribed">Prescription</option>
              <option value="employer">Inscription employeur</option>
              <option value="manager">Inscription gestionnaire</option>
            </select>
            {' '}
            <button className="btn" disabled={busy || !selected.length} onClick={enroll}>
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
                <tr><th></th><th>Apprenant</th><th>Fonction</th><th>Service</th><th>Statut</th></tr>
              </thead>
              <tbody>
                {learners.map(learner => {
                  const isIn = enrolled.has(learner.id)
                  return (
                    <tr key={learner.id}>
                      <td><input type="checkbox" checked={selected.includes(learner.id) || isIn} disabled={isIn} onChange={() => toggle(learner.id)} /></td>
                      <td><b>{learner.first_name} {learner.last_name}</b><div className="muted small">{learner.email || '—'}</div></td>
                      <td>{learner.job_title || '—'}</td>
                      <td>{learner.department || '—'}</td>
                      <td><span className="badge">{isIn ? 'Déjà inscrit' : 'Disponible'}</span></td>
                    </tr>
                  )
                })}
              </tbody>
            </table>
          )}
        </div>
      </div>
    </Shell>
  )
}
