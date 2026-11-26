
insert into public.organizations (name, kind)
select 'IFAP', 'ifap'::organization_kind
where not exists (select 1 from public.organizations where name='IFAP');

insert into public.organizations (name, kind)
select 'Collectivité de démonstration', 'collectivite'::organization_kind
where not exists (select 1 from public.organizations where name='Collectivité de démonstration');

create or replace function app_private.touch_updated_at()
returns trigger language plpgsql set search_path=public,app_private as $$
begin new.updated_at=now(); return new; end $$;

drop trigger if exists courses_touch_updated_at on public.courses;
create trigger courses_touch_updated_at before update on public.courses
for each row execute function app_private.touch_updated_at();

create or replace function app_private.create_course_event()
returns trigger language plpgsql set search_path=public,app_private as $$
begin
  insert into public.event_outbox(event_type,aggregate_type,aggregate_id,payload)
  values (
    case when tg_op='INSERT' then 'course.created' else 'course.updated' end,
    'course', new.id,
    jsonb_build_object('course_id',new.id,'organization_id',new.owner_organization_id,'title',new.title,'status',new.status)
  );
  return new;
end $$;

drop trigger if exists courses_event_outbox on public.courses;
create trigger courses_event_outbox after insert or update on public.courses
for each row execute function app_private.create_course_event();

create or replace function app_private.create_enrollment_event()
returns trigger language plpgsql set search_path=public,app_private as $$
begin
  insert into public.event_outbox(event_type,aggregate_type,aggregate_id,payload)
  values ('enrollment.created','enrollment',new.id,
    jsonb_build_object('enrollment_id',new.id,'learner_id',new.learner_id,'deployment_id',new.deployment_id));
  return new;
end $$;

drop trigger if exists enrollments_event_outbox on public.enrollments;
create trigger enrollments_event_outbox after insert on public.enrollments
for each row execute function app_private.create_enrollment_event();
