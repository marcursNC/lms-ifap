
alter table public.course_modules add column if not exists description text;
alter table public.course_modules add column if not exists is_required boolean not null default true;
create table public.course_resources (
 id uuid primary key default gen_random_uuid(),
 course_id uuid not null references public.courses(id) on delete cascade,
 module_id uuid references public.course_modules(id) on delete cascade,
 title text not null,
 resource_type text not null,
 storage_path text,
 external_url text,
 created_at timestamptz not null default now()
);
alter table public.course_resources enable row level security;
create index course_resources_course_idx on public.course_resources(course_id);
create index course_modules_course_position_idx on public.course_modules(course_id, position);
