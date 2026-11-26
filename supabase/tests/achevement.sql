-- Tests de l'achèvement et des attestations, par profil. Base jetable uniquement. Données fictives.
\set ON_ERROR_STOP 1
\pset footer off
begin;
\o /dev/null
create schema t;
create table t.res(n serial, nom text, ok boolean, detail text);
create table t.who(k text primary key, uid uuid);
insert into t.who select k, ('a0000000-0000-0000-0000-00000000000'||i)::uuid from (values
 ('ifap_admin',1),('ifap_formateur',2),('col_admin',3),('col_formateur',4),('apprenant',5),('second',6),('agent_ifap',7),('autre_admin',8)) v(k,i);
create function t.id(p text, i int) returns uuid language sql immutable as $$ select (p||'0000000-0000-0000-0000-'||lpad(i::text,12,'0'))::uuid $$;
insert into public.organizations(id,name,kind) values (t.id('1',1),'T IFAP','ifap'),(t.id('1',2),'T Commune','collectivite'),(t.id('1',3),'T Autre','collectivite');
insert into public.organization_members(organization_id,user_id,role)
select t.id('1',o), w.uid, r::public.member_role from (values ('ifap_admin',1,'org_admin'),('ifap_formateur',1,'trainer'),('col_admin',2,'org_admin'),
 ('col_formateur',2,'trainer'),('apprenant',2,'learner'),('second',2,'learner'),('agent_ifap',1,'learner'),('autre_admin',3,'org_admin')) v(k,o,r) join t.who w using(k);
insert into public.learners(id,organization_id,user_id,first_name,last_name)
select t.id('2',i), t.id('1',o), (select uid from t.who where k=who), 'Test', who from (values (1,2,'apprenant'),(2,2,'second'),(3,1,'agent_ifap')) v(i,o,who);
-- 1 en ligne complète, 2 sans condition, 3 ressources seules, 4 présentiel chez un tiers, 5 présentiel interne IFAP,
-- 6 libre inscription, 7 formation de la commune avec séance, 8 ressource + séance chez un tiers
insert into public.courses(id,owner_organization_id,title,visibility,status)
select t.id('3',i), t.id('1',case when i=7 then 2 else 1 end), 'T cours '||i, case when i=7 then 'private' else 'ifap_catalog' end,'published' from generate_series(1,8) i;
insert into public.course_modules(id,course_id,title,position,content_type) select t.id('4',i),t.id('3',i),'M',1,'text' from generate_series(1,8) i;
insert into public.course_resources(id,course_id,module_id,title,resource_type,is_required) values
 (t.id('b',11),t.id('3',1),t.id('4',1),'R','pdf',true),(t.id('b',31),t.id('3',3),t.id('4',3),'R','pdf',true),
 (t.id('b',32),t.id('3',3),t.id('4',3),'Facultative','pdf',false),(t.id('b',33),t.id('3',3),null,'Hors module','pdf',true),
 (t.id('b',61),t.id('3',6),t.id('4',6),'R','pdf',true),(t.id('b',81),t.id('3',8),t.id('4',8),'R','pdf',true);
insert into public.evaluations(id,course_id,title,pass_score,is_required) values (t.id('5',1),t.id('3',1),'E1',50,true),(t.id('5',2),t.id('3',1),'E2',50,true);
insert into public.deployments(id,course_id,target_organization_id,status,enrollment_mode)
select t.id('8',i), t.id('3',i), t.id('1',case when i=5 then 1 else 2 end), 'available', case when i=6 then 'self_service' else 'manager' end::public.enrollment_mode from generate_series(1,8) i;
-- inscription n : déploiement d, apprenant l
create function t.enr(i int, d int, l int, extra text default '', vals text default '') returns text language sql as $$
 select format('insert into public.enrollments(id,deployment_id,learner_id,enrollment_mode%s) values (%L,%L,%L,%L%s)',extra,t.id('9',i),t.id('8',d),t.id('2',l),
  case when d=6 then 'self_service' else 'manager' end,vals) $$;

create function t.chk(nom text, qui text, q text, attendu text, conserver boolean default false) returns void language plpgsql as $f$
declare n bigint := 0; err text; code text; res boolean;
begin
  begin
    perform set_config('test.uid', coalesce((select uid::text from t.who where k=qui),''), true);
    if qui = 'anonyme' then set local role anon;
    elsif qui <> 'systeme' then set local role authenticated; end if;
    execute q; get diagnostics n = row_count;
    reset role;
    if not conserver then raise exception using errcode='ZZ999'; end if;
  exception
    when sqlstate 'ZZ999' then null;
    when others then err := sqlerrm; code := sqlstate;
  end;
  reset role; perform set_config('test.uid','',true);
  res := case
    when attendu='ok' then err is null and n>0
    when attendu='refus' then (err is null and n=0) or coalesce(code in ('42501','P0001','23505','23503'),false)
    else err is null and n=attendu::bigint end;
  insert into t.res(nom,ok,detail) values (nom,res,coalesce(code||' '||err, n||' ligne(s)'));
end $f$;
-- état d'une inscription : statut, progression, attestations (total), attestations valides
create function t.etat(nom text, i int, st text, prog numeric, att int, valides int default null) returns void language plpgsql as $f$
declare r record;
begin
  select e.status, e.progress,
    (select count(*) from public.attestations a where a.enrollment_id=e.id) a,
    (select count(*) from public.attestations a where a.enrollment_id=e.id and a.revoked_at is null) v
  into r from public.enrollments e where e.id=t.id('9',i);
  insert into t.res(nom,ok,detail) values (nom, coalesce(r.status=st and r.progress=prog and r.a=att and r.v=coalesce(valides,att),false),
    format('%s %s%% att=%s valides=%s', r.status, r.progress, r.a, r.v));
end $f$;
create function t.act(i int, typ text, res int default null, md int default null) returns text language sql as $$
 select format('insert into public.learning_activity_log(enrollment_id,activity_type,resource_id,module_id) values (%L,%L,%L,%L)',t.id('9',i),typ,
  case when res is not null then t.id('b',res) end, case when md is not null then t.id('4',md) end) $$;
create function t.tentative(ev int, l int) returns text language sql as $$
 select format('insert into public.evaluation_attempts(evaluation_id,learner_id,score,passed) values (%L,%L,100,true)',t.id('5',ev),t.id('2',l)) $$;
create function t.rpc(f text, i int, motif text default null) returns text language sql as $$
 select format('select public.%I(%L%s)',f,t.id('9',i),case when motif is not null then ','||quote_literal(motif) else '' end) $$;
-- l'identifiant est lu par le système : le refus vient de la fonction, pas d'une attestation invisible
create function t.revoquer(i int, motif text) returns text language sql as $$
 select format('select public.revoke_attestation(%L,%L)',(select id from public.attestations where enrollment_id=t.id('9',i) order by revoked_at nulls first limit 1),motif) $$;
create function t.seance(i int, d int, seuil int default 80) returns text language sql as $$
 select format('insert into public.sessions(id,deployment_id,title,start_at,end_at,required_attendance_percent) values (%L,%L,''S'',now()-interval ''2 hours'',now()-interval ''1 hour'',%s)',t.id('c',i),t.id('8',d),seuil) $$;
create function t.porter(s int, i int) returns text language sql as $$
 select format('insert into public.session_enrollments(session_id,enrollment_id) values (%L,%L)',t.id('c',s),t.id('9',i)) $$;
create function t.presence(s int, l int, present boolean) returns text language sql as $$
 select format('insert into public.attendance(session_id,learner_id,present) values (%L,%L,%L) on conflict (session_id,learner_id) do update set present=excluded.present',t.id('c',s),t.id('2',l),present) $$;

-- A. Création d'inscription
select t.chk('A1 employeur : inscription déjà terminée refusée','col_admin',t.enr(1,1,1,',status,progress,completed_at',',''completed'',100,now()'),'refus');
select t.chk('A2 apprenant : libre inscription déjà terminée refusée','apprenant',t.enr(6,6,1,',status,progress,completed_at',',''completed'',100,now()'),'refus');
select t.chk('A3 progression initiale refusée','col_admin',t.enr(1,1,1,',progress',',50'),'refus');
select t.chk('A4 date de validation initiale refusée','col_admin',t.enr(1,1,1,',validated_at',',now()'),'refus');
select t.chk('A5 libre inscription normale','apprenant',t.enr(6,6,1),'ok',true);
select t.chk('A6 inscription 1','col_admin',t.enr(1,1,1),'ok',true);
select t.chk('A7 inscription 2','col_admin',t.enr(2,2,1),'ok',true);
select t.chk('A8 inscription 3','col_admin',t.enr(3,3,1),'ok',true);
select t.chk('A9 inscription 4','col_admin',t.enr(4,4,1),'ok',true);
select t.chk('A10 inscription 14 (second, présentiel)','col_admin',t.enr(14,4,2),'ok',true);
select t.chk('A11 inscription 5 interne IFAP','ifap_admin',t.enr(5,5,3),'ok',true);
select t.chk('A12 inscription 7','col_admin',t.enr(7,7,1),'ok',true);
select t.chk('A13 inscription 8','col_admin',t.enr(8,8,1),'ok',true);

select t.chk('A14 demande « en attente » acceptée','second',t.enr(26,6,2,',status',',''pending'''),'ok',true);
select t.chk('A15 le demandeur ne se valide pas','second',t.rpc('reactivate_enrollment',26),'refus');
select t.chk('A16 une demande n''enregistre aucune activité','second',t.act(26,'resource_completed',61,6),'refus');
select t.etat('A17 reste en attente',26,'pending',0,0);
select t.chk('A18 l''employeur accepte la demande','col_admin',t.rpc('reactivate_enrollment',26),'ok',true);
select t.etat('A19 acceptée : inscrit',26,'enrolled',0,0);
select t.chk('A20 une fois acceptée, l''activité compte','second',t.act(26,'resource_completed',61,6),'ok',true);
select t.etat('A21 le parcours se calcule',26,'completed',100,1);

-- B. Écritures interdites
select t.chk('B1 apprenant : module terminé enregistré','apprenant',t.act(1,'module_completed',null,1),'ok',true);
select t.etat('B2 … sans achèvement ni attestation',1,'in_progress',0,0);
select t.chk('B3 employeur ne déclare pas une ressource','col_admin',t.act(1,'resource_completed',11,1),'refus');
select t.chk('B4 propriétaire ne déclare pas une ressource','ifap_admin',t.act(1,'resource_completed',11,1),'refus');
select t.chk('B5 un autre apprenant non plus','second',t.act(1,'resource_completed',11,1),'refus');
select t.chk('B6 employeur ne modifie pas le statut','col_admin','update public.enrollments set status=''completed'',progress=100,completed_at=now()','refus');
select t.chk('B7 propriétaire : pas d''écriture directe','ifap_admin','update public.enrollments set status=''completed''','refus');
select t.chk('B8 apprenant : pas d''écriture directe','apprenant','update public.enrollments set progress=100','refus');
select t.chk('B9 employeur ne supprime pas','col_admin','delete from public.enrollments','refus');
select t.chk('B10 apprenant ne supprime pas','apprenant','delete from public.enrollments','refus');
select t.chk('B11 employeur n''écrit pas de tentative','col_admin',t.tentative(1,1),'refus');
select t.chk('B12 apprenant n''écrit pas de tentative','apprenant',t.tentative(1,1),'refus');
select t.chk('B13 employeur ne crée pas d''attestation','col_admin',format('insert into public.attestations(enrollment_id) values (%L)',t.id('9',1)),'refus');
select t.chk('B14 propriétaire non plus en direct','ifap_admin',format('insert into public.attestations(enrollment_id) values (%L)',t.id('9',1)),'refus');
select t.chk('B15 aucun dépôt ni remplacement de PDF','systeme','select 1 from pg_policies where schemaname=''storage'' and policyname in (''certificates_insert'',''certificates_update'')','0');
select t.chk('B16 ancien recalcul supprimé','systeme','select 1 from pg_proc where proname=''recalculate_enrollment_completion_for_current_user''','0');

-- C. Règle : ressources et évaluations
select t.chk('C1 ressource consultée','apprenant',t.act(1,'resource_completed',11,1),'ok',true);
select t.etat('C2 une condition sur trois',1,'in_progress',33.33,0);
select t.chk('C3 première évaluation réussie','systeme',t.tentative(1,1),'ok',true);
select t.etat('C4 une évaluation sur deux ne suffit pas',1,'in_progress',66.67,0);
select t.chk('C5 seconde évaluation réussie','systeme',t.tentative(2,1),'ok',true);
select t.etat('C6 terminée et attestée',1,'completed',100,1);
select t.chk('C7 émetteur = propriétaire','systeme',format('select 1 from public.attestations where enrollment_id=%L and issuer_name=''T IFAP''',t.id('9',1)),'1');
select t.chk('C8 sans condition : activité','apprenant',t.act(2,'module_completed',null,2),'ok',true);
select t.etat('C9 sans condition : jamais terminée seule',2,'in_progress',0,0);
select t.chk('C10 ressource facultative','apprenant',t.act(3,'resource_completed',32,3),'ok',true);
select t.etat('C11 facultative sans effet',3,'in_progress',0,0);
select t.chk('C12 ressource obligatoire','apprenant',t.act(3,'resource_completed',31,3),'ok',true);
select t.etat('C13 ressource hors module encore due',3,'in_progress',50,0);
select t.chk('C14 déploiement clos','systeme',format('update public.deployments set status=''closed'' where id=%L',t.id('8',3)),'ok',true);
select t.chk('C15 clos : l''inscrit continue','apprenant',t.act(3,'resource_completed',33),'ok',true);
select t.etat('C16 terminée',3,'completed',100,1);
select t.chk('C17 contenu ajouté ensuite','systeme',format('insert into public.course_resources(course_id,title,resource_type) values (%L,''Nouvelle'',''pdf'')',t.id('3',3)),'ok',true);
select t.chk('C18 nouvelle activité','apprenant',t.act(3,'resource_opened',31),'ok',true);
select t.etat('C19 achèvement acquis conservé',3,'completed',100,1);
select t.chk('C20 archivage','systeme',format('update public.deployments set status=''archived'' where id=%L',t.id('8',6)),'ok',true);
select t.chk('C21 activité sur archivé (système)','systeme',t.act(6,'resource_completed',61,6),'ok',true);
select t.etat('C22 archivé : plus de progression',6,'enrolled',0,0);

-- D. Séances chez un tiers
select t.chk('D1 séance','col_admin',t.seance(4,4),'ok',true);
select t.chk('D2 inscrit porté','col_admin',t.porter(4,4),'ok',true);
select t.chk('D3 second porté','col_admin',t.porter(4,14),'ok',true);
select t.etat('D4 être porté ne démarre pas',4,'enrolled',0,0);
select t.chk('D5 formateur employeur coche présent','col_formateur',t.presence(4,1,true),'ok',true);
select t.etat('D6 à valider, sans attestation',4,'awaiting_validation',100,0);
select t.chk('D7 présence manuelle = 100 %','systeme','select 1 from public.attendance where present and attendance_percent=100','1');
select t.chk('D8 employeur ne valide pas','col_admin',t.rpc('validate_enrollment',4),'refus');
select t.chk('D9 formateur IFAP ne valide pas','ifap_formateur',t.rpc('validate_enrollment',4),'refus');
select t.chk('D10 apprenant ne valide pas','apprenant',t.rpc('validate_enrollment',4),'refus');
select t.chk('D11 anonyme ne valide pas','anonyme',t.rpc('validate_enrollment',4),'refus');
select t.chk('D12 l''IFAP valide sans motif','ifap_admin',t.rpc('validate_enrollment',4),'ok',true);
select t.etat('D13 terminée et attestée',4,'completed',100,1);
select t.chk('D14 absent','col_formateur',t.presence(4,2,false),'ok',true);
select t.etat('D15 absent : rien',14,'enrolled',0,0);
select t.chk('D16 absent = 0 %','systeme','select 1 from public.attendance where not present and attendance_percent=0','1');
select t.chk('D17 correction : présent','col_formateur',t.presence(4,2,true),'ok',true);
select t.etat('D18 à valider',14,'awaiting_validation',100,0);
select t.chk('D19 correction : absent','col_formateur',t.presence(4,2,false),'ok',true);
select t.etat('D20 retour en cours',14,'in_progress',0,0);
select t.chk('D21 employeur abaisse le seuil','col_admin',format('update public.sessions set required_attendance_percent=0 where id=%L',t.id('c',4)),'ok',true);
select t.chk('D22 présence partielle 30 %','systeme',format('update public.attendance set present=true, attended_seconds=1080 where learner_id=%L',t.id('2',2)),'ok',true);
select t.etat('D23 plancher de 80 % chez un tiers',14,'in_progress',0,0);
select t.chk('D24 employeur ne retire pas un inscrit','col_admin',format('delete from public.session_enrollments where enrollment_id=%L',t.id('9',14)),'refus');
select t.chk('D25 ni ne déplace son inscription à la séance','col_admin',format('update public.session_enrollments set enrollment_id=%L where enrollment_id=%L',t.id('9',1),t.id('9',14)),'refus');
select t.chk('D26 ni ne supprime la séance','col_admin',format('delete from public.sessions where id=%L',t.id('c',4)),'refus');
select t.chk('D27 ni ne la rattache ailleurs','col_admin',format('update public.sessions set deployment_id=%L where id=%L',t.id('8',7),t.id('c',4)),'refus');
select t.chk('D28 ressource + séance : séance','col_admin',t.seance(8,8),'ok',true);
select t.chk('D29 ressource consultée sans être porté sur la séance','apprenant',t.act(8,'resource_completed',81,8),'ok',true);
select t.etat('D30 non porté : validation exigée quand même',8,'awaiting_validation',100,0);

select t.chk('D31 employeur n''annule pas une séance avec inscrits','col_admin',format('update public.sessions set status=''cancelled'' where id=%L',t.id('c',4)),'refus');
select t.chk('D32 son formateur non plus','col_formateur',format('update public.sessions set status=''cancelled'' where id=%L',t.id('c',4)),'refus');
select t.chk('D33 employeur modifie toujours le titre','col_admin',format('update public.sessions set title=''T'' where id=%L',t.id('c',4)),'ok');
select t.chk('D34 le système peut encore annuler','systeme',format('update public.sessions set status=''cancelled'' where id=%L',t.id('c',4)),'ok');
select t.chk('D35 séance vide : annulation permise','col_admin',format('update public.sessions set status=''cancelled'' where id=%L',t.id('c',8)),'ok',true);
select t.chk('D36 aucune inscription sur une séance annulée','col_admin',t.porter(8,8),'refus');

-- E. Interne : automatique
select t.chk('E1 séance interne','ifap_admin',t.seance(5,5),'ok',true);
select t.chk('E2 porté','ifap_admin',t.porter(5,5),'ok',true);
select t.chk('E3 présent','ifap_formateur',t.presence(5,3,true),'ok',true);
select t.etat('E4 IFAP interne : attestée',5,'completed',100,1);
select t.chk('E5 séance commune','col_admin',t.seance(7,7),'ok',true);
select t.chk('E6 porté','col_admin',t.porter(7,7),'ok',true);
select t.chk('E7 propriétaire retire un inscrit','col_admin',format('delete from public.session_enrollments where enrollment_id=%L',t.id('9',7)),'ok');
select t.chk('E8 présent','col_formateur',t.presence(7,1,true),'ok',true);
select t.etat('E9 formation de la commune : attestée',7,'completed',100,1);
select t.chk('E10 émetteur = la commune','systeme',format('select 1 from public.attestations where enrollment_id=%L and issuer_name=''T Commune''',t.id('9',7)),'1');
select t.chk('E11 IFAP ne révoque pas chez la commune propriétaire','ifap_admin',t.revoquer(7,'x'),'refus');
select t.chk('E12 la commune révoque la sienne','col_admin',t.revoquer(7,'Erreur de saisie'),'ok');

-- F. Révocation et validation manuelle
select t.chk('F1 employeur ne révoque pas','col_admin',t.revoquer(1,'x'),'refus');
select t.chk('F2 formateur IFAP non plus','ifap_formateur',format('select public.revoke_attestation(%L,''x'')',gen_random_uuid()),'refus');
select t.chk('F3 apprenant non plus','apprenant',t.revoquer(1,'x'),'refus');
select t.chk('F4 motif obligatoire','ifap_admin',format('select public.revoke_attestation(%L,''  '')',(select id from public.attestations where enrollment_id=t.id('9',1))),'refus');
select t.chk('F5 l''IFAP révoque','ifap_admin',format('select public.revoke_attestation(%L,''Fraude fictive'')',(select id from public.attestations where enrollment_id=t.id('9',1))),'ok',true);
select t.etat('F6 conservée, non valide',1,'completed',100,1,0);
select t.chk('F7 apprenant lit le motif','apprenant','select 1 from public.attestations where revocation_reason=''Fraude fictive'' and revoked_by is not null','1');
select t.chk('F8 nouvelle activité','apprenant',t.act(1,'resource_opened',11,1),'ok',true);
select t.etat('F9 pas de redélivrance automatique',1,'completed',100,1,0);
select t.chk('F10 redélivrance sans motif refusée','ifap_admin',t.rpc('validate_enrollment',1),'refus');
select t.chk('F11 redélivrance motivée','ifap_admin',t.rpc('validate_enrollment',1,'Erreur levée'),'ok',true);
select t.etat('F12 une seule valide',1,'completed',100,2,1);
select t.chk('F13 pas de double validation','ifap_admin',t.rpc('validate_enrollment',1,'encore'),'refus');
select t.chk('F14 jamais deux valides','systeme',format('insert into public.attestations(enrollment_id) values (%L)',t.id('9',1)),'refus');
select t.chk('F15 validation manuelle sans motif refusée','ifap_admin',t.rpc('validate_enrollment',2),'refus');
select t.chk('F16 employeur ne valide pas','col_admin',t.rpc('validate_enrollment',2,'x'),'refus');
select t.chk('F17 validation manuelle motivée','ifap_admin',t.rpc('validate_enrollment',2,'Acquis vérifiés'),'ok',true);
select t.etat('F18 attestée',2,'completed',100,1);
select t.chk('F19 trace conservée','systeme',format('select 1 from public.enrollments where id=%L and validation_reason=''Acquis vérifiés'' and validated_by is not null and validated_at is not null',t.id('9',2)),'1');

-- G. Annulation
select t.chk('G1 apprenant n''annule pas','apprenant',t.rpc('cancel_enrollment',14),'refus');
select t.chk('G2 autre collectivité non plus','autre_admin',t.rpc('cancel_enrollment',14),'refus');
select t.chk('G3 formateur IFAP non plus','ifap_formateur',t.rpc('cancel_enrollment',14),'refus');
select t.chk('G4 propriétaire annule','ifap_admin',t.rpc('cancel_enrollment',14),'ok');
select t.chk('G5 employeur annule','col_formateur',t.rpc('cancel_enrollment',14),'ok',true);
select t.chk('G6 trace d''annulation','systeme',format('select 1 from public.enrollments where id=%L and status=''cancelled'' and cancelled_by is not null',t.id('9',14)),'1');
select t.chk('G7 deux fois : refus','col_admin',t.rpc('cancel_enrollment',14),'refus');
select t.chk('G8 annulée : pas de déclaration','second',t.act(14,'resource_opened'),'refus');
select t.chk('G9 annulée : pas de validation','ifap_admin',t.rpc('validate_enrollment',14,'x'),'refus');
select t.chk('G10 présence sur annulée (système)','systeme',format('update public.attendance set attended_seconds=3600 where learner_id=%L',t.id('2',2)),'ok',true);
select t.etat('G11 reste annulée',14,'cancelled',0,0);
select t.chk('G12 terminée : pas d''annulation','col_admin',t.rpc('cancel_enrollment',4),'refus');
select t.chk('G13 apprenant ne réactive pas','second',t.rpc('reactivate_enrollment',14),'refus');
select t.chk('G14 réactivation','col_admin',t.rpc('reactivate_enrollment',14),'ok',true);
select t.etat('G15 reprend et recalcule',14,'awaiting_validation',100,0);
select t.chk('G16 annulation à nouveau','col_admin',t.rpc('cancel_enrollment',14),'ok',true);
select t.chk('G17 déploiement clos','systeme',format('update public.deployments set status=''closed'' where id=%L',t.id('8',4)),'ok',true);
select t.chk('G18 pas de réactivation hors déploiement ouvert','col_admin',t.rpc('reactivate_enrollment',14),'refus');
select t.chk('G19 capacité fixée à 1','systeme',format('update public.deployments set capacity=1 where id=%L',t.id('8',2)),'ok',true);
select t.chk('G20 inscription au-delà refusée (la terminée compte)','col_admin',t.enr(12,2,2),'refus');

-- H. Rien ne s'efface
select t.chk('H1 inscription attestée','systeme',format('delete from public.enrollments where id=%L',t.id('9',1)),'refus');
select t.chk('H2 inscription démarrée','systeme',format('delete from public.enrollments where id=%L',t.id('9',8)),'refus');
select t.chk('H3 cascade apprenant','systeme',format('delete from public.learners where id=%L',t.id('2',1)),'refus');
select t.chk('H4 cascade déploiement','systeme',format('delete from public.deployments where id=%L',t.id('8',1)),'refus');
select t.chk('H5 cascade organisation','systeme',format('delete from public.organizations where id=%L',t.id('1',2)),'refus');
select t.chk('H6 attestation (cascade interdite)','systeme','select 1 from pg_constraint where conrelid=''public.attestations''::regclass and confrelid=''public.enrollments''::regclass and confdeltype=''r''','1');
select t.chk('H7 inscription intacte supprimable par maintenance','systeme',t.enr(23,1,2)||'; delete from public.enrollments where id='''||t.id('9',23)||'''','ok');

-- I. Liste de suivi
select t.chk('I1 l''IFAP voit les inscrits de sa formation','ifap_admin',format('select * from public.list_course_enrollments(%L)',t.id('3',4)),'2');
select t.chk('I2 employeur : liste vide','col_admin',format('select * from public.list_course_enrollments(%L)',t.id('3',4)),'0');
select t.chk('I3 formateur IFAP : vide','ifap_formateur',format('select * from public.list_course_enrollments(%L)',t.id('3',4)),'0');
select t.chk('I4 apprenant : vide','apprenant',format('select * from public.list_course_enrollments(%L)',t.id('3',4)),'0');
select t.chk('I5 anonyme refusé','anonyme',format('select * from public.list_course_enrollments(%L)',t.id('3',4)),'refus');
select t.chk('I6 pas la formation interne d''un employeur','ifap_admin',format('select * from public.list_course_enrollments(%L)',t.id('3',7)),'0');
select t.chk('I7 fiches apprenants toujours fermées','ifap_admin',format('select 1 from public.learners where organization_id=%L',t.id('1',2)),'0');

\o
select n, nom, left(detail,100) detail from t.res where not ok order by n;
select count(*) filter (where ok) as reussis, count(*) filter (where not ok) as echecs from t.res;
rollback;
