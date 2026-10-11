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
