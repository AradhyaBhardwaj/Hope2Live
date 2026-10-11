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
    join public.blood_requests as request
      on request.id = response.request_id
    where response.id = target_response_id
      and response.status in ('Accepted', 'Completed')
      and request.status <> 'Cancelled'
      and (
        response.donor_id = (select auth.uid())
        or request.requester_id = (select auth.uid())
      )
  );
$$;

revoke all on function public.hope2live_is_donation_participant(uuid) from public;
grant execute on function public.hope2live_is_donation_participant(uuid) to authenticated;

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
    raise exception 'Authentication is required.'
      using errcode = '42501';
  end if;

  select request.id
    into owned_request_id
  from public.blood_requests as request
  where request.id = target_request_id
    and request.requester_id = (select auth.uid())
  for update;

  if not found then
    return false;
  end if;

  delete from public.donation_messages as message
  using public.blood_request_responses as response
  where message.response_id = response.id
    and response.request_id = target_request_id;

  update public.blood_requests
  set status = 'Cancelled'
  where id = target_request_id
    and requester_id = (select auth.uid());

  return true;
end;
$$;

revoke all on function public.cancel_blood_request_and_delete_chats(uuid) from public;
grant execute on function public.cancel_blood_request_and_delete_chats(uuid) to authenticated;
