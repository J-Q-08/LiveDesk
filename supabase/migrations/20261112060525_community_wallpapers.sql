-- Shared catalog metadata. Video and thumbnail bytes live in Supabase Storage.
create table public.wallpapers (
    id uuid primary key,
    owner_id uuid not null references auth.users(id) on delete cascade,
    title text not null check (char_length(title) between 1 and 100),
    video_path text not null unique,
    thumbnail_path text,
    file_extension text not null check (file_extension in ('mp4', 'mov', 'm4v')),
    created_at timestamptz not null default now(),
    constraint video_belongs_to_owner check (split_part(video_path, '/', 1) = owner_id::text),
    constraint thumbnail_belongs_to_owner check (
        thumbnail_path is null or split_part(thumbnail_path, '/', 1) = owner_id::text
    )
);

create index wallpapers_created_at_idx on public.wallpapers (created_at desc, id desc);
create index wallpapers_owner_id_idx on public.wallpapers (owner_id);

alter table public.wallpapers enable row level security;
revoke all on public.wallpapers from anon, authenticated;
grant select on public.wallpapers to anon, authenticated;
grant insert on public.wallpapers to authenticated;

create policy "Anyone can browse wallpapers"
    on public.wallpapers for select to anon, authenticated using (true);

create policy "Owners can publish wallpapers"
    on public.wallpapers for insert to authenticated
    with check (owner_id = (select auth.uid()));

insert into storage.buckets (id, name, public, file_size_limit, allowed_mime_types)
values (
    'wallpapers', 'wallpapers', true, 52428800,
    array['video/mp4', 'video/quicktime', 'image/png']
);

create policy "Owners can upload wallpaper media"
    on storage.objects for insert to authenticated
    with check (
        bucket_id = 'wallpapers'
        and (storage.foldername(name))[1] = (select auth.uid())::text
        and name ~* '\.(mp4|mov|m4v|png)$'
    );
