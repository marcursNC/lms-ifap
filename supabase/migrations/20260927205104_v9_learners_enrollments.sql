alter table public.learners
  add column if not exists external_reference text,
  add column if not exists job_title text,
  add column if not exists department text,
  add column if not exists phone text,
  add column if not exists is_active boolean not null default true;

create unique index if not exists learners_org_external_ref_uidx
  on public.learners(organization_id, external_reference)
  where external_reference is not null;

create unique index if not exists enrollments_deployment_learner_uidx
  on public.enrollments(deployment_id, learner_id);

create table if not exists public.learner_groups (
  id uuid primary key default gen_random_uuid(),
  organization_id uuid not null references public.organizations(id) on delete cascade,
  name text not null,
  description text,
  created_at timestamptz not null default now(),
  unique (organization_id, name)
);
alter table public.learner_groups enable row level security;

create table if not exists public.learner_group_members (
  group_id uuid not null references public.learner_groups(id) on delete cascade,
  learner_id uuid not null references public.learners(id) on delete cascade,
  created_at timestamptz not null default now(),
  primary key (group_id, learner_id)
);
alter table public.learner_group_members enable row level security;

drop policy if exists learner_groups_select on public.learner_groups;
create policy learner_groups_select on public.learner_groups for select to authenticated
using (app_private.is_platform_admin() or app_private.is_org_member(organization_id));

drop policy if exists learner_groups_manage on public.learner_groups;
create policy learner_groups_manage on public.learner_groups for all to authenticated
using (app_private.is_platform_admin() or app_private.is_org_member(organization_id, array['org_admin'::member_role,'trainer'::member_role,'platform_admin'::member_role]))
with check (app_private.is_platform_admin() or app_private.is_org_member(organization_id, array['org_admin'::member_role,'trainer'::member_role,'platform_admin'::member_role]));

drop policy if exists learner_group_members_select on public.learner_group_members;
create policy learner_group_members_select on public.learner_group_members for select to authenticated
using (exists(select 1 from public.learner_groups g where g.id=group_id and (app_private.is_platform_admin() or app_private.is_org_member(g.organization_id))));

drop policy if exists learner_group_members_manage on public.learner_group_members;
create policy learner_group_members_manage on public.learner_group_members for all to authenticated
using (exists(select 1 from public.learner_groups g join public.learners l on l.id=learner_id where g.id=group_id and g.organization_id=l.organization_id and (app_private.is_platform_admin() or app_private.is_org_member(g.organization_id, array['org_admin'::member_role,'trainer'::member_role,'platform_admin'::member_role]))))
with check (exists(select 1 from public.learner_groups g join public.learners l on l.id=learner_id where g.id=group_id and g.organization_id=l.organization_id and (app_private.is_platform_admin() or app_private.is_org_member(g.organization_id, array['org_admin'::member_role,'trainer'::member_role,'platform_admin'::member_role]))));

create or replace function app_private.enforce_enrollment_rules()
returns trigger language plpgsql set search_path=public,pg_catalog as $$
declare target_org uuid; cap integer; current_count integer; deadline timestamptz;
begin
  select target_organization_id, capacity, enrollment_deadline into target_org, cap, deadline
  from public.deployments where id=new.deployment_id;
  if not exists(select 1 from public.learners where id=new.learner_id and organization_id=target_org and is_active) then
    raise exception 'Learner must belong to the deployment target organisation and be active';
  end if;
  if deadline is not null and now() > deadline and tg_op='INSERT' then
    raise exception 'Enrollment deadline has passed';
  end if;
  if tg_op='INSERT' and cap is not null then
    select count(*) into current_count from public.enrollments where deployment_id=new.deployment_id and status in ('enrolled','started');
    if current_count >= cap then raise exception 'Deployment capacity reached'; end if;
  end if;
  return new;
end; $$;

drop trigger if exists enrollments_enforce_rules on public.enrollments;
create trigger enrollments_enforce_rules before insert on public.enrollments
for each row execute function app_private.enforce_enrollment_rules();

create or replace function app_private.create_enrollment_event()
returns trigger language plpgsql set search_path=public,pg_catalog as $$
begin
  insert into public.event_outbox(event_type,aggregate_type,aggregate_id,payload)
  values ('enrollment.created','enrollment',new.id,jsonb_build_object('enrollment_id',new.id,'deployment_id',new.deployment_id,'learner_id',new.learner_id));
  return new;
end; $$;

drop trigger if exists enrollments_event_trigger on public.enrollments;
create trigger enrollments_event_trigger after insert on public.enrollments
for each row execute function app_private.create_enrollment_event();

create index if not exists learner_groups_org_idx on public.learner_groups(organization_id);
create index if not exists learner_group_members_learner_idx on public.learner_group_members(learner_id);