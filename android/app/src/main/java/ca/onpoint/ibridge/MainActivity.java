package ca.onpoint.ibridge;

import android.app.AlertDialog;
import android.app.DatePickerDialog;
import android.app.TimePickerDialog;
import android.content.Intent;
import android.graphics.Color;
import android.graphics.Typeface;
import android.graphics.drawable.GradientDrawable;
import android.os.Bundle;
import android.text.Editable;
import android.text.InputType;
import android.text.TextWatcher;
import android.view.Gravity;
import android.view.View;
import android.view.ViewGroup;
import android.view.inputmethod.InputMethodManager;
import android.widget.Button;
import android.widget.CheckBox;
import android.widget.EditText;
import android.widget.LinearLayout;
import android.widget.ProgressBar;
import android.widget.ScrollView;
import android.widget.TextView;
import android.widget.Spinner;
import android.widget.ArrayAdapter;
import android.widget.AdapterView;
import androidx.activity.ComponentActivity;
import androidx.activity.OnBackPressedCallback;
import androidx.activity.result.ActivityResultLauncher;
import androidx.activity.result.contract.ActivityResultContracts;
import androidx.core.view.ViewCompat;
import androidx.core.view.WindowInsetsCompat;
import androidx.lifecycle.ViewModelProvider;
import ca.onpoint.ibridge.api.ReadOperation;
import org.json.JSONArray;
import org.json.JSONObject;
import java.nio.charset.StandardCharsets;
import java.util.Base64;
import java.util.Collections;
import java.util.Iterator;
import java.util.LinkedHashMap;
import java.util.Locale;
import java.util.Map;
import java.time.LocalDateTime;
import java.time.OffsetDateTime;
import java.time.ZoneId;
import java.time.format.DateTimeFormatter;
import java.time.format.FormatStyle;

/** Native Android client. Server content is always rendered as plain text. */
public final class MainActivity extends ComponentActivity {
    private static final int INK = Color.rgb(20, 37, 62);
    private static final int MUTED = Color.rgb(85, 101, 124);
    private static final int BLUE = Color.rgb(49, 91, 232);
    private static final String[] SERVICES = {"Calendar", "Reminders", "Contacts", "Drive", "Notes", "Messages"};
    private static final String[] PREFIXES = {"calendar.", "reminders.", "contacts.", "drive.", "notes.", "messages."};
    private static final String[] DESCRIPTIONS = {"Your calendars and upcoming events", "Lists and reminders from your Mac", "Find the people you need", "Browse your authorized iCloud folders", "Search and read your notes", "Read conversations on your Mac"};
    private BridgeViewModel model;
    private LinearLayout content;
    private final ActivityResultLauncher<Intent> saveFile = registerForActivityResult(
            new ActivityResultContracts.StartActivityForResult(), result -> {
                if (result.getResultCode() == RESULT_OK && result.getData() != null) model.saveDocument(result.getData().getData());
                else model.pendingDownload = null;
            });

    @Override protected void onCreate(Bundle savedInstanceState) {
        super.onCreate(savedInstanceState);
        model = new ViewModelProvider(this).get(BridgeViewModel.class);
        getOnBackPressedDispatcher().addCallback(this, new OnBackPressedCallback(true) {
            @Override public void handleOnBackPressed() { if (!model.back()) finish(); }
        });
        model.changes().observe(this, ignored -> render());
    }

    private void render() {
        ScrollView scroll = new ScrollView(this);
        scroll.setFillViewport(true);
        scroll.setBackgroundColor(Color.rgb(244, 246, 251));
        content = column();
        content.setPadding(dp(24), dp(20), dp(24), dp(28));
        content.setFocusableInTouchMode(true);
        scroll.addView(content);
        ViewCompat.setOnApplyWindowInsetsListener(scroll, (view, insets) -> {
            androidx.core.graphics.Insets bars = insets.getInsets(WindowInsetsCompat.Type.systemBars() | WindowInsetsCompat.Type.ime());
            scroll.setPadding(bars.left, bars.top, bars.right, bars.bottom);
            return insets;
        });
        setContentView(scroll);
        if (model.screen != BridgeViewModel.Screen.CONNECT && model.screen != BridgeViewModel.Screen.HOME) {
            button(content, "‹ Back", () -> model.back());
        }
        if (model.busy) {
            ProgressBar progress = new ProgressBar(this, null, android.R.attr.progressBarStyleHorizontal);
            progress.setIndeterminate(true);
            progress.setContentDescription("Connecting to your bridge");
            content.addView(progress, new LinearLayout.LayoutParams(-1, dp(4)));
        }
        switch (model.screen) {
            case CONNECT: connection(); break;
            case HOME: home(); break;
            case SERVICE: service(); break;
            case FORM: form(); break;
            case RESULTS: results(false); break;
            case PICKER: results(true); break;
        }
        if (!model.error.isEmpty()) {
            TextView error = text(content, model.error, 16, Color.rgb(156, 37, 54));
            error.setAccessibilityLiveRegion(View.ACCESSIBILITY_LIVE_REGION_POLITE);
        }
        if (!model.notice.isEmpty()) text(content, model.notice, 14, MUTED);
    }

    private void connection() {
        text(content, "iBridge", 34, BLUE).setTypeface(null, Typeface.BOLD);
        title("Your Mac, within reach.");
        text(content, "Connect to your personal bridge to browse the Apple services you authorize on your Mac.", 17, MUTED);
        LinearLayout card = card(content);
        EditText origin = field(card, "Bridge address", "https://your-mac.example.ts.net", model.origin,
                InputType.TYPE_CLASS_TEXT | InputType.TYPE_TEXT_VARIATION_URI, value -> model.origin = value);
        EditText token = field(card, "Client token", "Token issued by your bridge", model.connectionToken,
                InputType.TYPE_CLASS_TEXT | InputType.TYPE_TEXT_VARIATION_PASSWORD, value -> model.connectionToken = value);
        token.setSaveEnabled(false);
        token.setImportantForAutofill(View.IMPORTANT_FOR_AUTOFILL_NO);
        CheckBox remember = new CheckBox(this);
        remember.setText(R.string.remember_connection);
        remember.setTextColor(INK);
        remember.setChecked(model.remember);
        remember.setEnabled(!model.busy);
        remember.setOnCheckedChangeListener((view, checked) -> model.remember = checked);
        card.addView(remember);
        primary(card, model.busy ? "Connecting…" : "Connect", () -> {
            hideKeyboard();
            model.connect(origin.getText().toString(), token.getText().toString(), remember.isChecked());
        });
        button(card, "Forget saved connection", model::disconnect);
        text(content, "Use a bridge client token, never your Apple Account password. Saved credentials are encrypted on this device.", 14, MUTED);
        text(content, "Your Mac must be online and running the bridge. Use its HTTPS address, and connect to the same private network when needed.", 14, MUTED);
    }

    private void home() {
        text(content, "iBridge", 30, BLUE).setTypeface(null, Typeface.BOLD);
        title("Your services");
        text(content, model.origin, 14, MUTED);
        text(content, "Available through your Mac", 16, MUTED);
        for (int i = 0; i < SERVICES.length; i++) {
            String service = SERVICES[i];
            String prefix = PREFIXES[i];
            int count = 0;
            for (ReadOperation op : ReadOperation.values()) if (op.capability.startsWith(prefix) && model.available(op)) count++;
            LinearLayout row = card(content);
            text(row, service, 21, INK).setTypeface(null, Typeface.BOLD);
            text(row, DESCRIPTIONS[i], 15, MUTED);
            text(row, count > 0 ? "Available" : "Not available for this connection", 13, count > 0 ? BLUE : MUTED);
            Button open = button(row, "Open " + service, () -> model.openService(service));
            open.setEnabled(!model.busy && count > 0);
        }
        observation(model.capabilities);
        button(content, "Refresh services", model::refresh);
        button(content, "Disconnect and forget", model::disconnect);
    }

    private void service() {
        title(model.service);
        if (model.service.equals("Notes") || model.service.equals("Messages")) {
            text(content, "Experimental · Available only after these features are enabled and tested on your Mac.", 14, MUTED);
        }
        String prefix = prefix(model.service);
        for (ReadOperation op : ReadOperation.values()) {
            if (!op.capability.startsWith(prefix)) continue;
            Button action = button(content, label(op), () -> model.open(op, Collections.emptyMap()));
            action.setEnabled(!model.busy && model.available(op));
            if (!model.available(op)) text(content, "Not enabled by your bridge", 13, MUTED);
        }
        button(content, "Refresh availability", model::refresh);
    }

    private void form() {
        title(label(model.operation));
        text(content, "Choose what to read from your Mac.", 16, MUTED);
        for (ReadOperation.Argument arg : model.operation.arguments()) {
            if (arg.name.equals("cursor") || arg.name.equals("limit")) continue;
            String current = model.draft.getOrDefault(arg.name, "");
            String name = argumentLabel(arg.name) + (arg.required ? "" : " (optional)");
            if (arg.kind == ReadOperation.Kind.DATE) {
                dateField(name, arg.name, current);
                continue;
            }
            if (arg.kind == ReadOperation.Kind.BOOLEAN) {
                completionField(current);
                continue;
            }
            int type = arg.kind == ReadOperation.Kind.INTEGER ? InputType.TYPE_CLASS_NUMBER : InputType.TYPE_CLASS_TEXT;
            field(content, name, hint(arg.name), current, type, value -> {
                model.draft.put(arg.name, value);
                model.selectionNames.remove(arg.name);
            });
            if (model.selectionNames.containsKey(arg.name)) text(content, model.selectionNames.get(arg.name), 14, BLUE);
            ReadOperation selector = BridgeViewModel.selector(arg.name);
            if (selector != null) {
                Button choose = button(content, "Choose " + argumentLabel(arg.name).toLowerCase(Locale.ROOT), () -> {
                    hideKeyboard(); model.choose(arg.name);
                });
                choose.setEnabled(!model.busy && model.available(selector));
            }
        }
        primary(content, "Read from Mac", () -> { hideKeyboard(); model.submit(); });
    }

    private void dateField(String label, String key, String value) {
        text(content, label, 14, INK);
        OffsetDateTime selected;
        try { selected = OffsetDateTime.parse(value); }
        catch (java.time.DateTimeException ignored) { selected = OffsetDateTime.now(); }
        OffsetDateTime initial = selected;
        String display = initial.format(DateTimeFormatter.ofLocalizedDateTime(FormatStyle.MEDIUM));
        button(content, display, () -> new DatePickerDialog(this, (picker, year, month, day) -> {
            new TimePickerDialog(this, (clock, hour, minute) -> {
                String timestamp = LocalDateTime.of(year, month + 1, day, hour, minute)
                        .atZone(ZoneId.systemDefault()).toOffsetDateTime()
                        .format(DateTimeFormatter.ofPattern("uuuu-MM-dd'T'HH:mm:ssXXX"));
                model.draft.put(key, timestamp);
                render();
            }, initial.getHour(), initial.getMinute(), android.text.format.DateFormat.is24HourFormat(this)).show();
        }, initial.getYear(), initial.getMonthValue() - 1, initial.getDayOfMonth()).show());
        text(content, ZoneId.systemDefault().getId(), 12, MUTED);
    }

    private void completionField(String current) {
        text(content, "Show reminders", 14, INK);
        Spinner status = new Spinner(this);
        ArrayAdapter<String> adapter = new ArrayAdapter<>(this, android.R.layout.simple_spinner_item,
                new String[]{"Any status", "Incomplete", "Completed"});
        adapter.setDropDownViewResource(android.R.layout.simple_spinner_dropdown_item);
        status.setAdapter(adapter);
        status.setSelection(current.equals("true") ? 2 : current.equals("false") ? 1 : 0);
        status.setContentDescription("Reminder completion status");
        status.setMinimumHeight(dp(48));
        status.setEnabled(!model.busy);
        status.setOnItemSelectedListener(new AdapterView.OnItemSelectedListener() {
            @Override public void onItemSelected(AdapterView<?> parent, View view, int position, long id) {
                model.draft.put("completed", position == 0 ? "" : position == 1 ? "false" : "true");
            }
            @Override public void onNothingSelected(AdapterView<?> parent) { }
        });
        content.addView(status, new LinearLayout.LayoutParams(-1, -2));
    }

    private void results(boolean picking) {
        ReadOperation op = picking ? model.pickerOperation : model.operation;
        title(picking ? "Choose " + argumentLabel(model.pickerField).toLowerCase(Locale.ROOT) : label(op));
        JSONObject envelope = picking ? model.choices : model.result;
        if (envelope == null) return;
        observation(envelope);
        JSONObject data = envelope.optJSONObject("data");
        if (data == null) return;
        JSONArray items = data.optJSONArray("items");
        if (items != null) {
            if (items.length() == 0) text(content, "No results on this page.", 18, MUTED);
            for (int i = 0; i < items.length(); i++) {
                JSONObject item = items.optJSONObject(i);
                if (item == null) continue;
                String title = itemTitle(item);
                LinearLayout row = card(content);
                text(row, title, 20, INK).setTypeface(null, Typeface.BOLD);
                if (picking) {
                    String id = item.optString("id", "");
                    Button select = button(row, "Select", () -> model.select(id, title));
                    select.setEnabled(!model.busy && item.opt("id") instanceof String && !id.isEmpty());
                } else {
                    String preview = preview(item);
                    if (!preview.isEmpty()) text(row, preview, 14, MUTED);
                    button(row, "Details", () -> details(title, item));
                    drillDown(row, op, item);
                }
            }
            String next = data.opt("next_cursor") instanceof String ? data.optString("next_cursor") : "";
            if (!next.isEmpty()) {
                button(content, "Next page", () -> { if (picking) model.loadChoices(next); else model.fetchPage(next); });
            }
        } else if (op == ReadOperation.DRIVE_READ) {
            file(data);
        } else {
            text(content, readable(data, 0), 17, INK).setTextIsSelectable(true);
        }
        button(content, "Refresh this page", model::refresh);
    }

    private void drillDown(LinearLayout row, ReadOperation op, JSONObject item) {
        String id = item.opt("id") instanceof String ? item.optString("id") : "";
        ReadOperation target = null;
        Map<String, String> args = new LinkedHashMap<>();
        switch (op) {
            case CALENDARS: target = ReadOperation.EVENTS; args.put("calendar_id", id); break;
            case REMINDER_LISTS: target = ReadOperation.REMINDERS; args.put("list_id", id); break;
            case DRIVE_ROOTS: target = ReadOperation.DRIVE_LIST; args.put("root_id", id); break;
            case NOTE_FOLDERS: target = ReadOperation.NOTES_SEARCH; args.put("folder_id", id); break;
            case NOTES_SEARCH: target = ReadOperation.NOTES_READ; args.put("note_id", id); break;
            case MESSAGE_CHATS: target = ReadOperation.MESSAGES_READ; args.put("chat_id", id); break;
            case DRIVE_LIST:
            case DRIVE_SEARCH:
                if (item.opt("path") instanceof String) {
                    target = item.optBoolean("is_directory", false) || item.optString("type").equals("directory")
                            ? ReadOperation.DRIVE_LIST : ReadOperation.DRIVE_READ;
                    args.put("root_id", model.draft.getOrDefault("root_id", ""));
                    args.put("path", item.optString("path"));
                }
                break;
            default: break;
        }
        if (target != null && model.available(target) && (!id.isEmpty() || args.containsKey("path"))) {
            ReadOperation selected = target;
            button(row, label(target), () -> model.open(selected, args));
        }
    }

    private void file(JSONObject data) {
        if (data.optString("state").equals("downloading")) {
            text(content, "Your Mac is downloading this file from iCloud. Refresh this page to check again.", 17, MUTED);
            return;
        }
        byte[] bytes = Base64.getDecoder().decode(data.optString("content_base64"));
        String media = data.optString("media_type", "application/octet-stream");
        text(content, bytes.length + " bytes · " + media, 15, MUTED);
        if (media.startsWith("text/")) {
            String preview = new String(bytes, StandardCharsets.UTF_8);
            text(content, preview.length() > 16000 ? preview.substring(0, 16000) + "\n… Preview shortened. Save to read the full file." : preview, 16, INK).setTextIsSelectable(true);
        }
        primary(content, "Save a copy", () -> {
            String path = model.draft.getOrDefault("path", "download");
            String filename = path.substring(path.lastIndexOf('/') + 1);
            model.pendingDownload = bytes;
            Intent intent = new Intent(Intent.ACTION_CREATE_DOCUMENT);
            intent.addCategory(Intent.CATEGORY_OPENABLE);
            intent.setType(media.matches("[A-Za-z0-9!#$&^_.+-]+/[A-Za-z0-9!#$&^_.+-]+") ? media : "application/octet-stream");
            intent.putExtra(Intent.EXTRA_TITLE, filename);
            try { saveFile.launch(intent); }
            catch (android.content.ActivityNotFoundException ignored) {
                model.pendingDownload = null;
                new AlertDialog.Builder(this).setMessage("No file picker is available on this device.").setPositiveButton(android.R.string.ok, null).show();
            }
        });
    }

    private void details(String title, JSONObject item) {
        ScrollView scroll = new ScrollView(this);
        TextView body = new TextView(this);
        body.setPadding(dp(24), dp(12), dp(24), dp(12));
        body.setText(readable(item, 0));
        body.setTextColor(INK);
        body.setTextSize(16);
        body.setTextIsSelectable(true);
        scroll.addView(body);
        new AlertDialog.Builder(this).setTitle(title).setView(scroll).setPositiveButton(android.R.string.ok, null).show();
    }

    private void observation(JSONObject envelope) {
        JSONObject meta = envelope == null ? null : envelope.optJSONObject("meta");
        String observed = meta == null ? "" : meta.optString("observed_at", "");
        text(content, "Data reflects this Mac; iCloud delivery to other devices is not confirmed." + (observed.isEmpty() ? "" : "\nObserved: " + observed), 13, MUTED);
    }

    private void title(String title) { text(content, title, 28, INK).setTypeface(null, Typeface.BOLD); }
    private LinearLayout column() { LinearLayout view = new LinearLayout(this); view.setOrientation(LinearLayout.VERTICAL); return view; }
    private LinearLayout card(LinearLayout parent) {
        LinearLayout view = column();
        view.setPadding(dp(18), dp(12), dp(18), dp(12));
        GradientDrawable background = new GradientDrawable();
        background.setColor(Color.WHITE);
        background.setCornerRadius(dp(18));
        view.setBackground(background);
        LinearLayout.LayoutParams params = new LinearLayout.LayoutParams(-1, -2);
        params.topMargin = dp(14);
        parent.addView(view, params);
        return view;
    }
    private TextView text(LinearLayout parent, String value, int size, int color) {
        TextView view = new TextView(this);
        view.setText(value);
        view.setTextSize(size);
        view.setTextColor(color);
        view.setPadding(0, dp(8), 0, dp(8));
        parent.addView(view, new LinearLayout.LayoutParams(-1, -2));
        return view;
    }
    private Button button(LinearLayout parent, String label, Runnable action) {
        Button view = new Button(this);
        view.setText(label);
        view.setAllCaps(false);
        view.setTextColor(BLUE);
        view.setMinHeight(dp(48));
        view.setEnabled(!model.busy);
        view.setOnClickListener(ignored -> action.run());
        LinearLayout.LayoutParams params = new LinearLayout.LayoutParams(-1, -2);
        params.topMargin = dp(6);
        parent.addView(view, params);
        return view;
    }
    private void primary(LinearLayout parent, String label, Runnable action) {
        Button button = button(parent, label, action);
        button.setTextColor(Color.WHITE);
        button.setBackgroundTintList(android.content.res.ColorStateList.valueOf(BLUE));
    }
    private interface Edited { void accept(String value); }
    private EditText field(LinearLayout parent, String label, String hint, String value, int type, Edited edited) {
        TextView name = text(parent, label, 14, INK);
        EditText input = new EditText(this);
        input.setId(label.equals("Bridge address") ? R.id.bridge_address
                : label.equals("Client token") ? R.id.bridge_token : View.generateViewId());
        name.setLabelFor(input.getId());
        input.setContentDescription(label);
        input.setInputType(type);
        input.setSingleLine(true);
        input.setHint(hint);
        input.setText(value);
        input.setTextSize(16);
        input.setTextColor(INK);
        input.setMinHeight(dp(48));
        input.setEnabled(!model.busy);
        // Form state belongs to the ViewModel, never the saved activity Bundle.
        input.setSaveEnabled(false);
        input.addTextChangedListener(new TextWatcher() {
            @Override public void beforeTextChanged(CharSequence s, int start, int count, int after) { }
            @Override public void onTextChanged(CharSequence s, int start, int before, int count) { edited.accept(s.toString()); }
            @Override public void afterTextChanged(Editable value) { }
        });
        parent.addView(input, new LinearLayout.LayoutParams(-1, -2));
        return input;
    }
    private int dp(int value) { return Math.round(value * getResources().getDisplayMetrics().density); }
    private void hideKeyboard() {
        View focus = getCurrentFocus();
        if (focus != null) {
            InputMethodManager keyboard = (InputMethodManager) getSystemService(INPUT_METHOD_SERVICE);
            if (keyboard != null) keyboard.hideSoftInputFromWindow(focus.getWindowToken(), 0);
            focus.clearFocus();
        }
    }

    private static String prefix(String service) {
        for (int i = 0; i < SERVICES.length; i++) if (SERVICES[i].equals(service)) return PREFIXES[i];
        return "";
    }
    static String label(ReadOperation op) {
        switch (op) {
            case CALENDARS: return "Browse calendars";
            case EVENTS: return "Read events";
            case REMINDER_LISTS: return "Browse reminder lists";
            case REMINDERS: return "Read reminders";
            case CONTACTS: return "Search contacts";
            case DRIVE_ROOTS: return "Browse Drive folders";
            case DRIVE_LIST: return "Browse files";
            case DRIVE_SEARCH: return "Search files";
            case DRIVE_READ: return "Read a file";
            case NOTE_FOLDERS: return "Browse Notes folders";
            case NOTES_SEARCH: return "Search notes";
            case NOTES_READ: return "Read a note";
            case MESSAGE_CHATS: return "Browse conversations";
            case MESSAGES_SEARCH: return "Search messages";
            case MESSAGES_READ: return "Read a conversation";
            default: return "Read from Mac";
        }
    }
    private static String argumentLabel(String name) {
        switch (name) {
            case "calendar_id": return "Calendar";
            case "list_id": return "Reminder list";
            case "root_id": return "Drive folder";
            case "folder_id": return "Notes folder";
            case "chat_id": return "Conversation";
            case "note_id": return "Note identifier";
            case "query": return "Search";
            case "path": return "Path within the Drive folder";
            case "start": return "Start date and time";
            case "end": return "End date and time";
            case "completed": return "Completed reminders";
            case "max_bytes": return "Maximum file size in bytes";
            default: return name.replace('_', ' ');
        }
    }
    private static String hint(String name) {
        if (BridgeViewModel.selector(name) != null) return "Use Choose below, or enter an identifier";
        if (name.equals("start") || name.equals("end")) return "2026-10-18T09:00:00-07:00";
        if (name.equals("completed")) return "true or false; leave blank for both";
        if (name.equals("path")) return "Documents/example.txt";
        if (name.equals("note_id")) return "Find a note using Search notes first";
        return "";
    }
    private static String itemTitle(JSONObject item) {
        for (String key : new String[]{"name", "title", "display_name", "subject", "path", "id"}) {
            String value = item.optString(key, "");
            if (!value.isEmpty()) return value;
        }
        return "Item";
    }
    private static String preview(JSONObject item) {
        for (String key : new String[]{"summary", "start", "due", "email", "text", "body", "path"}) {
            String value = item.optString(key, "");
            if (!value.isEmpty()) return value.length() > 160 ? value.substring(0, 160) + "…" : value;
        }
        return "";
    }
    private static String readable(Object value, int depth) {
        if (value == null || value == JSONObject.NULL) return "—";
        if (depth > 5) return "…";
        if (value instanceof JSONObject) {
            StringBuilder out = new StringBuilder();
            JSONObject object = (JSONObject) value;
            Iterator<String> keys = object.keys();
            while (keys.hasNext()) {
                String key = keys.next();
                if (key.equals("content_base64")) continue;
                if (out.length() > 0) out.append("\n\n");
                out.append(key.replace('_', ' ')).append(": ").append(readable(object.opt(key), depth + 1));
            }
            return out.toString();
        }
        if (value instanceof JSONArray) {
            StringBuilder out = new StringBuilder();
            JSONArray array = (JSONArray) value;
            for (int i = 0; i < array.length(); i++) {
                if (i > 0) out.append("\n");
                out.append(readable(array.opt(i), depth + 1));
            }
            return out.toString();
        }
        return String.valueOf(value);
    }
}
