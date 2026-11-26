-- Retour à l'état antérieur à 20261126184023_deploiement_organisations.
-- Attention : rétablit les blocages d'origine et supprime l'origine des déploiements.
-- Les déploiements, inscriptions et événements sont conservés.
begin;

drop policy deployments_insert on public.deployments;
drop policy deployments_update on public.deployments;
create policy deployments_manage on public.deployments for all to authenticated
using (
  app_private.is_platform_admin()
  or app_private.is_org_member(target_organization_id, array['org_admin','platform_admin']::public.member_role[])
  or exists (select 1 from public.courses c where c.id = deployments.course_id
             and app_private.is_org_member(c.owner_organization_id, array['org_admin','trainer','platform_admin']::public.member_role[]))
)
with check (
  app_private.is_platform_admin()
  or app_private.is_org_member(target_organization_id, array['org_admin','platform_admin']::public.member_role[])
  or exists (select 1 from public.courses c where c.id = deployments.course_id
             and app_private.is_org_member(c.owner_organization_id, array['org_admin','trainer','platform_admin']::public.member_role[]))
);

alter policy courses_select on public.courses using (
  app_private.is_platform_admin()
  or app_private.is_org_member(owner_organization_id)
  or (visibility = 'ifap_catalog' and status = 'published'::public.course_status)
);

drop function public.list_deployable_organizations();

drop trigger deployments_enforce_course_rules on public.deployments;
drop trigger enrollments_enforce_rules on public.enrollments;

-- Définitions d'origine
-- create_deployment_event
CREATE OR REPLACE FUNCTION app_private.create_deployment_event()
 RETURNS trigger
 LANGUAGE plpgsql
 SET search_path TO 'public', 'pg_catalog'
AS $function$
begin
  insert into public.event_outbox(event_type, aggregate_type, aggregate_id, payload)
  values (
    case when tg_op='INSERT' then 'deployment.created' else 'deployment.updated' end,
    'deployment', new.id,
    jsonb_build_object('deployment_id',new.id,'course_id',new.course_id,'target_organization_id',new.target_organization_id,'status',new.status)
  );
  return new;
end;
$function$
;
-- create_enrollment_event
CREATE OR REPLACE FUNCTION app_private.create_enrollment_event()
 RETURNS trigger
 LANGUAGE plpgsql
 SET search_path TO 'public', 'pg_catalog'
AS $function$
begin
  insert into public.event_outbox(event_type,aggregate_type,aggregate_id,payload)
  values ('enrollment.created','enrollment',new.id,jsonb_build_object('enrollment_id',new.id,'deployment_id',new.deployment_id,'learner_id',new.learner_id));
  return new;
end; $function$
;
-- create_attestation_event
CREATE OR REPLACE FUNCTION app_private.create_attestation_event()
 RETURNS trigger
 LANGUAGE plpgsql
 SET search_path TO 'public', 'pg_catalog'
AS $function$
begin
  insert into public.event_outbox(event_type,aggregate_type,aggregate_id,payload)
  values ('certificate.issued','attestation',new.id,
    jsonb_build_object('attestation_id',new.id,'enrollment_id',new.enrollment_id,'certificate_number',new.certificate_number,'verification_token',new.verification_token));
  return new;
end; $function$
;
-- enforce_deployment_course_rules
CREATE OR REPLACE FUNCTION app_private.enforce_deployment_course_rules()
 RETURNS trigger
 LANGUAGE plpgsql
 SET search_path TO 'public', 'pg_catalog'
AS $function$
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
$function$
;
-- enforce_enrollment_rules
CREATE OR REPLACE FUNCTION app_private.enforce_enrollment_rules()
 RETURNS trigger
 LANGUAGE plpgsql
 SET search_path TO 'public', 'pg_catalog'
AS $function$
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
end; $function$
;

grant execute on function
  app_private.enforce_deployment_course_rules(),
  app_private.enforce_enrollment_rules(),
  app_private.create_deployment_event(),
  app_private.create_enrollment_event(),
  app_private.create_attestation_event()
to public;

create trigger deployments_enforce_course_rules
  before insert or update of course_id, target_organization_id on public.deployments
  for each row execute function app_private.enforce_deployment_course_rules();
create trigger enrollments_enforce_rules
  before insert on public.enrollments
  for each row execute function app_private.enforce_enrollment_rules();
create trigger enrollments_event_outbox
  after insert on public.enrollments
  for each row execute function app_private.create_enrollment_event();

drop function app_private.can_view_deployed_course(uuid);
drop function app_private.can_create_deployment(uuid, uuid);
drop function app_private.is_ifap_admin();
alter table public.deployments drop column initiated_by_organization_id;

commit;
