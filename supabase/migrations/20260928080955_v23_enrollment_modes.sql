create type public.enrollment_mode as enum ('prescribed','self_service','link','employer','manager');

alter table public.deployments
  add column if not exists enrollment_mode public.enrollment_mode not null default 'manager',
  add column if not exists enrollment_requires_approval boolean not null default false;

alter table public.enrollments
  add column if not exists enrollment_mode public.enrollment_mode not null default 'manager',
  add column if not exists prescribed_by uuid,
  add column if not exists prescribed_at timestamptz not null default now(),
  add column if not exists enrollment_source text;

create table if not exists public.enrollment_links (
  id uuid primary key default gen_random_uuid(),
  deployment_id uuid not null references public.deployments(id) on delete cascade,
  token uuid not null default gen_random_uuid(),
  label text,
  expires_at timestamptz,
  max_uses integer,
  uses_count integer not null default 0,
  is_active boolean not null default true,
  created_at timestamptz not null default now(),
  created_by uuid,
  constraint enrollment_links_max_uses_check check (max_uses is null or max_uses > 0),
  constraint enrollment_links_uses_check check (uses_count >= 0 and (max_uses is null or uses_count <= max_uses))
);

create unique index if not exists enrollment_links_token_uidx on public.enrollment_links(token);
create index if not exists enrollment_links_deployment_idx on public.enrollment_links(deployment_id);

alter table public.enrollment_links enable row level security;

create policy enrollment_links_select on public.enrollment_links
for select to authenticated
using (
  app_private.is_platform_admin()
  or exists (
    select 1 from public.deployments d
    where d.id=enrollment_links.deployment_id
      and app_private.is_org_member(d.target_organization_id, array['org_admin'::member_role,'trainer'::member_role,'platform_admin'::member_role])
  )
);

create policy enrollment_links_manage on public.enrollment_links
for all to authenticated
using (
  app_private.is_platform_admin()
  or exists (
    select 1 from public.deployments d
    where d.id=enrollment_links.deployment_id
      and app_private.is_org_member(d.target_organization_id, array['org_admin'::member_role,'trainer'::member_role,'platform_admin'::member_role])
  )
)
with check (
  app_private.is_platform_admin()
  or exists (
    select 1 from public.deployments d
    where d.id=enrollment_links.deployment_id
      and app_private.is_org_member(d.target_organization_id, array['org_admin'::member_role,'trainer'::member_role,'platform_admin'::member_role])
  )
);