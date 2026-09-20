-- Waitlist cho landing page Volar. Trang public chi duoc INSERT (email, source);
-- khong ai doc/sua/xoa qua API. Trung email (khong phan biet hoa thuong) -> 409.
create table public.waitlist (
  id bigint generated always as identity primary key,
  email text not null check (char_length(email) <= 254 and email ~* '^[^@\s]+@[^@\s]+\.[^@\s]+$'),
  source text check (char_length(source) <= 64),
  created_at timestamptz not null default now()
);
create unique index waitlist_email_lower_idx on public.waitlist (lower(email));
alter table public.waitlist enable row level security;
revoke all on public.waitlist from anon, authenticated;
grant insert (email, source) on public.waitlist to anon;
create policy "anon can join waitlist" on public.waitlist for insert to anon with check (true);
