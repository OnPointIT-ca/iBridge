package ca.onpoint.ibridge;

import android.app.Application;
import android.os.Handler;
import android.os.Looper;
import android.net.Uri;
import androidx.annotation.NonNull;
import androidx.lifecycle.AndroidViewModel;
import androidx.lifecycle.LiveData;
import androidx.lifecycle.MutableLiveData;
import ca.onpoint.ibridge.api.BridgeClient;
import ca.onpoint.ibridge.api.BridgeException;
import ca.onpoint.ibridge.api.ReadOperation;
import org.json.JSONObject;
import java.time.OffsetDateTime;
import java.time.temporal.ChronoUnit;
import java.time.format.DateTimeFormatter;
import java.io.OutputStream;
import java.util.LinkedHashMap;
import java.util.Map;
import java.util.concurrent.ExecutorService;
import java.util.concurrent.Executors;

/** Keeps requests and private, in-memory results across activity recreation. */
public final class BridgeViewModel extends AndroidViewModel {
    enum Screen { CONNECT, HOME, SERVICE, FORM, RESULTS, PICKER }
    final MutableLiveData<Integer> changes = new MutableLiveData<>(0);
    private final ExecutorService worker = Executors.newSingleThreadExecutor();
    private final Handler main = new Handler(Looper.getMainLooper());
    private final CredentialStore credentials;
    private BridgeClient client;
    private int generation;
    Screen screen = Screen.CONNECT;
    boolean busy;
    String error = "";
    String origin = "";
    String connectionToken = "";
    boolean remember = true;
    String service = "";
    JSONObject capabilities;
    JSONObject result;
    JSONObject choices;
    ReadOperation operation;
    ReadOperation pickerOperation;
    String pickerField;
    byte[] pendingDownload;
    String notice = "";
    final Map<String, String> draft = new LinkedHashMap<>();
    final Map<String, String> selectionNames = new LinkedHashMap<>();
    private Map<String, String> submitted = new LinkedHashMap<>();
    // Cursors represent the currently displayed page, not an accumulated data cache.
    private String currentCursor;
    private String pickerCursor;

    public BridgeViewModel(@NonNull Application application) {
        super(application);
        credentials = new CredentialStore(application);
        busy = true;
        final int startup = generation;
        worker.execute(() -> {
            try {
                CredentialStore.Credentials saved = credentials.load();
                main.post(() -> {
                    if (startup != generation) return;
                    busy = false;
                    if (saved != null) connect(saved.origin, saved.token, true);
                    else changed();
                });
            } catch (Exception ignored) {
                main.post(() -> {
                    if (startup != generation) return;
                    busy = false; error = "Saved connection could not be unlocked. Enter your bridge details again."; changed();
                });
            }
        });
    }

    LiveData<Integer> changes() { return changes; }
    private void changed() { changes.setValue(changes.getValue() + 1); }

    void connect(String url, String token, boolean save) {
        if (busy) return;
        final BridgeClient next;
        try {
            origin = BridgeClient.validateOrigin(url.trim());
            next = new BridgeClient(origin, token);
        } catch (BridgeException invalid) { error = invalid.getMessage(); changed(); return; }
        connectionToken = token;
        remember = save;
        if (client != null) client.cancel();
        client = next;
        busy = true;
        error = "";
        int request = ++generation;
        changed();
        worker.execute(() -> {
            try {
                JSONObject response = next.capabilities();
                try {
                    if (save) credentials.save(origin, token);
                    else credentials.clear();
                } catch (Exception ignored) {
                    postError(request, "The connection could not be saved securely. Try again, or turn off Remember this connection.");
                    return;
                }
                main.post(() -> {
                    if (request != generation) return;
                    capabilities = response;
                    connectionToken = "";
                    screen = Screen.HOME;
                    busy = false;
                    changed();
                });
            } catch (BridgeException failure) { postError(request, failure.getMessage()); }
        });
    }

    boolean available(ReadOperation op) {
        JSONObject data = capabilities == null ? null : capabilities.optJSONObject("data");
        JSONObject operations = data == null ? null : data.optJSONObject("operations");
        JSONObject entry = operations == null ? null : operations.optJSONObject(op.capability);
        return entry != null && Boolean.TRUE.equals(entry.opt("available"));
    }

    void openService(String name) { service = name; screen = Screen.SERVICE; error = ""; changed(); }

    void open(ReadOperation op, Map<String, String> initial) {
        operation = op;
        draft.clear();
        selectionNames.clear();
        for (ReadOperation.Argument argument : op.arguments()) {
            if (argument.defaultValue != null) draft.put(argument.name, argument.defaultValue);
        }
        if (op == ReadOperation.EVENTS) {
            OffsetDateTime now = OffsetDateTime.now().truncatedTo(ChronoUnit.MINUTES);
            DateTimeFormatter format = DateTimeFormatter.ofPattern("uuuu-MM-dd'T'HH:mm:ssXXX");
            draft.put("start", now.format(format));
            draft.put("end", now.plusDays(7).format(format));
        }
        draft.putAll(initial);
        currentCursor = null;
        result = null;
        error = "";
        notice = "";
        screen = Screen.FORM;
        boolean hasFields = op.arguments().stream().anyMatch(a -> !a.name.equals("limit") && !a.name.equals("cursor"));
        if (hasFields) changed(); else submit();
    }

    void submit() {
        if (busy) return;
        submitted = new LinkedHashMap<>();
        for (Map.Entry<String, String> entry : draft.entrySet()) {
            if (!entry.getValue().isEmpty()) submitted.put(entry.getKey(), entry.getValue());
        }
        currentCursor = null;
        fetchPage(null);
    }

    void fetchPage(String cursor) {
        if (busy || client == null) return;
        final Map<String, String> args = new LinkedHashMap<>(submitted);
        if (cursor != null) args.put("cursor", cursor); else args.remove("cursor");
        runRead(operation, args, response -> {
            result = response;
            currentCursor = cursor;
            screen = Screen.RESULTS;
        });
    }

    void refresh() {
        if (busy || client == null) return;
        if (screen == Screen.RESULTS) { fetchPage(currentCursor); return; }
        if (screen == Screen.PICKER) { loadChoices(pickerCursor); return; }
        busy = true;
        error = "";
        int request = ++generation;
        BridgeClient active = client;
        changed();
        worker.execute(() -> {
            try {
                JSONObject response = active.capabilities();
                main.post(() -> {
                    if (request != generation) return;
                    capabilities = response; busy = false; changed();
                });
            } catch (BridgeException failure) { postError(request, failure.getMessage()); }
        });
    }

    static ReadOperation selector(String field) {
        switch (field) {
            case "calendar_id": return ReadOperation.CALENDARS;
            case "list_id": return ReadOperation.REMINDER_LISTS;
            case "root_id": return ReadOperation.DRIVE_ROOTS;
            case "folder_id": return ReadOperation.NOTE_FOLDERS;
            case "chat_id": return ReadOperation.MESSAGE_CHATS;
            default: return null;
        }
    }

    void choose(String field) {
        pickerField = field;
        pickerOperation = selector(field);
        pickerCursor = null;
        choices = null;
        loadChoices(null);
    }

    void loadChoices(String cursor) {
        if (busy) return;
        Map<String, String> args = new LinkedHashMap<>();
        if (cursor != null) args.put("cursor", cursor);
        runRead(pickerOperation, args, response -> {
            choices = response; pickerCursor = cursor; screen = Screen.PICKER;
        });
    }

    void select(String id, String name) {
        draft.put(pickerField, id);
        selectionNames.put(pickerField, name);
        screen = Screen.FORM;
        error = "";
        changed();
    }

    private interface Received { void accept(JSONObject response); }

    private void runRead(ReadOperation op, Map<String, String> args, Received receive) {
        if (client == null) return;
        busy = true;
        error = "";
        int request = ++generation;
        BridgeClient active = client;
        changed();
        worker.execute(() -> {
            try {
                JSONObject response = active.read(op.capability, args);
                main.post(() -> {
                    if (request != generation) return;
                    receive.accept(response); busy = false; changed();
                });
            } catch (BridgeException failure) { postError(request, failure.getMessage()); }
        });
    }

    private void postError(int request, String message) {
        main.post(() -> {
            if (request != generation) return;
            busy = false; error = message; changed();
        });
    }

    boolean back() {
        if (busy) return true;
        error = "";
        switch (screen) {
            case PICKER: screen = Screen.FORM; break;
            case RESULTS: screen = Screen.FORM; break;
            case FORM: screen = Screen.SERVICE; result = null; choices = null; break;
            case SERVICE: screen = Screen.HOME; break;
            default: return false;
        }
        changed();
        return true;
    }

    void saveDocument(Uri destination) {
        byte[] bytes = pendingDownload;
        pendingDownload = null;
        if (bytes == null || destination == null) return;
        busy = true;
        int request = ++generation;
        changed();
        worker.execute(() -> {
            try {
                try (OutputStream output = getApplication().getContentResolver().openOutputStream(destination, "wt")) {
                    if (output == null) throw new java.io.IOException();
                    output.write(bytes);
                }
                main.post(() -> {
                    if (request != generation) return;
                    busy = false; notice = "File saved to your selected location."; changed();
                });
            } catch (Exception ignored) { postError(request, "Could not save the file. Check the selected location and try again."); }
        });
    }

    void disconnect() {
        final int request = ++generation;
        if (client != null) client.cancel();
        client = null;
        capabilities = null;
        result = null;
        choices = null;
        draft.clear();
        submitted.clear();
        selectionNames.clear();
        connectionToken = "";
        pendingDownload = null;
        notice = "";
        screen = Screen.CONNECT;
        busy = true;
        error = "";
        changed();
        worker.execute(() -> {
            String failure = "";
            try { credentials.clear(); }
            catch (Exception ignored) { failure = "Saved connection could not be removed. Clear iBridge's app storage in Android Settings."; }
            final String message = failure;
            main.post(() -> {
                if (request != generation) return;
                busy = false; error = message; changed();
            });
        });
    }

    @Override protected void onCleared() {
        ++generation;
        if (client != null) client.cancel();
        worker.shutdownNow();
        main.removeCallbacksAndMessages(null);
    }
}
