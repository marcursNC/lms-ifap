'use client'

import { Suspense, useEffect, useState } from 'react'
import { useSearchParams } from 'next/navigation'
import Link from 'next/link'
import Shell from '../../components/Shell'
import { createClient } from '../../lib/supabase-browser'

function SessionsContent() {
  const params = useSearchParams()
  const initialDeployment = params.get('deployment') || ''
  const [rows, setRows] = useState([])
  const [deployments, setDeployments] = useState([])
  const [dep, setDep] = useState(initialDeployment)
  const [title, setTitle] = useState('')
  const [start, setStart] = useState('')
  const [end, setEnd] = useState('')
  const [mode, setMode] = useState('presentiel')
  const [location, setLocation] = useState('')
  const [capacity, setCapacity] = useState('')
  const [provider, setProvider] = useState('')
  const [meetingId, setMeetingId] = useState('')
  const [organizerId, setOrganizerId] = useState('')
  const [requiredAttendance, setRequiredAttendance] = useState('80')
  const [open, setOpen] = useState(Boolean(initialDeployment))
  const [loading, setLoading] = useState(true)
  const [busy, setBusy] = useState(false)
  const [error, setError] = useState('')
  const [message, setMessage] = useState('')

  async function load() {
    const s = createClient()
    const [r, d] = await Promise.all([
      s.from('sessions')
        .select('id,title,start_at,end_at,mode,location,capacity,deployments(course_id,courses(title),target_organization_id,organizations:target_organization_id(name))')
        .order('start_at', { ascending: true }),
      s.from('deployments')
        .select('id,course_id,organizations:target_organization_id(name),courses(title)')
        .eq('status', 'available')
        .order('published_at', { ascending: false })
    ])

    if (r.error) setError(r.error.message)
    setRows(r.data || [])
    setDeployments(d.data || [])
    setLoading(false)
  }

  useEffect(() => {
    load()
  }, [])

  async function createSession(e) {
    e.preventDefault()
    setBusy(true)
    setError('')
    setMessage('')

    const s = createClient()
    const payload = {
      deployment_id: dep,
      title,
      start_at: start ? new Date(start).toISOString() : null,
      end_at: end ? new Date(end).toISOString() : null,
      mode,
      location: location || null,
      capacity: capacity ? Number(capacity) : null,
      status: 'planned',
      tracking_mode: mode === 'visio' || mode === 'hybride' ? 'virtual_classroom' : 'manual',
      external_provider: provider || null,
      external_meeting_id: meetingId || null,
      external_organizer_user_id: organizerId || null,
      required_attendance_percent: Number(requiredAttendance) || 80
    }

    const { error: insertError } = await s.from('sessions').insert(payload)

    if (insertError) {
      setError(insertError.message)
    } else {
      setMessage('Session créée.')
      setTitle('')
      setStart('')
      setEnd('')
      setLocation('')
      setCapacity('')
      setProvider('')
      setMeetingId('')
      setOrganizerId('')
      await load()
    }

    setBusy(false)
  }

  return (
    <Shell active="sessions">
      <div className="top">
        <div>
          <div className="eyebrow">PLANIFICATION</div>
          <h1>Sessions</h1>
          <div className="muted">Créer et piloter les sessions des déploiements</div>
        </div>
        <button className="btn" onClick={() => setOpen(v => !v)}>+ Nouvelle session</button>
      </div>

      {message && <div className="success">{message}</div>}
      {error && <div className="error">{error}</div>}

      {open && (
        <form className="card form-grid" onSubmit={createSession}>
          <label>
            Déploiement
            <select value={dep} onChange={e => setDep(e.target.value)} required>
              <option value="">Choisir…</option>
              {deployments.map(d => (
                <option key={d.id} value={d.id}>{d.courses?.title} — {d.organizations?.name}</option>
              ))}
            </select>
          </label>

          <label>Intitulé<input required value={title} onChange={e => setTitle(e.target.value)} placeholder="Session 1" /></label>
          <label>Début<input type="datetime-local" value={start} onChange={e => setStart(e.target.value)} /></label>
          <label>Fin<input type="datetime-local" value={end} onChange={e => setEnd(e.target.value)} /></label>

          <label>
            Modalité
            <select value={mode} onChange={e => setMode(e.target.value)}>
              <option value="presentiel">Présentiel</option>
              <option value="visio">Visio</option>
              <option value="hybride">Hybride</option>
            </select>
          </label>

          <label>Lieu / lien<input value={location} onChange={e => setLocation(e.target.value)} placeholder="Salle, Teams…" /></label>
          <label>Capacité<input type="number" min="1" value={capacity} onChange={e => setCapacity(e.target.value)} /></label>

          <label>
            Suivi visio
            <select value={provider} onChange={e => setProvider(e.target.value)}>
              <option value="">Aucun</option>
              <option value="microsoft_teams">Microsoft Teams</option>
              <option value="zoom">Zoom</option>
              <option value="webex">Webex</option>
              <option value="google_meet">Google Meet</option>
            </select>
          </label>

          {provider === 'microsoft_teams' && (
            <>
              <label>ID réunion Teams<input value={meetingId} onChange={e => setMeetingId(e.target.value)} placeholder="onlineMeeting.id" required /></label>
              <label>ID Entra de l’organisateur<input value={organizerId} onChange={e => setOrganizerId(e.target.value)} placeholder="GUID utilisateur" required /></label>
              <label>Présence minimale (%)<input type="number" min="0" max="100" value={requiredAttendance} onChange={e => setRequiredAttendance(e.target.value)} /></label>
            </>
          )}

          <div className="form-actions">
            <button className="btn" disabled={busy || !dep || !title}>{busy ? 'Création…' : 'Créer la session'}</button>
          </div>
        </form>
      )}

      <div className="card">
        {loading ? (
          <div>Chargement…</div>
        ) : rows.length === 0 ? (
          <div className="empty">Aucune session.</div>
        ) : (
          <table className="table">
            <thead><tr><th>Session</th><th>Formation</th><th>Organisation</th><th>Date</th><th>Format</th><th>Lieu</th><th>Capacité</th></tr></thead>
            <tbody>
              {rows.map(r => (
                <tr key={r.id}>
                  <td><Link className="text-link" href={`/sessions/${r.id}`}><b>{r.title}</b></Link></td>
                  <td>{r.deployments?.courses?.title || '—'}</td>
                  <td>{r.deployments?.organizations?.name || '—'}</td>
                  <td>{r.start_at ? new Date(r.start_at).toLocaleString('fr-FR') : 'À planifier'}</td>
                  <td>{r.mode || '—'}</td>
                  <td>{r.location || '—'}</td>
                  <td>{r.capacity || '—'}</td>
                </tr>
              ))}
            </tbody>
          </table>
        )}
      </div>
    </Shell>
  )
}

export default function Sessions() {
  return (
    <Suspense fallback={<Shell active="sessions"><div className="card">Chargement…</div></Shell>}>
      <SessionsContent />
    </Suspense>
  )
}
