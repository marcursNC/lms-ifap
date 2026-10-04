'use client'

import Link from 'next/link'
import { useEffect, useState } from 'react'
import { useParams } from 'next/navigation'
import Shell from '../../../../components/Shell'
import { createClient } from '../../../../lib/supabase-browser'

export default function CatalogDetail() {
  const { id } = useParams()
  const [course, setCourse] = useState(null)
  const [deployment, setDeployment] = useState(null)
  const [modules, setModules] = useState([])
  const [enrollment, setEnrollment] = useState(null)
  const [learner, setLearner] = useState(null)
  const [loading, setLoading] = useState(true)
  const [busy, setBusy] = useState(false)
  const [error, setError] = useState('')
  const [done, setDone] = useState('')

  useEffect(() => {
    if (!id) return
    ;(async () => {
      const s = createClient()
      const { data: { user } } = await s.auth.getUser()
      if (!user) {
        location.href = '/login'
        return
      }

      const { data: l } = await s.from('learners')
        .select('id,organization_id').eq('user_id', user.id).eq('is_active', true).maybeSingle()
      setLearner(l)

      const { data: c, error: ce } = await s.from('courses')
        .select('id,title,description,objectives,target_audience,duration_minutes,modality,prerequisites,category,level,tags,organizations(name)')
        .eq('id', id).maybeSingle()

      if (ce || !c) {
        setError(ce?.message || 'Formation introuvable')
        setLoading(false)
        return
      }
      setCourse(c)

      const { data: mods } = await s.from('course_modules')
        .select('id,title,description,position,content_type,estimated_minutes')
        .eq('course_id', id).order('position')
      setModules(mods || [])

      if (l) {
        const { data: d } = await s.from('deployments')
          .select('id,status,enrollment_mode,enrollment_requires_approval,available_from,available_until,enrollment_deadline,capacity')
          .eq('course_id', id).eq('target_organization_id', l.organization_id)
          .eq('status', 'available').maybeSingle()
        setDeployment(d)

        if (d) {
          const { data: e } = await s.from('enrollments')
            .select('id,status,progress,completed_at')
            .eq('deployment_id', d.id).eq('learner_id', l.id).maybeSingle()
          setEnrollment(e)
        }
      }
      setLoading(false)
    })()
  }, [id])

  async function enroll() {
    if (!deployment || !learner) return
    setBusy(true)
    setError('')
    const s = createClient()
    const { data, error: insertError } = await s.from('enrollments').insert({
      deployment_id: deployment.id,
      learner_id: learner.id,
      enrollment_mode: 'self_service',
      enrollment_source: 'catalog',
      status: deployment.enrollment_requires_approval ? 'pending' : 'enrolled',
      progress: 0
    }).select('id,status,progress').single()

    if (insertError) setError(insertError.message)
    else {
      setEnrollment(data)
      setDone('Vous êtes maintenant inscrit à cette formation.')
    }
    setBusy(false)
  }

  if (loading) return <Shell active="catalog"><div className="card">Chargement de la formation…</div></Shell>

  return (
    <Shell active="catalog">
      <Link className="back-link" href="/catalog">← Retour au catalogue</Link>
      {error && <div className="error">{error}</div>}

      {course && (
        <>
          <div className="detail-hero">
            <div>
              <div className="eyebrow">{course.category || 'FORMATION IFAP'}{course.level ? ' · ' + course.level : ''}</div>
              <h1>{course.title}</h1>
              <p>{course.description || 'Une formation pour développer des compétences directement mobilisables.'}</p>
              <div className="detail-meta">
                <span>◷ {course.duration_minutes ? Math.round(course.duration_minutes / 60 * 10) / 10 + ' h' : 'Durée variable'}</span>
                <span>◆ {course.modality || 'À distance'}</span>
                {course.target_audience && <span>♙ {course.target_audience}</span>}
              </div>
            </div>
            <div className="detail-mark">{course.title.split(/\s+/).slice(0, 2).map(x => x[0]).join('').toUpperCase()}</div>
          </div>

          {done && <div className="success">✓ {done}</div>}

          <div className="detail-layout">
            <main>
              <section className="card">
                <span className="eyebrow">CE QUE VOUS ALLEZ APPRENDRE</span>
                <h2>Objectifs</h2>
                <p className="detail-copy">{course.objectives || 'Les objectifs pédagogiques seront précisés dans le programme de la formation.'}</p>
              </section>
              <section className="card">
                <span className="eyebrow">PROGRAMME</span>
                <h2>{modules.length} modules</h2>
                {modules.map((m, i) => (
                  <div className="catalog-module" key={m.id}>
                    <div className="module-number">{i + 1}</div>
                    <div><b>{m.title}</b><p>{m.description || 'Module de formation'}</p></div>
                    <span>{m.estimated_minutes ? m.estimated_minutes + ' min' : ''}</span>
                  </div>
                ))}
              </section>
            </main>

            <aside>
              <div className="card enroll-card">
                <span className="eyebrow">VOTRE PARCOURS</span>
                {enrollment ? (
                  <>
                    <div className="enrolled-state">✓</div>
                    <h2>Vous êtes inscrit</h2>
                    <p>Votre progression actuelle : <b>{Math.round(Number(enrollment.progress || 0))}%</b></p>
                    <div className="progress-line"><span style={{ width: Math.min(100, Number(enrollment.progress || 0)) + '%' }} /></div>
                    <Link className="btn" href={`/learner/courses/${deployment?.id}`}>Accéder à la formation →</Link>
                  </>
                ) : deployment ? (
                  <>
                    <h2>{deployment.enrollment_mode === 'self_service' ? 'Prêt à commencer ?' : 'Inscription gérée'}</h2>
                    <p>{deployment.enrollment_mode === 'self_service' ? 'Cette formation est ouverte à l’auto-inscription.' : 'Votre inscription est gérée par votre organisation.'}</p>
                    {deployment.enrollment_mode === 'self_service' && (
                      <button className="btn" disabled={busy} onClick={enroll}>
                        {busy ? 'Inscription…' : deployment.enrollment_requires_approval ? 'Demander mon inscription →' : 'S’inscrire à la formation →'}
                      </button>
                    )}
                    {deployment.enrollment_mode !== 'self_service' && <span className="badge">👥 Inscription gérée</span>}
                  </>
                ) : (
                  <>
                    <h2>Formation IFAP</h2>
                    <p>Cette formation n’est pas encore ouverte à l’inscription pour votre organisation.</p>
                    <span className="badge">Disponible sur catalogue</span>
                  </>
                )}
              </div>

              {course.prerequisites && (
                <div className="card">
                  <span className="eyebrow">PRÉREQUIS</span>
                  <p className="detail-copy">{course.prerequisites}</p>
                </div>
              )}
            </aside>
          </div>
        </>
      )}
    </Shell>
  )
}
