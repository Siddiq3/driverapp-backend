-- Each person's app language, so push notifications arrive in that language.
alter table public.profiles
  add column language text not null default 'en' check (language in ('en', 'te', 'hi'));

grant update (language) on public.profiles to authenticated;
