package com.hope2live;

import com.sun.net.httpserver.HttpExchange;
import com.sun.net.httpserver.HttpServer;
import java.io.IOException;
import java.net.InetSocketAddress;
import java.net.URI;
import java.net.URLEncoder;
import java.net.http.HttpClient;
import java.net.http.HttpRequest;
import java.net.http.HttpResponse;
import java.nio.charset.StandardCharsets;
import java.time.Duration;
import java.util.concurrent.Executors;
import java.util.regex.Matcher;
import java.util.regex.Pattern;

/** Java 17 API gateway. Supabase remains the source of truth; all database
 * calls carry the signed-in user's JWT so PostgreSQL RLS remains enforced. */
public final class Hope2LiveApi {
    private static final HttpClient HTTP = HttpClient.newBuilder()
        .connectTimeout(Duration.ofSeconds(10)).build();
    private static final String SUPABASE_URL = env("VITE_SUPABASE_URL", "");
    private static final String SUPABASE_KEY = env("VITE_SUPABASE_PUBLISHABLE_KEY", "");
    private static final int PORT = Integer.parseInt(env("HOPE2LIVE_JAVA_PORT", "8081"));

    public static void main(String[] args) throws Exception {
        if (SUPABASE_URL.isBlank() || SUPABASE_KEY.isBlank()) {
            throw new IllegalStateException("Missing VITE_SUPABASE_URL or VITE_SUPABASE_PUBLISHABLE_KEY. Check .env.local.");
        }
        HttpServer server = HttpServer.create(new InetSocketAddress("127.0.0.1", PORT), 0);
        server.createContext("/api/health", x -> respond(x, 200, "{\"status\":\"ok\",\"service\":\"hope2live-java\"}"));
        server.createContext("/api/matching/requests", Hope2LiveApi::matchingRequests);
        server.setExecutor(Executors.newFixedThreadPool(8));
        server.start();
        System.out.println("Hope2Live Java API running at http://127.0.0.1:" + PORT);
    }

    private static void matchingRequests(HttpExchange x) throws IOException {
        if (preflight(x)) return;
        if (!"POST".equalsIgnoreCase(x.getRequestMethod())) { respond(x, 405, error("Method not allowed")); return; }
        String auth = x.getRequestHeaders().getFirst("Authorization");
        if (auth == null || !auth.startsWith("Bearer ") || auth.length() < 20) { respond(x, 401, error("Sign-in required")); return; }
        String jwt = auth.substring(7).trim();
        String body = new String(x.getRequestBody().readAllBytes(), StandardCharsets.UTF_8);
        String bloodGroup = jsonString(body, "bloodGroup");
        String lat = jsonNumberOrNull(body, "latitude");
        String lon = jsonNumberOrNull(body, "longitude");
        boolean cooldown = jsonBoolean(body, "isDonationCoolingDown");
        if (bloodGroup == null || !bloodGroup.matches("(?i)(A|B|AB|O)[+-]")) { respond(x, 400, error("Valid donor bloodGroup is required")); return; }

        try {
            // Validate the user's JWT with Supabase Auth before using it for PostgREST.
            HttpRequest verify = HttpRequest.newBuilder(URI.create(SUPABASE_URL + "/auth/v1/user"))
                .timeout(Duration.ofSeconds(15)).header("apikey", SUPABASE_KEY)
                .header("Authorization", "Bearer " + jwt).GET().build();
            HttpResponse<String> verified = HTTP.send(verify, HttpResponse.BodyHandlers.ofString());
            if (verified.statusCode() != 200) { respond(x, 401, error("Supabase session is invalid or expired")); return; }

            String accepted = rpc("get_donor_accepted_blood_requests", "{}", jwt);
            String matching = "[]";
            if (!cooldown) {
                String payload = "{\"donor_blood_group\":\"" + bloodGroup.toUpperCase()
                    + "\",\"donor_latitude\":" + lat + ",\"donor_longitude\":" + lon + "}";
                matching = rpc("get_matching_blood_requests", payload, jwt);
            }
            respond(x, 200, "{\"accepted\":" + accepted + ",\"matching\":" + matching + "}");
        } catch (InterruptedException e) {
            Thread.currentThread().interrupt(); respond(x, 503, error("Request interrupted"));
        } catch (Exception e) {
            System.err.println("Java matching API error: " + e.getMessage());
            respond(x, 502, error("Supabase matching request failed"));
        }
    }

    private static String rpc(String name, String json, String jwt) throws Exception {
        HttpRequest request = HttpRequest.newBuilder(URI.create(SUPABASE_URL + "/rest/v1/rpc/" + name))
            .timeout(Duration.ofSeconds(25)).header("apikey", SUPABASE_KEY)
            .header("Authorization", "Bearer " + jwt).header("Content-Type", "application/json")
            .POST(HttpRequest.BodyPublishers.ofString(json)).build();
        HttpResponse<String> response = HTTP.send(request, HttpResponse.BodyHandlers.ofString());
        if (response.statusCode() < 200 || response.statusCode() >= 300) {
            throw new IOException("Supabase RPC " + name + " returned HTTP " + response.statusCode() + ": " + response.body());
        }
        return response.body().isBlank() ? "[]" : response.body();
    }

    private static boolean preflight(HttpExchange x) throws IOException {
        cors(x);
        if ("OPTIONS".equalsIgnoreCase(x.getRequestMethod())) { x.sendResponseHeaders(204, -1); return true; }
        return false;
    }
    private static void respond(HttpExchange x, int status, String body) throws IOException {
        cors(x); x.getResponseHeaders().set("Content-Type", "application/json; charset=utf-8");
        byte[] bytes = body.getBytes(StandardCharsets.UTF_8); x.sendResponseHeaders(status, bytes.length);
        try (var out = x.getResponseBody()) { out.write(bytes); }
    }
    private static void cors(HttpExchange x) {
        x.getResponseHeaders().set("Access-Control-Allow-Origin", "http://localhost:5173");
        x.getResponseHeaders().set("Access-Control-Allow-Methods", "POST, OPTIONS, GET");
        x.getResponseHeaders().set("Access-Control-Allow-Headers", "Content-Type, Authorization");
    }
    private static String error(String message) { return "{\"error\":\"" + message.replace("\\", "\\\\").replace("\"", "\\\"") + "\"}"; }
    private static String jsonString(String json, String key) {
        Matcher m = Pattern.compile("\\\"" + Pattern.quote(key) + "\\\"\\s*:\\s*\\\"([^\\\"]*)\\\"").matcher(json);
        return m.find() ? m.group(1) : null;
    }
    private static boolean jsonBoolean(String json, String key) {
        Matcher m = Pattern.compile("\\\"" + Pattern.quote(key) + "\\\"\\s*:\\s*(true|false)", Pattern.CASE_INSENSITIVE).matcher(json);
        return m.find() && Boolean.parseBoolean(m.group(1));
    }
    private static String jsonNumberOrNull(String json, String key) {
        Matcher m = Pattern.compile("\\\"" + Pattern.quote(key) + "\\\"\\s*:\\s*(null|-?[0-9]+(?:\\.[0-9]+)?)").matcher(json);
        return m.find() ? m.group(1) : "null";
    }
    private static String env(String key, String fallback) { String v = System.getenv(key); return v == null ? fallback : v.trim(); }
}
