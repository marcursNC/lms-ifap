'use client'
import Link from 'next/link'
import {useEffect,useMemo,useState} from 'react'
import Shell from '../../components/Shell'
import {createClient} from '../../lib/supabase-browser'

const cats=['Toutes','Management','Communication','Bureautique & numérique','Culture administrative','Préparation concours','Qualité de vie au travail']

export default function Catalog(){
 const [rows,setRows]=useState([]),[loading,setLoading]=useState(true),[error,setError]=useState('')
 const [q,setQ]=useState(''),[cat,setCat]=useState('Toutes'),[modality,setModality]=useState('Toutes'),[sort,setSort]=useState('relevance')
 useEffect(()=>{(async()=>{const s=createClient();const {data:{user}}=await s.auth.getUser();if(!user){location.href='/login';return}
  const {data,error}=await s.from('courses').select('id,title,description,category,level,tags,featured,duration_minutes,modality,thumbnail_path,status,visibility,organizations(name)').eq('visibility','ifap_catalog').eq('status','published').order('featured',{ascending:false}).order('updated_at',{ascending:false})
  if(error)setError(error.message);setRows(data||[]);setLoading(false)
 })()},[])
 const filtered=useMemo(()=>{let x=rows.filter(r=>{const hay=`${r.title||''} ${r.description||''} ${(r.tags||[]).join(' ')} ${r.category||''}`.toLowerCase();return (!q||hay.includes(q.toLowerCase()))&&(cat==='Toutes'||r.category===cat)&&(modality==='Toutes'||r.modality===modality)});if(sort==='duration')x.sort((a,b)=>(a.duration_minutes||9999)-(b.duration_minutes||9999));if(sort==='alpha')x.sort((a,b)=>a.title.localeCompare(b.title));return x},[rows,q,cat,modality,sort])
 const featured=rows.filter(r=>r.featured).slice(0,3)
 const modalities=[...new Set(rows.map(r=>r.modality).filter(Boolean))]
 return <Shell active="catalog">
  <div className="catalog-hero"><div><div className="eyebrow">CATALOGUE IFAP</div><h1>Développez vos compétences.</h1><p>Des formations pensées pour les agents publics, à suivre à votre rythme ou dans le cadre d'un parcours.</p></div><div className="catalog-orbit">✦</div></div>
  {error&&<div className="error">{error}</div>}
  {featured.length>0&&<section className="catalog-featured"><div className="section-title"><div><span className="eyebrow">À LA UNE</span><h2>À découvrir</h2></div></div><div className="featured-grid">{featured.map((r,i)=><CourseCard key={r.id} r={r} featured index={i}/>)}</div></section>}
  <section className="catalog-browser"><div className="catalog-toolbar"><div className="search-box"><span>⌕</span><input value={q} onChange={e=>setQ(e.target.value)} placeholder="Rechercher une formation, une compétence…"/></div><select value={sort} onChange={e=>setSort(e.target.value)}><option value="relevance">Pertinence</option><option value="alpha">A → Z</option><option value="duration">Durée</option></select></div>
   <div className="chip-row">{cats.map(c=><button key={c} className={cat===c?'chip active':'chip'} onClick={()=>setCat(c)}>{c}</button>)}</div>
   <div className="chip-row secondary-chips"><button className={modality==='Toutes'?'chip active':'chip'} onClick={()=>setModality('Toutes')}>Tous les formats</button>{modalities.map(m=><button key={m} className={modality===m?'chip active':'chip'} onClick={()=>setModality(m)}>{m}</button>)}</div>
   <div className="catalog-result-head"><div><span className="eyebrow">CATALOGUE</span><h2>{filtered.length} formation{filtered.length>1?'s':''}</h2></div><span className="muted small">Des contenus sélectionnés par l'IFAP</span></div>
   {loading?<div className="card">Chargement du catalogue…</div>:filtered.length?<div className="catalog-grid">{filtered.map(r=><CourseCard key={r.id} r={r}/>)}</div>:<div className="empty card">Aucune formation ne correspond à votre recherche.<br/><button className="btn secondary" onClick={()=>{setQ('');setCat('Toutes');setModality('Toutes')}}>Réinitialiser les filtres</button></div>}
  </section>
 </Shell>
}
function CourseCard({r,featured,index=0}){const initials=(r.title||'Formation').split(/\s+/).slice(0,2).map(x=>x[0]).join('').toUpperCase();return <Link href={`/learner/catalog/${r.id}`} className={featured?'catalog-card featured-card':'catalog-card'}><div className={`catalog-art art-${index%4}`}><span>{initials}</span>{r.featured&&<b>À la une</b>}<i>→</i></div><div className="catalog-card-body"><div className="course-meta">{r.category||'FORMATION'} {r.level?` · ${r.level}`:''}</div><h3>{r.title}</h3><p>{r.description||'Développez une compétence directement mobilisable dans votre activité professionnelle.'}</p><div className="tag-row">{(r.tags||[]).slice(0,3).map(t=><span key={t}>{t}</span>)}</div><div className="course-footer"><span>{r.duration_minutes?`${Math.round(r.duration_minutes/60*10)/10} h`:'Durée variable'} · {r.modality||'À distance'}</span><strong>Découvrir →</strong></div></div></Link>}
