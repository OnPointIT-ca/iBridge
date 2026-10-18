package ca.onpoint.ibridge.api;

import org.json.JSONArray;
import org.json.JSONObject;
import org.junit.After;
import org.junit.Before;
import org.junit.Test;

import java.io.IOException;
import java.nio.charset.StandardCharsets;
import java.nio.file.Files;
import java.nio.file.Path;
import java.nio.file.Paths;
import java.util.Arrays;
import java.util.Collections;
import java.util.HashMap;
import java.util.HashSet;
import java.util.LinkedHashMap;
import java.util.Map;
import java.util.Set;
import java.util.concurrent.ExecutorService;
import java.util.concurrent.Executors;
import java.util.concurrent.Future;
import java.util.concurrent.TimeUnit;

import okhttp3.OkHttpClient;
import okhttp3.mockwebserver.MockResponse;
import okhttp3.mockwebserver.MockWebServer;
import okhttp3.mockwebserver.RecordedRequest;
import okhttp3.mockwebserver.SocketPolicy;
import okhttp3.tls.HandshakeCertificates;
import okhttp3.tls.HeldCertificate;
import okio.Buffer;

import static org.junit.Assert.*;

/** HTTPS protocol fixtures only; these tests do not access a Mac or Apple services. */
public class BridgeClientTest {
    private static final String TOKEN = "fixture-client-token";
    private MockWebServer server;
    private BridgeClient client;
    private OkHttpClient trustedTransport;

    @Before public void setUp() throws IOException {
        HeldCertificate certificate = new HeldCertificate.Builder()
                .commonName("localhost").addSubjectAlternativeName("localhost").build();
        HandshakeCertificates serverCertificates = new HandshakeCertificates.Builder().heldCertificate(certificate).build();
        HandshakeCertificates clientCertificates = new HandshakeCertificates.Builder()
                .addTrustedCertificate(certificate.certificate()).build();
        server = new MockWebServer();
        server.useHttps(serverCertificates.sslSocketFactory(), false);
        server.start();
        trustedTransport = new OkHttpClient.Builder()
                .sslSocketFactory(clientCertificates.sslSocketFactory(), clientCertificates.trustManager()).build();
        client = new BridgeClient(server.url("/").toString(), TOKEN, trustedTransport);
    }

    @After public void tearDown() throws IOException {
        if (client != null) client.cancel();
        if (server != null) server.shutdown();
    }

    @Test public void acceptsAndNormalizesHttpsOrigins() {
        assertEquals("https://example.test", BridgeClient.validateOrigin("https://EXAMPLE.test:443/"));
        assertEquals("https://[::1]:8443", BridgeClient.validateOrigin("https://[::1]:8443"));
        assertEquals("https://mac.tailnet.ts.net", BridgeClient.validateOrigin("https://mac.tailnet.ts.net"));
    }

    @Test public void rejectsNonOriginsAndCredentialSmuggling() {
        String[] rejected = {null, "", "http://localhost", "https://user:secret@example.test", "https://example.test/a",
                "https://example.test?", "https://example.test#", "https://example.test/?token=secret", "https://example.test/..",
                "https://example.test\\@evil.test", " https://example.test", "https://example.test\n", "https://example.test:0",
                "https://example.test:65536", "https://example.test:", "https:///example.test", "https://example.test/%2e"};
        for (String origin : rejected) assertError("configuration_error", () -> BridgeClient.validateOrigin(origin));
        assertEquals(0, server.getRequestCount());
    }

    @Test public void validatesBearerSyntaxWithoutTrimmingOrEchoing() {
        assertEquals("abc-._~+/==", BridgeClient.validateToken("abc-._~+/=="));
        for (String token : new String[]{null, "", "Bearer abc", "abc\nInjected: yes", " secret", "a=b", "ümlaut"}) {
            BridgeException error = assertError("configuration_error", () -> BridgeClient.validateToken(token));
            if (token != null && !token.isEmpty()) assertFalse(error.getMessage().contains(token));
        }
    }

    @Test public void discoversCapabilitiesOverVerifiedHttpsWithAuth() throws Exception {
        server.enqueue(capabilities("calendar.list", true));
        assertEquals("1", client.capabilities().getJSONObject("data").getString("api_version"));
        RecordedRequest request = takeRequest();
        assertEquals("GET", request.getMethod());
        assertEquals("/api/v1/system/capabilities", request.getPath());
        assertEquals("Bearer " + TOKEN, request.getHeader("Authorization"));
        assertEquals("application/json", request.getHeader("Accept"));
        assertNotNull(request.getHandshake());
        assertEquals(0, request.getBodySize());
    }

    @Test public void productionClientRejectsUntrustedCertificates() {
        BridgeClient untrusted = new BridgeClient(server.url("/").toString(), TOKEN);
        try {
            assertError("connection_failed", untrusted::capabilities);
            assertEquals(0, server.getRequestCount());
        } finally {
            untrusted.cancel();
        }
    }

    @Test public void discoversImmediatelyBeforeEachReadAndDoesNotCachePermissions() throws Exception {
        server.enqueue(capabilities("calendar.list", true));
        server.enqueue(json("{\"data\":{\"items\":[]}}"));
        server.enqueue(capabilities("calendar.list", false));
        client.read("calendar.list", Collections.emptyMap());
        assertError("capability_unavailable", () -> client.read("calendar.list", Collections.emptyMap()));
        assertEquals("/api/v1/system/capabilities", takeRequest().getPath());
        assertEquals("/api/v1/calendars?limit=50", takeRequest().getPath());
        assertEquals("/api/v1/system/capabilities", takeRequest().getPath());
        assertEquals(3, server.getRequestCount());
    }

    @Test public void missingAndMalformedCapabilitiesFailClosed() {
        for (String entry : new String[]{"null", "{}", "{\"available\":false}", "{\"available\":\"true\"}", "{\"available\":1}"}) {
            server.enqueue(json("{\"data\":{\"api_version\":\"1\",\"operations\":{\"calendar.list\":" + entry + "}}}"));
            assertError("capability_unavailable", () -> client.read("calendar.list", Collections.emptyMap()));
        }
        server.enqueue(json("{\"data\":{\"api_version\":\"1\",\"operations\":{}}}"));
        assertError("capability_unavailable", () -> client.read("calendar.list", Collections.emptyMap()));
        assertEquals(6, server.getRequestCount());
    }

    @Test public void mismatchedVersionsAndInvalidCapabilityMapNeverReachService() {
        for (String version : new String[]{"\"2\"", "1", "null"}) {
            server.enqueue(json("{\"data\":{\"api_version\":" + version + ",\"operations\":{}}}"));
            assertError("incompatible_bridge", () -> client.read("calendar.list", Collections.emptyMap()));
        }
        server.enqueue(json("{\"data\":{\"api_version\":\"1\",\"operations\":[]}}"));
        assertError("invalid_response", () -> client.read("calendar.list", Collections.emptyMap()));
        assertEquals(4, server.getRequestCount());
    }

    @Test public void allReadOperationsUseDeclaredGetRoutesAndDefaults() throws Exception {
        for (ReadOperation operation : ReadOperation.values()) {
            Map<String, String> arguments = validArguments(operation);
            server.enqueue(capabilities(operation.capability, true));
            server.enqueue(json(operation == ReadOperation.DRIVE_READ
                    ? "{\"data\":{\"state\":\"ready\",\"content_base64\":\"\",\"size_bytes\":0,\"media_type\":\"text/plain\"}}"
                    : "{\"data\":{\"items\":[]}}"));
            client.read(operation.capability, arguments);
            takeRequest();
            RecordedRequest request = takeRequest();
            assertEquals("GET", request.getMethod());
            assertEquals("Bearer " + TOKEN, request.getHeader("Authorization"));
            assertEquals("/api/v1" + operation.route.replace("{note_id}", "opaque-id").replace("{chat_id}", "opaque-id"),
                    request.getRequestUrl().encodedPath());
            assertEquals(operation.paginated() ? "50" : null, request.getRequestUrl().queryParameter("limit"));
            assertEquals(0, request.getBodySize());
        }
        assertEquals(30, server.getRequestCount());
    }

    @Test public void percentEncodesOpaquePathIdsOnce() throws Exception {
        server.enqueue(capabilities("notes.read", true));
        server.enqueue(json("{\"data\":{\"body\":\"Example\"}}"));
        String opaqueId = "a/b%2F?c#d ☃";
        client.read("notes.read", Collections.singletonMap("note_id", opaqueId));
        takeRequest();
        RecordedRequest request = takeRequest();
        assertEquals("/api/v1/notes/a%2Fb%252F%3Fc%23d%20%E2%98%83", request.getPath());
        assertEquals(opaqueId, request.getRequestUrl().pathSegments().get(3));
    }

    @Test public void rejectsMalformedPagesCursorsAndContainerRows() {
        for (String data : new String[]{"{}", "{\"items\":{}}", "{\"items\":[1]}", "{\"items\":[null]}",
                "{\"items\":[],\"next_cursor\":1}", "{\"items\":[],\"next_cursor\":\"\"}",
                "{\"items\":[],\"next_cursor\":\"" + repeat("x", 4097) + "\"}",
                "{\"items\":[{\"name\":\"A calendar\"}]}", "{\"items\":[{\"id\":\"\",\"name\":\"A calendar\"}]}",
                "{\"items\":[{\"id\":1,\"name\":\"A calendar\"}]}", "{\"items\":[{\"id\":\"calendar-id\"}]}",
                "{\"items\":[{\"id\":\"calendar-id\",\"name\":42}]}"}) {
            server.enqueue(capabilities("calendar.list", true));
            server.enqueue(json("{\"data\":" + data + "}"));
            assertError("invalid_response", () -> client.read("calendar.list", Collections.emptyMap()));
        }
    }

    @Test public void preservesNamedResourcesAndAllowsNullEndCursor() throws Exception {
        server.enqueue(capabilities("calendar.list", true));
        server.enqueue(json("{\"data\":{\"items\":[{\"id\":\"opaque-id\",\"name\":\"Example calendar\"}],\"next_cursor\":null}}"));
        JSONObject result = client.read("calendar.list", Collections.emptyMap());
        JSONObject item = result.getJSONObject("data").getJSONArray("items").getJSONObject(0);
        assertEquals("opaque-id", item.getString("id"));
        assertEquals("Example calendar", item.getString("name"));
        assertTrue(result.getJSONObject("data").isNull("next_cursor"));
    }

    @Test public void rejectsPagesThatExceedTheRequestedLimit() {
        server.enqueue(capabilities("calendar.list", true));
        server.enqueue(json("{\"data\":{\"items\":[{\"id\":\"one\",\"name\":\"One\"},{\"id\":\"two\",\"name\":\"Two\"}]}}"));
        assertError("invalid_response", () -> client.read("calendar.list", Collections.singletonMap("limit", "1")));
    }

    @Test public void preservesNativeDriveRowsAndLongResponseIds() throws Exception {
        String path = repeat("a", 200) + "/" + repeat("b", 200) + "/" + repeat("c", 200);
        String id = "root-id:" + path;
        JSONObject row = new JSONObject().put("id", id).put("root_id", "root-id").put("name", repeat("c", 200))
                .put("path", path).put("kind", "directory");
        JSONObject data = new JSONObject().put("items", new JSONArray().put(row))
                .put("scan_truncated", true).put("search_scope", "file_names");
        server.enqueue(capabilities("drive.search", true));
        server.enqueue(json(new JSONObject().put("data", data).toString()));
        JSONObject result = client.read("drive.search", validArguments(ReadOperation.DRIVE_SEARCH)).getJSONObject("data");
        JSONObject returnedRow = result.getJSONArray("items").getJSONObject(0);
        assertEquals(id, returnedRow.getString("id"));
        assertEquals(path, returnedRow.getString("path"));
        assertEquals("directory", returnedRow.getString("kind"));
        assertTrue(result.getBoolean("scan_truncated"));
        assertEquals("file_names", result.getString("search_scope"));
        // Response IDs need not match input-ID limits; inputs still follow their schema.
        int requests = server.getRequestCount();
        assertError("invalid_arguments", () -> client.read("notes.read", Collections.singletonMap("note_id", id)));
        assertEquals(requests, server.getRequestCount());
    }

    @Test public void encodesSearchAndCursorAsQueryValues() throws Exception {
        server.enqueue(capabilities("messages.search", true));
        server.enqueue(json("{\"data\":{\"items\":[],\"next_cursor\":\"next\"}}"));
        Map<String, String> arguments = new LinkedHashMap<>();
        arguments.put("query", "a+b & ü/?");
        arguments.put("cursor", "next=%2F&limit=999");
        arguments.put("limit", "4");
        JSONObject result = client.read("messages.search", arguments);
        takeRequest();
        RecordedRequest request = takeRequest();
        assertEquals(arguments.get("query"), request.getRequestUrl().queryParameter("query"));
        assertEquals(arguments.get("cursor"), request.getRequestUrl().queryParameter("cursor"));
        assertEquals(Collections.singletonList("4"), request.getRequestUrl().queryParameterValues("limit"));
        assertEquals("next", result.getJSONObject("data").getString("next_cursor"));
        assertEquals(2, server.getRequestCount()); // Never auto-scans a next page.
    }

    @Test public void acceptsOffsetDatesAndPreservesSubNanosecondOrdering() throws Exception {
        Map<String, String> events = validArguments(ReadOperation.EVENTS);
        events.put("start", "2026-01-01T12:00:00.0000000001+01:00");
        events.put("end", "2026-01-01T11:00:00.0000000002Z");
        server.enqueue(capabilities("calendar.events.list", true));
        server.enqueue(json("{\"data\":{\"items\":[]}}"));
        client.read("calendar.events.list", events);
        takeRequest();
        RecordedRequest request = takeRequest();
        assertEquals(events.get("start"), request.getRequestUrl().queryParameter("start"));
        assertEquals(events.get("end"), request.getRequestUrl().queryParameter("end"));
    }

    @Test public void acceptsAnExactly366DayEventRangeAfterTimezoneConversion() throws Exception {
        Map<String, String> events = validArguments(ReadOperation.EVENTS);
        events.put("start", "2024-01-01T12:00:00+02:00");
        events.put("end", "2025-01-01T05:00:00-05:00");
        server.enqueue(capabilities("calendar.events.list", true));
        server.enqueue(json("{\"data\":{\"items\":[]}}"));
        client.read("calendar.events.list", events);
        takeRequest();
        RecordedRequest request = takeRequest();
        assertEquals(events.get("start"), request.getRequestUrl().queryParameter("start"));
        assertEquals(events.get("end"), request.getRequestUrl().queryParameter("end"));
    }

    @Test public void rejectsEventRangesOver366DaysBeforeNetworking() {
        Map<String, String> events = validArguments(ReadOperation.EVENTS);
        events.put("start", "2024-01-01T12:00:00+02:00");
        for (String end : new String[]{"2025-01-01T05:00:00.0000000001-05:00", "2025-01-01T12:00:00+01:00"}) {
            events.put("end", end);
            assertError("invalid_arguments", () -> client.read("calendar.events.list", events));
        }
        assertEquals(0, server.getRequestCount());
    }

    @Test public void rejectsWritesUnknownArgumentsAndMissingFieldsBeforeNetworking() {
        assertError("invalid_arguments", () -> client.read("notes.create", Collections.emptyMap()));
        assertError("invalid_arguments", () -> client.read(null, Collections.emptyMap()));
        assertError("invalid_arguments", () -> client.read("calendar.list", null));
        assertError("invalid_arguments", () -> client.read("calendar.list", Collections.singletonMap("request_id", "a-request")));
        assertError("invalid_arguments", () -> client.read("contacts.search", Collections.emptyMap()));
        assertError("invalid_arguments", () -> client.read("contacts.search", Collections.singletonMap("query", null)));
        assertEquals(0, server.getRequestCount());
    }

    @Test public void rejectsOutOfRangeNumbersAndInvalidBooleansBeforeNetworking() {
        for (String limit : new String[]{"0", "101", "-1", "1.0", "true", "999999999999999999999"}) {
            assertError("invalid_arguments", () -> client.read("calendar.list", Collections.singletonMap("limit", limit)));
        }
        Map<String, String> reminder = new HashMap<>();
        reminder.put("list_id", "opaque-id");
        reminder.put("completed", "TRUE");
        assertError("invalid_arguments", () -> client.read("reminders.list", reminder));
        Map<String, String> file = validArguments(ReadOperation.DRIVE_READ);
        file.put("max_bytes", "262145");
        assertError("invalid_arguments", () -> client.read("drive.read", file));
        assertEquals(0, server.getRequestCount());
    }

    @Test public void rejectsUnsafePathsAndDotIdsBeforeNetworking() {
        for (String path : new String[]{"/private/file", "../file", "a/../file", "a/./file", "a\\file", "a//file", "a/", "\u0000file"}) {
            Map<String, String> arguments = validArguments(ReadOperation.DRIVE_READ);
            arguments.put("path", path);
            assertError("invalid_arguments", () -> client.read("drive.read", arguments));
        }
        for (String id : new String[]{".", "..", "", "a\r\nInjected"}) {
            assertError("invalid_arguments", () -> client.read("notes.read", Collections.singletonMap("note_id", id)));
        }
        assertEquals(0, server.getRequestCount());
    }

    @Test public void validatesNativeDriveUtf8PathLimitAndAllowsEmptyRootListing() {
        StringBuilder path = new StringBuilder();
        for (int index = 0; index < 9; index++) {
            if (index > 0) path.append('/');
            path.append(repeat("é", 113));
        }
        path.append("ééé");
        String maximumPath = path.toString();
        assertEquals(2048, maximumPath.getBytes(StandardCharsets.UTF_8).length);
        Map<String, String> arguments = validArguments(ReadOperation.DRIVE_READ);
        arguments.put("path", maximumPath);
        assertEquals(maximumPath, ReadOperation.DRIVE_READ.validate(arguments).get("path"));
        arguments.put("path", maximumPath + "a");
        assertError("invalid_arguments", () -> client.read("drive.read", arguments));
        assertEquals("", ReadOperation.DRIVE_LIST.validate(Collections.singletonMap("root_id", "root-id")).get("path"));
        assertEquals(0, server.getRequestCount());
    }

    @Test public void rejectsWhitespaceOnlyQueriesBeforeNetworking() {
        for (ReadOperation operation : new ReadOperation[]{ReadOperation.CONTACTS, ReadOperation.DRIVE_SEARCH,
                ReadOperation.NOTES_SEARCH, ReadOperation.MESSAGES_SEARCH}) {
            Map<String, String> arguments = validArguments(operation);
            for (String query : new String[]{" ", "\n\t", "\u00a0\u2003"}) {
                arguments.put("query", query);
                assertError("invalid_arguments", () -> client.read(operation.capability, arguments));
            }
            arguments.put("query", "  actual text  ");
            assertEquals("  actual text  ", operation.validate(arguments).get("query"));
        }
        assertEquals(0, server.getRequestCount());
    }

    @Test public void validatesRfc3339AndComparesActualInstantsBeforeNetworking() {
        Map<String, String> events = validArguments(ReadOperation.EVENTS);
        for (String date : new String[]{"0000-01-01T12:00:00Z", "2026-01-01", "2026-01-01T12:00:00", "2026-02-30T12:00:00Z",
                "2026-01-01T24:00:00Z", "2026-01-01T12:00:60Z", "2026-01-01T12:00:00+02:99", "2026-01-01T12:00:00+24:00"}) {
            events.put("start", date);
            assertError("invalid_arguments", () -> client.read("calendar.events.list", events));
        }
        events.put("start", "2026-01-01T12:00:00-08:00");
        events.put("end", "2026-01-01T14:00:00-05:00");
        assertError("invalid_arguments", () -> client.read("calendar.events.list", events));
        events.put("end", "2026-01-01T20:00:00Z");
        assertError("invalid_arguments", () -> client.read("calendar.events.list", events));
        assertEquals(0, server.getRequestCount());
    }

    @Test public void rejectsMalformedJsonAndEnvelopesEvenOnSuccess() {
        for (String body : new String[]{"{}", "[]", "{\"data\":null}", "{\"data\":[]}", "{\"data\":\"text\"}", "{\"data\":{},\"error\":{}}", "{data:{}}",
                "{'data':{}}", "{\"data\":{},}", "{\"data\":{}} trailing", "{\"data\":NaN}", "{\"data\":{},\"data\":{}}",
                "{\"data\":{/*comment*/}}", "{\"data\":{},\"meta\":\"text\"}", "{\"data\":{\"number\":01}}"}) {
            server.enqueue(json(body));
            assertError("invalid_response", client::capabilities);
        }
    }

    @Test public void rejectsDeepJsonAndInvalidUtf8() {
        server.enqueue(json("{\"data\":" + repeat("[", 70) + "0" + repeat("]", 70) + "}"));
        assertError("invalid_response", client::capabilities);
        server.enqueue(new MockResponse().setHeader("Content-Type", "application/json")
                .setBody(new Buffer().write(new byte[]{'{', '"', 'd', 'a', 't', 'a', '"', ':', '"', (byte) 0xc3, '"', '}'})));
        assertError("invalid_response", client::capabilities);
    }

    @Test public void rejectsNonJsonAndNonUtf8ContentTypes() {
        server.enqueue(new MockResponse().setBody("{\"data\":{}}"));
        assertError("invalid_response", client::capabilities);
        server.enqueue(json("{\"data\":{}}").setHeader("Content-Type", "text/html"));
        assertError("invalid_response", client::capabilities);
        server.enqueue(json("{\"data\":{}}").setHeader("Content-Type", "application/json;charset=utf-16"));
        assertError("invalid_response", client::capabilities);
    }

    @Test public void mapsAuthErrorsWithoutExposingServerTextOrToken() {
        int[] statuses = {401, 403, 429, 503};
        String[] codes = {"authentication_failed", "permission_denied", "rate_limited", "unavailable"};
        for (int index = 0; index < statuses.length; index++) {
            server.enqueue(json("{\"error\":{\"message\":\"server-secret " + TOKEN + "\"}}").setResponseCode(statuses[index]));
            BridgeException error = assertError(codes[index], client::capabilities);
            assertFalse(error.getMessage().contains(TOKEN));
            assertFalse(error.getMessage().contains("server-secret"));
            assertNull(error.getCause());
        }
        assertEquals(statuses.length, server.getRequestCount());
    }

    @Test public void serviceCanDenyAReadAfterSuccessfulCapabilityDiscovery() {
        server.enqueue(capabilities("notes.read", true));
        server.enqueue(json("{\"error\":{\"message\":\"" + TOKEN + "\"}}").setResponseCode(403));
        BridgeException error = assertError("permission_denied", () -> client.read("notes.read", Collections.singletonMap("note_id", "opaque-id")));
        assertFalse(error.getMessage().contains(TOKEN));
        assertEquals(2, server.getRequestCount());
    }

    @Test public void refusesSameAndCrossOriginRedirectsWithoutForwardingCredentials() throws Exception {
        try (MockWebServer other = new MockWebServer()) {
            other.start();
            for (String location : new String[]{server.url("/other").toString(), other.url("/steal").toString()}) {
                server.enqueue(new MockResponse().setResponseCode(302).setHeader("Location", location));
                assertError("redirect_refused", client::capabilities);
            }
            assertEquals(2, server.getRequestCount());
            assertEquals(0, other.getRequestCount());
        }
    }

    @Test public void neverRetriesServiceUnavailableEvenWithRetryAfterZero() {
        server.enqueue(new MockResponse().setResponseCode(503).setHeader("Retry-After", "0"));
        assertError("connection_failed", client::capabilities);
        assertEquals(1, server.getRequestCount());
    }

    @Test public void rejectsContentLengthAndStreamingBodiesBeyondTwoMiB() {
        String large = "{\"data\":\"" + repeat("x", BridgeClient.MAX_RESPONSE_BYTES) + "\"}";
        server.enqueue(json(large));
        assertError("response_too_large", client::capabilities);
        server.enqueue(json("").setChunkedBody(large, 16384));
        assertError("response_too_large", client::capabilities);
    }

    @Test public void validatesReadyFileLengthCanonicalBase64AndRequestedLimit() throws Exception {
        Map<String, String> arguments = validArguments(ReadOperation.DRIVE_READ);
        arguments.put("max_bytes", "3");
        server.enqueue(capabilities("drive.read", true));
        server.enqueue(json("{\"data\":{\"state\":\"ready\",\"content_base64\":\"YWJj\",\"size_bytes\":3,\"media_type\":\"text/plain\"}}"));
        assertEquals("YWJj", client.read("drive.read", arguments).getJSONObject("data").getString("content_base64"));
        for (String data : new String[]{
                "{\"state\":\"ready\",\"content_base64\":\"YWJjZA==\",\"size_bytes\":4,\"media_type\":\"text/plain\"}",
                "{\"state\":\"ready\",\"content_base64\":\"YWJj\",\"size_bytes\":2,\"media_type\":\"text/plain\"}",
                "{\"state\":\"ready\",\"content_base64\":\"YQ\",\"size_bytes\":1,\"media_type\":\"text/plain\"}",
                "{\"state\":\"ready\",\"content_base64\":\"!!!\",\"size_bytes\":1,\"media_type\":\"text/plain\"}",
                "{\"state\":\"ready\",\"content_base64\":\"YQ==\",\"size_bytes\":1.0,\"media_type\":\"text/plain\"}",
                "{\"state\":\"ready\",\"content_base64\":\"YQ==\",\"size_bytes\":1}",
                "{\"state\":\"unknown\"}", "{\"state\":\"downloading\",\"content_base64\":\"\"}"}) {
            server.enqueue(capabilities("drive.read", true));
            server.enqueue(json("{\"data\":" + data + "}"));
            assertError("invalid_response", () -> client.read("drive.read", arguments));
        }
    }

    @Test public void preservesPendingDownloadWithoutInventingContent() throws Exception {
        server.enqueue(capabilities("drive.read", true));
        server.enqueue(json("{\"data\":{\"state\":\"downloading\"},\"meta\":{\"sync_state\":\"local\"}}"));
        JSONObject result = client.read("drive.read", validArguments(ReadOperation.DRIVE_READ));
        assertEquals("downloading", result.getJSONObject("data").getString("state"));
        assertFalse(result.getJSONObject("data").has("content_base64"));
        assertEquals("local", result.getJSONObject("meta").getString("sync_state"));
        assertEquals(2, server.getRequestCount());
    }

    @Test public void cancelledClientCannotStartRequests() {
        client.cancel();
        assertError("cancelled", client::capabilities);
        assertError("cancelled", () -> client.read("calendar.list", Collections.emptyMap()));
        assertEquals(0, server.getRequestCount());
    }

    @Test public void cancellationStopsDiscoveryAndPreventsServiceDispatch() throws Exception {
        server.enqueue(new MockResponse().setSocketPolicy(SocketPolicy.NO_RESPONSE));
        ExecutorService executor = Executors.newSingleThreadExecutor();
        try {
            Future<BridgeException> future = executor.submit(() -> assertError("cancelled", () -> client.read("calendar.list", Collections.emptyMap())));
            takeRequest();
            client.cancel();
            assertEquals("cancelled", future.get(5, TimeUnit.SECONDS).getCode());
            assertEquals(1, server.getRequestCount());
        } finally {
            executor.shutdownNow();
        }
    }

    @Test public void readOperationCatalogMatchesSharedContract() throws Exception {
        Path directory = Paths.get(System.getProperty("user.dir"));
        while (directory != null && !Files.exists(directory.resolve("shared/operations.json"))) directory = directory.getParent();
        assertNotNull("Run tests from the repository so shared/operations.json can be checked", directory);
        JSONArray operations = new JSONObject(new String(Files.readAllBytes(directory.resolve("shared/operations.json")), StandardCharsets.UTF_8))
                .getJSONArray("operations");
        Set<String> seen = new HashSet<>();
        for (int index = 0; index < operations.length(); index++) {
            JSONObject shared = operations.getJSONObject(index);
            if (!shared.getString("method").equals("GET")) continue;
            ReadOperation operation = ReadOperation.forCapability(shared.getString("capability"));
            seen.add(operation.capability);
            assertEquals(shared.getString("path"), operation.route);
            JSONObject parameters = shared.getJSONObject("schema").getJSONObject("parameters");
            JSONObject properties = parameters.getJSONObject("properties");
            Set<String> required = new HashSet<>();
            JSONArray requiredJson = parameters.getJSONArray("required");
            for (int item = 0; item < requiredJson.length(); item++) required.add(requiredJson.getString(item));
            assertEquals(properties.length(), operation.arguments().size());
            for (ReadOperation.Argument argument : operation.arguments()) {
                JSONObject schema = properties.getJSONObject(argument.name);
                assertEquals(required.contains(argument.name), argument.required);
                String type = argument.kind == ReadOperation.Kind.INTEGER ? "integer" : argument.kind == ReadOperation.Kind.BOOLEAN ? "boolean" : "string";
                assertEquals(schema.getString("type"), type);
                if (!type.equals("boolean")) {
                    assertEquals(schema.getInt(type.equals("integer") ? "minimum" : "minLength"), argument.minimum);
                    assertEquals(schema.getInt(type.equals("integer") ? "maximum" : "maxLength"), argument.maximum);
                }
                // Required fields must be supplied even when the contract contains a placeholder default.
                assertEquals(schema.has("default") && !argument.required ? schema.get("default").toString() : null, argument.defaultValue);
            }
        }
        assertEquals(ReadOperation.values().length, seen.size());
        assertEquals(15, seen.size());
    }

    private RecordedRequest takeRequest() throws InterruptedException {
        RecordedRequest request = server.takeRequest(5, TimeUnit.SECONDS);
        assertNotNull("Expected HTTPS request", request);
        return request;
    }

    private static Map<String, String> validArguments(ReadOperation operation) {
        Map<String, String> result = new LinkedHashMap<>();
        for (ReadOperation.Argument argument : operation.arguments()) {
            if (!argument.required) continue;
            if (argument.name.equals("start")) result.put(argument.name, "2026-01-01T12:00:00Z");
            else if (argument.name.equals("end")) result.put(argument.name, "2026-01-01T13:00:00Z");
            else if (argument.name.equals("path")) result.put(argument.name, "Folder/example.txt");
            else if (argument.name.equals("query")) result.put(argument.name, "example");
            else result.put(argument.name, "opaque-id");
        }
        return result;
    }

    private static MockResponse capabilities(String capability, boolean available) {
        return json("{\"data\":{\"api_version\":\"1\",\"operations\":{\"" + capability + "\":{\"available\":" + available + "}}}}");
    }

    private static MockResponse json(String body) {
        return new MockResponse().setHeader("Content-Type", "application/json; charset=utf-8").setBody(body);
    }

    private static String repeat(String value, int count) {
        char[] chars = new char[count];
        Arrays.fill(chars, value.charAt(0));
        return new String(chars);
    }

    private static BridgeException assertError(String code, Runnable action) {
        try {
            action.run();
            fail("Expected " + code);
            return null;
        } catch (BridgeException error) {
            assertEquals(code, error.getCode());
            return error;
        }
    }
}
