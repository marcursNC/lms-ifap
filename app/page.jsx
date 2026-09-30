'use client'
import Link from 'next/link'
import {useEffect,useMemo,useState} from 'react'
import Shell from '../components/Shell'
import {createClient} from '../lib/supabase-browser'

export default function Page(){
 const [loading,setLoading]=useState(true)
 const [error,setError]=useState('')
 const [orgFilter,setOrgFilter]=useState('all')
 const [courseFilter,setCourseFilter]=useState('all')
 const [period,setPeriod]=useState('all')
 const [data,setData]=useState({enrollments:[],sessions:[],evaluations:[],certificates:[],courses:[],orgs:[]})

 useEffect(()=>{(async()=>{
   const s=createClient(); const {data:{user}}=await s.auth.getUser();
   if(!user){window.location.href='/login';return}
   const {data:member}=await s.from('organization_members').select('role').eq('user_id',user.id).limit(1).maybeSingle();
   if(member?.role==='learner'){window.location.href='/learner';return}
   const [en,ss,ev,ce,co,org]=await Promise.all([
    s.from('dashboard_enrollment_metrics').select('*'),
    s.from('dashboard_session_metrics').select('*').order('start_at',{ascending:false}),
    s.from('dashboard_evaluation_metrics').select('*'),
    s.from('dashboard_certificate_metrics').select('*').order('issued_at',{ascending:false}),
    s.from('courses').select('id,title,status,visibility,owner_organization_id,updated_at').order('updated_at',{ascending:false}),
    s.from('organizations').select('id,name,kind').order('name')
   ])
   const firstError=[en,ss,ev,ce,co,org].find(x=>x.error)
   if(firstError)setError(firstError.error.message)
   setData({enrollments:en.data||[],sessions:ss.data||[],evaluations:ev.data||[],certificates:ce.data||[],courses:co.data||[],orgs:org.data||[]})
   setLoading(false)
 })()},[])

 const cutoff=useMemo(()=>{
   if(period==='all')return null
   const d=new Date(); if(period==='30')d.setDate(d.getDate()-30); else if(period==='90')d.setDate(d.getDate()-90); else d.setFullYear(d.getFullYear()-1); return d
 },[period])
 const filtered=useMemo(()=>{
   const match=(r,dateField)=>{
     if(orgFilter!=='all' && r.organization_id!==orgFilter)return false
     if(courseFilter!=='all' && r.course_id!==courseFilter)return false
     if(cutoff && r[dateField] && new Date(r[dateField])<cutoff)return false
     return true
   }
   return {
    enrollments:data.enrollments.filter(r=>match(r,'started_at')),
    sessions:data.sessions.filter(r=>match(r,'start_at')),
    evaluations:data.evaluations.filter(r=>match(r,'attempted_at')),
    certificates:data.certificates.filter(r=>match(r,'issued_at'))
   }
 },[data,orgFilter,courseFilter,cutoff])

 const kpis=useMemo(()=>{
   const e=filtered.enrollments, s=filtered.sessions, ev=filtered.evaluations, c=filtered.certificates
   const completed=e.filter(x=>x.status==='completed' || Number(x.progress)>=100).length
   const progress=e.length?Math.round(e.reduce((a,x)=>a+Number(x.progress||0),0)/e.length):0
   const attendance=s.reduce((a,x)=>a+Number(x.registered_count||0),0)
   const present=s.reduce((a,x)=>a+Number(x.present_count||0),0)
   const attendanceRate=attendance?Math.round(present/attendance*100):0
   const attempted=ev.filter(x=>x.learner_id).length
   const passed=ev.filter(x=>x.learner_id && x.passed).length
   const passRate=attempted?Math.round(passed/attempted*100):0
   return {enrollments:e.length,completed,progress,attendanceRate,passRate,certificates:c.length,sessions:s.length}
 },[filtered])

 const orgRows=useMemo(()=>{
   const map={}; filtered.enrollments.forEach(e=>{const k=e.organization_id;if(!map[k])map[k]={name:e.organization_name,inscrits:0,completed:0,progress:0};map[k].inscrits++;map[k].progress+=Number(e.progress||0);if(e.status==='completed'||Number(e.progress)>=100)map[k].completed++})
   return Object.values(map).map(x=>({...x,progress:x.inscrits?Math.round(x.progress/x.inscrits):0})).sort((a,b)=>b.inscrits-a.inscrits).slice(0,8)
 },[filtered.enrollments])
 const courseRows=useMemo(()=>{
   const map={};filtered.enrollments.forEach(e=>{const k=e.course_id;if(!map[k])map[k]={id:k,title:e.course_title,inscrits:0,completed:0,progress:0};map[k].inscrits++;map[k].progress+=Number(e.progress||0);if(e.status==='completed'||Number(e.progress)>=100)map[k].completed++})
   return Object.values(map).map(x=>({...x,progress:x.inscrits?Math.round(x.progress/x.inscrits):0})).sort((a,b)=>b.inscrits-a.inscrits).slice(0,8)
 },[filtered.enrollments])

 function exportCsv(){
   const rows=[['Organisation','Formation','Apprenants','Terminés','Progression moyenne']].concat(courseRows.map(x=>[orgFilter==='all'?'Toutes':(data.orgs.find(o=>o.id===orgFilter)?.name||''),x.title,x.inscrits,x.completed,`${x.progress}%`]))
   const csv=rows.map(r=>r.map(v=>`"${String(v).replaceAll('"','""')}"`).join(';')).join('\n')
   const blob=new Blob([csv],{type:'text/csv;charset=utf-8'}),url=URL.createObjectURL(blob),a=document.createElement('a');a.href=url;a.download='lms-ifap-pilotage.csv';a.click();URL.revokeObjectURL(url)
 }

 return <Shell active="dashboard"><div className="top"><div><div className="eyebrow">PILOTAGE</div><h1>Tableau de bord</h1><div className="muted">Vue consolidée de l'activité de formation dans votre périmètre</div></div><div className="actions"><button className="btn secondary" onClick={exportCsv}>Exporter CSV</button><Link className="btn" href="/courses/new">+ Créer une formation</Link></div></div>
 {error&&<div className="error">{error}</div>}
 {loading?<div className="card">Chargement du pilotage…</div>:<>
  <div className="dashboard-filters card"><div className="filter-title">Filtres de pilotage</div><label>Organisation<select value={orgFilter} onChange={e=>setOrgFilter(e.target.value)}><option value="all">Toutes les organisations</option>{data.orgs.map(o=><option key={o.id} value={o.id}>{o.name}</option>)}</select></label><label>Formation<select value={courseFilter} onChange={e=>setCourseFilter(e.target.value)}><option value="all">Toutes les formations</option>{data.courses.map(c=><option key={c.id} value={c.id}>{c.title}</option>)}</select></label><label>Période<select value={period} onChange={e=>setPeriod(e.target.value)}><option value="all">Tout l'historique</option><option value="30">30 derniers jours</option><option value="90">90 derniers jours</option><option value="365">12 derniers mois</option></select></label></div>
  <div className="grid dashboard-kpis"><Kpi label="Inscriptions" value={kpis.enrollments}/><Kpi label="Terminées" value={kpis.completed} sub={kpis.enrollments?`${Math.round(kpis.completed/kpis.enrollments*100)} % des inscrits`:''}/><Kpi label="Progression moyenne" value={`${kpis.progress} %`}/><Kpi label="Présence" value={`${kpis.attendanceRate} %`} sub={`${kpis.sessions} sessions analysées`}/><Kpi label="Réussite évaluations" value={`${kpis.passRate} %`}/><Kpi label="Attestations" value={kpis.certificates}/></div>
  <div className="grid2 dashboard-main"><div className="card"><div className="section-head"><div><h2>Activité par organisation</h2><p className="muted">Inscriptions et progression moyenne</p></div></div>{orgRows.length?<table className="table"><thead><tr><th>Organisation</th><th>Inscrits</th><th>Terminés</th><th>Progression</th></tr></thead><tbody>{orgRows.map(x=><tr key={x.name}><td><b>{x.name}</b></td><td>{x.inscrits}</td><td>{x.completed}</td><td><Progress value={x.progress}/></td></tr>)}</tbody></table>:<Empty text="Aucune donnée pour ces filtres."/>}</div>
   <div className="card"><h2>Indicateurs pédagogiques</h2><Metric label="Progression moyenne" value={kpis.progress}/><Metric label="Présence" value={kpis.attendanceRate}/><Metric label="Réussite évaluations" value={kpis.passRate}/><div className="mini-note">Les indicateurs se recalculent automatiquement à partir des inscriptions, présences et évaluations.</div></div></div>
  <div className="card dashboard-course"><div className="section-head"><div><h2>Formations les plus suivies</h2><p className="muted">Classement par nombre d'inscriptions — sans notation qualitative</p></div><Link href="/courses" className="text-link">Gérer les formations →</Link></div>{courseRows.length?<table className="table"><thead><tr><th>Formation</th><th>Inscrits</th><th>Terminés</th><th>Progression moyenne</th></tr></thead><tbody>{courseRows.map(x=><tr key={x.id}><td><Link className="text-link" href={`/courses/${x.id}`}>{x.title}</Link></td><td>{x.inscrits}</td><td>{x.completed}</td><td><Progress value={x.progress}/></td></tr>)}</tbody></table>:<Empty text="Aucune inscription pour ces filtres."/>}</div>
  <div className="grid2"><div className="card"><h2>Sessions</h2><p className="muted">{kpis.sessions} sessions dans le périmètre sélectionné</p><div className="session-strip">{filtered.sessions.slice(0,5).map(s=><div className="session-card" key={s.session_id}><b>{s.title||s.course_title}</b><span>{s.organization_name}</span><span>{s.start_at?new Date(s.start_at).toLocaleDateString('fr-FR'):''} · {s.mode||'—'}</span></div>)}</div></div><div className="card"><h2>Attestations récentes</h2>{filtered.certificates.slice(0,5).map(c=><div className="certificate-row" key={c.attestation_id}><div><b>{c.certificate_number||'Certificat'}</b><div className="muted small">{c.learner_id?'Apprenant':'—'} · {c.course_title}</div></div><span className="badge">{c.revoked_at?'Révoquée':'Valide'}</span></div>)}{!filtered.certificates.length&&<Empty text="Aucune attestation."/>}</div></div>
 </>}
 </Shell>
}
function Kpi({label,value,sub}){return <div className="card"><div className="muted">{label}</div><div className="kpi">{value}</div>{sub&&<div className="kpi-sub">{sub}</div>}</div>}
function Progress({value}){return <div className="progress-wrap"><div className="progress"><span style={{width:`${Math.min(100,value)}%`}}/></div><b>{value}%</b></div>}
function Metric({label,value}){return <div className="metric"><div><span>{label}</span><b>{value}%</b></div><div className="progress"><span style={{width:`${Math.min(100,value)}%`}}/></div></div>}
function Empty({text}){return <div className="empty">{text}</div>}
