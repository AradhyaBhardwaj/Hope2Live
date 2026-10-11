alter table public.profiles
  add column if not exists blood_report_path text;
alter table public.profiles
  alter column last_donation_date drop not null,
  alter column last_donation_date set default null;

insert into storage.buckets (
  id,
  name,
  public,
  file_size_limit,
  allowed_mime_types
)
values (
  'blood-reports',
  'blood-reports',
  false,
  10485760,
  array['application/pdf', 'image/jpeg', 'image/png']
)
on conflict (id) do update
set public = false,
    file_size_limit = excluded.file_size_limit,
    allowed_mime_types = excluded.allowed_mime_types;

drop policy if exists "hope2live_blood_report_select"
  on storage.objects;
create policy "hope2live_blood_report_select"
  on storage.objects
  for select
  to authenticated
  using (
    bucket_id = 'blood-reports'
    and (storage.foldername(name))[1] = (select auth.uid())::text
  );

drop policy if exists "hope2live_blood_report_select_guard"
  on storage.objects;
create policy "hope2live_blood_report_select_guard"
  on storage.objects
  as restrictive
  for select
  to authenticated
  using (
    bucket_id = 'blood-reports'
    and (storage.foldername(name))[1] = (select auth.uid())::text
  );

drop policy if exists "hope2live_blood_report_insert"
  on storage.objects;
create policy "hope2live_blood_report_insert"
  on storage.objects
  for insert
  to authenticated
  with check (
    bucket_id = 'blood-reports'
    and (storage.foldername(name))[1] = (select auth.uid())::text
  );

drop policy if exists "hope2live_blood_report_insert_guard"
  on storage.objects;
create policy "hope2live_blood_report_insert_guard"
  on storage.objects
  as restrictive
  for insert
  to authenticated
  with check (
    bucket_id = 'blood-reports'
    and (storage.foldername(name))[1] = (select auth.uid())::text
  );

drop policy if exists "hope2live_blood_report_update"
  on storage.objects;
create policy "hope2live_blood_report_update"
  on storage.objects
  for update
  to authenticated
  using (
    bucket_id = 'blood-reports'
    and (storage.foldername(name))[1] = (select auth.uid())::text
  )
  with check (
    bucket_id = 'blood-reports'
    and (storage.foldername(name))[1] = (select auth.uid())::text
  );

drop policy if exists "hope2live_blood_report_update_guard"
  on storage.objects;
create policy "hope2live_blood_report_update_guard"
  on storage.objects
  as restrictive
  for update
  to authenticated
  using (
    bucket_id = 'blood-reports'
    and (storage.foldername(name))[1] = (select auth.uid())::text
  )
  with check (
    bucket_id = 'blood-reports'
    and (storage.foldername(name))[1] = (select auth.uid())::text
  );

alter table public.blood_request_responses enable row level security;
alter table public.donation_messages enable row level security;
grant select, insert on public.blood_request_responses to authenticated;
grant select, insert on public.donation_messages to authenticated;

create or replace function public.hope2live_is_donation_participant(
  target_response_id uuid
)
returns boolean
language sql
stable
security definer
set search_path = ''
set row_security = off
as $$
  select exists (
    select 1
    from public.blood_request_responses as response
    where response.id = target_response_id
      and response.status in ('Accepted', 'Completed')
      and (
        response.donor_id = (select auth.uid())
        or exists (
          select 1
          from public.blood_requests as request
          where request.id = response.request_id
            and request.requester_id = (select auth.uid())
        )
      )
  );
$$;

revoke all on function public.hope2live_is_donation_participant(uuid) from public;
grant execute on function public.hope2live_is_donation_participant(uuid) to authenticated;

drop policy if exists "hope2live_response_participants_select"
  on public.blood_request_responses;
create policy "hope2live_response_participants_select"
  on public.blood_request_responses
  for select
  to authenticated
  using (
    donor_id = (select auth.uid())
    or exists (
      select 1
      from public.blood_requests as request
      where request.id = blood_request_responses.request_id
        and request.requester_id = (select auth.uid())
    )
  );

drop policy if exists "hope2live_response_participants_select_guard"
  on public.blood_request_responses;
create policy "hope2live_response_participants_select_guard"
  on public.blood_request_responses
  as restrictive
  for select
  to authenticated
  using (
    donor_id = (select auth.uid())
    or exists (
      select 1
      from public.blood_requests as request
      where request.id = blood_request_responses.request_id
        and request.requester_id = (select auth.uid())
    )
  );

drop policy if exists "hope2live_donor_response_insert"
  on public.blood_request_responses;
create policy "hope2live_donor_response_insert"
  on public.blood_request_responses
  for insert
  to authenticated
  with check (
    donor_id = (select auth.uid())
    and status in ('Interested', 'Declined', 'Unavailable')
  );

drop policy if exists "hope2live_donor_response_insert_guard"
  on public.blood_request_responses;
create policy "hope2live_donor_response_insert_guard"
  on public.blood_request_responses
  as restrictive
  for insert
  to authenticated
  with check (
    donor_id = (select auth.uid())
    and status in ('Interested', 'Declined', 'Unavailable')
  );

drop policy if exists "hope2live_chat_participants_select"
  on public.donation_messages;
create policy "hope2live_chat_participants_select"
  on public.donation_messages
  for select
  to authenticated
  using (public.hope2live_is_donation_participant(response_id));

drop policy if exists "hope2live_chat_participants_select_guard"
  on public.donation_messages;
create policy "hope2live_chat_participants_select_guard"
  on public.donation_messages
  as restrictive
  for select
  to authenticated
  using (public.hope2live_is_donation_participant(response_id));

drop policy if exists "hope2live_chat_participants_insert"
  on public.donation_messages;
create policy "hope2live_chat_participants_insert"
  on public.donation_messages
  for insert
  to authenticated
  with check (
    sender_id = (select auth.uid())
    and public.hope2live_is_donation_participant(response_id)
  );

drop policy if exists "hope2live_chat_participants_insert_guard"
  on public.donation_messages;
create policy "hope2live_chat_participants_insert_guard"
  on public.donation_messages
  as restrictive
  for insert
  to authenticated
  with check (
    sender_id = (select auth.uid())
    and public.hope2live_is_donation_participant(response_id)
  );

create or replace function public.hope2live_guard_donation_cooldown()
returns trigger
language plpgsql
set search_path = ''
as $$
declare
  last_donation date;
  report_path text;
begin
  select nullif(profile.last_donation_date::text, '')::date,
         profile.blood_report_path
    into last_donation, report_path
  from public.profiles as profile
  where profile.id = new.donor_id;

  if lower(coalesce(new.status::text, '')) not in ('declined', 'unavailable')
    and report_path is null then
    raise exception 'A blood report must be uploaded before responding to a donation request.'
      using errcode = '23514';
  end if;

  if lower(coalesce(new.status::text, '')) not in ('declined', 'unavailable')
    and last_donation is not null
    and last_donation + interval '6 months' > current_date
    and current_setting('hope2live.donation_completion', true) is distinct from 'on' then
    raise exception 'Donors must wait six months after a successful donation.'
      using errcode = '23514';
  end if;

  return new;
end;
$$;

drop trigger if exists hope2live_guard_donation_cooldown
  on public.blood_request_responses;
create trigger hope2live_guard_donation_cooldown
  before insert or update of donor_id, status on public.blood_request_responses
  for each row
  execute function public.hope2live_guard_donation_cooldown();

create or replace function public.hope2live_guard_profile_cooldown()
returns trigger
language plpgsql
set search_path = ''
as $$
declare
  previous_donation date;
  next_available_date date;
begin
  if tg_op = 'INSERT' then
    if new.last_donation_date is not null then
      raise exception 'Last donation date can only be set by confirming a successful donation.'
        using errcode = '23514';
    end if;

    return new;
  end if;

  previous_donation := nullif(old.last_donation_date::text, '')::date;
  next_available_date := previous_donation + interval '6 months';

  if new.last_donation_date is not null
    and nullif(new.last_donation_date::text, '')::date > current_date then
    raise exception 'Last donation date cannot be in the future.'
      using errcode = '23514';
  end if;

  if new.last_donation_date is distinct from old.last_donation_date
    and current_setting('hope2live.donation_completion', true) is distinct from 'on' then
    raise exception 'Last donation date can only be set by confirming a successful donation.'
      using errcode = '23514';
  end if;

  if previous_donation is not null and next_available_date > current_date then
    new.availability := 'false';
  end if;

  return new;
end;
$$;

drop trigger if exists hope2live_guard_profile_cooldown
  on public.profiles;
create trigger hope2live_guard_profile_cooldown
  before insert or update on public.profiles
  for each row
  execute function public.hope2live_guard_profile_cooldown();

create or replace function public.complete_donation_response(response_id uuid)
returns date
language plpgsql
security definer
set search_path = ''
as $$
declare
  response_donor_id uuid;
  response_status text;
begin
  if (select auth.uid()) is null then
    raise exception 'Authentication is required.'
      using errcode = '42501';
  end if;

  select response.donor_id, response.status
    into response_donor_id, response_status
  from public.blood_request_responses as response
  where response.id = complete_donation_response.response_id
  for update;

  if not found
    or response_donor_id <> (select auth.uid())
    or response_status <> 'Accepted' then
    return null;
  end if;

  perform set_config('hope2live.donation_completion', 'on', true);

  update public.profiles
  set last_donation_date = current_date,
      availability = 'false'
  where id = (select auth.uid());

  if not found then
    raise exception 'Donor profile could not be found.';
  end if;

  update public.blood_request_responses
  set status = 'Completed'
  where id = complete_donation_response.response_id;

  return current_date;
end;
$$;

revoke all on function public.complete_donation_response(uuid) from public;
grant execute on function public.complete_donation_response(uuid) to authenticated;

create or replace function public.get_request_donation_responses(recipient_id uuid)
returns table (
  response_id uuid,
  request_id uuid,
  status text,
  created_at timestamptz,
  distance_km double precision
)
language plpgsql
security definer
set search_path = ''
as $$
begin
  return query
  select response_data.response_id,
         response_data.request_id,
         response_data.status,
         response_data.created_at,
         response_data.distance_km
  from (
    select donor_response.id as response_id,
           donor_response.request_id,
           donor_response.status::text as status,
           donor_response.created_at,
           case
             when request.latitude is null
               or request.longitude is null
               or donor.latitude is null
               or donor.longitude is null
               or request.latitude::text = ''
               or request.longitude::text = ''
               or donor.latitude::text = ''
               or donor.longitude::text = ''
             then null
             else 6371 * 2 * asin(sqrt(
               power(sin(radians(
                 donor.latitude::double precision - request.latitude::double precision
               ) / 2), 2)
               + cos(radians(request.latitude::double precision))
               * cos(radians(donor.latitude::double precision))
               * power(sin(radians(
                 donor.longitude::double precision - request.longitude::double precision
               ) / 2), 2)
             ))
           end as distance_km
    from public.blood_request_responses as donor_response
    join public.blood_requests as request
      on request.id = donor_response.request_id
    join public.profiles as donor
      on donor.id = donor_response.donor_id
    where request.requester_id = recipient_id
      and request.status <> 'Cancelled'
      and (
        request.status = 'Open'
        or donor_response.status in ('Accepted', 'Completed')
      )
      and donor_response.status in ('Interested', 'Accepted', 'Completed')
  ) as response_data
  order by response_data.distance_km asc nulls last,
           response_data.created_at desc;
end;
$$;

revoke all on function public.get_request_donation_responses(uuid) from public;
grant execute on function public.get_request_donation_responses(uuid) to authenticated;

create or replace function public.mark_donation_unavailable(response_id uuid)
returns boolean
language plpgsql
security definer
set search_path = ''
as $$
declare
  updated_response_id uuid;
begin
  if (select auth.uid()) is null then
    raise exception 'Authentication is required.'
      using errcode = '42501';
  end if;

  update public.blood_request_responses as donor_response
  set status = 'Unavailable'
  where donor_response.id = mark_donation_unavailable.response_id
    and donor_response.donor_id = (select auth.uid())
    and donor_response.status in ('Interested', 'Accepted')
  returning donor_response.id into updated_response_id;

  return updated_response_id is not null;
end;
$$;

revoke all on function public.mark_donation_unavailable(uuid) from public;
grant execute on function public.mark_donation_unavailable(uuid) to authenticated;
