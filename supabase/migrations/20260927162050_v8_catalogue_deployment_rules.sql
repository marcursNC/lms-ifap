create or replace function app_private.enforce_course_catalog_visibility()
returns trigger
language plpgsql
set search_path = public, pg_catalog
as $$
declare org_kind public.organization_kind;
begin
  if new.visibility = 'ifap_catalog' then
    select kind into org_kind from public.organizations where id = new.owner_organization_id;
    if org_kind is distinct from 'ifap'::public.organization_kind then
      raise exception 'Only IFAP-owned courses can be published to the IFAP catalogue';
    end if;
    if new.status <> 'published'::public.course_status then
      raise exception 'An IFAP catalogue course must be published';
    end if;
  end if;
  return new;
end;
$$;

drop trigger if exists courses_enforce_catalog_visibility on public.courses;
create trigger courses_enforce_catalog_visibility
before insert or update of owner_organization_id, visibility, status
on public.courses for each row execute function app_private.enforce_course_catalog_visibility();

alter table public.deployments
  add column if not exists available_from timestamptz,
  add column if not exists available_until timestamptz,
  add column if not exists enrollment_deadline timestamptz,
  add column if not exists capacity integer,
  add column if not exists notes text;

do $$ begin
  if not exists (select 1 from pg_constraint where conname='deployments_dates_check') then
    alter table public.deployments add constraint deployments_dates_check check (available_until is null or available_from is null or available_until >= available_from);
  end if;
  if not exists (select 1 from pg_constraint where conname='deployments_capacity_check') then
    alter table public.deployments add constraint deployments_capacity_check check (capacity is null or capacity > 0);
  end if;
end $$;

create or replace function app_private.enforce_deployment_course_rules()
returns trigger
language plpgsql
set search_path = public, pg_catalog
as $$
declare c_owner uuid; c_status public.course_status; c_visibility text;
begin
  select owner_organization_id, status, visibility into c_owner, c_status, c_visibility
  from public.courses where id = new.course_id;
  if c_status <> 'published'::public.course_status then
    raise exception 'Only published courses can be deployed';
  end if;
  if new.target_organization_id = c_owner then return new; end if;
  if not (c_visibility = 'ifap_catalog' and exists (select 1 from public.organizations o where o.id=c_owner and o.kind='ifap'::public.organization_kind)) then
    raise exception 'A course can be deployed to another organisation only from the IFAP catalogue';
  end if;
  return new;
end;
$$;

drop trigger if exists deployments_enforce_course_rules on public.deployments;
create trigger deployments_enforce_course_rules
before insert or update of course_id, target_organization_id on public.deployments
for each row execute function app_private.enforce_deployment_course_rules();

create or replace function app_private.create_deployment_event()
returns trigger
language plpgsql
set search_path = public, pg_catalog
as $$
begin
  insert into public.event_outbox(event_type, aggregate_type, aggregate_id, payload)
  values (
    case when tg_op='INSERT' then 'deployment.created' else 'deployment.updated' end,
    'deployment', new.id,
    jsonb_build_object('deployment_id',new.id,'course_id',new.course_id,'target_organization_id',new.target_organization_id,'status',new.status)
  );
  return new;
end;
$$;

drop trigger if exists deployments_event_trigger on public.deployments;
create trigger deployments_event_trigger after insert or update on public.deployments for each row execute function app_private.create_deployment_event();

create index if not exists deployments_target_org_idx on public.deployments(target_organization_id);
create index if not exists deployments_course_idx on public.deployments(course_id);