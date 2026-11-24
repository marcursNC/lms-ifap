'use client'
import Link from 'next/link'
import {useEffect,useState} from 'react'
import {useParams} from 'next/navigation'
import Shell from '../../../../components/Shell'
import {createClient} from '../../../../lib/supabase-browser'

export default function LearnerCourse(){
  const {id}=useParams()
  const [row,setRow]=useState(null),[modules,setModules]=useState([]),[resources,setResources]=useState([]),[completedResources,setCompletedResources]=useState(new Set()),[completedModules,setCompletedModules]=useState(new Set()),[loading,setLoading]=useState(true),[error,setError]=useState(''),[opened,setOpened]=useState(null),[busy,setBusy]=useState('')

  useEffect(()=>{(async()=>{
    const s=createClient(); const {data:{user}}=await s.auth.getUser()
    if(!user){location.href='/login';return}
    const {data:l}=await s.from('learners').select('id').eq('user_id',user.id).maybeSingle()
    if(!l){setError('Profil apprenant introuvable.');setLoading(false);return}
    const {data:e,error:ee}=await s.from('enrollments').select('id,status,progress,started_at,completed_at,deployment_id,deployments(id,course_id,courses(id,title,description,duration_minutes,modality,objectives))').eq('deployment_id',id).eq('learner_id',l.id).maybeSingle()
    if(ee||!e){setError(ee?.message||'Cette formation ne vous est pas accessible.');setLoading(false);return}
    setRow(e)
    const {data:m,error:me}=await s.from('course_modules').select('id,title,description,position,is_required').eq('course_id',e.deployments.course_id).order('position')
    if(me){setError(me.message);setLoading(false);return}
    setModules(m||[])
    const {data:rs,error:re}=await s.from('course_resources').select('id,module_id,title,resource_type,storage_path,external_url,metadata,is_required').eq('course_id',e.deployments.course_id).order('created_at')
    if(re){setError(re.message);setLoading(false);return}
    setResources(rs||[])
    const {data:acts}=await s.from('learning_activity_log').select('resource_id,module_id,activity_type').eq('enrollment_id',e.id).in('activity_type',['resource_completed','module_completed'])
    setCompletedResources(new Set((acts||[]).filter(a=>a.activity_type==='resource_completed'&&a.resource_id).map(a=>a.resource_id)))
    setCompletedModules(new Set((acts||[]).filter(a=>a.activity_type==='module_completed'&&a.module_id).map(a=>a.module_id)))
    setLoading(false)
  })()},[id])

  async function openResource(resource){
    const s=createClient()
    await s.from('learning_activity_log').insert({enrollment_id:row.id,resource_id:resource.id,module_id:resource.module_id,activity_type:'resource_opened',started_at:new Date().toISOString(),progress:0,metadata:{resource_type:resource.resource_type||'unknown'}})
    if(resource.external_url) window.open(resource.external_url,'_blank','noopener,noreferrer')
    else if(resource.storage_path){const {data}=await s.storage.from('course-resources').createSignedUrl(resource.storage_path,3600);if(data?.signedUrl) window.open(data.signedUrl,'_blank','noopener,noreferrer')}
  }

  async function completeResource(resource){
    setBusy(resource.id)
    const s=createClient()
    const {error:e}=await s.from('learning_activity_log').insert({enrollment_id:row.id,resource_id:resource.id,module_id:resource.module_id,activity_type:'resource_completed',started_at:new Date().toISOString(),ended_at:new Date().toISOString(),progress:100,metadata:{resource_type:resource.resource_type||'unknown'}})
    if(e)setError(e.message); else setCompletedResources(prev=>new Set([...prev,resource.id]))
    setBusy('')
  }

  async function completeModule(module){
    const required=resources.filter(r=>r.module_id===module.id&&r.is_required)
    const done=required.every(r=>completedResources.has(r.id))
    if(!done){setError('Terminez d’abord toutes les ressources obligatoires de ce module.');return}
    setBusy(module.id)
    const s=createClient()
    const {error:e}=await s.from('learning_activity_log').insert({enrollment_id:row.id,module_id:module.id,activity_type:'module_completed',started_at:new Date().toISOString(),ended_at:new Date().toISOString(),progress:100,metadata:{module_title:module.title}})
    if(e)setError(e.message); else {setCompletedModules(prev=>new Set([...prev,module.id]));setRow(prev=>({...prev,progress:Math.min(100,Number(prev.progress||0)+(100/Math.max(1,modules.filter(m=>m.is_required).length)))}))}
    setBusy('')
  }

  const resourceTypeLabel=(type)=>({video:'Vidéo',pdf:'PDF',document:'Document',link:'Lien',scorm:'Module interactif',audio:'Audio'}[type]||type||'Ressource')

  return <Shell active="learner">
    <header className="top">
      <div><Link className="back-link" href="/learner">← Mon espace</Link><div className="eyebrow">MA FORMATION</div><h1>{row?.deployments?.courses?.title||'Formation'}</h1><p className="muted">{row?.deployments?.courses?.description||'Votre parcours de développement des compétences.'}</p></div>
      <div className="course-progress-large" aria-label={`Progression : ${Math.round(Number(row?.progress||0))} pour cent`}><span aria-hidden="true">{Math.round(Number(row?.progress||0))}%</span><div className="progress" role="progressbar" aria-valuenow={Math.round(Number(row?.progress||0))} aria-valuemin="0" aria-valuemax="100" aria-label="Progression de la formation"><span aria-hidden="true" style={{width:`${Math.min(100,Number(row?.progress||0))}%`}}/></div></div>
    </header>
    {error&&<div className="error" role="alert">{error}</div>}
    {loading?<div className="card" role="status" aria-live="polite">Chargement de votre parcours…</div>:<>
      <section className="course-hero-meta" aria-label="Informations sur la formation"><span>◷ {row?.deployments?.courses?.duration_minutes?`${row.deployments.courses.duration_minutes} min`:'À votre rythme'}</span><span>▣ {row?.deployments?.courses?.modality||'E-learning'}</span><span>✓ {row?.status==='completed'?'Terminée':'En cours'}</span></section>
      <div className="grid2 learner-detail-grid">
        <section className="card" aria-labelledby="programme-title"><span className="eyebrow">PARCOURS</span><h2 id="programme-title">Votre programme</h2>
          {modules.length?modules.map((m,i)=>{const rs=resources.filter(r=>r.module_id===m.id);const required=rs.filter(r=>r.is_required);const ready=required.every(r=>completedResources.has(r.id));const done=completedModules.has(m.id);const isOpen=opened===m.id;return <article className="module-row" key={m.id}>
            <button type="button" className="module-toggle" aria-expanded={isOpen} onClick={()=>setOpened(isOpen?null:m.id)}><span className="module-number" aria-hidden="true">{i+1}</span><span><b>{m.title}</b><span className="muted small">{m.description||'Module de formation'}</span>{m.is_required&&<span className="badge">Obligatoire</span>}</span><span aria-hidden="true">{done?'✓':isOpen?'−':'+'}</span></button>
            {isOpen&&<div className="module-resources" aria-label={`Ressources du module ${m.title}`}>
              {rs.length?rs.map(resource=><div className="resource-row" key={resource.id}><button type="button" onClick={()=>openResource(resource)}><span className="resource-icon" aria-hidden="true">↗</span><span><b>{resource.title}</b><span className="muted small">{resourceTypeLabel(resource.resource_type)}{resource.is_required?' · Obligatoire':' · Facultatif'}</span></span></button><button type="button" className="resource-complete" disabled={completedResources.has(resource.id)||busy===resource.id} onClick={()=>completeResource(resource)}>{completedResources.has(resource.id)?'✓ Terminé':busy===resource.id?'…':'Terminer'}</button></div>):<p className="empty">Aucune ressource disponible pour le moment.</p>}
              {!done&&<button type="button" className="btn module-complete" disabled={!ready||busy===m.id} onClick={()=>completeModule(m)}>{busy===m.id?'Validation…':ready?'Valider le module':'Terminez les ressources obligatoires'}</button>}
              {done&&<p className="success" role="status">Module terminé ✓</p>}
            </div>}
          </article>}):<div className="empty">Les contenus seront bientôt disponibles.</div>}
        </section>
        <section className="card" aria-labelledby="progress-title"><span className="eyebrow">VOTRE PROGRESSION</span><h2 id="progress-title">{Math.round(Number(row?.progress||0))}%</h2><p className="muted">Votre progression se met à jour au fil de vos activités et de vos sessions.</p><div className="big-progress" role="progressbar" aria-valuenow={Math.round(Number(row?.progress||0))} aria-valuemin="0" aria-valuemax="100" aria-label="Progression de votre formation"><span aria-hidden="true" style={{width:`${Math.min(100,Number(row?.progress||0))}%`}}/></div><Link className="btn" href="/learner">Retour à mon espace</Link></section>
      </div>
    </>}
  </Shell>
}