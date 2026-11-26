-- Achèvement des formations et attestations : la base calcule seule l'achèvement et délivre.
-- Retour arrière : supabase/rollback/20261127000000_achevement_attestations.sql

-- 1. Colonnes de trace et statuts ---------------------------------------------------------------
alter table public.enrollments
  add column cancelled_at timestamptz,
  add column cancelled_by uuid,
  add column validated_at timestamptz,
  add column validated_by uuid,
  add column validation_reason text;
alter table public.enrollments add constraint enrollments_status_check
  check (status in ('pending','not_started','enrolled','started','in_progress','awaiting_validation','completed','cancelled'));

alter table public.attestations
  add column revoked_by uuid,
  add column revocation_reason text;
alter table public.attestations drop constraint attestations_enrollment_id_fkey;
alter table public.attestations add constraint attestations_enrollment_id_fkey
  foreign key (enrollment_id) references public.enrollments(id) on delete restrict;
create unique index attestations_one_active_per_enrollment
  on public.attestations (enrollment_id) where revoked_at is null;

-- 2. Anciens recalculs concurrents -------------------------------------------------------------
drop trigger attendance_recalculate_completion on public.attendance;
drop trigger attendance_updates_progress on public.attendance;
drop trigger trg_attendance_recalculate_completion on public.attendance;
drop trigger evaluation_recalculate_completion on public.evaluation_attempts;
drop trigger trg_eval_recalculate_completion on public.evaluation_attempts;
drop trigger trg_recalculate_activity_enrollment_progress on public.learning_activity_log;
drop trigger scorm_attempt_progress on public.scorm_attempts;
drop function public.recalculate_enrollment_completion_for_current_user(uuid);
drop function app_private.recalculate_from_attendance();
drop function app_private.recalculate_from_evaluation();
drop function app_private.trigger_recalculate_on_attendance();
drop function app_private.trigger_recalculate_on_evaluation();
drop function app_private.recalculate_activity_enrollment_progress();
drop function app_private.recalculate_enrollment_session_progress(uuid);
drop function app_private.recalculate_enrollment_progress_v27(uuid);
drop function app_private.recalculate_enrollment_completion(uuid);
drop function app_private.update_enrollment_progress();
drop function app_private.update_scorm_progress();

-- 3. Droits sur les cours -----------------------------------------------------------------------
create function app_private.is_course_owner_admin(p_course uuid)
returns boolean language sql stable security definer set search_path = '' as $$
  select app_private.is_platform_admin() or exists (
    select 1 from public.courses c
    where c.id = p_course
      and app_private.is_org_member(c.owner_organization_id, array['org_admin','platform_admin']::public.member_role[]));
$$;

-- 4. La règle d'achèvement, à un seul endroit ---------------------------------------------------
create function app_private.apply_completion(p_enrollment uuid)
returns void language plpgsql security definer set search_path = '' as $$
declare
  e record;
  n_total integer := 0; n_done integer := 0; n integer; d integer;
  third_party boolean; met boolean; active boolean; new_status text;
begin
  select en.status, en.learner_id, en.started_at, dep.id as deployment_id, dep.status as deployment_status,
         dep.course_id, dep.target_organization_id <> c.owner_organization_id as external
    into e
  from public.enrollments en
  join public.deployments dep on dep.id = en.deployment_id
  join public.courses c on c.id = dep.course_id
  where en.id = p_enrollment
  for update of en;
  if not found or e.status in ('cancelled','completed','pending')
     or e.deployment_status = 'archived'::public.deployment_status then
    return;
  end if;

  -- ressources obligatoires (hors module ou dans un module obligatoire)
  select count(*), count(*) filter (where exists (
           select 1 from public.learning_activity_log a
           where a.enrollment_id = p_enrollment and a.resource_id = r.id and a.activity_type = 'resource_completed'))
    into n, d
  from public.course_resources r
  where r.course_id = e.course_id and r.is_required
    and (r.module_id is null or exists (select 1 from public.course_modules m where m.id = r.module_id and m.is_required));
  n_total := n_total + n; n_done := n_done + d;

  -- évaluations obligatoires, toutes
  select count(*), count(*) filter (where exists (
           select 1 from public.evaluation_attempts t
           where t.evaluation_id = ev.id and t.learner_id = e.learner_id and t.passed))
    into n, d
  from public.evaluations ev where ev.course_id = e.course_id and ev.is_required;
  n_total := n_total + n; n_done := n_done + d;

  -- séances où l'inscription est portée ; chez un tiers le seuil ne descend pas sous 80 %
  select count(*), count(*) filter (where exists (
           select 1 from public.attendance a
           where a.session_id = s.id and a.learner_id = e.learner_id and a.present
             and coalesce(a.attendance_percent, 0) >= case when e.external
                   then greatest(coalesce(s.required_attendance_percent, 80), 80)
                   else coalesce(s.required_attendance_percent, 80) end))
    into n, d
  from public.session_enrollments se join public.sessions s on s.id = se.session_id
  where se.enrollment_id = p_enrollment and s.status <> 'cancelled';
  n_total := n_total + n; n_done := n_done + d;

  third_party := e.external and exists (select 1 from public.sessions s where s.deployment_id = e.deployment_id);
  met := n_total > 0 and n_done = n_total;
  active := e.started_at is not null
    or exists (select 1 from public.learning_activity_log a where a.enrollment_id = p_enrollment)
    or exists (select 1 from public.evaluation_attempts t join public.evaluations ev on ev.id = t.evaluation_id
               where t.learner_id = e.learner_id and ev.course_id = e.course_id)
    or exists (select 1 from public.session_enrollments se join public.attendance a on a.session_id = se.session_id
               where se.enrollment_id = p_enrollment and a.learner_id = e.learner_id and a.present);
  if not active and not met then
    return;
  end if;

  new_status := case when not met then 'in_progress'
                     when third_party then 'awaiting_validation'
                     else 'completed' end;
  update public.enrollments set
    status = new_status,
    progress = case when n_total = 0 then 0 else round(n_done::numeric / n_total * 100, 2) end,
    started_at = coalesce(started_at, now()),
    completed_at = case when new_status = 'completed' then now() end
  where id = p_enrollment;
end $$;

create function app_private.completion_from_activity()
returns trigger language plpgsql security definer set search_path = '' as $$
begin
  perform app_private.apply_completion(new.enrollment_id);
  return null;
end $$;

create function app_private.completion_from_attempt()
returns trigger language plpgsql security definer set search_path = '' as $$
begin
  perform app_private.apply_completion(en.id)
  from public.enrollments en
  join public.deployments dep on dep.id = en.deployment_id
  join public.evaluations ev on ev.course_id = dep.course_id
  where ev.id = new.evaluation_id and en.learner_id = new.learner_id;
  return null;
end $$;

create function app_private.completion_from_attendance()
returns trigger language plpgsql security definer set search_path = '' as $$
declare r record;
begin
  if tg_op = 'DELETE' then r := old; else r := new; end if;
  perform app_private.apply_completion(en.id)
  from public.session_enrollments se
  join public.enrollments en on en.id = se.enrollment_id
  where se.session_id = r.session_id and en.learner_id = r.learner_id;
  return null;
end $$;

create function app_private.completion_from_registration()
returns trigger language plpgsql security definer set search_path = '' as $$
begin
  if tg_op = 'DELETE' then
    perform app_private.apply_completion(old.enrollment_id);
  else
    perform app_private.apply_completion(new.enrollment_id);
  end if;
  return null;
end $$;

create trigger completion_on_activity after insert on public.learning_activity_log
  for each row execute function app_private.completion_from_activity();
create trigger completion_on_attempt after insert or update on public.evaluation_attempts
  for each row execute function app_private.completion_from_attempt();
create trigger completion_on_attendance after insert or update or delete on public.attendance
  for each row execute function app_private.completion_from_attendance();
create trigger completion_on_registration after insert or delete on public.session_enrollments
  for each row execute function app_private.completion_from_registration();

-- Présence cochée à la main (aucune durée de connexion) : 100 % ou 0 %.
create or replace function app_private.recalculate_attendance_percent()
returns trigger language plpgsql security definer set search_path = 'public', 'app_private' as $$
declare v_duration integer;
begin
  if new.joined_at is not null and new.left_at is not null then
    v_duration := greatest(0, extract(epoch from (new.left_at-new.joined_at))::integer);
    new.attended_seconds := greatest(new.attended_seconds, v_duration);
  end if;
  if new.attended_seconds = 0 and new.joined_at is null then
    new.attendance_percent := case when new.present then 100 else 0 end;
    return new;
  end if;
  select greatest(1, extract(epoch from (s.end_at-s.start_at))::integer)
  into v_duration
  from public.sessions s where s.id=new.session_id;
  if v_duration is not null then
    new.attendance_percent := least(100, round((new.attended_seconds::numeric / v_duration::numeric)*100,2));
  end if;
  return new;
end $$;

-- 5. Attestations : délivrées par la base, au nom du propriétaire de la formation ---------------
create function app_private.issue_attestation(p_enrollment uuid)
returns void language plpgsql security definer set search_path = '' as $$
declare v_issuer text; v_token uuid := gen_random_uuid();
begin
  if exists (select 1 from public.attestations a where a.enrollment_id = p_enrollment and a.revoked_at is null) then
    return;
  end if;
  select o.name into v_issuer
  from public.enrollments en
  join public.deployments dep on dep.id = en.deployment_id
  join public.courses c on c.id = dep.course_id
  join public.organizations o on o.id = c.owner_organization_id
  where en.id = p_enrollment;
  insert into public.attestations (enrollment_id, verification_token, issuer_name, verification_url)
  values (p_enrollment, v_token, v_issuer, '/verify/' || v_token::text);
end $$;

-- Une attestation révoquée n'est jamais redélivrée automatiquement.
create or replace function app_private.issue_attestation_on_completion()
returns trigger language plpgsql security definer set search_path = 'public', 'pg_catalog' as $$
begin
  if new.status = 'completed' and new.completed_at is not null
     and not exists (select 1 from public.attestations a where a.enrollment_id = new.id) then
    perform app_private.issue_attestation(new.id);
  end if;
  return new;
end $$;

-- 6. Inscriptions : création neutre, aucune suppression d'un parcours commencé ------------------
create function app_private.enforce_enrollment_initial_state()
returns trigger language plpgsql set search_path = '' as $$
begin
  if current_user in ('anon','authenticated') and (
       new.status not in ('enrolled','pending') or new.progress <> 0 or new.started_at is not null or new.completed_at is not null
       or new.cancelled_at is not null or new.cancelled_by is not null or new.validated_at is not null
       or new.validated_by is not null or new.validation_reason is not null) then
    raise exception 'Une inscription commence à « inscrit », sans progression';
  end if;
  return new;
end $$;
create trigger enrollments_initial_state before insert on public.enrollments
  for each row execute function app_private.enforce_enrollment_initial_state();

create function app_private.protect_enrollment_history()
returns trigger language plpgsql security definer set search_path = '' as $$
begin
  if old.started_at is not null or old.progress > 0
     or old.status in ('started','in_progress','awaiting_validation','completed')
     or exists (select 1 from public.attestations a where a.enrollment_id = old.id)
     or exists (select 1 from public.learning_activity_log a where a.enrollment_id = old.id) then
    raise exception 'Une inscription commencée ou attestée ne peut pas être supprimée';
  end if;
  return old;
end $$;
create trigger enrollments_protect_history before delete on public.enrollments
  for each row execute function app_private.protect_enrollment_history();

-- La capacité compte toutes les inscriptions non annulées.
create or replace function app_private.enforce_enrollment_rules()
returns trigger language plpgsql security definer set search_path = '' as $$
declare
  target_org uuid; cap integer; current_count integer; deadline timestamptz;
  dep_status public.deployment_status; c_owner uuid; c_visibility text;
begin
  select d.target_organization_id, d.capacity, d.enrollment_deadline, d.status, c.owner_organization_id, c.visibility
    into target_org, cap, deadline, dep_status, c_owner, c_visibility
  from public.deployments d join public.courses c on c.id = d.course_id
  where d.id = new.deployment_id;

  if not exists (select 1 from public.learners l
                 where l.id = new.learner_id and l.organization_id = target_org and l.is_active) then
    raise exception 'L''apprenant doit être actif et appartenir à l''organisation destinataire';
  end if;
  if dep_status <> 'available'::public.deployment_status then
    raise exception 'Ce déploiement n''accepte plus d''inscription';
  end if;
  if new.enrollment_mode = 'self_service'::public.enrollment_mode
     and target_org <> c_owner and c_visibility <> 'ifap_catalog' then
    raise exception 'L''auto-inscription est impossible pour cette formation';
  end if;
  if tg_op = 'INSERT' and deadline is not null and now() > deadline then
    raise exception 'La date limite d''inscription est dépassée';
  end if;
  if tg_op = 'INSERT' and cap is not null then
    select count(*) into current_count from public.enrollments e
    where e.deployment_id = new.deployment_id and e.status <> 'cancelled';
    if current_count >= cap then
      raise exception 'La capacité du déploiement est atteinte';
    end if;
  end if;
  return new;
end $$;

-- 7. Séances chez un tiers : seul le propriétaire retire un inscrit ou retire/annule une séance --
create function app_private.assert_session_owner(p_session uuid)
returns void language plpgsql security definer set search_path = '' as $$
declare v_course uuid;
begin
  if auth.uid() is null then return; end if;  -- opérations du système
  select dep.course_id into v_course
  from public.sessions s
  join public.deployments dep on dep.id = s.deployment_id
  join public.courses c on c.id = dep.course_id
  where s.id = p_session and dep.target_organization_id <> c.owner_organization_id;
  if v_course is not null and not app_private.is_course_owner_admin(v_course) then
    raise exception 'Seul l''organisme propriétaire de la formation peut retirer un inscrit, ou retirer ou annuler une séance';
  end if;
end $$;

create function app_private.protect_session_registration()
returns trigger language plpgsql security definer set search_path = '' as $$
begin
  perform app_private.assert_session_owner(old.session_id);
  if tg_op = 'DELETE' then return old; end if;
  return new;
end $$;
create trigger session_enrollments_protect before delete or update on public.session_enrollments
  for each row execute function app_private.protect_session_registration();

create function app_private.protect_session()
returns trigger language plpgsql security definer set search_path = '' as $$
begin
  if (tg_op = 'DELETE' or new.deployment_id is distinct from old.deployment_id
      or (new.status = 'cancelled' and old.status is distinct from 'cancelled'))
     and (exists (select 1 from public.session_enrollments se where se.session_id = old.id)
          or exists (select 1 from public.attendance a where a.session_id = old.id)) then
    perform app_private.assert_session_owner(old.id);
  end if;
  if tg_op = 'DELETE' then return old; end if;
  return new;
end $$;
create trigger sessions_protect before delete or update of deployment_id, status on public.sessions
  for each row execute function app_private.protect_session();

create function app_private.refuse_cancelled_session()
returns trigger language plpgsql security definer set search_path = '' as $$
begin
  if exists (select 1 from public.sessions s where s.id = new.session_id and s.status = 'cancelled') then
    raise exception 'Cette séance est annulée';
  end if;
  return new;
end $$;
create trigger session_enrollments_open_session before insert on public.session_enrollments
  for each row execute function app_private.refuse_cancelled_session();

-- 8. Écritures directes retirées ----------------------------------------------------------------
revoke update, delete, truncate on public.enrollments from anon, authenticated;
revoke insert, update, delete, truncate on public.attestations from anon, authenticated;
revoke insert, update, delete, truncate on public.evaluation_attempts from anon, authenticated;
drop policy attestations_insert on public.attestations;
drop policy attempts_manage on public.evaluation_attempts;
drop policy certificates_insert on storage.objects;
drop policy certificates_update on storage.objects;

-- Seul l'apprenant déclare sa propre activité.
drop policy learning_activity_manage on public.learning_activity_log;
drop policy learning_activity_insert_self on public.learning_activity_log;
drop policy learning_activity_log_insert_self on public.learning_activity_log;
create policy learning_activity_log_insert_self on public.learning_activity_log
for insert to authenticated with check (
  exists (
    select 1 from public.enrollments e
    join public.learners l on l.id = e.learner_id
    join public.deployments d on d.id = e.deployment_id
    where e.id = learning_activity_log.enrollment_id
      and e.status <> 'cancelled'
      and l.user_id = (select auth.uid())
      and (learning_activity_log.resource_id is null or exists (
            select 1 from public.course_resources r
            where r.id = learning_activity_log.resource_id and r.course_id = d.course_id))
      and (learning_activity_log.module_id is null or exists (
            select 1 from public.course_modules cm
            where cm.id = learning_activity_log.module_id and cm.course_id = d.course_id))
  ));

-- 9. Actions, avec contrôle des droits ----------------------------------------------------------
create function public.cancel_enrollment(p_enrollment uuid)
returns void language plpgsql security definer set search_path = '' as $$
declare e record;
begin
  select en.status, l.organization_id, d.course_id into e
  from public.enrollments en
  join public.learners l on l.id = en.learner_id
  join public.deployments d on d.id = en.deployment_id
  where en.id = p_enrollment for update of en;
  if not found or not (app_private.is_course_owner_admin(e.course_id)
      or app_private.is_org_member(e.organization_id, array['org_admin','trainer','platform_admin']::public.member_role[])) then
    raise exception 'Action non autorisée' using errcode = '42501';
  end if;
  if e.status = 'cancelled' then raise exception 'Cette inscription est déjà annulée'; end if;
  if e.status = 'completed' then raise exception 'Une formation terminée ne s''annule pas : révoquez l''attestation'; end if;
  update public.enrollments
  set status = 'cancelled', cancelled_at = now(), cancelled_by = auth.uid()
  where id = p_enrollment;
end $$;

-- Réactive une inscription annulée ou accepte une demande en attente.
create function public.reactivate_enrollment(p_enrollment uuid)
returns void language plpgsql security definer set search_path = '' as $$
declare e record; n integer;
begin
  select en.status, en.started_at, en.deployment_id, l.organization_id, l.is_active, d.course_id,
         d.status as deployment_status, d.capacity into e
  from public.enrollments en
  join public.learners l on l.id = en.learner_id
  join public.deployments d on d.id = en.deployment_id
  where en.id = p_enrollment for update of en;
  if not found or not (app_private.is_course_owner_admin(e.course_id)
      or app_private.is_org_member(e.organization_id, array['org_admin','trainer','platform_admin']::public.member_role[])) then
    raise exception 'Action non autorisée' using errcode = '42501';
  end if;
  if e.status not in ('cancelled','pending') then raise exception 'Cette inscription n''est ni annulée ni en attente'; end if;
  if e.deployment_status <> 'available'::public.deployment_status then
    raise exception 'Ce déploiement n''accepte plus d''inscription';
  end if;
  if not e.is_active then raise exception 'Cet apprenant n''est plus actif'; end if;
  select count(*) into n from public.enrollments x where x.deployment_id = e.deployment_id and x.status <> 'cancelled';
  if e.capacity is not null and n >= e.capacity then raise exception 'La capacité du déploiement est atteinte'; end if;
  update public.enrollments
  set status = case when e.started_at is null then 'enrolled' else 'in_progress' end
  where id = p_enrollment;
  perform app_private.apply_completion(p_enrollment);
end $$;

create function public.validate_enrollment(p_enrollment uuid, p_reason text default null)
returns void language plpgsql security definer set search_path = '' as $$
declare e record; reason text := nullif(btrim(p_reason), '');
begin
  select en.status, d.course_id into e
  from public.enrollments en join public.deployments d on d.id = en.deployment_id
  where en.id = p_enrollment for update of en;
  if not found or not app_private.is_course_owner_admin(e.course_id) then
    raise exception 'Action non autorisée' using errcode = '42501';
  end if;
  if e.status in ('cancelled','pending') then raise exception 'Cette inscription n''est pas active'; end if;
  if exists (select 1 from public.attestations a where a.enrollment_id = p_enrollment and a.revoked_at is null) then
    raise exception 'Une attestation valide existe déjà';
  end if;
  if reason is null and e.status <> 'awaiting_validation' then
    raise exception 'Le motif est obligatoire';
  end if;
  update public.enrollments set
    status = 'completed', progress = 100,
    started_at = coalesce(started_at, now()), completed_at = coalesce(completed_at, now()),
    validated_at = now(), validated_by = auth.uid(), validation_reason = reason
  where id = p_enrollment;
  perform app_private.issue_attestation(p_enrollment);  -- couvre la redélivrance après révocation
end $$;

create function public.revoke_attestation(p_attestation uuid, p_reason text)
returns void language plpgsql security definer set search_path = '' as $$
declare a record; reason text := nullif(btrim(p_reason), '');
begin
  select att.revoked_at, d.course_id into a
  from public.attestations att
  join public.enrollments en on en.id = att.enrollment_id
  join public.deployments d on d.id = en.deployment_id
  where att.id = p_attestation for update of att;
  if not found or not app_private.is_course_owner_admin(a.course_id) then
    raise exception 'Action non autorisée' using errcode = '42501';
  end if;
  if reason is null then raise exception 'Le motif est obligatoire'; end if;
  if a.revoked_at is not null then raise exception 'Cette attestation est déjà révoquée'; end if;
  update public.attestations
  set revoked_at = now(), revoked_by = auth.uid(), revocation_reason = reason
  where id = p_attestation;
end $$;

create function public.list_course_enrollments(p_course uuid)
returns table (
  enrollment_id uuid, first_name text, last_name text, organization_name text, status text, progress numeric,
  completed_at timestamptz, attestation_id uuid, certificate_number text, revoked_at timestamptz, revocation_reason text)
language sql stable security definer set search_path = '' as $$
  select en.id, l.first_name, l.last_name, o.name, en.status, en.progress, en.completed_at,
         a.id, a.certificate_number, a.revoked_at, a.revocation_reason
  from public.deployments d
  join public.enrollments en on en.deployment_id = d.id
  join public.learners l on l.id = en.learner_id
  join public.organizations o on o.id = l.organization_id
  left join lateral (
    select x.* from public.attestations x where x.enrollment_id = en.id
    order by (x.revoked_at is null) desc, x.issued_at desc limit 1) a on true
  where d.course_id = p_course and app_private.is_course_owner_admin(p_course)
  order by o.name, l.last_name, l.first_name;
$$;

-- 10. Exécution ---------------------------------------------------------------------------------
revoke all on function
  app_private.is_course_owner_admin(uuid), app_private.apply_completion(uuid),
  app_private.completion_from_activity(), app_private.completion_from_attempt(),
  app_private.completion_from_attendance(), app_private.completion_from_registration(),
  app_private.issue_attestation(uuid), app_private.enforce_enrollment_initial_state(),
  app_private.protect_enrollment_history(), app_private.assert_session_owner(uuid),
  app_private.protect_session_registration(), app_private.protect_session(), app_private.refuse_cancelled_session()
from public, anon, authenticated;

revoke all on function
  public.cancel_enrollment(uuid), public.reactivate_enrollment(uuid), public.validate_enrollment(uuid, text),
  public.revoke_attestation(uuid, text), public.list_course_enrollments(uuid)
from public, anon;
grant execute on function
  public.cancel_enrollment(uuid), public.reactivate_enrollment(uuid), public.validate_enrollment(uuid, text),
  public.revoke_attestation(uuid, text), public.list_course_enrollments(uuid)
to authenticated;
