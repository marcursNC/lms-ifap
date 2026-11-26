-- Déploiement d'une formation vers une organisation.
-- Conception : docs/superpowers/specs/2026-11-27-deploiement-design.md
-- Retour arrière : supabase/rollback/20261127000000_deploiement_organisations.sql

-- 1. Organisation à l'origine du déploiement -------------------------------------------------
do $$ begin
  if exists (select 1 from public.deployments) then
    raise exception 'La table deployments n''est pas vide : définir la reprise de initiated_by_organization_id avant application';
  end if;
end $$;

alter table public.deployments
  add column initiated_by_organization_id uuid not null
  references public.organizations(id) on delete cascade;

-- 2. Fonctions d'aide ------------------------------------------------------------------------
create function app_private.is_ifap_admin()
returns boolean language sql stable security definer set search_path = '' as $$
  select exists (
    select 1 from public.organization_members m
    join public.organizations o on o.id = m.organization_id
    where m.user_id = (select auth.uid())
      and m.role = 'org_admin'::public.member_role
      and o.kind = 'ifap'::public.organization_kind
  );
$$;

-- Qui peut créer un déploiement.
create function app_private.can_create_deployment(p_course uuid, p_target uuid)
returns boolean language sql stable security definer set search_path = '' as $$
  select app_private.is_platform_admin() or exists (
    select 1 from public.courses c
    join public.organizations o on o.id = c.owner_organization_id
    where c.id = p_course
      and c.status = 'published'::public.course_status
      and (
        (o.kind = 'ifap'::public.organization_kind
          and app_private.is_org_member(c.owner_organization_id, array['org_admin']::public.member_role[]))
        or
        (app_private.is_org_member(p_target, array['org_admin']::public.member_role[])
          and (c.owner_organization_id = p_target
               or (c.visibility = 'ifap_catalog' and o.kind = 'ifap'::public.organization_kind)))
      )
  );
$$;

-- Lecture d'une formation grâce à un déploiement ouvert ou clos vers mon organisation.
-- security definer : lit deployments sans repasser par les politiques (évite la récursion).
create function app_private.can_view_deployed_course(p_course uuid)
returns boolean language sql stable security definer set search_path = '' as $$
  select exists (
    select 1 from public.deployments d
    where d.course_id = p_course
      and d.status in ('available'::public.deployment_status, 'closed'::public.deployment_status)
      and (
        app_private.is_org_member(d.target_organization_id, array['org_admin','trainer']::public.member_role[])
        or exists (
          select 1 from public.enrollments e
          join public.learners l on l.id = e.learner_id
          where e.deployment_id = d.id
            and l.organization_id = d.target_organization_id
            and l.user_id = (select auth.uid())
            and l.is_active
            and e.status not in ('pending', 'cancelled')
        )
      )
  );
$$;

revoke all on function
  app_private.is_ifap_admin(),
  app_private.can_create_deployment(uuid, uuid),
  app_private.can_view_deployed_course(uuid)
from public;
grant execute on function
  app_private.is_ifap_admin(),
  app_private.can_create_deployment(uuid, uuid),
  app_private.can_view_deployed_course(uuid)
to authenticated;

-- 3. Politiques des déploiements : aucune politique de suppression -----------------------------
drop policy deployments_manage on public.deployments;

create policy deployments_insert on public.deployments for insert to authenticated
with check (app_private.can_create_deployment(course_id, target_organization_id));

create policy deployments_update on public.deployments for update to authenticated
using (
  app_private.is_platform_admin()
  or app_private.is_org_member(initiated_by_organization_id, array['org_admin']::public.member_role[])
)
with check (
  app_private.is_platform_admin()
  or app_private.is_org_member(initiated_by_organization_id, array['org_admin']::public.member_role[])
);

-- 4. Règles appliquées à chaque écriture ------------------------------------------------------
create or replace function app_private.enforce_deployment_course_rules()
returns trigger language plpgsql security definer set search_path = '' as $$
declare
  c_owner uuid; c_status public.course_status; c_visibility text; c_kind public.organization_kind;
  opening boolean; external_private boolean;
begin
  if tg_op = 'UPDATE' and (
       new.course_id is distinct from old.course_id
    or new.target_organization_id is distinct from old.target_organization_id
    or new.initiated_by_organization_id is distinct from old.initiated_by_organization_id) then
    raise exception 'La formation, l''organisation destinataire et l''origine d''un déploiement ne se modifient pas';
  end if;

  select c.owner_organization_id, c.status, c.visibility, o.kind
    into c_owner, c_status, c_visibility, c_kind
  from public.courses c join public.organizations o on o.id = c.owner_organization_id
  where c.id = new.course_id;
  if c_owner is null then
    raise exception 'Formation introuvable';
  end if;

  if tg_op = 'INSERT' then
    -- Jamais fournie par le navigateur.
    new.initiated_by_organization_id := case
      when app_private.is_org_member(c_owner, array['org_admin']::public.member_role[]) then c_owner
      else new.target_organization_id end;
  end if;

  opening := tg_op = 'INSERT';
  if tg_op = 'UPDATE' then
    opening := new.status = 'available'::public.deployment_status and old.status <> new.status;
  end if;
  external_private := new.target_organization_id <> c_owner and c_visibility <> 'ifap_catalog';

  if opening then
    if c_status <> 'published'::public.course_status then
      raise exception 'Seule une formation publiée peut être déployée';
    end if;
    if new.target_organization_id <> c_owner and c_kind <> 'ifap'::public.organization_kind then
      raise exception 'Seul l''IFAP déploie une formation hors de son organisation';
    end if;
    if external_private
       and new.initiated_by_organization_id <> c_owner
       and not app_private.is_platform_admin() then
      raise exception 'Cette formation n''est plus au catalogue IFAP';
    end if;
  end if;

  if external_private and new.enrollment_mode = 'self_service'::public.enrollment_mode then
    if opening then
      raise exception 'L''auto-inscription est impossible pour une formation privée envoyée à une autre organisation';
    elsif new.enrollment_mode is distinct from old.enrollment_mode then
      raise exception 'L''auto-inscription est impossible pour une formation privée envoyée à une autre organisation';
    end if;
  end if;

  return new;
end $$;

drop trigger deployments_enforce_course_rules on public.deployments;
create trigger deployments_enforce_course_rules
  before insert or update on public.deployments
  for each row execute function app_private.enforce_deployment_course_rules();

-- 5. Lecture des formations --------------------------------------------------------------------
alter policy courses_select on public.courses using (
  app_private.is_platform_admin()
  or app_private.is_org_member(owner_organization_id)
  or (visibility = 'ifap_catalog' and status = 'published'::public.course_status)
  or (status <> 'draft'::public.course_status and app_private.can_view_deployed_course(id))
);

-- 6. Inscriptions ------------------------------------------------------------------------------
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
    where e.deployment_id = new.deployment_id and e.status in ('enrolled', 'started');
    if current_count >= cap then
      raise exception 'La capacité du déploiement est atteinte';
    end if;
  end if;
  return new;
end $$;

drop trigger enrollments_enforce_rules on public.enrollments;
create trigger enrollments_enforce_rules
  before insert or update of deployment_id, learner_id on public.enrollments
  for each row execute function app_private.enforce_enrollment_rules();

-- 7. Liste des clients, réservée à l'IFAP ------------------------------------------------------
create function public.list_deployable_organizations()
returns table (id uuid, name text, kind public.organization_kind)
language sql stable security definer set search_path = '' as $$
  select o.id, o.name, o.kind
  from public.organizations o
  where o.kind in ('collectivite'::public.organization_kind, 'organisme'::public.organization_kind)
    and (app_private.is_platform_admin() or app_private.is_ifap_admin())
  order by o.name;
$$;
revoke all on function public.list_deployable_organizations() from public, anon;
grant execute on function public.list_deployable_organizations() to authenticated;

-- 8. Événements : écriture dans event_outbox par les déclencheurs ------------------------------
create or replace function app_private.create_deployment_event()
returns trigger language plpgsql security definer set search_path = '' as $$
begin
  insert into public.event_outbox(event_type, aggregate_type, aggregate_id, payload)
  values (
    case when tg_op = 'INSERT' then 'deployment.created' else 'deployment.updated' end,
    'deployment', new.id,
    pg_catalog.jsonb_build_object('deployment_id', new.id, 'course_id', new.course_id,
      'target_organization_id', new.target_organization_id, 'status', new.status)
  );
  return new;
end $$;

create or replace function app_private.create_enrollment_event()
returns trigger language plpgsql security definer set search_path = '' as $$
begin
  insert into public.event_outbox(event_type, aggregate_type, aggregate_id, payload)
  values ('enrollment.created', 'enrollment', new.id,
    pg_catalog.jsonb_build_object('enrollment_id', new.id, 'deployment_id', new.deployment_id, 'learner_id', new.learner_id));
  return new;
end $$;

create or replace function app_private.create_attestation_event()
returns trigger language plpgsql security definer set search_path = '' as $$
begin
  insert into public.event_outbox(event_type, aggregate_type, aggregate_id, payload)
  values ('certificate.issued', 'attestation', new.id,
    pg_catalog.jsonb_build_object('attestation_id', new.id, 'enrollment_id', new.enrollment_id,
      'certificate_number', new.certificate_number, 'verification_token', new.verification_token));
  return new;
end $$;

revoke all on function
  app_private.enforce_deployment_course_rules(),
  app_private.enforce_enrollment_rules(),
  app_private.create_deployment_event(),
  app_private.create_enrollment_event(),
  app_private.create_attestation_event()
from public;

drop trigger enrollments_event_outbox on public.enrollments;
