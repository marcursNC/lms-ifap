'use client'

import Link from 'next/link'
import { useEffect, useMemo, useState } from 'react'
import Shell from '../../components/Shell'
import { createClient } from '../../lib/supabase-browser'
import { ENROLLMENT_LABELS, isActiveEnrollment, isCompleted } from '../../lib/enrollment-rules.mjs'

export default function LearnerHome() {
  const [loading, setLoading] = useState(true)
  const [error, setError] = useState('')
  const [learner, setLearner] = useState(null)
  const [rows, setRows] = useState([])
  const [certs, setCerts] = useState([])
  const [catalog, setCatalog] = useState([])
  const [sessions, setSessions] = useState([])
  const [attendance, setAttendance] = useState([])

  useEffect(() => {
    ;(async () => {
      const s = createClient()
      const { data: { user } } = await s.auth.getUser()
      if (!user) { location.href = '/login'; return }

      const { data: l, error: le } = await s.from('learners')
        .select('id,first_name,last_name,email,job_title,organization_id,organizations(name)')
        .eq('user_id', user.id).eq('is_active', true).maybeSingle()

      if (le || !l) {
        setError(le?.message || 'Aucun profil apprenant associé à ce compte.')
        setLoading(false)
        return
      }
      setLearner(l)

      const { data: e, error: ee } = await s.from('enrollments')
        .select('id,status,progress,started_at,completed_at,deployment_id,deployments(id,course_id,status,available_from,available_until,courses(id,title,description,duration_minutes,modality,thumbnail_path))')
        .eq('learner_id', l.id).order('started_at', { ascending: false })

      const { data: cat, error: ce } = await s.from('courses')
        .select('id,title,description,category,level,tags,featured,duration_minutes,modality')
        .eq('visibility', 'ifap_catalog').eq('status', 'published')
        .order('featured', { ascending: false }).order('updated_at', { ascending: false })

      const { data: a, error: ae } = await s.from('attestations')
        .select('id,certificate_number,issued_at,revoked_at,pdf_path,enrollments!inner(learner_id,deployments(courses(title)))')
        .eq('enrollments.learner_id', l.id).order('issued_at', { ascending: false })

      const enrollmentIds = (e || []).map(x => x.id)
      let upcoming = []
      if (enrollmentIds.length) {
        const { data: se, error: seErr } = await s.from('session_enrollments')
          .select('session_id,enrollment_id,sessions(id,title,start_at,end_at,mode,location,tracking_mode,join_url,recording_url,status,required_attendance_percent)')
          .in('enrollment_id', enrollmentIds)
        if (seErr) setError(seErr.message)
        const sessionIds = (se || []).map(x => x.session_id)
        if (sessionIds.length) { const { data: at } = await s.from('attendance').select('session_id,present,attendance_percent,attended_seconds,source').in('session_id', sessionIds); setAttendance(at || []) }
        upcoming = (se || [])
          .map(x => ({ ...x.sessions, enrollment_id: x.enrollment_id }))
          .filter(x => x?.start_at && new Date(x.start_at) >= new Date())
          .sort((a, b) => new Date(a.start_at) - new Date(b.start_at))
          .slice(0, 4)
      }

      if (ee || ce || ae) setError((ee || ce || ae).message)
      setRows(e || [])
      setCerts(a || [])
      setCatalog(cat || [])
      setSessions(upcoming)
      setLoading(false)
    })()
  }, [])

  const mine = useMemo(() => rows.filter(isActiveEnrollment), [rows])

  const stats = useMemo(() => ({
    active: mine.filter(r => !isCompleted(r)).length,
    completed: mine.filter(isCompleted).length,
    avg: mine.length ? Math.round(mine.reduce((a, r) => a + Number(r.progress || 0), 0) / mine.length) : 0,
    certs: certs.filter(c => !c.revoked_at).length
  }), [mine, certs])

  const sessionStatus = (session) => { const a = attendance.find(x => x.session_id === session.id); if (new Date(session.start_at) >= new Date()) return {label:'À venir',kind:'upcoming'}; if (!a) return {label:'Présence en attente',kind:'pending'}; const ok = Number(a.attendance_percent ?? (a.present ? 100 : 0)) >= Number(session.required_attendance_percent ?? 80); return {label:ok?'Présence validée':'Présence insuffisante',kind:ok?'ok':'warning'} }

  const next = mine.find(r => !['completed', 'awaiting_validation', 'pending'].includes(r.status))

  const recommendations = useMemo(() => {
    const enrolled = new Set(rows.map(r => r.deployments?.course_id).filter(Boolean))
    return catalog.filter(c => !enrolled.has(c.id)).slice(0, 3)
  }, [catalog, rows])

  if (loading) return <Shell active="learner"><div className="card">Chargement de votre espace…</div></Shell>

  return (
    <Shell active="learner">
      <div className="learner-hero">
        <div>
          <div className="eyebrow">MON ESPACE D'APPRENTISSAGE</div>
          <h1>Bonjour {learner?.first_name || ''} <span className="wave">👋</span></h1>
          <p>Continuez votre parcours et développez vos compétences à votre rythme.</p>
        </div>
        <div className="hero-avatar">{(learner?.first_name || 'A').slice(0, 1)}{(learner?.last_name || '').slice(0, 1)}</div>
      </div>

      {error && <div className="error">{error}</div>}

      <div className="learner-next card">
        <div className="next-copy">
          <span className="eyebrow">À REPRENDRE</span>
          <h2>{next?.deployments?.courses?.title || 'Votre parcours est à jour'}</h2>
          <p>{next ? 'Poursuivez là où vous vous êtes arrêté.' : 'Découvrez vos prochaines formations dans le catalogue.'}</p>
          {next
            ? <Link className="btn" href={`/learner/courses/${next.deployment_id}`}>Reprendre la formation →</Link>
            : <Link className="btn" href="/catalog">Explorer les formations →</Link>}
        </div>
        <div className="next-progress"><div className="ring"><span>{next ? Math.round(Number(next.progress || 0)) : 100}<small>%</small></span></div></div>
      </div>

      <div className="grid learner-kpis modern-kpis">
        <Stat label="En cours" value={stats.active} />
        <Stat label="Terminées" value={stats.completed} />
        <Stat label="Progression" value={stats.avg + '%'} />
        <Stat label="Attestations" value={stats.certs} />
      </div>

      <div className="section-title">
        <div><span className="eyebrow">VOTRE PARCOURS</span><h2>Mes formations</h2></div>
        <Link className="text-link" href="/catalog">Voir le catalogue →</Link>
      </div>

      {recommendations.length > 0 && (
        <>
          <div className="section-title recommendation-title">
            <div><span className="eyebrow">POUR VOUS</span><h2>Continuez à développer vos compétences</h2><p className="muted">Des formations proposées selon votre parcours.</p></div>
          </div>
          <div className="recommendation-grid">
            {recommendations.map((r, i) => (
              <Link href={`/learner/catalog/${r.id}`} className="recommendation-card" key={r.id}>
                <div className={`recommendation-art rec-${i}`}><span>{courseInitial(r.title)}</span><b>{r.featured ? 'À la une' : 'Suggestion'}</b></div>
                <div><div className="course-meta">{r.category || 'FORMATION'}{r.level ? ' · ' + r.level : ''}</div><h3>{r.title}</h3><p>{r.description || 'Une compétence à développer.'}</p><div className="recommendation-cta">Découvrir →</div></div>
              </Link>
            ))}
          </div>
        </>
      )}

      <section className="card learner-sessions">
        <div className="section-head">
          <div><span className="eyebrow">AGENDA</span><h2>Mes prochaines sessions</h2><p className="muted">Présentiel, visio et webinaires liés à vos formations.</p></div>
          <Link className="text-link" href="/sessions">Voir les sessions →</Link>
        </div>
        {sessions.length ? <div className="upcoming-session-grid">{sessions.map(s => (
          <div className="upcoming-session" key={s.id}>
            <div className="session-date"><b>{new Date(s.start_at).toLocaleDateString('fr-FR',{day:'2-digit',month:'short'})}</b><span>{new Date(s.start_at).toLocaleTimeString('fr-FR',{hour:'2-digit',minute:'2-digit'})}</span></div>
            <div className="session-info"><h3>{s.title || 'Session de formation'}</h3><span>{s.mode || 'Session'}{s.location ? ' · ' + s.location : ''}</span><small>{s.tracking_mode === 'webinar' || s.tracking_mode === 'virtual_classroom' || s.tracking_mode === 'meeting' ? 'Suivi de présence automatique prévu' : 'Présence suivie'}</small></div>
            {s.join_url && <a className="btn secondary session-join" aria-label={`Rejoindre ${s.title || 'la session'}`} href={s.join_url} target="_blank" rel="noreferrer">Rejoindre ↗</a>}
            {(() => { const st=sessionStatus(s); return <span className={`session-attendance ${st.kind}`}>{st.label}</span> })()}
            {s.recording_url && new Date(s.end_at) < new Date() && <a className="text-link" href={s.recording_url} target="_blank" rel="noreferrer">Voir le replay →</a>}
          </div>
        ))}</div> : <div className="empty">Aucune session à venir pour le moment.</div>}
      </section>

      <div className="learner-course-grid">
        {mine.map(r => {
          const c = r.deployments?.courses
          const p = Math.round(Number(r.progress || 0))
          return (
            <Link className="modern-course" href={`/learner/courses/${r.deployment_id}`} key={r.id}>
              <div className="course-art"><span>{courseInitial(c?.title)}</span><i>{isCompleted(r) ? '✓' : '▶'}</i></div>
              <div className="modern-course-body">
                <div className="course-meta">{c?.modality || 'FORMATION'}{c?.duration_minutes ? ' · ' + Math.round(c.duration_minutes / 60 * 10) / 10 + ' h' : ''}</div>
                <h3>{c?.title || 'Formation'}</h3>
                <p>{c?.description || 'Développez vos compétences.'}</p>
                <div className="progress-line"><span style={{ width: Math.min(100, p) + '%' }} /></div>
                <div className="course-footer"><span>{['completed', 'awaiting_validation', 'pending'].includes(r.status) ? ENROLLMENT_LABELS[r.status] : 'Progression'}</span><b>{p}%</b></div>
              </div>
            </Link>
          )
        })}
      </div>

      {!mine.length && <div className="empty card">Aucune formation ne vous est encore attribuée.</div>}

      <div className="grid2 learner-bottom">
        <div className="card modern-panel">
          <div className="section-head"><div><span className="eyebrow">RÉUSSITES</span><h2>Mes attestations</h2></div><Link className="text-link" href="/certificates">Tout voir →</Link></div>
          {certs.slice(0, 3).map(c => (
            <div className="certificate-modern" key={c.id}>
              <div className="cert-icon">◇</div>
              <div><b>{c.enrollments?.deployments?.courses?.title || 'Attestation'}</b><span>{c.certificate_number || 'Certificat'} · {new Date(c.issued_at).toLocaleDateString('fr-FR')}</span></div>
              <span className="badge">{c.revoked_at ? 'Révoquée' : 'Validée'}</span>
            </div>
          ))}
          {!certs.length && <div className="empty">Votre première attestation apparaîtra ici.</div>}
        </div>
        <div className="card modern-panel profile-card">
          <span className="eyebrow">MON PROFIL</span>
          <div className="profile-big"><div className="avatar large">{(learner?.first_name || 'A').slice(0, 1)}{(learner?.last_name || '').slice(0, 1)}</div><div><h3>{learner?.first_name} {learner?.last_name}</h3><span>{learner?.job_title || 'Apprenant'}</span></div></div>
          <div className="profile-line"><span>Organisation</span><b>{learner?.organizations?.name || '—'}</b></div>
        </div>
      </div>
    </Shell>
  )
}

function Stat({ label, value }) {
  return <div className="card modern-stat"><div><span>{label}</span><strong>{value}</strong></div></div>
}

function courseInitial(title = 'Formation') {
  return title.trim().split(/\s+/).slice(0, 2).map(x => x[0]).join('').toUpperCase()
}
