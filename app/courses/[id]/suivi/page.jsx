'use client'

import Link from 'next/link'
import { useEffect, useState } from 'react'
import { useParams } from 'next/navigation'
import Shell from '../../../../components/Shell'
import { createClient } from '../../../../lib/supabase-browser'
import { frenchError } from '../../../../lib/deployment-rules.mjs'
import { ENROLLMENT_LABELS, enrollmentActions, isCourseOwnerAdmin } from '../../../../lib/enrollment-rules.mjs'

export default function CourseFollowUp() {
  const { id } = useParams()
  const [course, setCourse] = useState(null)
  const [allowed, setAllowed] = useState(false)
  const [rows, setRows] = useState([])
  const [pending, setPending] = useState(null)
  const [reason, setReason] = useState('')
  const [loading, setLoading] = useState(true)
  const [busy, setBusy] = useState(false)
  const [error, setError] = useState('')
  const [message, setMessage] = useState('')

  async function load() {
    const s = createClient()
    const { data: { user } } = await s.auth.getUser()
    if (!user) { location.href = '/login'; return }
    const [c, me, list] = await Promise.all([
      s.from('courses').select('id,title,owner_organization_id').eq('id', id).maybeSingle(),
      s.from('organization_members').select('organization_id,role').eq('user_id', user.id),
      s.rpc('list_course_enrollments', { p_course: id })
    ])
    const failed = [c, me, list].find(r => r.error)
    if (failed) setError(frenchError(failed.error))
    setCourse(c.data)
    setAllowed(isCourseOwnerAdmin(c.data, me.data || []))
    setRows(list.data || [])
    setLoading(false)
  }

  useEffect(() => { if (id) load() }, [id])

  const waiting = rows.filter(r => r.status === 'awaiting_validation')

  function ask(action) {
    setPending(action)
    setReason('')
    setError('')
    setMessage('')
  }

  // calls : liste de [fonction, paramètres], exécutés l'un après l'autre ; arrêt à la première erreur.
  async function run(calls, success) {
    setBusy(true)
    setError('')
    setMessage('')
    const s = createClient()
    let done = 0
    for (const [name, params] of calls) {
      const { error: failure } = await s.rpc(name, params)
      if (failure) {
        setError(frenchError(failure) + (calls.length > 1 ? ` (${done} sur ${calls.length} traitées)` : ''))
        break
      }
      done += 1
    }
    if (done === calls.length) setMessage(success)
    setPending(null)
    await load()
    setBusy(false)
  }

  function confirm(event) {
    event.preventDefault()
    const { kind, row } = pending
    if (kind === 'all') {
      run(waiting.map(r => ['validate_enrollment', { p_enrollment: r.enrollment_id }]), `${waiting.length} inscription(s) validée(s).`)
    } else if (kind === 'validate') {
      run([['validate_enrollment', { p_enrollment: row.enrollment_id, p_reason: reason || null }]], 'Inscription validée, attestation délivrée.')
    } else if (kind === 'revoke') {
      run([['revoke_attestation', { p_attestation: row.attestation_id, p_reason: reason }]], 'Attestation révoquée.')
    } else if (kind === 'cancel') {
      run([['cancel_enrollment', { p_enrollment: row.enrollment_id }]], 'Inscription annulée.')
    } else {
      run([['reactivate_enrollment', { p_enrollment: row.enrollment_id }]], 'Inscription réactivée.')
    }
  }

  const TITLES = { all: 'Valider les inscriptions à valider', validate: 'Valider et délivrer l’attestation', revoke: 'Révoquer l’attestation', cancel: 'Annuler l’inscription', reactivate: 'Réactiver l’inscription' }
  const withReason = pending && (pending.kind === 'revoke' || (pending.kind === 'validate' && enrollmentActions(pending.row).needsReason))

  return (
    <Shell active="courses">
      <div className="top">
        <div>
          <div className="eyebrow">SUIVI ET VALIDATION</div>
          <h1>{course?.title || 'Formation'}</h1>
          <div className="muted">Inscrits à cette formation, toutes organisations destinataires.</div>
        </div>
        <div className="actions">
          <Link className="btn secondary" href={`/courses/${id}`}>← Formation</Link>
          {allowed && waiting.length > 0 && <button className="btn" disabled={busy} onClick={() => ask({ kind: 'all' })}>Valider les {waiting.length} à valider</button>}
        </div>
      </div>

      {message && <div className="success" role="status">{message}</div>}
      {error && <div className="error" role="alert">{error}</div>}

      {pending && (
        <form className="card" style={{ marginBottom: 18 }} onSubmit={confirm}>
          <div>
            <b>{TITLES[pending.kind]}</b>
            <div className="muted small">
              {pending.kind === 'all'
                ? waiting.map(r => `${r.first_name} ${r.last_name} (${r.organization_name})`).join(', ')
                : `${pending.row.first_name} ${pending.row.last_name} — ${pending.row.organization_name}`}
            </div>
          </div>
          {withReason && <label>Motif (obligatoire)<input value={reason} onChange={e => setReason(e.target.value)} required pattern=".*\S.*" /></label>}
          <div className="actions">
            <button className="btn" disabled={busy}>Confirmer</button>
            <button type="button" className="btn secondary" disabled={busy} onClick={() => setPending(null)}>Fermer</button>
          </div>
        </form>
      )}

      <div className="card">
        {loading ? <div>Chargement…</div> : !allowed ? (
          <div className="empty">Ce suivi est réservé à l’administrateur de l’organisme propriétaire de la formation.</div>
        ) : rows.length === 0 ? <div className="empty">Aucune inscription.</div> : (
          <table className="table">
            <thead><tr><th>Apprenant</th><th>Employeur</th><th>Statut</th><th>Progression</th><th>Attestation</th><th>Actions</th></tr></thead>
            <tbody>
              {rows.map(row => {
                const can = enrollmentActions(row)
                return (
                  <tr key={row.enrollment_id}>
                    <td><b>{row.first_name} {row.last_name}</b></td>
                    <td>{row.organization_name}</td>
                    <td><span className="badge">{ENROLLMENT_LABELS[row.status] || row.status}</span></td>
                    <td>{Math.round(Number(row.progress))} %</td>
                    <td>
                      {row.attestation_id ? row.certificate_number : '—'}
                      {row.revoked_at && <div className="muted small">Révoquée le {new Date(row.revoked_at).toLocaleDateString('fr-FR')} : {row.revocation_reason}</div>}
                    </td>
                    <td>
                      <div className="actions">
                        {can.validate && <button className="btn small-btn" disabled={busy} onClick={() => ask({ kind: 'validate', row })}>Valider</button>}
                        {can.revoke && <button className="btn secondary small-btn" disabled={busy} onClick={() => ask({ kind: 'revoke', row })}>Révoquer</button>}
                        {can.reactivate && <button className="btn secondary small-btn" disabled={busy} onClick={() => ask({ kind: 'reactivate', row })}>{row.status === 'pending' ? 'Accepter' : 'Réactiver'}</button>}
                        {can.cancel && <button className="btn secondary small-btn" disabled={busy} onClick={() => ask({ kind: 'cancel', row })}>Annuler</button>}
                      </div>
                    </td>
                  </tr>
                )
              })}
            </tbody>
          </table>
        )}
      </div>
    </Shell>
  )
}
