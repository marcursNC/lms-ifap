create type public.virtual_classroom_provider as enum ('microsoft_teams','zoom','webex','google_meet','other');

create table if not exists public.virtual_classroom_connections (
  id uuid primary key default gen_random_uuid(),
  organization_id uuid not null references public.organizations(id) on delete cascade,
  provider public.virtual_classroom_provider not null,
  external_tenant_id text,
  display_name text not null,
  is_active boolean not null default true,
  configuration jsonb not null default '{}',
  created_at timestamptz not null default now(),
  updated_at timestamptz not null default now()
);

create unique index if not exists virtual_classroom_connections_org_provider_uidx
  on public.virtual_classroom_connections(organization_id,provider);

alter table public.virtual_classroom_connections enable row level security;

create policy virtual_classroom_connections_select on public.virtual_classroom_connections
for select to authenticated
using (
  app_private.is_platform_admin()
  or app_private.is_org_member(organization_id, array['org_admin'::member_role,'trainer'::member_role,'platform_admin'::member_role])
);

create policy virtual_classroom_connections_manage on public.virtual_classroom_connections
for all to authenticated
using (
  app_private.is_platform_admin()
  or app_private.is_org_member(organization_id, array['org_admin'::member_role,'platform_admin'::member_role])
)
with check (
  app_private.is_platform_admin()
  or app_private.is_org_member(organization_id, array['org_admin'::member_role,'platform_admin'::member_role])
);

create table if not exists public.virtual_classroom_events (
  id uuid primary key default gen_random_uuid(),
  provider public.virtual_classroom_provider not null,
  external_event_id text not null,
  external_session_id text,
  event_type text not null,
  occurred_at timestamptz,
  payload jsonb not null default '{}',
  processed_at timestamptz,
  created_at timestamptz not null default now()
);

create unique index if not exists virtual_classroom_events_provider_external_uidx
  on public.virtual_classroom_events(provider,external_event_id);

alter table public.virtual_classroom_events enable row level security;

create policy virtual_classroom_events_admin on public.virtual_classroom_events
for select to authenticated
using (app_private.is_platform_admin());

create or replace function app_private.record_virtual_classroom_event(
  p_provider public.virtual_classroom_provider,
  p_external_event_id text,
  p_external_session_id text,
  p_event_type text,
  p_occurred_at timestamptz,
  p_payload jsonb
)
returns uuid
language plpgsql
security definer
set search_path=public,app_private
as $$
declare v_id uuid;
begin
  insert into public.virtual_classroom_events(
    provider,external_event_id,external_session_id,event_type,occurred_at,payload
  )
  values(p_provider,p_external_event_id,p_external_session_id,p_event_type,p_occurred_at,coalesce(p_payload,'{}'))
  on conflict(provider,external_event_id) do nothing
  returning id into v_id;
  return v_id;
end;
$$;

revoke all on function app_private.record_virtual_classroom_event(public.virtual_classroom_provider,text,text,text,timestamptz,jsonb) from public;