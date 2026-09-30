'use client'
import Link from 'next/link'
import {useEffect,useState} from 'react'
import {createClient} from '../lib/supabase-browser'

const nav=[
 {key:'dashboard',label:'Pilotage',href:'/'},
 {key:'learner',label:'Mon espace',href:'/learner'},
 {key:'courses',label:'Formations',href:'/courses'},
 {key:'catalog',label:'Catalogue IFAP',href:'/catalog'},
 {key:'learners',label:'Apprenants',href:'/learners'},
 {key:'sessions',label:'Sessions',href:'/sessions'},
 {key:'certificates',label:'Attestations',href:'/certificates'},
]
export default function Shell({children,active}){
 const [email,setEmail]=useState(''),[org,setOrg]=useState(''),[role,setRole]=useState('')
 useEffect(()=>{(async()=>{const s=createClient();const {data:{user}}=await s.auth.getUser();if(user){setEmail(user.email||'');const {data}=await s.from('organization_members').select('role,organizations(name)').eq('user_id',user.id).limit(1).maybeSingle();setOrg(data?.organizations?.name||'');setRole(data?.role||'')}})()},[])
 const logout=async()=>{await createClient().auth.signOut();window.location.href='/login'}
 const learner=role==='learner'
 return <div className="app-shell">
  <aside className="side">
   <Link href={learner?'/learner':'/'} className="brand"><span className="brand-mark">I</span><span><b>IFAP</b><small>LMS</small></span></Link>
   <div className="org-context"><span className="online-dot"/> {org||'Espace formation'}</div>
   <nav className="nav">{nav.filter(x=>learner ? ['learner','catalog'].includes(x.key) : x.key!=='catalog').map(x=><Link key={x.key} className={active===x.key?'active':''} href={x.href}><span className="nav-icon">{icons[x.key]}</span>{x.label}</Link>)}</nav>
   <div className="side-bottom"><div className="profile-mini"><div className="avatar">{(email||'U').slice(0,1).toUpperCase()}</div><div><b>{learner?'Mon compte':'Administration'}</b><span>{email}</span></div></div><button className="logout" onClick={logout}>Se déconnecter</button></div>
  </aside>
  <main className="main">{children}</main>
 </div>
}
const icons={dashboard:'⌂',learner:'✦',catalog:'✧',courses:'▣',learners:'♙',sessions:'◷',certificates:'◇'}
