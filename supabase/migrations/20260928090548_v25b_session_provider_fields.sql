alter table public.sessions
  add column if not exists external_provider public.virtual_classroom_provider,
  add column if not exists external_meeting_id text,
  add column if not exists last_attendance_sync_at timestamptz,
  add column if not exists attendance_sync_status text not null default 'never';

alter table public.sessions
  add constraint sessions_attendance_sync_status_chk
  check (attendance_sync_status in ('never','pending','synced','error'));

create index if not exists sessions_external_meeting_idx
  on public.sessions(external_provider,external_meeting_id)
  where external_meeting_id is not null;