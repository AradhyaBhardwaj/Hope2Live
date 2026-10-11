
import { createClient } from "@supabase/supabase-js";

const supabaseUrl = import.meta.env.VITE_SUPABASE_URL?.trim();
const supabaseKey =
  import.meta.env.VITE_SUPABASE_PUBLISHABLE_KEY?.trim();

if (!supabaseUrl || !supabaseKey) {
  throw new Error(
    "Supabase configuration missing. Check .env.local."
  );
}

let parsedUrl;

try {
  parsedUrl = new URL(supabaseUrl);
} catch {
  throw new Error(
    "Invalid Supabase URL. Copy the Project URL from Supabase Dashboard."
  );
}

if (
  parsedUrl.protocol !== "https:" ||
  !parsedUrl.hostname.endsWith(".supabase.co")
) {
  throw new Error(
    "Invalid Supabase URL. Use your actual HTTPS Supabase Project URL."
  );
}

if (
  /YOUR_PROJECT_ID|YOUR_REAL_SUPABASE_PUBLISHABLE_KEY|placeholder/i.test(
    supabaseUrl + " " + supabaseKey
  )
) {
  throw new Error(
    "Replace placeholder values in .env.local with real Supabase credentials."
  );
}

export const supabase = createClient(
  supabaseUrl,
  supabaseKey,
  {
    auth: {
      autoRefreshToken: true,
      persistSession: true,
      detectSessionInUrl: true,
    },
  }
);
