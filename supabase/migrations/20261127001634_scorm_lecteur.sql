-- Modules SCORM 1.2 : paquets, stockage, tickets du lecteur isolé, enregistrement des résultats.
-- Retour arrière : supabase/rollback/20261127001634_scorm_lecteur.sql

-- 1. Paquets -------------------------------------------------------------------------------------
alter table public.scorm_packages
  add column status text not null default 'uploading',
  add column module_id uuid references public.course_modules(id) on delete set null,
  add column file_count integer not null default 1,
  add column total_bytes bigint not null default 0,
  add column mastery_score numeric;
alter table public.scorm_packages
  add constraint scorm_packages_status_check check (status in ('uploading','ready')),
  add constraint scorm_packages_path_check check (storage_path = course_id::text || '/' || id::text),
  add constraint scorm_packages_size_check
    check (file_count between 1 and 1000 and total_bytes between 0 and 157286400),
  add constraint scorm_packages_mastery_check check (mastery_score is null or mastery_score between 0 and 100);
create unique index scorm_packages_resource_unique on public.scorm_packages (resource_id)
  where resource_id is not null;

-- Écritures par les fonctions ci-dessous uniquement.
drop policy scorm_packages_manage on public.scorm_packages;
drop policy scorm_packages_select on public.scorm_packages;
create policy scorm_packages_select on public.scorm_packages for select to authenticated
using (app_private.can_manage_course_content(course_id));

drop policy scorm_attempts_insert on public.scorm_attempts;
drop policy scorm_attempts_update on public.scorm_attempts;
drop policy scorm_attempts_select on public.scorm_attempts;
create policy scorm_attempts_select on public.scorm_attempts for select to authenticated
using (exists (
  select 1 from public.enrollments e join public.learners l on l.id = e.learner_id
  where e.id = scorm_attempts.enrollment_id
    and (l.user_id = (select auth.uid()) or app_private.is_platform_admin()
         or app_private.is_org_member(l.organization_id,
              array['org_admin','trainer','platform_admin']::public.member_role[]))));

revoke insert, update, delete, truncate on public.scorm_packages, public.scorm_attempts
from anon, authenticated;

-- L'import reste réservé aux formations de l'IFAP tant que le LMS partage le domaine du lecteur.
create function app_private.can_import_scorm(p_course uuid)
returns boolean language sql stable security definer set search_path = '' as $$
  select app_private.can_manage_course_content(p_course) and exists (
    select 1 from public.courses c
    join public.organizations o on o.id = c.owner_organization_id
    where c.id = p_course and o.kind = 'ifap'::public.organization_kind);
$$;

-- 2. Stockage ------------------------------------------------------------------------------------
update storage.buckets set public = false, file_size_limit = 52428800 where id = 'scorm-packages';

-- Le paquet auquel appartient un fichier (null si le chemin ne correspond à aucun paquet).
create function app_private.scorm_package_of(p_name text)
returns uuid language sql stable security definer set search_path = '' as $$
  select p.id from public.scorm_packages p
  where p.storage_path = split_part(p_name, '/', 1) || '/' || split_part(p_name, '/', 2)
    and split_part(p_name, '/', 3) <> ''
    and not (string_to_array(p_name, '/') && array['', '.', '..']);
$$;

drop policy scorm_storage_select on storage.objects;
drop policy scorm_storage_insert on storage.objects;
drop policy scorm_storage_update on storage.objects;
drop policy scorm_storage_delete on storage.objects;

-- Les stagiaires ne lisent jamais le stockage : le lecteur le fait après contrôle d'un ticket.
create policy scorm_storage_select on storage.objects for select to authenticated using (
  bucket_id = 'scorm-packages' and exists (
    select 1 from public.scorm_packages p
    where p.id = app_private.scorm_package_of(objects.name)
      and app_private.can_manage_course_content(p.course_id)));

create policy scorm_storage_insert on storage.objects for insert to authenticated with check (
  bucket_id = 'scorm-packages' and exists (
    select 1 from public.scorm_packages p
    where p.id = app_private.scorm_package_of(objects.name)
      and p.status = 'uploading' and app_private.can_import_scorm(p.course_id)));

-- Suppression seulement quand aucun contenu ne s'appuie sur le paquet.
create policy scorm_storage_delete on storage.objects for delete to authenticated using (
  bucket_id = 'scorm-packages' and exists (
    select 1 from public.scorm_packages p
    where p.id = app_private.scorm_package_of(objects.name)
      and p.resource_id is null and app_private.can_manage_course_content(p.course_id)));

-- 3. Import ---------------------------------------------------------------------------------------
create function public.scorm_register_package(
  p_course uuid, p_module uuid, p_title text, p_launch text, p_mastery numeric, p_files integer, p_bytes bigint)
returns uuid language plpgsql security definer set search_path = '' as $$
declare v_id uuid := gen_random_uuid();
begin
  if not app_private.can_import_scorm(p_course) then
    raise exception 'Import SCORM non autorisé pour cette formation' using errcode = '42501';
  end if;
  if p_module is not null and not exists (
       select 1 from public.course_modules m where m.id = p_module and m.course_id = p_course and m.retired_at is null) then
    raise exception 'Module introuvable dans cette formation';
  end if;
  if coalesce(btrim(p_title), '') = '' then raise exception 'Saisissez un titre.'; end if;
  if coalesce(p_launch, '') = '' or p_launch like '%\\%'
     or string_to_array(split_part(split_part(p_launch, '?', 1), '#', 1), '/') && array['', '.', '..'] then
    raise exception 'Fichier de démarrage invalide';
  end if;
  if p_files is null or p_files not between 1 and 1000 or p_bytes is null or p_bytes not between 1 and 157286400 then
    raise exception 'Paquet trop volumineux (1 000 fichiers et 150 Mo au maximum)';
  end if;
  insert into public.scorm_packages
    (id, course_id, module_id, version, title, storage_path, launch_path, mastery_score, file_count, total_bytes)
  values (v_id, p_course, p_module, '1.2', btrim(p_title), p_course::text || '/' || v_id::text,
          p_launch, p_mastery, p_files, p_bytes);
  return v_id;
end $$;

create function public.scorm_finalize_package(p_package uuid)
returns uuid language plpgsql security definer set search_path = '' as $$
declare p public.scorm_packages; v_resource uuid; v_count integer;
begin
  select * into p from public.scorm_packages where id = p_package for update;
  if p.id is null or not app_private.can_import_scorm(p.course_id) then
    raise exception 'Paquet introuvable ou action non autorisée' using errcode = '42501';
  end if;
  if p.status <> 'uploading' then raise exception 'Ce paquet est déjà publié'; end if;
  select count(*) into v_count from storage.objects o
  where o.bucket_id = 'scorm-packages' and starts_with(o.name, p.storage_path || '/');
  if v_count <> p.file_count then
    raise exception 'Envoi incomplet : % fichier(s) sur %', v_count, p.file_count;
  end if;
  if not exists (select 1 from storage.objects o where o.bucket_id = 'scorm-packages'
        and o.name = p.storage_path || '/' || split_part(split_part(p.launch_path, '?', 1), '#', 1)) then
    raise exception 'Le fichier de démarrage est absent';
  end if;
  if p.module_id is not null and not exists (
       select 1 from public.course_modules m where m.id = p.module_id and m.retired_at is null) then
    raise exception 'Le module choisi a été retiré';
  end if;
  insert into public.course_resources
    (course_id, module_id, title, resource_type, is_required, launch_path, package_version, position)
  select p.course_id, p.module_id, p.title, 'scorm', true, p.launch_path, p.version,
         coalesce(max(r.position), 0) + 1
  from public.course_resources r where r.course_id = p.course_id
  returning id into v_resource;
  update public.scorm_packages set resource_id = v_resource, status = 'ready', updated_at = now() where id = p.id;
  return v_resource;
end $$;

-- Abandon d'un envoi, ou ménage après suppression d'un contenu jamais suivi.
create function public.scorm_discard_package(p_package uuid)
returns void language plpgsql security definer set search_path = '' as $$
declare p public.scorm_packages;
begin
  select * into p from public.scorm_packages where id = p_package for update;
  if p.id is null or not app_private.can_manage_course_content(p.course_id) then
    raise exception 'Paquet introuvable ou action non autorisée' using errcode = '42501';
  end if;
  if p.resource_id is not null or exists (select 1 from public.scorm_attempts a where a.scorm_package_id = p.id) then
    raise exception 'Ce paquet est utilisé';
  end if;
  if exists (select 1 from storage.objects o
             where o.bucket_id = 'scorm-packages' and starts_with(o.name, p.storage_path || '/')) then
    raise exception 'Supprimez d''abord les fichiers du paquet';
  end if;
  delete from public.scorm_packages where id = p.id;
end $$;

-- 4. Tickets du lecteur ---------------------------------------------------------------------------
create table app_private.scorm_tickets (
  token_hash text primary key,
  package_id uuid not null references public.scorm_packages(id) on delete cascade,
  user_id uuid not null,
  enrollment_id uuid references public.enrollments(id) on delete cascade,
  expires_at timestamptz not null
);
alter table app_private.scorm_tickets enable row level security;
revoke all on app_private.scorm_tickets from public, anon, authenticated;
create index scorm_tickets_expiry_idx on app_private.scorm_tickets (expires_at);

create function app_private.token_hash(p_token text)
returns text language sql immutable set search_path = '' as $$
  select encode(sha256(convert_to(p_token, 'UTF8')), 'hex');
$$;

-- L'inscription est-elle celle de l'appelant, ouverte, et le contenu suivi par elle encore actif ?
create function app_private.scorm_learner_access(p_enrollment uuid, p_resource uuid)
returns boolean language sql stable security definer set search_path = '' as $$
  select exists (
    select 1
    from public.enrollments e
    join public.learners l on l.id = e.learner_id
    join public.deployments d on d.id = e.deployment_id
    join public.course_resources r on r.course_id = d.course_id
    where e.id = p_enrollment and r.id = p_resource
      and l.user_id = (select auth.uid())
      and e.status not in ('cancelled','pending')
      and d.status <> 'archived'::public.deployment_status
      and r.retired_at is null
      and (r.module_id is null or exists (
            select 1 from public.course_modules m where m.id = r.module_id and m.retired_at is null))
      and app_private.can_view_course_content(r.course_id));
$$;

create function public.scorm_open(p_resource uuid, p_enrollment uuid default null)
returns jsonb language plpgsql security definer set search_path = '' as $$
declare p public.scorm_packages; v_token text; v_state jsonb;
begin
  select sp.* into p from public.scorm_packages sp
  join public.course_resources r on r.id = sp.resource_id and r.resource_type = 'scorm'
  where sp.resource_id = p_resource and sp.status = 'ready';
  if (select auth.uid()) is null or p.id is null
     or not (case when p_enrollment is null then app_private.can_manage_course_content(p.course_id)
                  else app_private.scorm_learner_access(p_enrollment, p_resource) end) then
    raise exception 'Module indisponible ou accès non autorisé' using errcode = '42501';
  end if;
  if p_enrollment is not null then
    select jsonb_build_object(
      'student_id', p_enrollment,
      'student_name', l.last_name || ', ' || l.first_name,
      'lesson_status', coalesce(a.lesson_status, 'not attempted'),
      'score_raw', a.score,
      'lesson_location', coalesce(a.cmi_data->>'lesson_location', ''),
      'suspend_data', coalesce(a.suspend_data, ''),
      'total_time_seconds', coalesce(a.total_time_seconds, 0),
      'mastery_score', p.mastery_score,
      'entry', case when a.id is null then 'ab-initio' else 'resume' end)
    into v_state
    from public.enrollments e
    join public.learners l on l.id = e.learner_id
    left join public.scorm_attempts a
      on a.enrollment_id = e.id and a.scorm_package_id = p.id and a.attempt_number = 1
    where e.id = p_enrollment;
  end if;
  -- 244 bits aléatoires ; seul le condensat est conservé.
  v_token := replace(gen_random_uuid()::text || gen_random_uuid()::text, '-', '');
  delete from app_private.scorm_tickets where expires_at < now();
  insert into app_private.scorm_tickets (token_hash, package_id, user_id, enrollment_id, expires_at)
  values (app_private.token_hash(v_token), p.id, (select auth.uid()), p_enrollment, now() + interval '4 hours');
  return jsonb_build_object('token', v_token, 'package_id', p.id, 'launch_path', p.launch_path, 'state', v_state);
end $$;

-- Appelée par le lecteur seul (clé secrète) : dossier de stockage ouvert par un ticket valide.
create function public.scorm_resolve_ticket(p_token text)
returns text language sql stable security definer set search_path = '' as $$
  select p.storage_path
  from app_private.scorm_tickets t
  join public.scorm_packages p on p.id = t.package_id
  where t.token_hash = app_private.token_hash(p_token) and t.expires_at > now() and p.status = 'ready';
$$;

-- 5. Résultats -------------------------------------------------------------------------------------
create function public.scorm_save(p_enrollment uuid, p_package uuid, p_session uuid, p_data jsonb)
returns jsonb language plpgsql security definer set search_path = '' as $$
declare
  p public.scorm_packages; a public.scorm_attempts; r public.course_resources;
  v_status text; v_score numeric; v_done boolean; v_was_done boolean;
  v_seconds integer; v_previous integer := 0;
begin
  select * into p from public.scorm_packages where id = p_package and status = 'ready';
  if p.id is null or not app_private.scorm_learner_access(p_enrollment, p.resource_id) then
    raise exception 'Enregistrement non autorisé pour ce module' using errcode = '42501';
  end if;
  if p_data is null or jsonb_typeof(p_data) <> 'object' or p_session is null then
    raise exception 'Résultat illisible';
  end if;
  if p_data ? 'lesson_status' and coalesce(p_data->>'lesson_status', '') not in
       ('passed','completed','failed','incomplete','browsed','not attempted') then
    raise exception 'Statut SCORM inconnu';
  end if;
  if p_data->>'score_raw' is not null then
    if p_data->>'score_raw' !~ '^[0-9]{1,3}(\.[0-9]+)?$' then raise exception 'Score invalide'; end if;
    if (p_data->>'score_raw')::numeric > 100 then raise exception 'Score invalide'; end if;
  end if;
  if length(p_data->>'suspend_data') > 64000 or length(p_data->>'lesson_location') > 1000 then
    raise exception 'Données de reprise trop longues';
  end if;
  if p_data->>'session_seconds' is not null then
    if p_data->>'session_seconds' !~ '^[0-9]+$' then raise exception 'Durée invalide'; end if;
    -- Un onglet resté ouvert ne bloque pas l'enregistrement : la séance compte au plus 24 h.
    v_seconds := least((p_data->>'session_seconds')::numeric, 86400)::integer;
  end if;

  insert into public.scorm_attempts (scorm_package_id, enrollment_id, attempt_number, status, lesson_status, started_at)
  values (p.id, p_enrollment, 1, 'in_progress', 'incomplete', now())
  on conflict (scorm_package_id, enrollment_id, attempt_number) do nothing;
  select * into a from public.scorm_attempts
  where scorm_package_id = p.id and enrollment_id = p_enrollment and attempt_number = 1 for update;

  v_was_done := a.completed_at is not null;
  v_status := coalesce(p_data->>'lesson_status', a.lesson_status);
  v_score := coalesce((p_data->>'score_raw')::numeric, a.score);
  -- Avec un score minimal, c'est le score qui décide.
  if p.mastery_score is not null and v_score is not null and v_status in ('passed','completed','failed') then
    v_status := case when v_score >= p.mastery_score then 'passed' else 'failed' end;
  end if;
  v_done := v_was_done or v_status in ('passed','completed');
  if v_was_done then v_status := a.lesson_status; v_score := a.score; end if;
  if v_seconds is not null then
    v_previous := coalesce((a.cmi_data->'sessions'->>p_session::text)::integer, 0);
  end if;

  update public.scorm_attempts set
    lesson_status = v_status,
    score = v_score,
    suspend_data = case when p_data ? 'suspend_data' then p_data->>'suspend_data' else suspend_data end,
    status = case when v_done then 'completed' else 'in_progress' end,
    progress = case when v_done then 100 else 0 end,
    total_time_seconds = total_time_seconds + greatest(coalesce(v_seconds, 0) - v_previous, 0),
    cmi_data = cmi_data
      || case when p_data ? 'lesson_location'
              then jsonb_build_object('lesson_location', p_data->>'lesson_location') else '{}'::jsonb end
      || case when v_seconds is not null
              then jsonb_build_object('sessions', coalesce(cmi_data->'sessions', '{}'::jsonb)
                     || jsonb_build_object(p_session::text, greatest(v_seconds, v_previous)))
              else '{}'::jsonb end,
    completed_at = case when v_done then coalesce(completed_at, now()) end,
    updated_at = now()
  where id = a.id;

  select * into r from public.course_resources where id = p.resource_id;
  if not exists (select 1 from public.learning_activity_log l
                 where l.enrollment_id = p_enrollment and l.resource_id = r.id) then
    insert into public.learning_activity_log (enrollment_id, resource_id, module_id, activity_type, started_at, progress)
    values (p_enrollment, r.id, r.module_id, 'resource_opened', now(), 0);
  end if;
  -- La règle d'achèvement existante s'applique à partir de cette trace.
  if v_done and not exists (select 1 from public.learning_activity_log l
        where l.enrollment_id = p_enrollment and l.resource_id = r.id and l.activity_type = 'resource_completed') then
    insert into public.learning_activity_log (enrollment_id, resource_id, module_id, activity_type, ended_at, progress)
    values (p_enrollment, r.id, r.module_id, 'resource_completed', now(), 100);
  end if;
  return jsonb_build_object('lesson_status', v_status, 'completed', v_done);
end $$;

-- 6. Le stagiaire ne peut pas déclarer lui-même un SCORM terminé -----------------------------------
create function app_private.is_scorm_resource(p_resource uuid)
returns boolean language sql stable security definer set search_path = '' as $$
  select exists (select 1 from public.course_resources r where r.id = p_resource and r.resource_type = 'scorm');
$$;

create policy learning_activity_log_scorm_guard on public.learning_activity_log
as restrictive for insert to authenticated with check (
  resource_id is null
  or not app_private.is_scorm_resource(resource_id)
  or (activity_type = 'resource_opened' and coalesce(progress, 0) = 0));

-- 7. Un SCORM qui a une tentative n'est jamais supprimé --------------------------------------------
create function app_private.has_scorm_attempt(p_resources uuid[])
returns boolean language sql stable security definer set search_path = '' as $$
  select exists (select 1 from public.scorm_packages p
    join public.scorm_attempts a on a.scorm_package_id = p.id
    where p.resource_id = any (p_resources));
$$;

create or replace function public.remove_course_item(p_kind text, p_id uuid)
returns text language plpgsql security definer set search_path = '' as $$
declare v_course uuid; v_retired timestamptz; v_used boolean;
begin
  if p_kind = 'resource' then
    select course_id, retired_at into v_course, v_retired from public.course_resources where id = p_id for update;
  elsif p_kind = 'module' then
    select course_id, retired_at into v_course, v_retired from public.course_modules where id = p_id for update;
  else
    raise exception 'Type d''élément inconnu';
  end if;
  if v_course is null or not app_private.can_manage_course_content(v_course) then
    raise exception 'Élément introuvable ou action non autorisée' using errcode = '42501';
  end if;
  if v_retired is not null then raise exception 'Cet élément est déjà retiré'; end if;

  if p_kind = 'resource' then
    select exists (select 1 from public.learning_activity_log a where a.resource_id = p_id)
        or app_private.has_scorm_attempt(array[p_id]) into v_used;
    if v_used then
      update public.course_resources set retired_at = now() where id = p_id;
    else
      delete from public.course_resources where id = p_id;
    end if;
  else
    select exists (
      select 1 from public.learning_activity_log a
      where a.module_id = p_id
         or a.resource_id in (select r.id from public.course_resources r where r.module_id = p_id))
      or app_private.has_scorm_attempt(array(select r.id from public.course_resources r where r.module_id = p_id))
      into v_used;
    if v_used then
      update public.course_resources set retired_at = now() where module_id = p_id and retired_at is null;
      update public.course_modules set retired_at = now() where id = p_id;
    else
      delete from public.course_resources where module_id = p_id;
      delete from public.course_modules where id = p_id;
    end if;
  end if;
  return case when v_used then 'retired' else 'deleted' end;
end $$;

-- 8. Exécution -------------------------------------------------------------------------------------
revoke all on function
  app_private.can_import_scorm(uuid), app_private.scorm_package_of(text), app_private.token_hash(text),
  app_private.scorm_learner_access(uuid, uuid), app_private.is_scorm_resource(uuid),
  app_private.has_scorm_attempt(uuid[])
from public, anon, authenticated;
grant execute on function
  app_private.can_import_scorm(uuid), app_private.scorm_package_of(text), app_private.is_scorm_resource(uuid)
to authenticated;

revoke all on function
  public.scorm_register_package(uuid, uuid, text, text, numeric, integer, bigint),
  public.scorm_finalize_package(uuid), public.scorm_discard_package(uuid),
  public.scorm_open(uuid, uuid), public.scorm_resolve_ticket(text),
  public.scorm_save(uuid, uuid, uuid, jsonb)
from public, anon, authenticated;
grant execute on function
  public.scorm_register_package(uuid, uuid, text, text, numeric, integer, bigint),
  public.scorm_finalize_package(uuid), public.scorm_discard_package(uuid),
  public.scorm_open(uuid, uuid), public.scorm_save(uuid, uuid, uuid, jsonb)
to authenticated;
grant execute on function public.scorm_resolve_ticket(text) to service_role;
