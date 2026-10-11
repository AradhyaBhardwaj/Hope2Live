-- Bind recipient response data to the signed-in recipient. The client still
-- supplies recipient_id for compatibility, but it can no longer be used to
-- inspect another user's request responses.
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
set row_security = off
as $$
begin
  if (select auth.uid()) is null then
    raise exception 'Authentication is required.' using errcode = '42501';
  end if;

  if recipient_id is distinct from (select auth.uid()) then
    raise exception 'You can only view responses to your own requests.'
      using errcode = '42501';
  end if;

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
    where request.requester_id = (select auth.uid())
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

-- A cancelled request cannot be completed or withdrawn from through a stale UI.
create or replace function public.complete_donation_response(response_id uuid)
returns date
language plpgsql
security definer
set search_path = ''
as $$
declare
  response_donor_id uuid;
  response_status text;
  request_status text;
begin
  if (select auth.uid()) is null then
    raise exception 'Authentication is required.' using errcode = '42501';
  end if;

  select response.donor_id, response.status, request.status
    into response_donor_id, response_status, request_status
  from public.blood_request_responses as response
  join public.blood_requests as request
    on request.id = response.request_id
  where response.id = complete_donation_response.response_id
  for update of response, request;

  if not found
    or response_donor_id <> (select auth.uid())
    or response_status <> 'Accepted'
    or request_status = 'Cancelled' then
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
    raise exception 'Authentication is required.' using errcode = '42501';
  end if;

  update public.blood_request_responses as donor_response
  set status = 'Unavailable'
  from public.blood_requests as request
  where donor_response.id = mark_donation_unavailable.response_id
    and request.id = donor_response.request_id
    and request.status <> 'Cancelled'
    and donor_response.donor_id = (select auth.uid())
    and donor_response.status in ('Interested', 'Accepted')
  returning donor_response.id into updated_response_id;

  return updated_response_id is not null;
end;
$$;

revoke all on function public.mark_donation_unavailable(uuid) from public;
grant execute on function public.mark_donation_unavailable(uuid) to authenticated;

-- Block new message inserts while cancellation changes the request state and
-- removes every existing message for that request.
create or replace function public.cancel_blood_request_and_delete_chats(
  target_request_id uuid
)
returns boolean
language plpgsql
security definer
set search_path = ''
as $$
declare
  owned_request_id uuid;
begin
  if (select auth.uid()) is null then
    raise exception 'Authentication is required.' using errcode = '42501';
  end if;

  select request.id
    into owned_request_id
  from public.blood_requests as request
  where request.id = target_request_id
    and request.requester_id = (select auth.uid())
    and request.status <> 'Cancelled'
  for update;

  if not found then
    return false;
  end if;

  lock table public.donation_messages in share row exclusive mode;

  update public.blood_requests
  set status = 'Cancelled'
  where id = owned_request_id;

  delete from public.donation_messages as message
  using public.blood_request_responses as response
  where message.response_id = response.id
    and response.request_id = owned_request_id;

  return true;
end;
$$;

revoke all on function public.cancel_blood_request_and_delete_chats(uuid) from public;
grant execute on function public.cancel_blood_request_and_delete_chats(uuid) to authenticated;
