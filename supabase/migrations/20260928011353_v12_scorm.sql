alter table public.course_resources
  add column if not exists package_version text,
  add column if not exists launch_path text,
  add column if not exists manifest_path text,
  add column if not exists metadata jsonb not null default '{}'::jsonb;

create table if not exists public.scorm_packages (
  id uuid primary key default gen_random_uuid(),
  course_id uuid not null references public.courses(id) on delete cascade,
  resource_id uuid references public.course_resources(id) on delete set null,
  version text not null default '1.2',
  title text not null,
  storage_path text not null,
  launch_path text not null,
  manifest_path text,
  entry_point text,
  package_hash text,
  created_at timestamptz not null default now(),
  updated_at timestamptz not null default now()
);
alter table public.scorm_packages enable row level security;

create table if not exists public.scorm_attempts (
  id uuid primary key default gen_random_uuid(),
  scorm_package_id uuid not null references public.scorm_packages(id) on delete cascade,
  enrollment_id uuid not null references public.enrollments(id) on delete cascade,
  attempt_number integer not null default 1,
  status text not null default 'not_started',
  progress numeric not null default 0,
  score numeric,
  lesson_status text,
  total_time_seconds integer not null default 0,
  suspend_data text,
  cmi_data jsonb not null default '{}'::jsonb,
  started_at timestamptz,
  completed_at timestamptz,
  updated_at timestamptz not null default now(),
  unique(scorm_package_id,enrollment_id,attempt_number),
  check(progress between 0 and 100),
  check(score is null or score between 0 and 100),
  check(total_time_seconds >= 0)
);
alter table public.scorm_attempts enable row level security;

drop policy if exists scorm_packages_select on public.scorm_packages;
create policy scorm_packages_select on public.scorm_packages for select to authenticated
using (exists(select 1 from public.courses c where c.id=course_id));

drop policy if exists scorm_packages_manage on public.scorm_packages;
create policy scorm_packages_manage on public.scorm_packages for all to authenticated
using (exists(select 1 from public.courses c where c.id=course_id and (app_private.is_platform_admin() or app_private.is_org_member(c.owner_organization_id,array['org_admin'::member_role,'trainer'::member_role,'platform_admin'::member_role]))))
with check (exists(select 1 from public.courses c where c.id=course_id and (app_private.is_platform_admin() or app_private.is_org_member(c.owner_organization_id,array['org_admin'::member_role,'trainer'::member_role,'platform_admin'::member_role]))));

drop policy if exists scorm_attempts_select on public.scorm_attempts;
create policy scorm_attempts_select on public.scorm_attempts for select to authenticated
using (exists(select 1 from public.enrollments e join public.learners l on l.id=e.learner_id join public.scorm_packages p on p.id=scorm_package_id where e.id=enrollment_id and (l.user_id=(select auth.uid()) or app_private.is_platform_admin() or app_private.is_org_member(l.organization_id))));

drop policy if exists scorm_attempts_insert on public.scorm_attempts;
create policy scorm_attempts_insert on public.scorm_attempts for insert to authenticated
with check (exists(select 1 from public.enrollments e join public.learners l on l.id=e.learner_id join public.deployments d on d.id=e.deployment_id join public.scorm_packages p on p.id=scorm_package_id where e.id=enrollment_id and p.course_id=(select course_id from public.deployments where id=e.deployment_id) and (l.user_id=(select auth.uid()) or app_private.is_platform_admin() or app_private.is_org_member(l.organization_id,array['org_admin'::member_role,'trainer'::member_role,'platform_admin'::member_role]))));

drop policy if exists scorm_attempts_update on public.scorm_attempts;
create policy scorm_attempts_update on public.scorm_attempts for update to authenticated
using (exists(select 1 from public.enrollments e join public.learners l on l.id=e.learner_id where e.id=enrollment_id and (l.user_id=(select auth.uid()) or app_private.is_platform_admin() or app_private.is_org_member(l.organization_id,array['org_admin'::member_role,'trainer'::member_role,'platform_admin'::member_role]))))
with check (exists(select 1 from public.enrollments e join public.learners l on l.id=e.learner_id where e.id=enrollment_id and (l.user_id=(select auth.uid()) or app_private.is_platform_admin() or app_private.is_org_member(l.organization_id,array['org_admin'::member_role,'trainer'::member_role,'platform_admin'::member_role]))));

create or replace function app_private.update_scorm_progress()
returns trigger language plpgsql set search_path=public,pg_catalog as $$
begin
  update public.enrollments
  set progress=greatest(progress,new.progress),
      started_at=coalesce(started_at,new.started_at),
      completed_at=case when new.status in ('completed','passed') or new.lesson_status in ('completed','passed') then coalesce(new.completed_at,now()) else completed_at end,
      status=case when new.status in ('completed','passed') or new.lesson_status in ('completed','passed') then 'completed' else status end
  where id=new.enrollment_id;
  return new;
end; $$;

drop trigger if exists scorm_attempt_progress on public.scorm_attempts;
create trigger scorm_attempt_progress after insert or update on public.scorm_attempts
for each row execute function app_private.update_scorm_progress();

create index if not exists scorm_packages_course_idx on public.scorm_packages(course_id);
create index if not exists scorm_attempts_enrollment_idx on public.scorm_attempts(enrollment_id);
create index if not exists scorm_attempts_package_idx on public.scorm_attempts(scorm_package_id);