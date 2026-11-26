
create extension if not exists pgcrypto;
create type organization_kind as enum ('ifap','collectivite','organisme');
create type member_role as enum ('platform_admin','org_admin','trainer','learner');
create type course_status as enum ('draft','published','archived');
create type deployment_status as enum ('available','closed','archived');
create type session_mode as enum ('presentiel','visio','hybride');

create schema if not exists app_private;

create table organizations(
 id uuid primary key default gen_random_uuid(),
 name text not null,
 kind organization_kind not null,
 created_at timestamptz not null default now()
);
create table organization_members(
 id uuid primary key default gen_random_uuid(),
 organization_id uuid not null references organizations(id) on delete cascade,
 user_id uuid not null,
 role member_role not null,
 unique(organization_id,user_id)
);
create table courses(
 id uuid primary key default gen_random_uuid(),
 owner_organization_id uuid not null references organizations(id) on delete cascade,
 title text not null,
 description text,
 visibility text not null default 'private' check(visibility in ('private','ifap_catalog')),
 status course_status not null default 'draft',
 created_at timestamptz not null default now(),
 updated_at timestamptz not null default now()
);
create table course_modules(
 id uuid primary key default gen_random_uuid(),
 course_id uuid not null references courses(id) on delete cascade,
 title text not null,
 position int not null,
 content_type text not null,
 content_ref text,
 estimated_minutes int not null default 0
);
create table deployments(
 id uuid primary key default gen_random_uuid(),
 course_id uuid not null references courses(id) on delete cascade,
 target_organization_id uuid not null references organizations(id) on delete cascade,
 status deployment_status not null default 'available',
 published_at timestamptz not null default now(),
 unique(course_id,target_organization_id)
);
create table learners(
 id uuid primary key default gen_random_uuid(),
 organization_id uuid not null references organizations(id) on delete cascade,
 user_id uuid,
 first_name text not null,
 last_name text not null,
 email text,
 created_at timestamptz not null default now()
);
create table enrollments(
 id uuid primary key default gen_random_uuid(),
 deployment_id uuid not null references deployments(id) on delete cascade,
 learner_id uuid not null references learners(id) on delete cascade,
 status text not null default 'enrolled',
 progress numeric(5,2) not null default 0 check(progress between 0 and 100),
 started_at timestamptz,
 completed_at timestamptz,
 unique(deployment_id,learner_id)
);
create table sessions(
 id uuid primary key default gen_random_uuid(),
 deployment_id uuid not null references deployments(id) on delete cascade,
 title text not null,
 start_at timestamptz,
 end_at timestamptz,
 mode session_mode,
 location text,
 capacity int
);
create table evaluations(
 id uuid primary key default gen_random_uuid(),
 course_id uuid not null references courses(id) on delete cascade,
 title text not null,
 pass_score numeric(5,2)
);
create table evaluation_attempts(
 id uuid primary key default gen_random_uuid(),
 evaluation_id uuid not null references evaluations(id) on delete cascade,
 learner_id uuid not null references learners(id) on delete cascade,
 score numeric(5,2),
 passed boolean,
 attempted_at timestamptz not null default now()
);
create table attendance(
 id uuid primary key default gen_random_uuid(),
 session_id uuid not null references sessions(id) on delete cascade,
 learner_id uuid not null references learners(id) on delete cascade,
 present boolean not null default false,
 checked_at timestamptz,
 unique(session_id,learner_id)
);
create table attestations(
 id uuid primary key default gen_random_uuid(),
 enrollment_id uuid not null references enrollments(id) on delete cascade,
 issued_at timestamptz not null default now(),
 pdf_path text,
 verification_token uuid not null default gen_random_uuid() unique
);
create table audit_logs(
 id uuid primary key default gen_random_uuid(),
 organization_id uuid references organizations(id) on delete cascade,
 actor_user_id uuid,
 action text not null,
 entity_type text,
 entity_id uuid,
 metadata jsonb,
 created_at timestamptz not null default now()
);
create table event_outbox(
 id uuid primary key default gen_random_uuid(),
 event_type text not null,
 aggregate_type text not null,
 aggregate_id uuid,
 payload jsonb not null,
 created_at timestamptz not null default now(),
 published_at timestamptz,
 attempts int not null default 0
);

create index courses_owner_idx on courses(owner_organization_id);
create index deployments_target_idx on deployments(target_organization_id);
create index learners_org_idx on learners(organization_id);
create index enrollments_learner_idx on enrollments(learner_id);
create index event_outbox_unpublished_idx on event_outbox(published_at) where published_at is null;

create or replace function app_private.is_org_member(p_org uuid, p_roles member_role[] default null)
returns boolean
language plpgsql
security definer
set search_path = public, app_private
as $$
begin
  if (select auth.uid()) is null then return false; end if;
  return exists (
    select 1 from public.organization_members om
    where om.organization_id = p_org
      and om.user_id = (select auth.uid())
      and (p_roles is null or om.role = any(p_roles))
  );
end;
$$;
revoke all on function app_private.is_org_member(uuid, member_role[]) from public;
grant execute on function app_private.is_org_member(uuid, member_role[]) to authenticated;

create or replace function app_private.is_platform_admin()
returns boolean
language plpgsql
security definer
set search_path = public, app_private
as $$
begin
  if (select auth.uid()) is null then return false; end if;
  return exists (
    select 1 from public.organization_members om
    where om.user_id = (select auth.uid())
      and om.role = 'platform_admin'
  );
end;
$$;
revoke all on function app_private.is_platform_admin() from public;
grant execute on function app_private.is_platform_admin() to authenticated;

alter table organizations enable row level security;
alter table organization_members enable row level security;
alter table courses enable row level security;
alter table course_modules enable row level security;
alter table deployments enable row level security;
alter table learners enable row level security;
alter table enrollments enable row level security;
alter table sessions enable row level security;
alter table evaluations enable row level security;
alter table evaluation_attempts enable row level security;
alter table attendance enable row level security;
alter table attestations enable row level security;
alter table audit_logs enable row level security;
alter table event_outbox enable row level security;

create policy organizations_select on organizations for select to authenticated
using (app_private.is_platform_admin() or app_private.is_org_member(id));
create policy organizations_insert on organizations for insert to authenticated
with check (app_private.is_platform_admin());
create policy organizations_update on organizations for update to authenticated
using (app_private.is_platform_admin()) with check (app_private.is_platform_admin());

create policy members_select on organization_members for select to authenticated
using (app_private.is_platform_admin() or app_private.is_org_member(organization_id));
create policy members_manage on organization_members for all to authenticated
using (app_private.is_platform_admin() or app_private.is_org_member(organization_id, array['org_admin','platform_admin']::member_role[]))
with check (app_private.is_platform_admin() or app_private.is_org_member(organization_id, array['org_admin','platform_admin']::member_role[]));

create policy courses_select on courses for select to authenticated
using (
  app_private.is_platform_admin()
  or app_private.is_org_member(owner_organization_id)
  or (visibility='ifap_catalog' and status='published')
);
create policy courses_insert on courses for insert to authenticated
with check (
  app_private.is_platform_admin()
  or app_private.is_org_member(owner_organization_id, array['org_admin','trainer','platform_admin']::member_role[])
);
create policy courses_update on courses for update to authenticated
using (app_private.is_platform_admin() or app_private.is_org_member(owner_organization_id, array['org_admin','trainer','platform_admin']::member_role[]))
with check (app_private.is_platform_admin() or app_private.is_org_member(owner_organization_id, array['org_admin','trainer','platform_admin']::member_role[]));

create policy modules_select on course_modules for select to authenticated
using (exists(select 1 from courses c where c.id=course_id));
create policy modules_manage on course_modules for all to authenticated
using (exists(select 1 from courses c where c.id=course_id and (app_private.is_platform_admin() or app_private.is_org_member(c.owner_organization_id, array['org_admin','trainer','platform_admin']::member_role[]))))
with check (exists(select 1 from courses c where c.id=course_id and (app_private.is_platform_admin() or app_private.is_org_member(c.owner_organization_id, array['org_admin','trainer','platform_admin']::member_role[]))));

create policy deployments_select on deployments for select to authenticated
using (
  app_private.is_platform_admin()
  or app_private.is_org_member(target_organization_id)
  or exists(select 1 from courses c where c.id=course_id and app_private.is_org_member(c.owner_organization_id))
);
create policy deployments_manage on deployments for all to authenticated
using (
  app_private.is_platform_admin()
  or app_private.is_org_member(target_organization_id, array['org_admin','platform_admin']::member_role[])
  or exists(select 1 from courses c where c.id=course_id and app_private.is_org_member(c.owner_organization_id, array['org_admin','trainer','platform_admin']::member_role[]))
)
with check (
  app_private.is_platform_admin()
  or app_private.is_org_member(target_organization_id, array['org_admin','platform_admin']::member_role[])
  or exists(select 1 from courses c where c.id=course_id and app_private.is_org_member(c.owner_organization_id, array['org_admin','trainer','platform_admin']::member_role[]))
);

create policy learners_select on learners for select to authenticated
using (app_private.is_platform_admin() or app_private.is_org_member(organization_id));
create policy learners_manage on learners for all to authenticated
using (app_private.is_platform_admin() or app_private.is_org_member(organization_id, array['org_admin','trainer','platform_admin']::member_role[]))
with check (app_private.is_platform_admin() or app_private.is_org_member(organization_id, array['org_admin','trainer','platform_admin']::member_role[]));

create policy enrollments_select on enrollments for select to authenticated
using (
  app_private.is_platform_admin()
  or exists(select 1 from learners l where l.id=learner_id and (l.user_id=(select auth.uid()) or app_private.is_org_member(l.organization_id)))
);
create policy enrollments_manage on enrollments for all to authenticated
using (
  app_private.is_platform_admin()
  or exists(
    select 1 from learners l join deployments d on d.target_organization_id=l.organization_id
    where l.id=learner_id and d.id=deployment_id
      and app_private.is_org_member(l.organization_id, array['org_admin','trainer','platform_admin']::member_role[])
  )
)
with check (
  app_private.is_platform_admin()
  or exists(
    select 1 from learners l join deployments d on d.target_organization_id=l.organization_id
    where l.id=learner_id and d.id=deployment_id
      and app_private.is_org_member(l.organization_id, array['org_admin','trainer','platform_admin']::member_role[])
  )
);

create policy sessions_select on sessions for select to authenticated
using (exists(select 1 from deployments d where d.id=deployment_id));
create policy sessions_manage on sessions for all to authenticated
using (exists(select 1 from deployments d where d.id=deployment_id and (app_private.is_platform_admin() or app_private.is_org_member(d.target_organization_id, array['org_admin','trainer','platform_admin']::member_role[]))))
with check (exists(select 1 from deployments d where d.id=deployment_id and (app_private.is_platform_admin() or app_private.is_org_member(d.target_organization_id, array['org_admin','trainer','platform_admin']::member_role[]))));

create policy evaluations_select on evaluations for select to authenticated
using (exists(select 1 from courses c where c.id=course_id));
create policy evaluations_manage on evaluations for all to authenticated
using (exists(select 1 from courses c where c.id=course_id and (app_private.is_platform_admin() or app_private.is_org_member(c.owner_organization_id, array['org_admin','trainer','platform_admin']::member_role[]))))
with check (exists(select 1 from courses c where c.id=course_id and (app_private.is_platform_admin() or app_private.is_org_member(c.owner_organization_id, array['org_admin','trainer','platform_admin']::member_role[]))));

create policy attempts_select on evaluation_attempts for select to authenticated
using (exists(select 1 from learners l where l.id=learner_id and (l.user_id=(select auth.uid()) or app_private.is_org_member(l.organization_id))));
create policy attempts_manage on evaluation_attempts for all to authenticated
using (exists(select 1 from learners l where l.id=learner_id and (l.user_id=(select auth.uid()) or app_private.is_org_member(l.organization_id, array['org_admin','trainer','platform_admin']::member_role[]))))
with check (exists(select 1 from learners l where l.id=learner_id and (l.user_id=(select auth.uid()) or app_private.is_org_member(l.organization_id, array['org_admin','trainer','platform_admin']::member_role[]))));

create policy attendance_select on attendance for select to authenticated
using (exists(select 1 from learners l where l.id=learner_id and (l.user_id=(select auth.uid()) or app_private.is_org_member(l.organization_id))));
create policy attendance_manage on attendance for all to authenticated
using (exists(select 1 from sessions s join deployments d on d.id=session_id join learners l on l.id=learner_id where s.id=session_id and l.organization_id=d.target_organization_id and app_private.is_org_member(d.target_organization_id, array['org_admin','trainer','platform_admin']::member_role[])))
with check (exists(select 1 from sessions s join deployments d on d.id=session_id join learners l on l.id=learner_id where s.id=session_id and l.organization_id=d.target_organization_id and app_private.is_org_member(d.target_organization_id, array['org_admin','trainer','platform_admin']::member_role[])));

create policy attestations_select on attestations for select to authenticated
using (exists(select 1 from enrollments e join learners l on l.id=e.learner_id where e.id=enrollment_id and (l.user_id=(select auth.uid()) or app_private.is_org_member(l.organization_id))));
create policy attestations_insert on attestations for insert to authenticated
with check (exists(select 1 from enrollments e join learners l on l.id=e.learner_id where e.id=enrollment_id and app_private.is_org_member(l.organization_id, array['org_admin','trainer','platform_admin']::member_role[])));

create policy audit_select on audit_logs for select to authenticated
using (app_private.is_platform_admin() or (organization_id is not null and app_private.is_org_member(organization_id)));
create policy audit_insert on audit_logs for insert to authenticated
with check (app_private.is_platform_admin() or (organization_id is not null and app_private.is_org_member(organization_id)));

create policy outbox_select on event_outbox for select to authenticated
using (app_private.is_platform_admin());
