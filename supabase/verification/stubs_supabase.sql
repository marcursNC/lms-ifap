do $$ declare r text; begin foreach r in array array['anon','authenticated','service_role'] loop
 begin execute format('create role %I nologin',r); exception when duplicate_object then null; end; end loop; end $$;
create schema auth;
create table auth.users(id uuid primary key, email text, raw_user_meta_data jsonb, created_at timestamptz default now());
create function auth.uid() returns uuid language sql stable as $f$ select null::uuid $f$;
create schema storage;
create table storage.buckets(id text primary key, name text, public boolean, file_size_limit bigint, allowed_mime_types text[]);
create table storage.objects(id uuid default gen_random_uuid(), bucket_id text, name text, owner uuid);
alter table storage.objects enable row level security;
