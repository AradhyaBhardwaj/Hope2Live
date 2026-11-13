# Hope2Live

Hope2Live is a React-based blood-donation coordination interface that connects potential donors with people requesting blood support. It uses Supabase for authentication and PostgreSQL-backed data access.

> **Safety note:** Hope2Live is a coordination tool, not a medical decision system. Blood compatibility, donor eligibility, and transfusion decisions must be confirmed by qualified medical professionals.

## Technology

- React 19
- Vite
- Java 17 (built-in JDK HTTP server and HttpClient)
- Supabase Auth and PostgreSQL
- Custom CSS

## Requirements

- Node.js 22.12+ (or a Vite-supported current Node.js release)
- npm
- A Supabase project configured with the required schema, functions, and Row Level Security policies

## Local setup

1. Install dependencies:

   ```bash
   npm ci
   ```

2. Copy `.env.example` to `.env.local`. The example contains this project’s existing Supabase URL and publishable key; replace them if you use a different Supabase project:

   ```env
   VITE_SUPABASE_URL=https://your-project.supabase.co
   VITE_SUPABASE_PUBLISHABLE_KEY=your-supabase-publishable-key
   ```

3. In the Supabase SQL Editor, run `supabase/migrations/20261011000100_private_chat_and_donation_cooldown.sql`. It configures participant-only private chat access, a private per-user `blood-reports` Storage bucket, the profile report path, nullable last-donation dates, per-donor unavailable responses, and server-side checks for report upload and the six-month donor cooldown. The project must already have the documented tables and their referenced columns.
4. Run `supabase/migrations/20261011000200_require_accepted_donation_for_chat.sql`, `supabase/migrations/20261011000300_current_request_chat_lifecycle.sql`, `supabase/migrations/20261011000400_show_accepted_requests_to_donors.sql`, and `supabase/migrations/20261011000500_secure_donation_workflow.sql`, in that order. These restrict chat to accepted donors, block chats for cancelled requests, delete messages when a request is cancelled, keep accepted requests visible to the donor, and lock the recipient/donor workflow to its actual participants. In the dashboard, **Close request** moves a request to Past Requests and prevents donors from responding to it.
5. The app also requires the existing RPC functions `get_matching_blood_requests`, `get_request_donation_responses`, and `accept_donation_response`. Their definitions are not included in this repository and must already exist in Supabase.

6. Start the complete application (Java API + Vite) from the project root terminal:

   ```bash
   npm run dev:full
   ```

   This command compiles the Java 17 source into `backend-java/target/classes`, starts the Java API on `127.0.0.1:8081`, and starts Vite. Vite proxies `/api` calls to Java. Stop both processes with `Ctrl+C`.

   To run only the original React frontend without Java, use `npm run dev`.

7. The donor matching screen first calls the Java API. Java validates the active Supabase access token through Supabase Auth and forwards the existing `get_matching_blood_requests` and `get_donor_accepted_blood_requests` RPC calls using that same user JWT. This preserves PostgreSQL Row Level Security; no service-role key or database password is used. If Java is unavailable, the frontend falls back to the original direct Supabase RPC flow.

8. Run the production build and lint checks:

   ```bash
   npm run build
   npm run lint
   ```

## Environment and security

- Never place a Supabase `service_role` key or database password in a `VITE_*` variable or browser code.
- `.env.local` is ignored by Git. Do not commit credentials.
- A publishable key is expected to be visible in browser code; database security must be enforced with Row Level Security and carefully audited RPC permissions.
- Keep exact donor coordinates private and disclose only what is necessary for matching.
- Before deployment, test authorization for every read/write operation, including private donation messages and request acceptance.

## Form input validation

- Name fields accept Unicode letters and spaces only.
- A profile mobile number is optional; when provided, it must contain exactly 10 digits and start with 6, 7, 8, or 9. The form filters non-digits and prevents entering more than 10 digits.
- These checks are enforced by the app's forms and write handlers. Database-level constraints depend on the separately configured Supabase schema.

## Project structure

- `src/App.jsx` — main pages, auth flows, dashboard, donor/recipient workflows
- `src/App.css` — application styles
- `src/main.jsx` — React entry point
- `src/lib/supabase.js` — single Supabase client configuration
- `src/supabaseClient.js` — compatibility re-export for existing imports
- `public/` — favicon and public SVG assets

## Current limitations

- The base database schema and matching/acceptance RPC definitions still need to be supplied/configured separately.
- Build/lint checks must be run after dependencies are installed.
- This application must not be used to determine medical eligibility or replace clinical blood compatibility testing.
