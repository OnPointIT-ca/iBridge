package ca.onpoint.ibridge.api;

import org.json.JSONException;
import org.json.JSONArray;
import org.json.JSONObject;

import java.io.ByteArrayOutputStream;
import java.io.IOException;
import java.io.InputStream;
import java.io.InterruptedIOException;
import java.net.URI;
import java.net.URISyntaxException;
import java.nio.ByteBuffer;
import java.nio.charset.CharacterCodingException;
import java.nio.charset.CodingErrorAction;
import java.nio.charset.StandardCharsets;
import java.util.HashSet;
import java.util.Base64;
import java.util.Map;
import java.util.Set;
import java.util.concurrent.TimeUnit;
import java.util.concurrent.atomic.AtomicBoolean;

import okhttp3.Call;
import okhttp3.HttpUrl;
import okhttp3.MediaType;
import okhttp3.OkHttpClient;
import okhttp3.Request;
import okhttp3.Response;
import okhttp3.ResponseBody;

/** Synchronous read-only client. Call off the main thread; cancel on disconnect. */
public final class BridgeClient {
    public static final int MAX_RESPONSE_BYTES = 2 * 1024 * 1024;
    private final HttpUrl origin;
    private final String token;
    private final OkHttpClient http;
    private final Set<Call> active = new HashSet<>();
    private boolean cancelled;

    public BridgeClient(String origin, String token) {
        this(origin, token, new OkHttpClient());
    }

    // Package-local injection trusts the test CA without weakening production TLS.
    BridgeClient(String origin, String token, OkHttpClient transport) {
        this.origin = HttpUrl.get(validateOrigin(origin));
        this.token = validateToken(token);
        this.http = transport.newBuilder()
                .followRedirects(false)
                .followSslRedirects(false)
                .retryOnConnectionFailure(false)
                .cache(null)
                .callTimeout(20, TimeUnit.SECONDS)
                .connectTimeout(20, TimeUnit.SECONDS)
                .readTimeout(20, TimeUnit.SECONDS)
                .writeTimeout(20, TimeUnit.SECONDS)
                .addNetworkInterceptor(chain -> {
                    Attempt attempt = chain.request().tag(Attempt.class);
                    // OkHttp can follow up a 503/421 even with connection retries disabled.
                    // This guard prevents any second dispatch for the same logical request.
                    if (attempt == null || !attempt.sent.compareAndSet(false, true)) {
                        throw new IOException("Automatic follow-up refused");
                    }
                    return chain.proceed(chain.request());
                }).build();
    }

    public static String validateOrigin(String value) {
        if (value == null || value.isEmpty()) throw invalidOrigin();
        for (int index = 0; index < value.length(); index++) {
            char character = value.charAt(index);
            if (Character.isWhitespace(character) || Character.isSpaceChar(character)
                    || character <= 32 || character == 127 || character == '\\') throw invalidOrigin();
        }
        try {
            URI uri = new URI(value);
            if (!"https".equalsIgnoreCase(uri.getScheme()) || uri.getHost() == null
                    || uri.getRawUserInfo() != null || uri.getRawQuery() != null || uri.getRawFragment() != null
                    || !(uri.getRawPath().isEmpty() || uri.getRawPath().equals("/"))
                    || uri.getPort() == 0 || uri.getPort() > 65535 || uri.getPort() < -1
                    || uri.getRawAuthority().endsWith(":")) throw invalidOrigin();
            HttpUrl parsed = HttpUrl.get(value);
            return parsed.toString().replaceFirst("/$", "");
        } catch (URISyntaxException | IllegalArgumentException exception) {
            throw invalidOrigin();
        }
    }

    public static String validateToken(String value) {
        if (value == null || value.length() > 8192 || !value.matches("[A-Za-z0-9._~+/-]+=*")) {
            throw new BridgeException("configuration_error", "Enter a valid nonempty bearer token without whitespace.");
        }
        return value;
    }

    public JSONObject capabilities() {
        JSONObject envelope = request(origin.newBuilder().encodedPath("/api/v1/system/capabilities").build());
        JSONObject data = envelope.optJSONObject("data");
        if (data == null || !"1".equals(data.opt("api_version"))) {
            throw new BridgeException("incompatible_bridge", "This app requires iBridge HTTP contract v1.");
        }
        if (!(data.opt("operations") instanceof JSONObject)) {
            throw new BridgeException("invalid_response", "Bridge capability map is missing or invalid.");
        }
        return envelope;
    }

    public JSONObject read(String capability, Map<String, String> arguments) {
        ReadOperation operation = ReadOperation.forCapability(capability);
        Map<String, String> values = operation.validate(arguments);
        JSONObject available = capabilities().optJSONObject("data").optJSONObject("operations").optJSONObject(capability);
        if (available == null || !Boolean.TRUE.equals(available.opt("available"))) {
            throw new BridgeException("capability_unavailable", "This operation is unavailable or not authorized on the Mac.");
        }
        HttpUrl.Builder url = origin.newBuilder().encodedPath("/api/v1");
        for (String segment : operation.route.substring(1).split("/")) {
            if (segment.startsWith("{")) {
                String key = segment.substring(1, segment.length() - 1);
                url.addPathSegment(values.get(key));
            } else url.addPathSegment(segment);
        }
        for (Map.Entry<String, String> entry : values.entrySet()) {
            if (!operation.route.contains("{" + entry.getKey() + "}")) {
                url.addQueryParameter(entry.getKey(), entry.getValue());
            }
        }
        JSONObject result = request(url.build());
        if (operation.paginated()) validatePage(result, operation, Integer.parseInt(values.get("limit")));
        if (operation == ReadOperation.DRIVE_READ) validateFile(result, Integer.parseInt(values.get("max_bytes")));
        return result;
    }

    private static void validatePage(JSONObject envelope, ReadOperation operation, int limit) {
        JSONObject data = envelope.optJSONObject("data");
        JSONArray items = data.optJSONArray("items");
        if (items == null || items.length() > limit) throw invalidEnvelope();
        if (data.has("next_cursor") && !data.isNull("next_cursor")) {
            Object cursor = data.opt("next_cursor");
            if (!(cursor instanceof String) || ((String) cursor).isEmpty()
                    || ((String) cursor).codePointCount(0, ((String) cursor).length()) > 4096) throw invalidEnvelope();
        }
        boolean namedContainer = operation == ReadOperation.CALENDARS || operation == ReadOperation.REMINDER_LISTS
                || operation == ReadOperation.DRIVE_ROOTS || operation == ReadOperation.NOTE_FOLDERS;
        for (int index = 0; index < items.length(); index++) {
            JSONObject item = items.optJSONObject(index);
            if (item == null || !(item.opt("id") instanceof String) || item.optString("id").isEmpty()
                    || item.optString("id").codePointCount(0, item.optString("id").length()) > 512
                    || (namedContainer && !(item.opt("name") instanceof String))) throw invalidEnvelope();
        }
    }

    private static void validateFile(JSONObject envelope, int maximum) {
        JSONObject data = envelope.optJSONObject("data");
        if (data == null) throw invalidEnvelope();
        if ("downloading".equals(data.opt("state"))) {
            if (data.has("content_base64")) throw invalidEnvelope();
            return;
        }
        if (!"ready".equals(data.opt("state")) || !(data.opt("content_base64") instanceof String)
                || !(data.opt("media_type") instanceof String) || data.optString("media_type").isEmpty()
                || !(data.opt("size_bytes") instanceof Number)) throw invalidEnvelope();
        Number size = (Number) data.opt("size_bytes");
        if (!(size instanceof Integer || size instanceof Long) || size.longValue() < 0
                || size.longValue() > maximum) throw invalidEnvelope();
        String encoded = data.optString("content_base64");
        try {
            byte[] bytes = Base64.getDecoder().decode(encoded);
            if (bytes.length != size.longValue() || bytes.length > maximum
                    || !Base64.getEncoder().encodeToString(bytes).equals(encoded)) throw invalidEnvelope();
        } catch (IllegalArgumentException exception) {
            throw invalidEnvelope();
        }
    }

    /** Permanently closes this client and prevents a pending discovery from dispatching a read. */
    public synchronized void cancel() {
        cancelled = true;
        for (Call call : active) call.cancel();
        http.connectionPool().evictAll();
    }

    private JSONObject request(HttpUrl url) {
        Request request = new Request.Builder().url(url).get()
                .header("Authorization", "Bearer " + token)
                .header("Accept", "application/json")
                .tag(Attempt.class, new Attempt()).build();
        Call call;
        synchronized (this) {
            if (cancelled) throw cancelled();
            call = http.newCall(request);
            active.add(call);
        }
        try (Response response = call.execute()) {
            if (!response.isSuccessful()) throw statusError(response.code());
            ResponseBody body = response.body();
            if (body == null) throw invalidEnvelope();
            MediaType mediaType = body.contentType();
            if (mediaType == null || !mediaType.type().equals("application") || !mediaType.subtype().equals("json")
                    || !StandardCharsets.UTF_8.equals(mediaType.charset(StandardCharsets.UTF_8))) {
                throw new BridgeException("invalid_response", "Bridge response must be UTF-8 JSON.");
            }
            if (body.contentLength() > MAX_RESPONSE_BYTES) throw tooLarge();
            ByteArrayOutputStream bytes = new ByteArrayOutputStream();
            try (InputStream input = body.byteStream()) {
                byte[] chunk = new byte[8192];
                int count;
                while ((count = input.read(chunk)) != -1) {
                    if (bytes.size() + count > MAX_RESPONSE_BYTES) throw tooLarge();
                    bytes.write(chunk, 0, count);
                }
            }
            String json = StandardCharsets.UTF_8.newDecoder()
                    .onMalformedInput(CodingErrorAction.REPORT).onUnmappableCharacter(CodingErrorAction.REPORT)
                    .decode(ByteBuffer.wrap(bytes.toByteArray())).toString();
            StrictJson.validate(json);
            JSONObject result = new JSONObject(json);
            if (!(result.opt("data") instanceof JSONObject) || result.has("error")
                    || (result.has("meta") && !(result.opt("meta") instanceof JSONObject))) throw invalidEnvelope();
            synchronized (this) {
                if (cancelled) throw cancelled();
            }
            return result;
        } catch (JSONException | CharacterCodingException exception) {
            throw invalidEnvelope();
        } catch (InterruptedIOException exception) {
            if (call.isCanceled()) {
                synchronized (this) {
                    if (cancelled) throw cancelled();
                }
            }
            throw new BridgeException("timeout", "Bridge request timed out.");
        } catch (IOException exception) {
            synchronized (this) {
                if (cancelled) throw cancelled();
            }
            throw new BridgeException("connection_failed", "Could not establish a verified connection to the bridge.");
        } finally {
            synchronized (this) {
                active.remove(call);
            }
        }
    }

    private static BridgeException statusError(int status) {
        if (status >= 300 && status < 400) return new BridgeException("redirect_refused", "Bridge redirects are not followed; check the configured origin.");
        switch (status) {
            case 400:
            case 422: return new BridgeException("invalid_request", "Bridge rejected the arguments.");
            case 401: return new BridgeException("authentication_failed", "Bridge token is missing, expired, or invalid.");
            case 403: return new BridgeException("permission_denied", "Bridge denied this operation or resource.");
            case 404: return new BridgeException("not_found", "Bridge route or resource was not found.");
            case 409: return new BridgeException("conflict", "Bridge reported a conflict; inspect the resource before retrying.");
            case 413: return new BridgeException("request_too_large", "Request exceeds the bridge limit.");
            case 429: return new BridgeException("rate_limited", "Bridge rate limit reached; retry later.");
            case 503: return new BridgeException("unavailable", "Bridge or Apple adapter is temporarily unavailable.");
            default: return new BridgeException("http_error", "Bridge request failed.");
        }
    }

    private static BridgeException invalidOrigin() {
        return new BridgeException("configuration_error", "Use an HTTPS origin without credentials, a path, query, or fragment.");
    }

    private static BridgeException invalidEnvelope() {
        return new BridgeException("invalid_response", "Bridge response does not match the v1 envelope.");
    }

    private static BridgeException tooLarge() {
        return new BridgeException("response_too_large", "Bridge response exceeds 2 MiB; narrow the request.");
    }

    private static BridgeException cancelled() {
        return new BridgeException("cancelled", "Bridge request was cancelled.");
    }

    private static final class Attempt {
        final AtomicBoolean sent = new AtomicBoolean();
    }
}
